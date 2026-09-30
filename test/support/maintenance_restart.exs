# Runs in a separate BEAM with real application, HTTP, dispatch and durable state.
# Only the worker body and tracker are synthetic; no live project is accessed.
Code.compiler_options(ignore_module_conflict: true)

defmodule SymphonyElixir.AgentRunner do
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.Maintenance

  def run(issue, _recipient, opts) do
    WriteContext.with_context(%{issue_id: issue.id, phase: issue.state}, fn ->
      send(:persistent_term.get(:fixture_owner), {:started, issue.id, issue.state, self(), opts})

      receive do
        :finish ->
          :ok

        {:maintenance_interrupt, generation} ->
          true = Maintenance.interrupt_current?(generation)
          exit(:maintenance_interrupt)
      end
    end)
  end
end

Application.put_all_env(Config.Reader.read!("config/config.exs", env: :test))
Application.put_env(:symphony_elixir, :workflow_file_path, hd(System.argv()))
Application.put_env(:symphony_elixir, :linear_rate_limit_root, Path.join(Path.dirname(hd(System.argv())), "rate-limits"))
System.put_env("SYMPHONY_LINEAR_ENV_DIR", Path.join(Path.dirname(hd(System.argv())), ".symphony"))
:persistent_term.put(:fixture_owner, self())

alias SymphonyElixir.{HttpServer, Maintenance, MaintenanceRecovery, Orchestrator, Tracker, WorkerCapacity}
alias SymphonyElixir.Linear.Issue

defmodule Cycle do
  def state do
    Req.get!("http://127.0.0.1:#{SymphonyElixir.HttpServer.bound_port()}/api/v1/state").body
  end

  def wait(fun, attempts \\ 200)
  def wait(fun, 0), do: raise("condition not reached: #{inspect(fun.())}")

  def wait(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait(fun, attempts - 1)
        )
  end

  def started(id) do
    receive do
      {:started, ^id, state, pid, opts} -> {state, pid, opts}
    after
      5_000 -> raise("worker did not resume: #{id}")
    end
  end
end

{:ok, _} = Application.ensure_all_started(:symphony_elixir)
active = %Issue{id: "active", identifier: "PRO-1", title: "Existing run", state: "In Arbeit (AI)", assigned_to_worker: true}
new = %Issue{id: "new", identifier: "PRO-2", title: "New candidate", state: "Test (AI)", assigned_to_worker: true}
wake = %Issue{id: "wake", identifier: "PRO-3", title: "One-shot wake-up", state: "Review (AI)", assigned_to_worker: true}
terminal = %Issue{id: "terminal", identifier: "PRO-4", title: "Finished while draining", state: "Fertig", assigned_to_worker: true}

interrupted =
  Enum.with_index(["Todo (AI)", "Planung (AI)", "In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)"], 5)
  |> Enum.map(fn {phase, n} ->
    %Issue{id: "interrupted-#{n}", identifier: "PRO-#{n}", title: "Interrupted phase", state: phase, assigned_to_worker: true}
  end)

Application.put_env(:symphony_elixir, :memory_tracker_issues, [active | interrupted])
send(Orchestrator, :tick)
{_, active_pid, _} = Cycle.started(active.id)

interrupted_runs =
  Enum.map(interrupted, fn issue ->
    {phase, pid, _} = Cycle.started(issue.id)
    true = phase == issue.state
    {issue, pid, Process.monitor(pid)}
  end)

:sys.replace_state(Orchestrator, fn state ->
  running =
    Enum.reduce(interrupted, state.running, fn issue, acc ->
      Map.update!(acc, issue.id, &Map.put(&1, :codex_app_server_pid, "synthetic-child"))
    end)

  %{state | running: running}
end)

# The tracker stops offering the active candidate and exposes a new one instead.
Application.put_env(:symphony_elixir, :memory_tracker_issues, [active, new, wake, terminal] ++ interrupted)

{:ok, %{status: 200}} =
  Req.post("http://127.0.0.1:#{HttpServer.bound_port()}/api/v1/maintenance",
    json: %{"enabled" => true, "reason" => "Isolated update", "deadline_seconds" => 300}
  )

# A retry/wake-up is produced once and is never offered as a candidate after restart.
# Retain its attempt and review context through the real pause handler.
:sys.replace_state(Orchestrator, fn state ->
  hint = %{
    attempt: 2,
    identifier: wake.identifier,
    error: nil,
    review_stay: true,
    recovered_turn_context: %{thread_id: "same-thread"},
    retry_token: make_ref(),
    timer_ref: nil,
    due_at_ms: System.monotonic_time(:millisecond)
  }

  retries = state.retry_attempts |> Map.put(wake.id, hint) |> Map.put(terminal.id, %{hint | identifier: terminal.identifier})
  %{state | retry_attempts: retries}
end)

send(Orchestrator, :tick)
Cycle.wait(fn -> match?({:ok, %{"wake" => _}}, MaintenanceRecovery.load()) end)
false = Cycle.state()["maintenance"]["idle"]

:sys.replace_state(WorkerCapacity, fn state ->
  put_in(state.maintenance.deadline_ms, System.monotonic_time(:millisecond) - 1)
end)

send(Orchestrator, {:maintenance_deadline, Maintenance.status().generation})

Enum.each(interrupted_runs, fn {issue, pid, ref} ->
  receive do
    {:DOWN, ^ref, :process, ^pid, :maintenance_interrupt} -> :ok
  after
    2_000 -> raise("deadline did not stop #{issue.state}")
  end
end)

after_drain = [%{active | state: "Review"}, new, wake, terminal] ++ interrupted
Application.put_env(:symphony_elixir, :memory_tracker_issues, after_drain)
send(active_pid, :finish)
Cycle.wait(fn -> Cycle.state()["maintenance"]["idle"] == true end)
%{"running" => 0, "reserved" => 0} = Cycle.state()["counts"]
true = Maintenance.enabled?()
{:ok, hints} = MaintenanceRecovery.load()
2 = hints[wake.id].attempt
# The already running worker completed normally while dispatch stayed paused.
receive do
  {:started, id, _, _, _} -> raise("new work during maintenance: #{id}")
after
  0 -> :ok
end

:ok = Application.stop(:symphony_elixir)
nil = Process.whereis(Orchestrator)
nil = Process.whereis(WorkerCapacity)
# Override only candidate enumeration: the durable wake-up must use a fresh by-ID read.
Code.compiler_options(ignore_module_conflict: true)

defmodule SymphonyElixir.Tracker.Memory do
  def fetch_candidate_issues, do: {:ok, Enum.filter(all(), &(&1.id == "new"))}
  def fetch_issues_by_states(_), do: {:ok, []}
  def fetch_issue_states_by_ids(ids), do: {:ok, Enum.filter(all(), &(&1.id in ids))}
  def fetch_issue_comments(_), do: {:ok, []}
  def fetch_issue_comment_bodies(_), do: {:ok, []}
  def update_issue_state(_, _), do: :ok
  defp all, do: Application.get_env(:symphony_elixir, :memory_tracker_issues)
end

{:ok, _} = Application.ensure_all_started(:symphony_elixir)
false = Maintenance.enabled?()
{"Review (AI)", wake_pid, wake_opts} = Cycle.started(wake.id)
2 = wake_opts[:attempt]
%{thread_id: "same-thread"} = wake_opts[:recovered_turn_context]

resumed =
  Enum.map(interrupted, fn issue ->
    {phase, pid, _opts} = Cycle.started(issue.id)
    true = phase == issue.state
    pid
  end)

send(Orchestrator, :tick)
{"Test (AI)", new_pid, _} = Cycle.started(new.id)
# Duplicate old messages and repeated polls cannot start either issue a second time.
send(Orchestrator, {:retry_issue, wake.id, make_ref()})
send(Orchestrator, :tick)
Cycle.wait(fn -> map_size(:sys.get_state(Orchestrator).running) == 8 end)
{:ok, []} = Tracker.fetch_candidate_issues() |> then(fn {:ok, issues} -> {:ok, Enum.filter(issues, &(&1.id == "wake"))} end)
Cycle.wait(fn -> MaintenanceRecovery.load() == {:ok, %{}} end)

receive do
  {:started, id, _, _, _} -> raise("duplicate or terminal start: #{id}")
after
  100 -> :ok
end

send(wake_pid, :finish)
send(new_pid, :finish)
Enum.each(resumed, &send(&1, :finish))
:ok = Application.stop(:symphony_elixir)
IO.puts("maintenance-restart: complete, no loss, no duplicate")
