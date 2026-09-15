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
    def handle_call({:candidates, _id}, _from, issue), do: {:reply, {:ok, List.wrap(issue)}, issue}
  end

  for cache <- [:stale, :missing] do
    test "normal merge completion cleans up with #{cache} candidates" do
      {context, issue, workspace, state} = completion_fixture(unquote(cache))

      ProjectContext.with_context(context, fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Review"}])
        completed = finish_worker(state, issue)
        assert File.dir?(workspace)
        assert completed.completed_states[issue.id] == "merge (ai)"
        retry = completed.retry_attempts[issue.id]
        assert {:noreply, cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, retry.retry_token}, completed)
        refute File.exists?(workspace)
        refute MapSet.member?(cleaned.claimed, issue.id)
        assert cleaned.retry_attempts == %{}
        assert {:noreply, ^cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, retry.retry_token}, cleaned)
      end)
    end
  end

  for cache <- [:stale, :missing] do
    test "failed merge worker resolves deferred cleanup with #{cache} candidates" do
      {context, issue, workspace, state} = completion_fixture(unquote(cache))

      ProjectContext.with_context(context, fn ->
        terminal = %{issue | state: "Review"}
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [terminal])
        reconciled = Orchestrator.reconcile_issue_states_for_test([terminal], state)
        assert File.dir?(workspace)
        assert {:noreply, failed} = Orchestrator.handle_info({:DOWN, state.running[issue.id].ref, :process, self(), :shutdown}, reconciled)
        refute Map.has_key?(failed.completed_states, issue.id)
        assert File.dir?(workspace)
        retry = failed.retry_attempts[issue.id]
        Process.cancel_timer(retry.timer_ref)
        assert {:noreply, cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, retry.retry_token}, failed)
        refute File.exists?(workspace)
        refute MapSet.member?(cleaned.claimed, issue.id)
        assert cleaned.retry_attempts == %{}
      end)
    end
  end

  test "missing live issue retains completion until authoritative recovery" do
    {context, issue, workspace, state} = completion_fixture(:missing)

    ProjectContext.with_context(context, fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      completed = finish_worker(state, issue)
      retry = completed.retry_attempts[issue.id]
      assert {:noreply, pending} = Orchestrator.handle_info({:retry_issue, issue.id, retry.retry_token}, completed)
      assert MapSet.member?(pending.claimed, issue.id)
      assert File.dir?(workspace)
      retained = pending.retry_attempts[issue.id]
      assert retained.attempt == 2
      assert retained.worker_host == retry.worker_host
      assert retained.workspace_path == workspace
      assert retained.recovered_turn_context == retry.recovered_turn_context
      assert retained.review_subagent_call_ids == retry.review_subagent_call_ids
      assert retained.review_subagent_ids == retry.review_subagent_ids
      assert retained.retry_token != retry.retry_token
      Process.cancel_timer(retained.timer_ref)
      assert {:noreply, ^pending} = Orchestrator.handle_info({:retry_issue, issue.id, retry.retry_token}, pending)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Review"}])
      assert {:noreply, cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, retained.retry_token}, pending)
      refute File.exists?(workspace)
      refute MapSet.member?(cleaned.claimed, issue.id)
    end)
  end

  test "reconciliation preserves merge post-turn work and exit draining before terminal cleanup" do
    {context, issue, workspace, state} = completion_fixture(:stale)

    ProjectContext.with_context(context, fn ->
      terminal = %{issue | state: "Review"}
      reconciled = Orchestrator.reconcile_issue_states_for_test([terminal], state)
      assert File.dir?(workspace)
      assert Map.has_key?(reconciled.running, issue.id)
      assert MapSet.member?(reconciled.claimed, issue.id)
      assert {:noreply, draining} = Orchestrator.handle_info({:DOWN, state.running[issue.id].ref, :process, self(), :normal}, reconciled)
      Process.cancel_timer(draining.running[issue.id].exit_finalize_timer_ref)
      assert Orchestrator.reconcile_issue_states_for_test([terminal], draining).running == draining.running
      assert File.dir?(workspace)
    end)
  end

  for next_state <- ["Merge (AI)", "Freigabe Implementierung", "Freigabe Review"] do
    test "completion preserves workspace in #{next_state}" do
      {context, issue, workspace, state} = completion_fixture(:missing)

      ProjectContext.with_context(context, fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: unquote(next_state)}])
        completed = finish_worker(state, issue)
        assert {:noreply, released} = Orchestrator.handle_info({:retry_issue, issue.id, completed.retry_attempts[issue.id].retry_token}, completed)
        assert File.dir?(workspace)
        refute MapSet.member?(released.claimed, issue.id)
        assert released.running == %{}
        assert released.retry_attempts == %{}
      end)
    end
  end

  test "completion retains active follow-up while waiting for capacity" do
    {context, issue, workspace, state} = completion_fixture(:missing)

    ProjectContext.with_context(context, fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Test (AI)"}])
      completed = finish_worker(%{state | max_concurrent_agents: 0}, issue)
      assert {:noreply, waiting} = Orchestrator.handle_info({:retry_issue, issue.id, completed.retry_attempts[issue.id].retry_token}, completed)
      assert File.dir?(workspace)
      assert MapSet.member?(waiting.claimed, issue.id)
      assert waiting.retry_attempts[issue.id].error == "no available orchestrator slots"
      Process.cancel_timer(waiting.retry_attempts[issue.id].timer_ref)
    end)
  end

  for owner <- [:local, :other] do
    test "fresh completion follow-up respects #{owner} relay ownership" do
      {context, issue, workspace, state} = completion_fixture(:missing)
      relay = %{"consumer_id" => "local", "state_root" => Path.join(context.root, "relay"), "owners" => %{"human" => Atom.to_string(unquote(owner))}}
      context = put_in(context.settings.tracker.relay, relay)
      context = put_in(context.settings.codex.command, "sleep 20")

      if is_nil(Process.whereis(SymphonyElixir.TaskSupervisor)) do
        start_supervised!({Task.Supervisor, name: SymphonyElixir.TaskSupervisor})
      end

      ProjectContext.with_context(context, fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Test (AI)", assignee_id: "human"}])
        completed = finish_worker(state, issue)
        token = completed.retry_attempts[issue.id].retry_token
        assert {:noreply, next} = Orchestrator.handle_info({:retry_issue, issue.id, token}, completed)
        assert File.dir?(workspace)
        assert next.retry_attempts == %{}
        assert {:noreply, ^next} = Orchestrator.handle_info({:retry_issue, issue.id, token}, next)

        if unquote(owner) == :local do
          assert next.running[issue.id].issue.state == "Test (AI)"
          assert next.running[issue.id].dispatch_issue.state == "Test (AI)"
          Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, next.running[issue.id].pid)
        else
          assert next.running == %{}
          refute MapSet.member?(next.claimed, issue.id)
        end
      end)
    end
  end

  for failure <- [:api, :rate_limit] do
    test "#{failure} during completion refresh retains the retry until recovery" do
      {context, issue, workspace, state} = completion_fixture(:stale)
      settings = context.settings
      settings = put_in(settings.tracker.kind, "linear")
      failing_context = %{context | settings: settings}
      on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
      Req.default_options(plug: fn conn -> Req.Test.json(conn, %{"access_token" => "synthetic-app", "token_type" => "Bearer", "expires_in" => 2_592_000, "scope" => "read write"}) end)
      parent = self()

      Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, _ ->
        query = payload[:query] || payload["query"]

        if query =~ "SymphonyAppIdentity" do
          app = settings.tracker.app
          {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => app["user_id"], "app" => true, "organization" => %{"id" => app["workspace_id"]}}}}}}
        else
          assert query =~ "SymphonyLinearIssuesById"
          send(parent, :completion_api_read)
          {:error, :timeout}
        end
      end)

      pending =
        ProjectContext.with_context(failing_context, fn ->
          if unquote(failure) == :rate_limit do
            assert {:ok, %{status: 429}} = RateLimit.request(settings.tracker.app, fn -> {:ok, %{status: 429, headers: %{"retry-after" => "3600"}}} end)
          end

          completed = finish_worker(state, issue)
          retry = completed.retry_attempts[issue.id]
          assert {:noreply, pending} = Orchestrator.handle_info({:retry_issue, issue.id, retry.retry_token}, completed)
          assert MapSet.member?(pending.claimed, issue.id)
          assert File.dir?(workspace)
          retained = pending.retry_attempts[issue.id]
          assert retained.attempt == 2
          assert retained.error =~ "completion refresh failed"
          assert retained.workspace_path == workspace
          assert retained.recovered_turn_context == retry.recovered_turn_context
          assert retained.review_subagent_call_ids == retry.review_subagent_call_ids
          assert retained.review_subagent_ids == retry.review_subagent_ids

          if unquote(failure) == :rate_limit do
            assert retained.error =~ "linear_app_rate_limited"
            assert retained.due_at_ms >= System.monotonic_time(:millisecond) + 3_590_000
            refute_received :completion_api_read
          else
            assert retained.error =~ "linear_app_request_unavailable"
            assert_received :completion_api_read
          end

          Process.cancel_timer(retained.timer_ref)
          pending
        end)

      ProjectContext.with_context(context, fn ->
        Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Review"}])
        assert {:noreply, cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, pending.retry_attempts[issue.id].retry_token}, pending)
        refute File.exists?(workspace)
        assert cleaned.retry_attempts == %{}
      end)
    end
  end

  test "terminal completion tolerates an already removed workspace" do
    {context, issue, workspace, state} = completion_fixture(:missing)
    File.rm_rf!(workspace)

    ProjectContext.with_context(context, fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Review"}])
      completed = finish_worker(state, issue)
      assert {:noreply, cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, completed.retry_attempts[issue.id].retry_token}, completed)
      assert cleaned.retry_attempts == %{}
      refute MapSet.member?(cleaned.claimed, issue.id)
      refute File.exists?(workspace)
    end)
  end

  test "completion runs the existing cleanup task and removes Git registration and branches" do
    {context, issue, workspace, state} = completion_fixture(:stale)
    source = Path.join(context.root, "source")
    remote = Path.join(context.root, "remote.git")
    bin_dir = Path.join(context.root, "bin")
    File.mkdir_p!(source)
    File.mkdir_p!(bin_dir)
    File.rm_rf!(workspace)
    git!(["init", "--bare", remote])
    git!(["init", "-b", "main", source])
    git!(["-C", source, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "fixture"])
    git!(["-C", source, "remote", "add", "origin", remote])
    git!(["-C", source, "worktree", "add", "-b", "symphony/#{issue.identifier}", workspace])
    git!(["-C", workspace, "push", "origin", "HEAD"])
    File.write!(Path.join(bin_dir, "gh"), "#!/bin/sh\nexit 1\n")
    File.chmod!(Path.join(bin_dir, "gh"), 0o755)
    marker = Path.join(context.root, "before-remove.log")
    task_file = Path.join(File.cwd!(), "lib/mix/tasks/workspace.before_remove.ex")
    code = "Mix.start(); Mix.Tasks.Workspace.BeforeRemove.run(#{inspect(["--workspace", workspace, "--source-repo", source])})"

    hook =
      "echo cleanup >> #{shell_quote(marker)}\n" <>
        "export PATH=#{shell_quote(bin_dir)}:$PATH\n" <>
        "#{shell_quote(System.find_executable("elixir"))} -r #{shell_quote(task_file)} -e #{shell_quote(code)}"

    settings = context.settings
    settings = put_in(settings.hooks.before_remove, hook)

    ProjectContext.with_context(%{context | settings: settings}, fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | state: "Review"}])
      completed = finish_worker(state, issue)
      token = completed.retry_attempts[issue.id].retry_token
      assert {:noreply, cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, token}, completed)
      refute File.exists?(workspace)
      refute git!(["-C", source, "worktree", "list", "--porcelain"]) =~ workspace
      refute git!(["-C", source, "branch", "--list"]) =~ "symphony/#{issue.identifier}"
      assert git!(["-C", source, "ls-remote", "--heads", "origin", "symphony/#{issue.identifier}"]) == ""
      assert File.read!(marker) == "cleanup\n"
      assert {:noreply, ^cleaned} = Orchestrator.handle_info({:retry_issue, issue.id, token}, cleaned)
      assert :ok = Workspace.remove_issue_workspaces(issue.identifier)
      assert File.read!(marker) == "cleanup\n"
    end)
  end

  defp git!(args) do
    {output, status} = System.cmd("git", args, stderr_to_stdout: true)
    assert status == 0, output
    output
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp completion_fixture(cache) do
    root = Path.join([File.cwd!(), "_build", "completion-refresh-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    issue = %Issue{id: "completion-refresh", identifier: "PRO-719-DUMMY", title: "Merge completion", state: "Merge (AI)", labels: []}
    start_supervised!({CachedCandidates, if(cache == :stale, do: issue, else: [])})
    settings = Config.settings!()
    settings = put_in(settings.tracker.kind, "memory")
    settings = put_in(settings.tracker.app["state_root"], Path.join(root, "app-state"))
    settings = put_in(settings.tracker.app["client_id"], Path.basename(root))
    settings = put_in(settings.workspace.root, Path.join(root, "workspaces"))
    context = %ProjectContext{id: "completion-project", root: root, settings: settings, env: %{}}
    workspace = Path.join(settings.workspace.root, issue.identifier)
    File.mkdir_p!(workspace)

    entry = %{
      pid: nil,
      ref: make_ref(),
      identifier: issue.identifier,
      dispatch_issue: issue,
      issue: issue,
      workspace_path: workspace,
      worker_host: nil,
      session_id: "completion-thread-turn",
      started_at: DateTime.utc_now(),
      recovered_turn_context: "Findings: handled",
      review_subagent_call_ids: MapSet.new(["round-1"]),
      review_subagent_ids: MapSet.new(["child-1"])
    }

    state = %Orchestrator.State{
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      max_concurrent_agents: 1,
      running: %{issue.id => entry},
      claimed: MapSet.new([issue.id])
    }

    {context, issue, workspace, state}
  end

  defp finish_worker(state, issue) do
    assert {:noreply, draining} = Orchestrator.handle_info({:DOWN, state.running[issue.id].ref, :process, self(), :normal}, state)
    entry = draining.running[issue.id]
    Process.cancel_timer(entry.exit_finalize_timer_ref)
    assert {:noreply, completed} = Orchestrator.handle_info({:finalize_running_issue_exit, issue.id, entry.exit_finalize_token}, draining)
    Process.cancel_timer(completed.retry_attempts[issue.id].timer_ref)
    completed
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
