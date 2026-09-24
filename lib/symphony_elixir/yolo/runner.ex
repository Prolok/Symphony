defmodule SymphonyElixir.Yolo.Runner do
  @moduledoc "One PO turn for a frozen group, with member leases and durable completion evidence."
  require Logger
  alias SymphonyElixir.Codex.AppServer, as: AppServer
  alias SymphonyElixir.{CommentCheckpoint, Config, ProjectContext, RuntimePaths, Tracker}
  alias SymphonyElixir.Linear.{Client, IssueLease, YoloAgent}
  alias SymphonyElixir.Yolo.{Admission, BlockerBrake, Completion, Delivery, Dependencies}
  alias SymphonyElixir.Yolo.{Group, Impulse, Observation, OpenClaw, Operations}
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
         :ok <- checkout_available(group, record),
         {:ok, epoch} <- ReviewReadiness.epoch(group) do
      record = Map.put(record, "capture_epoch", epoch)
      run_id = Ecto.UUID.generate()
      callback = fn -> run_locked(group, issues, project_issues, run_id, record, opts) end
      result = with_members(Enum.sort_by(issues, & &1.id), callback, Keyword.get(opts, :lease, &IssueLease.run/2))
      record_result(group, run_id, result, issues)
    end
  end

  defp record_result(_group, _run_id, :ok, _issues), do: :ok

  defp record_result(group, run_id, {:error, reason} = result, issues) do
    member_context = Enum.map_join(issues, " ", &"issue_id=#{&1.id} issue_identifier=#{&1.identifier}")
    Logger.warning("YOLO group failed group=#{group} run_id=#{run_id} #{member_context} reason=#{inspect(reason)}")

    with {:ok, current} <- Store.read(group) do
      attempt = if(get_in(current, ["attempt", "id"]) == run_id, do: current["attempt"], else: %{})
      {count, delay} = retry_delay(group, current["nonstart"], attempt)

      update = %{
        "error" => inspect(reason),
        "retry_at" => System.system_time(:millisecond) + delay,
        "failure" => %{"group" => group, "run_id" => run_id, "reason" => inspect(reason), "checkout_cleanup" => attempt["checkout_cleanup"]}
      }

      update = if(count > 0, do: Map.put(update, "nonstart", %{"fingerprint" => attempt["fingerprint"], "members" => attempt["members"], "count" => count}), else: update)

      Logger.warning(
        "YOLO group retry group=#{group} run_id=#{run_id} #{member_context} reason=#{inspect(reason)} checkout_cleanup=#{inspect(attempt["checkout_cleanup"])} nonstart_count=#{count} retry_ms=#{delay}"
      )

      Store.write(group, Map.merge(current, update))
    end

    result
  end

  defp retry_delay("review", previous, %{"checkout_cleanup" => "removed"} = attempt) do
    previous = previous || %{}
    same? = previous["fingerprint"] == attempt["fingerprint"] and previous["members"] == attempt["members"]
    count = if(same?, do: previous["count"] + 1, else: 1)
    {count, min(30_000 * Integer.pow(2, min(count - 1, 5)), 900_000)}
  end

  defp retry_delay(_, _, _), do: {0, 30_000}

  defp checkout_available("review", %{"checkout_cleanup_blocked" => true}), do: {:error, :yolo_review_checkout_cleanup_unconfirmed}

  defp checkout_available("review", %{"attempt" => %{"cleanup_contract" => 1} = attempt} = record) do
    delivered? = Enum.any?(Map.values(record["deliveries"] || %{}), &(&1["run_id"] == attempt["id"]))

    if attempt["checkout_cleanup"] in ["none", "removed"] or is_binary(attempt["session_id"]) or delivered? or retired_attempt?(attempt),
      do: :ok,
      else: {:error, :yolo_review_checkout_cleanup_unconfirmed}
  end

  defp checkout_available(_, _), do: :ok

  defp retired_attempt?(attempt) do
    case Journal.read("review") do
      {:ok, %{"id" => id, "state" => "retired", "writable" => false, "retirement" => %{"kind" => "fenced_interruption", "attempt" => proof}}} ->
        id == attempt["id"] and proof == attempt

      _ ->
        false
    end
  end

  defp with_members([], callback, _lease), do: callback.()

  defp with_members([issue | rest], callback, lease) do
    lease.(issue, fn -> with_members(rest, callback, lease) end)
  end

  defp run_locked(group, issues, project_issues, run_id, record, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, fresh} <- fetch.(Enum.map(issues, & &1.id)),
         true <- Enum.sort(Enum.map(fresh, & &1.id)) == Enum.sort(Enum.map(issues, & &1.id)),
         {:ok, fresh} <- Dependencies.refresh(fresh, opts),
         true <- Enum.all?(fresh, &Dependencies.dispatchable?/1),
         true <- Enum.all?(fresh, &(Group.name(&1) == group and Admission.eligible?(&1) and not Admission.needed?(&1))),
         {:ok, project_issues} <- current_project(group, fresh, project_issues, opts),
         observation_issues = if(group == "review", do: Group.groups(project_issues)["review"] || [], else: fresh),
         {:ok, all_observations, fingerprint} <-
           Observation.capture(observation_issues, %{}, Keyword.put(opts, :impulse_generations, Impulse.generations(record))),
         observations = Map.take(all_observations, Enum.map(fresh, & &1.id)),
         record = Delivery.migrate(record, observations),
         {:ok, operations} <- Operations.pending(Enum.map(fresh, & &1.id)),
         pending = Delivery.pending(fresh, observations, if(operations == [], do: record, else: Map.put(record, "processed", nil))),
         {:ok, pending} <- if(group == "blocker", do: BlockerBrake.check(pending, opts), else: {:ok, pending}),
         true <- pending != [] do
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
    members = Enum.map(issues, & &1.id)
    attempt = %{"id" => run_id, "members" => members, "fingerprint" => fingerprint}
    reasons =
      Map.new(issues, fn issue ->
        reason = get_in(record, ["impulses", issue.id, "reason"])
        {issue.id, if(reason in [nil, "no_relevant_history", "no_relay_event"], do: "source_changed", else: reason)}
      end)

    resume_context = %{"previous_error" => record["error"] || record["previous_error"], "reason" => reasons}
    record = Map.merge(record, %{"previous_error" => resume_context["previous_error"], "resume_reason" => reasons})
    opts = Keyword.put(opts, :resume_context, resume_context)

    attempt =
      if group == "review",
        do: Map.merge(attempt, %{"cleanup_contract" => 1, "checkout_cleanup" => "creating"}),
        else: attempt

    state = {record, observations, fingerprint}

    with :ok <- reserve_attempt(group, record, observations, attempt),
         creation <- run_scoped(group, fn -> create.(group, run_id) end) do
      case creation do
        {:ok, workspace} ->
          record_created(group, issues, project_issues, run_id, state, opts, attempt, workspace)

        {:error, _} = error ->
          handle_create_error(group, run_id, error)
      end
    end
  end

  defp reserve_attempt("review", record, observations, attempt) do
    Store.write("review", Map.merge(record, %{"observations" => observations, "attempt" => attempt, "error" => nil}))
  end

  defp reserve_attempt(_, _, _, _), do: :ok

  defp record_created(group, issues, project_issues, run_id, {record, observations, fingerprint}, opts, attempt, workspace) do
    attempt = Map.merge(attempt, %{"workspace" => workspace.path, "sha" => workspace.sha})

    case Keyword.get(opts, :store_write, &Store.write/2).(group, Map.merge(record, %{"observations" => observations, "attempt" => attempt, "error" => nil})) do
      :ok -> run_created(group, issues, project_issues, run_id, workspace, {record, observations, fingerprint}, opts)
      {:error, _} = error -> cleanup_unrecorded(group, run_id, workspace, error)
    end
  end

  defp handle_create_error("review", run_id, {:error, reason} = error) do
    {status, blocked?} =
      if Workspace.review_checkout_present?(run_id) == {:ok, false},
        do: {"none", false},
        else: {"blocked", true}

    with {:ok, %{"attempt" => %{"id" => ^run_id} = attempt} = record} <- Store.read("review") do
      Store.write("review", Map.merge(record, %{"attempt" => Map.put(attempt, "checkout_cleanup", status), "checkout_cleanup_blocked" => blocked?}))
    end

    Logger.warning("YOLO review checkout creation failed group=review run_id=#{run_id} reason=#{inspect(reason)} checkout_cleanup=#{status}")
    error
  end

  defp handle_create_error(_, _, error), do: error

  defp run_created(group, issues, project_issues, run_id, workspace, {record, observations, fingerprint}, opts) do
    result =
      run_scoped(group, fn ->
        Scope.with_scope(
          group,
          issues,
          run_id,
          fn ->
            execute_session(group, issues, project_issues, workspace, run_id, {record, observations, fingerprint}, opts)
          end,
          workspace: workspace
        )
      end)

    cleanup_failed_start(group, run_id, issues, workspace, result)
  end

  defp run_scoped("review", callback) do
    callback.()
  rescue
    error -> {:error, {:yolo_review_start_exception, error.__struct__}}
  catch
    kind, reason -> {:error, {:yolo_review_start_caught, kind, inspect(reason)}}
  end

  defp run_scoped(_, callback), do: callback.()

  defp cleanup_unrecorded("review", run_id, workspace, error) do
    cleanup =
      if Workspace.owned_review?(workspace, run_id),
        do: Workspace.remove_review(workspace, run_id),
        else: {:error, :yolo_review_checkout_unsafe}

    status = if(cleanup == :ok, do: "removed", else: "blocked")

    with {:ok, %{"attempt" => %{"id" => ^run_id} = attempt} = record} <- Store.read("review") do
      attempt = Map.merge(attempt, %{"workspace" => workspace.path, "sha" => workspace.sha, "checkout_cleanup" => status})
      Store.write("review", Map.merge(record, %{"attempt" => attempt, "checkout_cleanup_blocked" => status == "blocked"}))
    end

    Logger.warning("YOLO review start journal failed group=review run_id=#{run_id} reason=#{inspect(error)} checkout_cleanup=#{status}")
    error
  end

  defp cleanup_unrecorded(_, _, _, error), do: error

  defp cleanup_failed_start("review", run_id, issues, workspace, {:error, reason} = result) do
    with true <- Workspace.owned_review?(workspace, run_id),
         {:ok, %{"attempt" => %{"id" => ^run_id} = attempt} = record} <- Store.read("review"),
         true <- is_nil(attempt["session_id"]) and (attempt["completed"] || %{}) == %{},
         false <- Enum.any?(Map.values(record["deliveries"] || %{}), &(&1["run_id"] == run_id)),
         :ok <- no_external_start(run_id),
         :ok <- Store.write("review", Map.merge(record, %{"attempt" => Map.put(attempt, "checkout_cleanup", "pending"), "checkout_cleanup_blocked" => true})),
         cleanup <- Workspace.remove_review(workspace, run_id) do
      status = if(cleanup == :ok, do: "removed", else: "blocked")
      member_context = Enum.map_join(issues, " ", &"issue_id=#{&1.id} issue_identifier=#{&1.identifier}")
      Logger.warning("YOLO review nonstart group=review run_id=#{run_id} #{member_context} reason=#{inspect(reason)} checkout_cleanup=#{status} workspace=#{workspace.path}")

      Store.write(
        "review",
        Map.merge(record, %{
          "attempt" => Map.put(attempt, "checkout_cleanup", status),
          "checkout_cleanup_blocked" => status == "blocked"
        })
      )
    else
      _ -> :ok
    end

    result
  end

  defp cleanup_failed_start(_, _, _, _, result), do: result

  defp no_external_start(run_id) do
    case Journal.read("review") do
      {:ok, nil} ->
        :ok

      {:ok, %{"id" => ^run_id, "state" => "rejected", "rejection" => proof} = order}
      when is_map(proof) ->
        if order["acceptance_observed"] != true and order["execution_observed"] != true, do: :ok, else: {:error, :yolo_review_delivery_uncertain}

      {:ok, %{"id" => other_id} = order} when other_id != run_id ->
        if Journal.pending?(order), do: {:error, :yolo_review_delivery_uncertain}, else: :ok

      _ ->
        {:error, :yolo_review_delivery_uncertain}
    end
  end

  defp execute_session(group, issues, project_issues, workspace, run_id, {record, observations, _fingerprint}, opts) do
    with {:ok, prompt} <- prompt(group, issues, project_issues, workspace, opts),
         :ok <- verify_start(group, issues, project_issues, workspace, opts),
         delivery_opts =
           Keyword.merge(opts,
             before_delivery: fn -> reserve_delivery(group, issues, run_id, observations, opts) end,
             delivery_rejected: fn -> release_delivery(group, issues, run_id) end
           ),
         {:ok, result} <- run_session(workspace, prompt, issues, run_id, delivery_opts),
         :ok <- session_ended(group, run_id, result),
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
          "decision_sources" => Map.merge(finished["decision_sources"] || %{}, Map.new(observations, fn {id, data} -> {id, data["source"]} end)),
          "decision_versions" => Map.merge(finished["decision_versions"] || %{}, Map.new(observations, fn {id, data} -> {id, data["member_semantic"]} end)),
          "observations" => observations,
          "processed_epoch" => record["capture_epoch"],
          "processed" => observations |> Map.take(Enum.map(retained, & &1.id)) |> Observation.fingerprint(),
          "attempt" => Map.put(finished["attempt"], "session_id", result.session_id),
          "error" => nil,
          "retry_at" => nil,
          "nonstart" => nil,
          "checkout_cleanup_blocked" => false
        })
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_group_incomplete_or_workspace_changed}
    end
  end

  defp reserve_delivery(group, issues, run_id, observations, opts) do
    with :ok <- Delivery.reserve(group, run_id, observations),
         :ok <- if(group == "blocker", do: BlockerBrake.reserve(issues, run_id, opts), else: :ok) do
      :ok
    else
      error ->
        Delivery.rejected(group, run_id)
        if group == "blocker", do: BlockerBrake.release(issues, run_id)
        error
    end
  end

  defp release_delivery(group, issues, run_id) do
    case Delivery.rejected(group, run_id) do
      :ok -> if(group == "blocker", do: BlockerBrake.release(issues, run_id), else: :ok)
      error -> error
    end
  end

  defp session_ended(group, run_id, result) do
    with {:ok, record} <- Store.read(group),
         %{"id" => ^run_id} = attempt <- record["attempt"] do
      record =
        record |> Map.put("attempt", Map.merge(attempt, %{"session_end" => true, "session_id" => result.session_id})) |> Map.update("delivery_ends", %{run_id => true}, &Map.put(&1, run_id, true))

      Store.write(group, record)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_attempt_unavailable}
    end
  end

  defp verify_start(group, issues, project_issues, workspace, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    # Fetch/checkpoints and checkout creation may take time. Keep all leases held
    # and recheck the exact frozen members immediately before starting Codex.
    with {:ok, _} <- current_project(group, issues, project_issues, opts),
         true <- Keyword.get(opts, :unchanged, &Workspace.unchanged?/1).(workspace),
         {:ok, fresh} <- fetch.(Enum.map(issues, & &1.id)),
         {:ok, fresh} <- Dependencies.refresh(fresh, opts),
         true <- Enum.sort_by(fresh, & &1.id) == Enum.sort_by(issues, & &1.id),
         true <- Enum.all?(fresh, &Dependencies.dispatchable?/1),
         true <- Enum.all?(fresh, &(Group.name(&1) == group and Admission.eligible?(&1) and not Admission.needed?(&1))) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_launch_changed}
    end
  end

  defp current_project("review", members, expected, opts) do
    fetch = Keyword.get(opts, :project, &Client.fetch_candidate_issues/0)

    with {:ok, issues} <- fetch.(),
         {:ok, issues} <- Dependencies.refresh(issues, opts),
         true <- review_chain_unchanged?(members, expected, issues) do
      {:ok, issues}
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_review_waiting}
    end
  end

  defp current_project(_, previous, _expected, _opts), do: {:ok, previous}

  defp review_chain_unchanged?(members, expected, current) do
    selected = MapSet.new(members, & &1.id)

    frozen =
      expected
      |> Dependencies.review_members()
      |> Dependencies.components()
      |> Enum.filter(fn chain -> Enum.any?(chain, &MapSet.member?(selected, &1.id)) end)
      |> List.flatten()

    MapSet.subset?(selected, MapSet.new(frozen, & &1.id)) and Dependencies.review_ready?(frozen, current)
  end

  defp run_session(workspace, prompt, [lead | _] = issues, run_id, opts) do
    Enum.each(issues, &Logger.info("YOLO group member issue_id=#{&1.id} issue_identifier=#{&1.identifier} run_id=#{run_id}"))

    on_message = fn message ->
      record_terminal_delivery(run_id, message)

      if recipient = opts[:recipient], do: send(recipient, {:yolo_event, Scope.current()["group"], Map.merge(message, %{workspace_path: workspace.path, worker_pid: self()})})
      if message[:session_id], do: Enum.each(issues, &Logger.info("YOLO member event issue_id=#{&1.id} issue_identifier=#{&1.identifier} run_id=#{run_id} session_id=#{message[:session_id]}"))
    end

    case Config.openclaw_yolo_agent() do
      nil ->
        with :ok <- opts[:before_delivery].(),
             do: Keyword.get(opts, :session, &AppServer.run/4).(workspace.path, prompt, lead, on_message: on_message, on_session_start_failure: opts[:delivery_rejected])

      _ ->
        OpenClaw.run(workspace, prompt, issues, run_id, opts)
    end
  end

  defp record_terminal_delivery(run_id, %{event: event, session_id: session_id} = message)
       when event in [:turn_failed, :turn_cancelled] and is_binary(session_id) do
    if is_nil(Config.openclaw_yolo_agent()) do
      group = Scope.current()["group"]

      case session_ended(group, run_id, message) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("YOLO terminal delivery evidence unavailable group=#{group} run_id=#{run_id} reason=#{inspect(reason)}")
      end
    end
  end

  defp record_terminal_delivery(_run_id, _message), do: :ok

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
        comment_inputs: inputs,
        resume_context: opts[:resume_context]
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
