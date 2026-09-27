defmodule SymphonyElixir.IssueReadCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{Budget, Client, IssueReadCache}
  alias SymphonyElixir.ProjectContext

  defp relay_settings do
    settings = put_in(Config.settings!().tracker.relay, %{})
    put_in(settings.tracker.app["workspace_id"], "read-cache-#{System.unique_integer([:positive])}")
  end

  test "relay reads reuse a verified epoch, then refresh on change or fifteen-minute safety deadline" do
    settings = relay_settings()
    context = %ProjectContext{id: "read-#{System.unique_integer([:positive])}", settings: settings}
    issue = %Issue{id: "issue", state: "In Arbeit (AI)", assignee_id: "human", blocked_by: []}
    {:ok, state} = Agent.start_link(fn -> %{epoch: 1, relay: issue, reads: 0, available: true} end)

    relay = fn _, _ ->
      Agent.get(state, fn current ->
        if current.available, do: {:ok, [{{"generation", current.epoch}, current.relay}]}, else: {:error, :relay_unavailable}
      end)
    end

    linear = fn _ ->
      Agent.get_and_update(state, fn current -> {{:ok, [issue]}, %{current | reads: current.reads + 1}} end)
    end

    opts = [context: context, relay: relay, fetch_linear: linear]
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 0))
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 899_999))
    assert Agent.get(state, & &1.reads) == 1

    Agent.update(state, &%{&1 | epoch: 2})
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 900_000))
    assert Agent.get(state, & &1.reads) == 2
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 1_800_000))
    assert Agent.get(state, & &1.reads) == 3

    Agent.update(state, &%{&1 | available: false})
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 1_800_001))
    assert Agent.get(state, & &1.reads) == 4
  end

  test "incomplete or disagreeing relay data cannot authorize a cached read" do
    settings = relay_settings()
    context = %ProjectContext{id: "read-#{System.unique_integer([:positive])}", settings: settings}
    linear_issue = %Issue{id: "issue", state: "Review", assignee_id: "human", blocked_by: []}
    stale = %{linear_issue | state: "In Arbeit (AI)"}
    {:ok, count} = Agent.start_link(fn -> 0 end)

    linear = fn _ ->
      Agent.update(count, &(&1 + 1))
      {:ok, [linear_issue]}
    end

    opts = [context: context, relay: fn _, _ -> {:ok, [{{"generation", 1}, stale}]} end, fetch_linear: linear, now: 0]
    assert {:ok, [^linear_issue]} = IssueReadCache.fetch(["issue"], opts)
    assert {:ok, [^linear_issue]} = IssueReadCache.fetch(["issue"], opts)
    assert Agent.get(count, & &1) == 2
    assert {:ok, [^linear_issue]} = IssueReadCache.fetch(["issue"], Keyword.put(opts, :relay, fn _, _ -> {:error, :relay_issue_incomplete} end))
    assert Agent.get(count, & &1) == 3
  end

  test "a confirmed local update invalidates the old relay epoch until hydration catches up" do
    settings = put_in(Config.settings!().tracker.relay, %{})
    context = %ProjectContext{id: "update-#{System.unique_integer([:positive])}", settings: settings}
    old = %Issue{id: "issue", state: "In Arbeit (AI)", assignee_id: "human", blocked_by: []}
    updated = %{old | state: "PreReview (AI)"}
    {:ok, source} = Agent.start_link(fn -> %{linear: old, relay: old, epoch: 1, reads: 0} end)

    linear = fn _ ->
      Agent.get_and_update(source, fn current -> {{:ok, [current.linear]}, %{current | reads: current.reads + 1}} end)
    end

    relay = fn _, _ -> Agent.get(source, fn current -> {:ok, [{{"generation", current.epoch}, current.relay}]} end) end
    opts = [context: context, relay: relay, fetch_linear: linear, critical: true]

    assert {:ok, [^old]} = IssueReadCache.fetch([old.id], Keyword.put(opts, :now, 0))
    Agent.update(source, &%{&1 | linear: updated})
    assert {:ok, [^old]} = IssueReadCache.fetch([old.id], Keyword.put(opts, :now, 1))

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
      {:ok, %{status: 200, body: %{"data" => %{"issueUpdate" => %{"success" => true}}}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    mutation = "mutation UpdateIssueTitle($id: String!, $title: String!) { issueUpdate(id: $id, input: {title: $title}) { success } }"

    assert {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}} =
             ProjectContext.with_context(context, fn -> Client.graphql(mutation, %{id: old.id, title: "Updated"}) end)

    assert {:ok, [^updated]} = IssueReadCache.fetch([old.id], Keyword.put(opts, :now, 2))
    assert {:ok, [^updated]} = IssueReadCache.fetch([old.id], Keyword.put(opts, :now, 3))
    assert Agent.get(source, & &1.reads) == 3

    Agent.update(source, &%{&1 | relay: updated, epoch: 2})
    assert {:ok, [^updated]} = IssueReadCache.fetch([old.id], Keyword.put(opts, :now, 4))
    assert {:ok, [^updated]} = IssueReadCache.fetch([old.id], Keyword.put(opts, :now, 5))
    assert Agent.get(source, & &1.reads) == 4
  end

  test "a pre-update Linear verification cannot restore an invalidated epoch" do
    settings = relay_settings()
    context = %ProjectContext{id: "race-#{System.unique_integer([:positive])}", settings: settings}
    issue = %Issue{id: "issue", state: "In Arbeit (AI)", assignee_id: "human", blocked_by: []}
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    linear = fn _ ->
      count = Agent.get_and_update(reads, &{&1, &1 + 1})
      if count == 0, do: IssueReadCache.invalidate([issue.id])
      {:ok, [issue]}
    end

    opts = [context: context, relay: fn _, _ -> {:ok, [{{"generation", 1}, issue}]} end, fetch_linear: linear]
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 0))
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 1))
    assert Agent.get(reads, & &1) == 2
  end

  test "critical shared budget defers new background verification while bound checkpoints may verify" do
    settings = relay_settings()
    app = Map.put(settings.tracker.app, "workspace_id", "critical-#{System.unique_integer([:positive])}")
    settings = put_in(settings.tracker.app, app)
    context = %ProjectContext{id: "critical-#{System.unique_integer([:positive])}", settings: settings}
    issue = %Issue{id: "issue", state: "In Arbeit (AI)", assignee_id: "human", blocked_by: []}
    {:ok, count} = Agent.start_link(fn -> 0 end)

    linear = fn _ ->
      Agent.update(count, &(&1 + 1))
      {:ok, [issue]}
    end

    relay = fn _, _ -> {:ok, [{{"generation", 1}, issue}]} end
    Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "999"})
    opts = [context: context, relay: relay, fetch_linear: linear]

    assert {:error, :linear_budget_reserved} = IssueReadCache.fetch([issue.id], opts)
    assert Agent.get(count, & &1) == 0
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :critical, true))
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], opts)
    assert Agent.get(count, & &1) == 1
  end

  test "empty reads skip both transports and a global invalidation requires verification again" do
    settings = relay_settings()
    context = %ProjectContext{id: "all-#{System.unique_integer([:positive])}", settings: settings}
    issue = %Issue{id: "issue", state: "In Arbeit (AI)", assignee_id: "human", blocked_by: []}
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    linear = fn _ ->
      Agent.update(reads, &(&1 + 1))
      {:ok, [issue]}
    end

    opts = [context: context, relay: fn _, _ -> {:ok, [{{"generation", 1}, issue}]} end, fetch_linear: linear]
    assert {:ok, []} = IssueReadCache.fetch([], opts)
    assert Agent.get(reads, & &1) == 0
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 0))
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 1))
    assert Agent.get(reads, & &1) == 1
    assert :ok = IssueReadCache.invalidate(:all)
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 2))
    assert Agent.get(reads, & &1) == 2
  end

  test "a failed second relay read does not mark its first epoch as verified" do
    settings = relay_settings()
    context = %ProjectContext{id: "epoch-#{System.unique_integer([:positive])}", settings: settings}
    issue = %Issue{id: "issue", state: "In Arbeit (AI)", assignee_id: "human", blocked_by: []}
    {:ok, calls} = Agent.start_link(fn -> %{relay: 0, linear: 0} end)

    relay = fn _, _ ->
      count = Agent.get_and_update(calls, fn current -> {current.relay, %{current | relay: current.relay + 1}} end)
      if count == 1, do: {:error, :relay_unavailable}, else: {:ok, [{{"generation", 1}, issue}]}
    end

    linear = fn _ ->
      Agent.update(calls, &%{&1 | linear: &1.linear + 1})
      {:ok, [issue]}
    end

    opts = [context: context, relay: relay, fetch_linear: linear]
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 0))
    assert {:ok, [^issue]} = IssueReadCache.fetch([issue.id], Keyword.put(opts, :now, 1))
    assert Agent.get(calls, & &1.linear) == 2
  end
end
