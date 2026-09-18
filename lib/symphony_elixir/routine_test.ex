defmodule SymphonyElixir.RoutineTest do
  @moduledoc "Runs journaled dummy fixtures through the existing service and project workers."
  alias SymphonyElixir.{CommentCheckpoint, Config, Orchestrator, PathSafety, ProjectContext, ProjectPoller, Projects}
  alias SymphonyElixir.Linear.{CommentMutations, DurableState, WriteContext}
  alias SymphonyElixir.{RuntimePaths, TestExecutor, TestRun}

  @phases ["In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)"]

  @spec run(map(), [ProjectContext.t()], map(), map() | nil, pid()) :: map()
  def run(job, contexts, config, runtime, _owner) do
    target = Enum.find(contexts, &(&1.name == "symphony-test"))
    result = failed(job, "preflight_or_runtime_failed") |> Map.put("runtime", %{"source" => runtime, "pid" => System.pid()})
    plan = %{"instance" => "routine", "evidence" => "live", "run_id" => job["request"]["run_id"], "source" => result["source"], "scenario" => job["request"]["scenario"]}
    directory = job["directory"]

    with :ok <- authorize(job, contexts),
         :ok <- TestExecutor.verify_target(target, config),
         :ok <- prepare_plan(job, plan, runtime),
         :ok <- control(directory, false) do
      execute(job, target, plan, config, result)
    else
      {:error, reason} -> Map.put(result, "error", error_code(reason))
    end
  rescue
    _ -> failed(job, "preflight_or_runtime_failed")
  end

  defp authorize(job, contexts) do
    request = job["request"]
    matches = Enum.filter(contexts, &(Path.join(&1.settings.workspace.root, request["identifier"]) == request["checkout"]))

    case matches do
      [context] -> authorize_current_context(context, request)
      _ -> {:error, :test_owner_mismatch}
    end
  end

  defp authorize_current_context(context, request) do
    with %ProjectContext{} = current <- ProjectPoller.context(context),
         true <- Path.join(current.settings.workspace.root, request["identifier"]) == request["checkout"] do
      ProjectContext.with_context(current, fn -> authorize_context(request) end)
    else
      _ -> {:error, :test_owner_mismatch}
    end
  catch
    :exit, _ -> {:error, :runtime_unavailable}
  end

  defp authorize_context(request) do
    WriteContext.with_context(%{issue_id: request["issue_id"]}, fn ->
      with {:ok, issue} <- CommentCheckpoint.bound_issue(request["issue_id"]),
           true <- issue.identifier == request["identifier"] and issue.state in @phases do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :test_owner_mismatch}
      end
    end)
  end

  defp prepare_plan(job, plan, runtime) do
    path = Path.join(job["directory"], "plan.json")

    cond do
      job["cleanup"] ->
        case DurableState.read(path) do
          {:ok, ^plan} -> :ok
          {:error, :enoent} -> DurableState.write(path, plan)
          _ -> {:error, :test_plan_identity_mismatch}
        end

      not is_map(runtime) or Map.take(runtime, ~w(sha source_sha256)) != Map.take(plan["source"], ~w(sha source_sha256)) ->
        {:error, :runtime_source_mismatch}

      true ->
        DurableState.write(path, plan)
    end
  end

  defp execute(job, target, plan, config, result) do
    directory = job["directory"]
    original = source(target.root)

    outcome = run_scenario(job, target, plan, config)
    cleaned = with :ok <- control(directory, false), do: cleanup(target, plan, directory)
    preserved = original != nil and source(target.root) == original
    assemble_result(result, job, plan, outcome, cleaned, preserved)
  end

  defp run_scenario(%{"cleanup" => true}, _target, _plan, _config), do: {:error, :cleanup_only}

  defp run_scenario(job, target, plan, config) do
    deadline = System.monotonic_time(:millisecond) + config["timeout"] * 1_000

    with {:ok, _} <- stage(target, plan, job["directory"], "prepare"),
         :ok <- control(job["directory"], true) do
      run_prepared(job, target, plan, deadline)
    end
  rescue
    _ -> {:error, :preflight_or_runtime_failed}
  catch
    :exit, _ -> {:error, :runtime_unavailable}
  end

  defp run_prepared(_job, _target, %{"scenario" => "failure-probe"}, _deadline),
    do: {:error, :intentional_failure_probe}

  defp run_prepared(job, target, plan, deadline), do: await_fixture(job, target, plan, deadline, %{})

  defp assemble_result(result, job, plan, outcome, cleaned, preserved) do
    success = match?({:ok, _}, outcome) and match?({:ok, _}, cleaned) and preserved and not job["cleanup"]
    fixtures = cleaned_fixtures(cleaned)
    sessions = outcome_sessions(outcome)
    error = outcome_error(outcome)

    Map.merge(result, %{
      "status" => if(success, do: "passed", else: "failed"),
      "cleanup" => match?({:ok, _}, cleaned),
      "main_preserved" => true,
      "originals_preserved" => preserved,
      "error" => error,
      "cleanup_error" => if(match?({:ok, _}, cleaned), do: nil, else: "cleanup_unconfirmed_journal_retained"),
      "sessions" => sessions,
      "fixtures" => Enum.map(fixtures || [], &Map.take(&1, ~w(id identifier complete deleted observed_state merge))),
      "scenarios" => %{plan["scenario"] => %{"passed" => success, "sessions" => sessions}, "readiness" => %{"passed" => true}}
    })
  end

  defp cleaned_fixtures({:ok, journal}), do: journal["fixtures"]
  defp cleaned_fixtures(_), do: []
  defp outcome_sessions({:ok, sessions}), do: sessions
  defp outcome_sessions(_), do: %{}
  defp outcome_error({:error, reason}), do: error_code(reason)
  defp outcome_error(_), do: nil

  defp stage(target, plan, directory, operation) do
    TestRun.with_routine(target, plan, directory, operation, fn -> TestRun.execute(operation) end)
  end

  defp await_fixture(job, target, plan, deadline, sessions) do
    cond do
      cancelled?(job["directory"]) ->
        {:error, :cancelled}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        probe_fixture(job, target, plan, deadline, sessions)
    end
  end

  defp probe_fixture(job, target, plan, deadline, sessions) do
    task = Task.Supervisor.async_nolink(SymphonyElixir.TaskSupervisor, fn -> probe_snapshot(job, target, plan) end)

    result =
      try do
        await_probe(task, job["directory"], deadline)
      after
        Task.shutdown(task, :brutal_kill)
      end

    with {:ok, {journal, snapshot}} <- result do
      inspect_probe(job, target, plan, deadline, sessions, journal, snapshot)
    end
  end

  defp probe_snapshot(job, target, plan) do
    with {:ok, journal} <- stage(target, plan, job["directory"], "probe"),
         snapshot when is_map(snapshot) <- Orchestrator.snapshot(Projects.server(target), 5_000) do
      {:ok, {journal, snapshot}}
    else
      {:error, _} = error -> error
      _ -> {:error, :runtime_unavailable}
    end
  end

  defp await_probe(task, directory, deadline) do
    with :ok <- continue_run(directory, deadline) do
      result = Task.yield(task, min(50, max(0, deadline - System.monotonic_time(:millisecond))))
      probe_reply(result, task, directory, deadline)
    end
  end

  defp probe_reply({:ok, result}, _task, directory, deadline), do: with(:ok <- continue_run(directory, deadline), do: result)
  defp probe_reply({:exit, _}, _task, _directory, _deadline), do: {:error, :runtime_unavailable}
  defp probe_reply(nil, task, directory, deadline), do: await_probe(task, directory, deadline)

  defp continue_run(directory, deadline) do
    cond do
      cancelled?(directory) -> {:error, :cancelled}
      System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
      true -> :ok
    end
  end

  defp inspect_probe(job, target, plan, deadline, sessions, journal, snapshot) do
    ids = Enum.map(journal["fixtures"], & &1["id"])
    sessions = live_sessions(snapshot.running, ids, sessions)
    sessions = recorded_sessions(job["directory"], ids, sessions)

    if Enum.all?(journal["fixtures"], &(&1["complete"] == true)) and map_size(sessions) == length(ids) do
      with :ok <- continue_run(job["directory"], deadline), do: {:ok, sessions}
    else
      wait_fixture(job, target, plan, deadline, sessions)
    end
  end

  defp live_sessions(running, ids, sessions) do
    Enum.reduce(running, sessions, fn entry, acc ->
      if entry.issue_id in ids and is_binary(entry.session_id), do: Map.put(acc, entry.issue_id, entry.session_id), else: acc
    end)
  end

  defp wait_fixture(job, target, plan, deadline, sessions) do
    receive do
      :cancel_test -> {:error, :cancelled}
    after
      500 -> await_fixture(job, target, plan, deadline, sessions)
    end
  end

  defp cancelled?(directory) do
    receive do
      :cancel_test -> true
    after
      0 -> File.exists?(Path.join(directory, "cancel.json"))
    end
  end

  defp cleanup(target, plan, directory) do
    case TestRun.routine_journal(target, plan, directory) do
      {:ok, %{"fixtures" => fixtures}} ->
        with :ok <- stop_fixtures(target, fixtures) do
          stage(target, plan, directory, "cleanup")
        end

      _ ->
        {:error, :test_journal_identity_mismatch}
    end
  end

  defp stop_fixtures(target, fixtures) do
    fixtures
    |> Enum.reject(&(&1["deleted"] == true))
    |> Enum.reduce_while(:ok, fn fixture, :ok ->
      case GenServer.call(Projects.server(target), {:stop_test_fixture, fixture["id"]}, 15_000) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  catch
    :exit, _ -> {:error, :runtime_unavailable}
  end

  @spec failed(map(), String.t()) :: map()
  def failed(job, reason) do
    request = job["request"]

    %{
      "evidence" => "live",
      "run_id" => request["run_id"],
      "source" => %{"checkout" => request["checkout"], "sha" => request["head_sha"], "source_sha256" => request["source_sha256"]},
      "status" => "failed",
      "cleanup" => false,
      "error" => reason
    }
  end

  defp error_code(reason)
       when reason in [
              :runtime_source_mismatch,
              :test_owner_mismatch,
              :test_plan_identity_mismatch,
              :routine_test_project_binding_rejected,
              :intentional_failure_probe,
              :timeout,
              :cancelled,
              :cleanup_only,
              :runtime_unavailable
            ],
       do: Atom.to_string(reason)

  defp error_code(:comment_issue_outside_active_scope), do: "test_owner_mismatch"
  defp error_code({:linear_api_status, _, %{classification: "auth"}}), do: "linear_access_denied"
  defp error_code({:linear_api_status, _, %{classification: "rate_limited"}}), do: "linear_rate_limited"
  defp error_code({:linear_api_request, reason}) when reason in [:linear_app_identity_denied, :linear_app_credentials_denied], do: "linear_access_denied"
  defp error_code({:linear_api_request, {:linear_app_rate_limited, _}}), do: "linear_rate_limited"
  defp error_code(_), do: "preflight_or_runtime_failed"

  defp control(directory, active), do: DurableState.write(Path.join(directory, "control.json"), %{"active" => active})

  @spec manages_project?() :: boolean()
  def manages_project? do
    Config.test_executor() != nil and match?(%ProjectContext{name: "symphony-test"}, ProjectContext.current())
  end

  defp target?, do: manages_project?()

  defp fixture(id) do
    root = Config.test_executor()["result_root"]

    Path.wildcard(Path.join(root, "*/*/fixtures.json"))
    |> Enum.find_value(fn path ->
      with {:ok, ^path} <- PathSafety.canonicalize(path),
           {:ok, plan} <- DurableState.read(Path.join(Path.dirname(path), "plan.json")),
           {:ok, %{"fixtures" => fixtures}} <- TestRun.routine_journal(ProjectContext.current(), plan, Path.dirname(path)),
           %{} = fixture <- Enum.find(fixtures, &(&1["id"] == id and &1["deleted"] == false)) do
        {Path.dirname(path), fixture}
      else
        _ -> nil
      end
    end)
  end

  @spec owns?(String.t()) :: boolean()
  def owns?(id), do: target?() and fixture(id) != nil

  @spec prepare_description_updates(map()) :: :ok | {:error, term()}
  def prepare_description_updates(payload) do
    if Config.test_executor() do
      context = ProjectContext.current() || helper_context()
      ProjectContext.with_context(context, fn -> prepare_bound_descriptions(payload) end)
    else
      :ok
    end
  end

  defp helper_context do
    root = ProjectContext.env("SYMPHONY_PROJECT_ROOT") || RuntimePaths.project_root()
    %ProjectContext{id: root, root: root, name: Path.basename(root), settings: Config.settings!()}
  end

  defp prepare_bound_descriptions(payload) do
    if target?(), do: collect_description_updates(payload), else: :ok
  end

  defp collect_description_updates(payload) do
    with {:ok, updates} <- CommentMutations.description_updates(payload),
         true <- Enum.uniq_by(updates, & &1["id"]) == updates do
      Enum.reduce_while(updates, :ok, &record_description_update/2)
    else
      {:error, _} = error -> error
      _ -> {:error, :duplicate_fixture_description_update}
    end
  end

  defp record_description_update(update, :ok) do
    case record_description_update(update) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp record_description_update(update) do
    writer = WriteContext.current()
    id = update["id"]

    case fixture(writer["issue_id"]) do
      {directory, %{"id" => fixture_id, "identifier" => identifier}} when id in [fixture_id, identifier] ->
        persist_description(directory, fixture_id, update["description"], writer)

      _ ->
        :ok
    end
  end

  defp persist_description(directory, fixture_id, description, writer) do
    with true <- writer["phase"] in ["Todo (AI)", "Planung (AI)"],
         {:ok, %{"active" => true}} <- DurableState.read(Path.join(directory, "control.json")),
         {:ok, plan} <- DurableState.read(Path.join(directory, "plan.json")) do
      TestRun.with_routine(ProjectContext.current(), plan, directory, "probe", fn ->
        TestRun.record_description_intent(fixture_id, description, writer)
      end)
    else
      _ -> {:error, :test_description_update_unbound}
    end
  end

  @spec start_allowed?(map()) :: boolean()
  def start_allowed?(issue) do
    if target?() do
      with {directory, _} <- fixture(issue.id),
           true <- TestExecutor.active?(directory),
           {:ok, %{"active" => true}} <- DurableState.read(Path.join(directory, "control.json")),
           {:ok, plan} <- DurableState.read(Path.join(directory, "plan.json")) do
        plan["scenario"] == "workflow" or (plan["scenario"] == "bootstrap" and issue.state == "Todo (AI)")
      else
        _ -> false
      end
    else
      true
    end
  end

  @spec record_workspace(Path.t(), map(), boolean()) :: :ok | {:error, term()}
  def record_workspace(path, issue, created?) do
    if target?() and created? do
      with {directory, _} <- fixture(issue.issue_id),
           {:ok, plan} <- DurableState.read(Path.join(directory, "plan.json")) do
        record_bound_workspace(ProjectContext.current(), plan, directory, path, issue)
      else
        _ -> {:error, :test_workspace_base_unconfirmed}
      end
    else
      :ok
    end
  end

  defp record_bound_workspace(context, plan, directory, path, issue) do
    TestRun.with_routine(context, plan, directory, "run", fn -> TestRun.record_workspace(path, issue, true) end)
  end

  @spec record_session(String.t(), String.t() | nil) :: :ok
  def record_session(id, session_id) do
    if target?() and is_binary(session_id) do
      case fixture(id) do
        {directory, _} -> DurableState.write(Path.join([directory, "sessions", id <> ".json"]), %{"session_id" => session_id})
        _ -> :ok
      end
    end

    :ok
  end

  defp recorded_sessions(directory, ids, sessions) do
    Enum.reduce(ids, sessions, fn id, acc ->
      case DurableState.read(Path.join([directory, "sessions", id <> ".json"])) do
        {:ok, %{"session_id" => session}} when is_binary(session) -> Map.put(acc, id, session)
        _ -> acc
      end
    end)
  end

  @spec merge_evidence(String.t()) :: map() | nil
  def merge_evidence(identifier) do
    context = ProjectContext.current()

    with {origin, 0} <- System.cmd("git", ["remote", "get-url", "origin"], cd: context.root, env: Config.without_linear_secret([])),
         {json, 0} <-
           System.cmd("gh", ["pr", "list", "--repo", String.trim(origin), "--head", "symphony/" <> identifier, "--state", "merged", "--limit", "2", "--json", "state,mergeCommit,url,headRefOid"],
             cd: context.root,
             env: Config.without_linear_secret([]),
             stderr_to_stdout: true
           ),
         {:ok, [%{"state" => "MERGED", "mergeCommit" => %{"oid" => sha}, "headRefOid" => head, "url" => url}]} <- Jason.decode(json),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
         true <- is_binary(head) and Regex.match?(~r/\A[0-9a-f]{40}\z/, head),
         true <- is_binary(url) and String.starts_with?(url, "https://") do
      %{"state" => "MERGED", "commit" => sha, "head" => head, "url" => url}
    else
      _ -> nil
    end
  end

  defp source(root) do
    case System.cmd("python3", [Path.join(SymphonyElixir.RuntimePaths.workflow_dir(), "scripts/test-instance.py"), "source", root], env: Config.without_linear_secret([]), stderr_to_stdout: true) do
      {json, 0} ->
        case Jason.decode(json) do
          {:ok, value} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
