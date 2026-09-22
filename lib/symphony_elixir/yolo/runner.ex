defmodule SymphonyElixir.Yolo.Runner do
  @moduledoc "One PO turn for a frozen group, with member leases and durable completion evidence."
  require Logger
  alias SymphonyElixir.Codex.AppServer, as: AppServer
  alias SymphonyElixir.{CommentCheckpoint, Config, ProjectContext, RuntimePaths, Tracker}
  alias SymphonyElixir.Linear.{Client, IssueLease, YoloAgent}
  alias SymphonyElixir.Yolo.{Admission, Completion, Delivery, Dependencies, Group, Observation, OpenClaw, Operations}
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  alias SymphonyElixir.Yolo.{ReviewContract, ReviewReadiness, Scope, Store, Workspace}

  @spec run(String.t(), [map()], [map()], keyword()) :: term()
  def run(group, issues, project_issues, opts \\ []) do
    Store.lock(group, fn ->
      with :ok <- Journal.available(group), do: start_locked(group, issues, project_issues, opts)
    end)
  end

  defp start_locked(group, issues, project_issues, opts) do
    with :ok <- Delivery.reconcile(group),
         {:ok, record} <- Store.read(group),
         {:ok, epoch} <- ReviewReadiness.epoch(group) do
      record = Map.put(record, "capture_epoch", epoch)
      run_id = Ecto.UUID.generate()
      callback = fn -> run_locked(group, issues, project_issues, run_id, record, opts) end
      result = with_members(Enum.sort_by(issues, & &1.id), callback, Keyword.get(opts, :lease, &IssueLease.run/2))
      record_result(group, run_id, result)
    end
  end

  defp record_result(_group, _run_id, :ok), do: :ok

  defp record_result(group, run_id, {:error, reason} = result) do
    Logger.warning("YOLO group failed group=#{group} run_id=#{run_id} reason=#{inspect(reason)}")

    with {:ok, current} <- Store.read(group) do
      Store.write(group, Map.merge(current, %{"error" => inspect(reason), "retry_at" => System.system_time(:millisecond) + 30_000}))
    end

    result
  end

  defp with_members([], callback, _lease), do: callback.()

  defp with_members([issue | rest], callback, lease) do
    lease.(issue, fn -> with_members(rest, callback, lease) end)
  end

  defp run_locked(group, issues, _project_issues, run_id, record, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, fresh} <- fetch.(Enum.map(issues, & &1.id)),
         true <- Enum.sort(Enum.map(fresh, & &1.id)) == Enum.sort(Enum.map(issues, & &1.id)),
         {:ok, fresh} <- Dependencies.refresh(fresh, opts),
         true <- Enum.all?(fresh, &(&1.state != "Backlog" or Dependencies.unblocked?(&1))),
         true <- Enum.all?(fresh, &(Group.name(&1) == group and Admission.eligible?(&1) and not Admission.needed?(&1))),
         {:ok, observations, fingerprint} <- Observation.capture(fresh, %{}, opts),
         record = Delivery.migrate(record, observations),
         {:ok, operations} <- Operations.pending(Enum.map(fresh, & &1.id)),
         pending = Delivery.pending(fresh, observations, if(operations == [], do: record, else: Map.put(record, "processed", nil))),
         true <- pending != [],
         {:ok, project_issues} <- current_project(group, fresh, opts) do
      fresh = pending
      observations = Map.take(observations, Enum.map(fresh, & &1.id))
      execute(group, fresh, project_issues, run_id, record, observations, fingerprint, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_group_changed}
    end
  end

  defp execute(group, issues, project_issues, run_id, record, observations, fingerprint, opts) do
    create = Keyword.get(opts, :workspace, &Workspace.create/2)

    with {:ok, workspace} <- create.(group, run_id),
         attempt = %{"id" => run_id, "members" => Enum.map(issues, & &1.id), "fingerprint" => fingerprint, "workspace" => workspace.path, "sha" => workspace.sha},
         :ok <- Store.write(group, Map.merge(record, %{"observations" => observations, "attempt" => attempt, "error" => nil})) do
      Scope.with_scope(
        group,
        issues,
        run_id,
        fn ->
          execute_session(group, issues, project_issues, workspace, run_id, {record, observations, fingerprint}, opts)
        end,
        workspace: workspace
      )
    end
  end

  defp execute_session(group, issues, project_issues, workspace, run_id, {record, observations, _fingerprint}, opts) do
    with {:ok, prompt} <- prompt(group, issues, project_issues, workspace, opts),
         :ok <- verify_start(group, issues, workspace, opts),
         delivery_opts = Keyword.merge(opts, before_delivery: fn -> Delivery.reserve(group, run_id, observations) end, delivery_rejected: fn -> Delivery.rejected(group, run_id) end),
         {:ok, result} <- run_session(workspace, prompt, issues, run_id, delivery_opts),
         true <- Keyword.get(opts, :unchanged, &Workspace.unchanged?/1).(workspace),
         {:ok, retained} <- retained_members(issues, opts),
         :ok <- complete_inputs(retained, opts),
         :ok <- Completion.verify_operations(retained),
         true <- Completion.ready?(group, retained),
         {:ok, finished} <- Store.read(group) do
      # Only the frozen source is processed, never a post-turn observation.
      Store.write(
        group,
        Map.merge(finished, %{
          "decisions" => Map.merge(finished["decisions"] || %{}, Map.new(observations, fn {id, data} -> {id, data["semantic"]} end)),
          "observations" => observations,
          "processed_epoch" => record["capture_epoch"],
          "processed" => observations |> Map.take(Enum.map(retained, & &1.id)) |> Observation.fingerprint(),
          "attempt" => Map.put(finished["attempt"], "session_id", result.session_id),
          "error" => nil,
          "retry_at" => nil
        })
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_group_incomplete_or_workspace_changed}
    end
  end

  defp verify_start(group, issues, workspace, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    # Fetch/checkpoints and checkout creation may take time. Keep all leases held
    # and recheck the exact frozen members immediately before starting Codex.
    with {:ok, _} <- current_project(group, issues, opts),
         true <- Keyword.get(opts, :unchanged, &Workspace.unchanged?/1).(workspace),
         {:ok, fresh} <- fetch.(Enum.map(issues, & &1.id)),
         {:ok, fresh} <- Dependencies.refresh(fresh, opts),
         true <- Enum.sort_by(fresh, & &1.id) == Enum.sort_by(issues, & &1.id),
         true <- Enum.all?(fresh, &(&1.state != "Backlog" or Dependencies.unblocked?(&1))),
         true <- Enum.all?(fresh, &(Group.name(&1) == group and Admission.eligible?(&1) and not Admission.needed?(&1))) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_launch_changed}
    end
  end

  defp current_project("review", members, opts) do
    fetch = Keyword.get(opts, :project, &Client.fetch_candidate_issues/0)

    with {:ok, issues} <- fetch.(),
         {:ok, issues} <- Dependencies.refresh(issues, opts),
         true <- Dependencies.review_ready?(members, issues) do
      {:ok, issues}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_review_waiting}
    end
  end

  defp current_project(_, previous, _opts), do: {:ok, previous}

  defp run_session(workspace, prompt, [lead | _] = issues, run_id, opts) do
    Enum.each(issues, &Logger.info("YOLO group member issue_id=#{&1.id} issue_identifier=#{&1.identifier} run_id=#{run_id}"))

    on_message = fn message ->
      if recipient = opts[:recipient], do: send(recipient, {:yolo_event, Scope.current()["group"], Map.merge(message, %{workspace_path: workspace.path, worker_pid: self()})})
      if message[:session_id], do: Enum.each(issues, &Logger.info("YOLO member event issue_id=#{&1.id} issue_identifier=#{&1.identifier} run_id=#{run_id} session_id=#{message[:session_id]}"))
    end

    case Config.openclaw_yolo_agent() do
      nil ->
        with :ok <- opts[:before_delivery].(), do: Keyword.get(opts, :session, &AppServer.run/4).(workspace.path, prompt, lead, on_message: on_message)

      _ ->
        OpenClaw.run(workspace, prompt, issues, run_id, opts)
    end
  end

  defp retained_members(issues, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, current} <- fetch.(Enum.map(issues, & &1.id)),
         true <- Enum.sort(Enum.map(current, & &1.id)) == Enum.sort(Enum.map(issues, & &1.id)) do
      {:ok, Enum.filter(current, &Admission.eligible?/1)}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_group_incomplete}
    end
  end

  defp complete_inputs(issues, opts) do
    check = Keyword.get(opts, :before_action, &CommentCheckpoint.before_action/1)

    Enum.reduce_while(issues, :ok, fn issue, _ ->
      case check.(issue) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp prompt(group, issues, project_issues, workspace, opts) do
    path = Path.join(RuntimePaths.workflow_dir(), "WORKFLOW_YOLO_AGENT.md")
    checkpoint = Keyword.get(opts, :checkpoint, &CommentCheckpoint.checkpoint/1)

    with {:ok, operations} <- Operations.related(Enum.map(issues, & &1.id)),
         {:ok, template} <- File.read(path),
         {:ok, inputs} <- checkpoints(issues, checkpoint) do
      context = %{
        group: group,
        project: Map.take(ProjectContext.current(), [:id, :name, :root]),
        recorded_operations: Enum.map(operations, &Map.take(&1, ~w(request issue_id done closing))),
        agent_id: Config.yolo_agent_id(),
        linear_workspace_id: Config.settings!().tracker.app["workspace_id"],
        openclaw_agent_id: Config.openclaw_yolo_agent(),
        contract_version: 2,
        review_contract: Scope.current()["review_contract"],
        workflow_file: "WORKFLOW_YOLO_AGENT.md",
        workflow_sha256: OpenClaw.digest(template),
        run_id: Scope.current()["run_id"],
        human_handoff_id: Config.human_handoff_id(),
        yolo: Config.yolo?(),
        workspace: workspace.path,
        sha: workspace.sha,
        issues: Enum.map(issues, &issue_data/1),
        open_project_work: project_issues |> Enum.filter(&YoloAgent.delegated?/1) |> Enum.map(&issue_data/1),
        comment_inputs: inputs
      }

      {:ok, template <> "\n\nGebundener Laufkontext:\n" <> Jason.encode!(context, pretty: true) <> review_instructions(workspace)}
    end
  end

  defp review_instructions(workspace) do
    case ReviewContract.load(workspace, Scope.current()["run_id"]) do
      %{"content" => content} -> "\n\nVersionierte Projekt-Prüfanweisung (#{workspace.path}/.codex/skills/sym-yolo-review/SKILL.md):\n" <> content
      %{"error" => error} -> "\n\nKeine gültige Schlussabnahme möglich: #{error}. Ursache und Lösungsvorschlag im Workpad dokumentieren und eskalieren; das Ticket bleibt in Yolo Review."
    end
  end

  defp checkpoints(issues, checkpoint) do
    Enum.reduce_while(issues, {:ok, %{}}, fn issue, {:ok, acc} ->
      case checkpoint.(issue) do
        {:ok, inputs} -> {:cont, {:ok, Map.put(acc, issue.id, inputs)}}
        error -> {:halt, error}
      end
    end)
  end

  defp issue_data(issue), do: Map.take(issue, [:id, :identifier, :title, :description, :state, :assignee_id, :delegate_id, :team_id, :project_id, :labels, :blocked_by])
end
