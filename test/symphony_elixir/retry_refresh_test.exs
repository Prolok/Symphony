defmodule SymphonyElixir.RetryRefreshTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.RateLimit
  alias SymphonyElixir.{ProjectContext, ProjectPoller}

  defmodule CachedCandidates do
    use GenServer
    def start_link(issue), do: GenServer.start_link(__MODULE__, issue, name: ProjectPoller)
    @impl true
    def init(issue), do: {:ok, issue}
    @impl true
    def handle_call({:candidates, _id}, _from, issue), do: {:reply, {:ok, [issue]}, issue}
  end

  test "a cached candidate followed by a rate-limited dispatch refresh retains the visible retry and result" do
    root = Path.join([File.cwd!(), "_build", "retry-refresh-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    issue = %Issue{id: "retry-refresh", identifier: "PRO-704", title: "Resume review", state: "Review (AI)", labels: []}
    start_supervised!({CachedCandidates, issue})
    settings = Config.settings!()
    settings = put_in(settings.tracker.app["state_root"], root)
    settings = put_in(settings.tracker.app["client_id"], "retry-refresh-#{System.unique_integer([:positive])}")
    context = %ProjectContext{id: "project", root: File.cwd!(), settings: settings, env: %{}}
    retry_token = make_ref()

    retry = %{
      attempt: 2,
      retry_token: retry_token,
      identifier: issue.identifier,
      recovered_turn_context: "Findings: pending result",
      review_subagent_ids: MapSet.new(["child"]),
      review_subagent_call_ids: MapSet.new(["round-1"])
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, claimed: MapSet.new([issue.id]), retry_attempts: %{issue.id => retry}}

    ProjectContext.with_context(context, fn ->
      assert {:ok, %{status: 429}} =
               RateLimit.request(settings.tracker.app, fn -> {:ok, %{status: 429, headers: %{"retry-after" => "3600"}}} end)

      started = System.monotonic_time(:millisecond)
      assert {:noreply, updated} = Orchestrator.handle_info({:retry_issue, issue.id, retry_token}, state)
      assert updated.running == %{}
      assert MapSet.member?(updated.claimed, issue.id)
      retained = updated.retry_attempts[issue.id]
      assert retained.error =~ "dispatch refresh failed"
      assert retained.error =~ "linear_app_rate_limited"
      assert retained.due_at_ms >= started + 3_599_000
      assert retained.recovered_turn_context == retry.recovered_turn_context
      assert retained.review_subagent_ids == retry.review_subagent_ids
      assert retained.review_subagent_call_ids == retry.review_subagent_call_ids
      assert retained.attempt == 2
      assert retained.retry_token != retry_token
      assert {:noreply, ^updated} = Orchestrator.handle_info({:retry_issue, issue.id, retry_token}, updated)
      Process.cancel_timer(retained.timer_ref)

      # HTTP recovery is covered with a controlled clock in RateLimitTest.
      # Here switch the refreshed tracker to the local adapter to prove that
      # the preserved retry dispatches only once when refreshing works again.
      recovered_settings = %{
        settings
        | tracker: %{settings.tracker | kind: "memory"},
          workspace: %{settings.workspace | root: Path.join(root, "workspaces")},
          codex: %{settings.codex | command: "sleep 20"}
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      if is_nil(Process.whereis(SymphonyElixir.TaskSupervisor)) do
        start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
      end

      ProjectContext.with_context(%{context | settings: recovered_settings, root: root}, fn ->
        assert {:noreply, dispatched} = Orchestrator.handle_info({:retry_issue, issue.id, retained.retry_token}, updated)
        assert map_size(dispatched.running) == 1
        assert dispatched.retry_attempts == %{}
        assert {:noreply, ^dispatched} = Orchestrator.handle_info({:retry_issue, issue.id, retained.retry_token}, dispatched)
        Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, dispatched.running[issue.id].pid)
      end)
    end)
  end
end
