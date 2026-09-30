defmodule SymphonyElixir.ProjectSnapshotLinearTest do
  use SymphonyElixir.TestSupport
  import Phoenix.ConnTest
  alias SymphonyElixir.{ProjectContext, Projects}
  @endpoint SymphonyElixirWeb.Endpoint

  test "HTTP and aggregate readers stay available during a Linear block longer than ten seconds" do
    SymphonyElixir.TestSupport.isolate_application_orchestrator()
    start_supervised!({Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry})
    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 60_000, poll_idle_shutdown_ms: 0)
    {:ok, workflow} = Workflow.current()
    settings = Config.settings!()
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _headers ->
      query = payload[:query] || payload["query"]

      cond do
        String.contains?(query, "SymphonyHumanAssignees") ->
          users = %{"nodes" => [%{"id" => "human", "email" => "dev@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false}}
          {:ok, %{status: 200, body: %{"data" => %{"users" => users}}}}

        String.contains?(query, "SymphonyLinearPoll") ->
          send(parent, {:linear_entered, self(), query, System.monotonic_time(:millisecond)})

          receive do
            :release_linear -> {:error, :synthetic_timeout}
          end

        true ->
          flunk("unexpected query #{query}")
      end
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)

    contexts =
      for name <- ["Blocked", "Healthy"] do
        %ProjectContext{
          id: name,
          name: name,
          root: Path.dirname(Workflow.workflow_file_path()),
          workflow_path: Workflow.workflow_file_path(),
          workflow: workflow,
          settings: settings,
          env: System.get_env(),
          assignee_ids: ["human"]
        }
      end

    for context <- contexts do
      start_supervised!(Supervisor.child_spec({Orchestrator, name: Projects.server(context), context: context, initial_poll?: false}, id: context.id))
    end

    start_supervised!({Projects, contexts: contexts})
    original = Application.get_env(:symphony_elixir, @endpoint, [])
    Application.put_env(:symphony_elixir, @endpoint, Keyword.merge(original, server: false, secret_key_base: String.duplicate("s", 64), orchestrator: Orchestrator, snapshot_timeout_ms: 15_000))
    on_exit(fn -> Application.put_env(:symphony_elixir, @endpoint, original) end)
    start_supervised!({@endpoint, []})
    initial = await_snapshot(fn snapshot -> not snapshot.partial end)
    initial_blocked = hd(initial.project_statuses)
    blocked = GenServer.whereis(Projects.server(hd(contexts)))
    send(blocked, :run_poll_cycle)
    assert_receive {:linear_entered, ^blocked, query, entered}, 2_000
    assert query =~ "SymphonyLinearPoll"
    healthy = GenServer.whereis(Projects.server(List.last(contexts)))
    :sys.replace_state(healthy, fn state -> %{state | codex_totals: %{state.codex_totals | input_tokens: 99}} end)
    Process.sleep(10_050)
    updated = await_snapshot(&(&1.codex_totals.input_tokens == 99))
    assert List.last(updated.project_statuses).observed_at != List.last(initial.project_statuses).observed_at

    tasks =
      for _ <- 1..20 do
        Task.async(fn ->
          started = System.monotonic_time(:millisecond)
          snapshot = Orchestrator.snapshot()
          payload = get(build_conn(), "/api/v1/state") |> json_response(200)
          {snapshot, payload, System.monotonic_time(:millisecond) - started}
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 2_000))

    for {snapshot, payload, elapsed} <- results do
      assert elapsed < 2_000
      refute Map.has_key?(payload, "error")
      refute payload["partial"]
      assert snapshot.codex_totals.input_tokens == 99
      [blocked_status, healthy_status] = payload["project_statuses"]
      assert blocked_status["status"] == "stale"
      assert blocked_status["observed_at"] == initial_blocked.observed_at
      assert blocked_status["age_ms"] >= 10_000
      assert healthy_status["status"] == "fresh"
    end

    assert System.monotonic_time(:millisecond) - entered > 10_000
    {:messages, messages} = Process.info(blocked, :messages)
    assert Enum.count(messages, &match?({:"$gen_call", _, :snapshot}, &1)) == 1
    IO.puts("PRO-924 after: Blocked SymphonyLinearPoll 20 parallel HTTP/aggregate readers max_elapsed_ms=#{Enum.max(Enum.map(results, &elem(&1, 2)))} age_ms=#{hd(updated.project_statuses).age_ms}")
    send(blocked, :release_linear)
    assert is_map(GenServer.call(blocked, :snapshot))
  end

  defp await_snapshot(predicate, attempts \\ 200)
  defp await_snapshot(_predicate, 0), do: flunk("snapshot did not converge")

  defp await_snapshot(predicate, attempts) do
    snapshot = Orchestrator.snapshot()

    if predicate.(snapshot),
      do: snapshot,
      else:
        (
          Process.sleep(10)
          await_snapshot(predicate, attempts - 1)
        )
  end
end
