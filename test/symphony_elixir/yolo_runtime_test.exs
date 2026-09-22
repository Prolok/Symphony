defmodule SymphonyElixir.YoloRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ProjectContext, Yolo}

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.CommentActionGuard
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.Yolo.{Completion, Coordinator, Group, Observation, Operations, Scope, Store}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.yolo_agent, "Pai")
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    ProjectContext.bind(context)

    issues =
      for {name, i} <- Enum.with_index(["Backlog", "Todo", "Definiert"]) do
        Client.relay_issue(%{
          "id" => "member#{i}",
          "identifier" => "PRO-#{i}",
          "title" => "Member #{i}",
          "state" => %{"name" => name},
          "assignee" => %{"id" => "human", "email" => "human@example.com", "app" => false},
          "delegate" => %{"id" => "pai"},
          "project" => %{"id" => "project-id", "slugId" => "project"},
          "team" => %{"id" => "team"},
          "labels" => %{"nodes" => Enum.map([~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")], &%{"name" => &1})}
        })
      end

    %{context: context, root: root, issues: issues}
  end

  defp tick(state, issues, opts), do: Coordinator.tick(state, issues, Keyword.put_new(opts, :dependencies, &{:ok, &1}))
  defp run_group(group, issues, project, opts \\ []), do: Yolo.Runner.run(group, issues, project, Keyword.put_new(opts, :dependencies, &{:ok, &1}))

  defp inbox(versions \\ %{}), do: %{"versions" => versions, "last_successful_scan" => "now", "scan_error" => nil}
  defp scan(_), do: {:ok, inbox()}

  test "blocked backlog waits and only Yolo Review enters acceptance", %{issues: [issue | _]} do
    blocked = %{issue | blocked_by: [%{id: "fix", state: "In Arbeit (AI)"}]}
    assert Group.groups([blocked]) == %{}
    assert Group.groups([%{blocked | blocked_by: [%{id: "fix", state: "Review"}]}])["incoming"] != nil
    assert Group.name(%{issue | state: "Review"}) == nil
    assert Group.name(%{issue | state: "Yolo Review"}) == "review"
  end

  test "a merged review chain is ready while an unfinished fix blocks its entire chain", %{issues: [issue | _]} do
    origin = %{issue | state: "Yolo Review", blocked_by: [%{id: "fix", state: "Yolo Review"}]}
    fix = %{issue | id: "fix", state: "Yolo Review"}
    assert Group.groups([origin, fix])["review"] == [fix, origin]
    unfinished = %{fix | blocked_by: [%{id: "external", state: "Test (AI)"}]}
    refute Map.has_key?(Group.groups([origin, unfinished]), "review")
  end

  test "incoming statuses share a group; unrelated work does not block review", %{issues: [first | _] = issues} do
    assert Group.groups(issues) == %{"incoming" => issues}
    review = %{first | id: "review", state: "Yolo Review"}
    assert Group.groups([review]) == %{"review" => [review]}
    assert Group.groups([first, review]) == %{"incoming" => [first], "review" => [review]}
    foreign = %{first | id: "foreign", assignee_id: "foreign", assigned_to_worker: false, state: "In Arbeit (AI)"}
    assert Group.groups([foreign, review]) == %{"review" => [review]}

    for state <- ["Fertig", "Abgebrochen", "Verworfen", "Duplicate", "Umsetzungsticket erstellt", "Todo (Dialog-AI)"] do
      assert Group.groups([%{first | state: state}, review])["review"] == [review]
    end

    assert Group.groups([%{first | delegate_id: nil}, review]) == %{"review" => [review]}
    for {state, group} <- [{"Planung", "planning"}, {"In Arbeit", "in_progress"}, {"BLOCKER", "blocker"}], do: assert(Group.name(%{first | state: state}) == group)
  end

  test "semantic observation survives replay/restart and ignores confirmed own outputs", %{issues: [issue | _]} do
    parent = self()

    scan = fn _ ->
      send(parent, :scan)
      {:ok, inbox(%{"own" => %{"key" => "own", "origin" => "own", "deleted" => false}})}
    end

    assert {:ok, observations, fingerprint} = Observation.capture([issue], %{}, scan: scan)
    assert_receive :scan
    assert {:ok, ^observations, ^fingerprint} = Observation.capture([issue], observations, scan: scan)
    refute_receive :scan
    changed = %{issue | last_comment_signal: %{relay_epoch: "new-event"}}
    assert {:ok, _, ^fingerprint} = Observation.capture([changed], observations, scan: scan)
    assert_receive :scan

    for deleted <- [false, true] do
      external = inbox(%{"human" => %{"key" => "human", "origin" => "human", "deleted" => deleted}})
      assert {:ok, _, different} = Observation.capture([changed], observations, scan: fn _ -> {:ok, external} end)
      refute different == fingerprint
    end

    assert {:error, :offline} = Observation.capture([changed], observations, scan: fn _ -> {:error, :offline} end)
    incomplete = %{inbox() | "scan_error" => "incomplete"}
    opts = [scan: fn _ -> {:ok, incomplete} end]
    assert {:error, :yolo_comments_incomplete} = Observation.capture([changed], observations, opts)
  end

  test "one session is scheduled for three states; overlap and shared capacity do not duplicate", %{issues: issues} do
    parent = self()
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    start = fn group, _callback ->
      send(parent, {:start, group})
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end

    running = tick(state, issues, scan: &scan/1, start: start)
    assert_receive {:start, "incoming"}
    assert map_size(running.yolo_runs) == 1
    assert length(Coordinator.entries(running.yolo_runs)) == 3
    assert tick(running, issues, scan: &scan/1, start: start).yolo_runs == running.yolo_runs
    refute_receive {:start, _}
    transitioned = [%{hd(issues) | state: "In Arbeit (AI)"} | tl(issues)]
    retained = tick(running, transitioned, scan: &scan/1, start: start)
    assert MapSet.member?(retained.claimed, hd(issues).id)
    assert retained.yolo_runs == running.yolo_runs
    refute_receive {:start, _}
    pid = running.yolo_runs["incoming"].pid
    ref = Process.monitor(pid)
    assert tick(running, [], scan: &scan/1, start: start).yolo_runs == %{}
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    busy = %{state | claimed: MapSet.new([hd(issues).id])}
    assert tick(busy, issues, scan: &scan/1, start: start).yolo_runs == %{}
    refute_receive {:start, _}
  end

  test "review comment create edit delete and replay have exact scan and session counts", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:review_counts, %{scans: 0, sessions: 0})
    Process.put(:review_versions, %{})

    opts = [
      scan: fn _ ->
        Process.put(:review_counts, Map.update!(Process.get(:review_counts), :scans, &(&1 + 1)))
        {:ok, inbox(Process.get(:review_versions))}
      end,
      start: fn "review", _ ->
        Process.put(:review_counts, Map.update!(Process.get(:review_counts), :sessions, &(&1 + 1)))
        {:error, :fixture_session_observed}
      end
    ]

    for {epoch, key, deleted} <- [{1, "human:create", false}, {2, "human:edit", false}, {3, "human:delete", true}] do
      Process.put(:review_versions, %{"comment" => %{"key" => key, "origin" => "human", "deleted" => deleted}})
      changed = %{review | last_comment_signal: %{relay_epoch: epoch}}
      tick(state, [changed], opts)
      assert Process.get(:review_counts) == %{scans: epoch, sessions: epoch}
      # Persist the observation acknowledged by a completed run, then recreate
      # the in-memory orchestrator and replay the exact relay notification.
      {:ok, record} = Store.read("review")
      :ok = Store.write("review", Map.put(record, "processed", Observation.fingerprint(record["observations"])))
      for _ <- 1..3, do: tick(%{state | yolo_runs: %{}}, [changed], opts)
      assert Process.get(:review_counts) == %{scans: epoch, sessions: epoch}
    end

    own = %{review | last_comment_signal: %{relay_epoch: 4}}
    Process.put(:review_versions, Map.put(Process.get(:review_versions), "own", %{"key" => "own:edit", "origin" => "own", "deleted" => false}))
    tick(state, [own], opts)
    assert Process.get(:review_counts) == %{scans: 4, sessions: 3}

    {:ok, before_failure} = Store.read("review")

    for error <- [:rate_limited, :incomplete_pagination] do
      failing = Keyword.put(opts, :scan, fn _ -> {:error, error} end)
      tick(state, [%{own | last_comment_signal: %{relay_epoch: 5}}], failing)
      assert Store.read("review") == {:ok, before_failure}
      assert Process.get(:review_counts) == %{scans: 4, sessions: 3}
    end
  end

  test "unrelated waiting work does not reopen a processed review after restart", %{issues: [issue | _]} do
    review = %{issue | id: "review", state: "Yolo Review"}
    expected = %{issue | state: "In Arbeit (AI)"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    {:ok, observations, fingerprint} = Observation.capture([review], %{}, scan: &scan/1)
    {:ok, record} = Store.read("review")
    :ok = Store.write("review", Map.merge(record, %{"observations" => observations, "processed" => fingerprint}))

    opts = [
      scan: fn _ -> flunk("unchanged review must not refetch comments") end,
      start: fn group, _ ->
        send(self(), {:started, group})
        {:error, :capacity}
      end
    ]

    for _ <- 1..3, do: assert(tick(state, [review], opts).yolo_runs == %{})
    refute_receive {:started, _}
    for _ <- 1..3, do: assert(tick(state, [expected, review], opts).yolo_runs == %{})
    refute_receive {:started, _}
    # No in-memory predecessor is passed, as on service restart.
    assert tick(state, [review], opts).yolo_runs == %{}
    refute_receive {:started, "review"}
  end

  test "waiting changes during a review remain open and corrupt readiness cannot start", %{issues: [issue | _], root: root} do
    alias SymphonyElixir.Yolo.ReviewReadiness
    review = %{issue | state: "Yolo Review"}
    assert {:ok, 0} = ReviewReadiness.observe([review])

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn -> {:ok, [review]} end,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ ->
        assert {:ok, 1} = ReviewReadiness.observe([issue, review])
        assert {:ok, 2} = ReviewReadiness.observe([review])
        assert :ok = Completion.invoke(%{"issue_id" => review.id, "result" => "checked snapshot"}, handoff_completed: true, fetch: fn _ -> {:ok, [review]} end, before_action: fn _ -> :ok end)
        {:ok, %{session_id: "review-session"}}
      end
    ]

    assert :ok = run_group("review", [review], [review], opts)
    assert {:ok, record} = Store.read("review")
    assert record["processed_epoch"] == 0
    assert {:ok, 2} = ReviewReadiness.epoch("review")

    assert {:error, :yolo_group_changed} = run_group("review", [review], [review], opts)
    {:ok, readiness} = Store.read("review-readiness")
    :ok = Store.write("review-readiness", Map.put(readiness, "members", %{("review:" <> review.id) => %{"ready" => false, "generation" => "corrupt"}}))
    assert {:error, :yolo_readiness_corrupt} = Observation.capture([review], %{}, scan: &scan/1)
    :ok = Store.write("review-readiness", Map.put(readiness, "epoch", "corrupt"))
    assert {:error, :yolo_readiness_corrupt} = ReviewReadiness.epoch("review")
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    assert tick(state, [review], start: fn _, _ -> flunk("corrupt readiness") end).yolo_runs == %{}
    File.write!(Store.path("review-readiness"), "corrupt")
    assert {:error, :yolo_state_corrupt} = ReviewReadiness.observe([review])
    assert {:error, :yolo_state_corrupt} = run_group("review", [review], [review], opts)
  end

  test "member checkpoints extend only the runtime-bound group and still reject revoked delegation", %{issues: [first, second | _] = issues} do
    assert {:error, :comment_issue_outside_active_scope} = SymphonyElixir.CommentCheckpoint.bound_issue(first.id, fetch_issue: fn _ -> {:ok, [first]} end)

    Scope.with_scope("incoming", issues, Ecto.UUID.generate(), fn ->
      assert Scope.member?(second.id)
      refute Scope.member?("unrelated")
      assert {:ok, ^second} = SymphonyElixir.CommentCheckpoint.bound_issue(second.id, fetch_issue: fn _ -> {:ok, [second]} end)
      assert {:error, :comment_issue_outside_active_scope} = SymphonyElixir.CommentCheckpoint.bound_issue(second.id, fetch_issue: fn _ -> {:ok, [%{second | delegate_id: nil}]} end)
      assert Config.linear_runtime_env()["SYMPHONY_YOLO_SCOPE"] =~ second.id
    end)

    refute Scope.current()
    WriteContext.with_context(%{yolo_scope: "invalid-json"}, fn -> refute Scope.current() end)
  end

  test "runner only confirms frozen observations after every member receipt", %{issues: issues, root: root} do
    {:ok, record} = Store.read("incoming")
    {:ok, observations, fingerprint} = Observation.capture(issues, %{}, scan: &scan/1)
    :ok = Store.write("incoming", %{record | "observations" => observations})

    session = fn _, prompt, _, opts ->
      assert %{"workspace" => ^root, "sha" => "merged-sha", "run_id" => run_id} = Scope.current()
      assert Config.linear_runtime_env()["SYMPHONY_RUN_ID"] == run_id
      assert prompt =~ "Definiert"
      assert prompt =~ "Backlog"
      assert prompt =~ "Todo"
      opts[:on_message].(%{session_id: "shared-session", event: :session_started})

      Enum.each(issues, fn issue ->
        assert :ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "Entscheidung belegt"}, fetch: fn _ -> {:ok, [issue]} end, before_action: fn _ -> :ok end)
      end)

      {:ok, %{session_id: "shared-session"}}
    end

    opts = [
      fetch: fn _ -> {:ok, issues} end,
      lease: fn _issue, callback -> callback.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "merged-sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{inputs: []}} end,
      before_action: fn _ -> :ok end,
      session: session,
      recipient: self()
    ]

    assert :ok = run_group("incoming", issues, issues, opts)
    assert_receive {:yolo_event, "incoming", %{session_id: "shared-session"}}
    assert {:ok, completed} = Store.read("incoming")
    assert completed["processed"] == fingerprint
    assert length(Map.keys(completed["attempt"]["completed"])) == 3
    # A later edit remains open, including across scheduler reconstruction.
    edited = [%{hd(issues) | description: "new request"} | tl(issues)]
    assert {:ok, _, next} = Observation.capture(edited, completed["observations"], scan: &scan/1)
    refute next == completed["processed"]
  end

  test "changes during checkout and checkpoints prevent launch while member leases remain held", %{issues: issues, root: root} do
    for change <- [:revoked, :missing, :duplicate, :edited, :offline, :workspace] do
      key = {__MODULE__, :launch_change}
      Process.put(key, false)

      fetch = fn _ ->
        if Process.get(key) do
          case change do
            :revoked -> {:ok, [%{hd(issues) | delegate_id: nil} | tl(issues)]}
            :missing -> {:ok, tl(issues)}
            :duplicate -> {:ok, [hd(issues), hd(issues), hd(issues)]}
            :edited -> {:ok, [%{hd(issues) | description: "new requirement"} | tl(issues)]}
            :offline -> {:error, :offline}
            :workspace -> {:ok, issues}
          end
        else
          {:ok, issues}
        end
      end

      opts = [
        fetch: fetch,
        lease: fn issue, callback ->
          Process.put({:leased, issue.id}, true)

          try do
            callback.()
          after
            Process.delete({:leased, issue.id})
          end
        end,
        scan: &scan/1,
        workspace: fn _, _ -> {:ok, %{path: root, sha: "merged-sha"}} end,
        unchanged: fn _ -> change != :workspace end,
        checkpoint: fn _ ->
          assert Enum.all?(issues, &Process.get({:leased, &1.id}))
          Process.put(key, true)
          {:ok, %{inputs: []}}
        end,
        session: fn _, _, _, _ -> flunk("changed group must not launch") end
      ]

      assert {:error, reason} = run_group("incoming", issues, issues, opts)
      assert reason == if(change == :offline, do: :offline, else: :yolo_launch_changed)
      assert {:ok, %{"processed" => nil}} = Store.read("incoming")
      refute Enum.any?(issues, &Process.get({:leased, &1.id}))
    end
  end

  test "fresh lookup cannot substitute unleased members", %{issues: issues} do
    first = hd(issues)

    for fresh <- [[first, first, first], [%{first | id: "unleased"} | tl(issues)]] do
      assert {:error, :yolo_group_changed} =
               run_group("incoming", issues, issues,
                 lease: fn _, callback -> callback.() end,
                 fetch: fn _ -> {:ok, fresh} end,
                 workspace: fn _, _ -> flunk("no checkout for unleased members") end
               )
    end
  end

  test "normal session exit and partial receipts cannot claim completion", %{issues: issues, root: root} do
    opts = [
      fetch: fn _ -> {:ok, issues} end,
      lease: fn _issue, callback -> callback.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "merged-sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{inputs: []}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ -> {:ok, %{session_id: "incomplete"}} end
    ]

    assert {:error, :yolo_group_incomplete_or_workspace_changed} = run_group("incoming", issues, issues, opts)
    assert {:ok, record} = Store.read("incoming")
    assert record["processed"] == nil
    assert record["retry_at"] > System.system_time(:millisecond)
    assert record["attempt"]["members"] == Enum.map(issues, & &1.id)
  end

  test "pending actions reopen an old processed snapshot and cannot hide behind member receipts", %{issues: issues, root: root} do
    ids = Enum.map(issues, & &1.id)
    {:ok, observations, fingerprint} = Observation.capture(issues, %{}, scan: &scan/1)
    {:ok, record} = Store.read("incoming")
    :ok = Store.write("incoming", Map.merge(record, %{"observations" => observations, "processed" => fingerprint}))
    request = %{"kind" => "aggregate", "origin_ids" => ids}
    assert :ok = Operations.run("unfinished", request, fn _ -> :ok end)
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    parent = self()

    start = fn _, _ ->
      send(parent, :scheduled)
      {:error, :capacity}
    end

    tick(state, issues, scan: fn _ -> flunk("unchanged poll must use cached observations") end, start: start)
    assert_receive :scheduled

    opts = [
      fetch: fn _ -> {:ok, issues} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ ->
        # Simulate receipts from an earlier client or an action opened after a
        # member receipt. The runner must verify the actual journal at exit.
        {:ok, current} = Store.read("incoming")
        current = put_in(current, ["attempt", "completed"], Map.new(ids, &{&1, "premature"}))
        :ok = Store.write("incoming", current)
        {:ok, %{session_id: "incomplete-actions"}}
      end
    ]

    assert {:error, {:yolo_operations_pending, ["unfinished"]}} = run_group("incoming", issues, issues, opts)
    assert {:ok, failed} = Store.read("incoming")
    assert failed["processed"] == fingerprint
    assert failed["retry_at"] > System.system_time(:millisecond)
    assert {:ok, [intent]} = Operations.pending(ids)
    :ok = Operations.save(Map.put(intent, "done", true))
    :ok = Store.write("incoming", %{failed | "retry_at" => nil})
    tick(state, issues, start: start)
    refute_receive :scheduled
  end

  test "corrupt operation journals block completion and scheduling", %{issues: [issue | _] = issues} do
    assert :ok = Operations.run("broken", %{"origin_ids" => [issue.id]}, fn _ -> :ok end)
    File.write!(Operations.path("broken"), "corrupt")

    Scope.with_scope("incoming", issues, "run", fn ->
      assert {:error, :yolo_operation_changed_or_corrupt} =
               Completion.invoke(%{"issue_id" => issue.id, "result" => "done"}, fetch: fn _ -> {:ok, [issue]} end, before_action: fn _ -> :ok end)
    end)

    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    assert tick(state, issues, start: fn _, _ -> flunk("corrupt operation") end).yolo_runs == %{}
  end

  test "incomplete admission blocks the entire incoming group, and retry can admit it", %{issues: [first | rest]} do
    missing = %{first | labels: []}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    assert Group.groups([missing | rest]) == %{}
    assert Group.terminal?(%{first | state: "Verworfen"})
    opts = [prepare: fn _ -> {:error, :offline} end, start: fn _, _ -> flunk("partial group") end]
    assert tick(state, [missing | rest], opts).yolo_runs == %{}
    opts = [prepare: fn _ -> {:ok, first} end, scan: &scan/1, start: fn _, _ -> {:error, :capacity} end]
    assert tick(state, [missing | rest], opts).yolo_runs == %{}
  end

  test "scheduler preserves waits, errors, events and uses actual shared worker capacity", %{issues: issues, context: context} do
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    no_start = fn _, _ -> flunk("unexpected restart") end
    {:ok, observations, fingerprint} = Observation.capture(issues, %{}, scan: &scan/1)
    {:ok, record} = Store.read("incoming")
    :ok = Store.write("incoming", Map.merge(record, %{"observations" => observations, "processed" => fingerprint}))
    assert tick(state, issues, start: no_start).yolo_runs == %{}
    :ok = Store.write("incoming", Map.put(record, "retry_at", System.system_time(:millisecond) + 30_000))
    assert tick(state, issues, start: no_start).yolo_runs == %{}
    File.write!(Store.path("incoming"), "corrupt")
    assert {:error, :yolo_state_corrupt} = Store.read("incoming")
    assert tick(state, issues, start: no_start).yolo_runs == %{}
    :ok = Store.write("incoming", record)
    assert tick(state, issues, scan: fn _ -> {:error, :offline} end, start: no_start).yolo_runs == %{}
    assert {:ok, %{}, _} = Observation.capture([], %{})

    parent = self()

    runner = fn _, _, _ ->
      send(parent, {:worker_context, ProjectContext.current().id})
      receive do: (:stop -> :ok)
    end

    start_supervised!({SymphonyElixir.WorkerCapacity, contexts: [context]})

    for external <- [false, true] do
      running = tick(%{state | external_poll: external}, issues, scan: &scan/1, runner: runner)
      assert_receive {:worker_context, id}
      assert id == context.id
      updated = Coordinator.event(running.yolo_runs, "incoming", %{session_id: "shared", workspace_path: "checkout"})
      assert Enum.all?(Coordinator.entries(updated), &(&1.session_id == "shared"))
      assert Coordinator.event(updated, "missing", %{}) == updated
      assert :ok = Coordinator.stop(updated)
    end
  end

  test "PO status actions require a current member and still apply fresh comment checks", %{issues: [first | _] = issues} do
    mutation = %{"query" => "mutation { issueUpdate(id: \"#{first.id}\", input: { stateId: \"target\" }) { success } }"}

    query = fn _, _ ->
      {:ok, %{"data" => %{"issue" => %{"id" => first.id, "team" => %{"states" => %{"nodes" => [%{"id" => "target", "name" => "Verworfen"}], "pageInfo" => %{"hasNextPage" => false}}}}}}}
    end

    Scope.with_scope("incoming", issues, Ecto.UUID.generate(), fn ->
      for {issue, expected} <- [
            {first, {:error, :new_comment}},
            {%{first | assigned_to_worker: false}, {:error, :yolo_action_outside_group}},
            {%{first | in_project_scope: false}, {:error, :yolo_action_outside_group}},
            {%{first | delegate_id: nil}, {:error, :yolo_delegation_changed}}
          ] do
        opts = [query: query, fetch_issue: fn _ -> {:ok, [issue]} end, guard: fn _ -> {:error, :new_comment} end]
        assert CommentActionGuard.check(mutation, opts) == expected
      end
    end)
  end

  test "completion transports reject unbound calls, failed checks and stale attempts", %{issues: [first | _] = issues} do
    refute Completion.execute(%{})["success"]
    assert Completion.mcp_call(%{})["isError"]
    refute DynamicTool.execute("symphony_yolo_complete", %{})["success"]
    args = %{"issue_id" => first.id, "result" => "checked"}
    assert {:error, :yolo_completion_outside_scope} = Completion.invoke(args, [])

    Scope.with_scope("incoming", issues, Ecto.UUID.generate(), fn ->
      opts = [fetch: fn _ -> {:ok, [first]} end, before_action: fn _ -> :ok end]
      assert {:error, :yolo_attempt_unavailable} = Completion.invoke(args, opts)
      assert {:error, :offline} = Completion.invoke(args, Keyword.put(opts, :before_action, fn _ -> {:error, :offline} end))
      {:ok, record} = Store.read("incoming")
      :ok = Store.write("incoming", Map.put(record, "attempt", %{"members" => [first.id]}))
      refute Completion.mcp_call(args, opts)["isError"]
      File.write!(Store.path("incoming"), "corrupt")
      assert {:error, :yolo_state_corrupt} = Completion.invoke(args, opts)
      refute Completion.ready?("incoming", issues)
    end)
  end

  test "waiting review performs no session or scans and starts when the last delegated blocker leaves", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review", id: "review", blocked_by: [%{id: "blocker", state: "BLOCKER"}]}
    blocker = %{issue | state: "BLOCKER", id: "blocker", assignee_id: "remote", assigned_to_worker: false}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    parent = self()

    opts = [
      scan: fn _ ->
        send(parent, :scanned)
        scan(issue)
      end,
      start: fn group, _ ->
        send(parent, {:start, group})
        {:error, :capacity}
      end
    ]

    for _ <- 1..3, do: assert(tick(state, [review, blocker], opts).yolo_runs == %{})
    refute_receive :scanned
    refute_receive {:start, _}
    tick(state, [%{review | blocked_by: [%{id: "blocker", state: "Review"}]}, %{blocker | state: "Review", delegate_id: nil}], opts)
    assert_receive :scanned
    assert_receive {:start, "review"}
  end

  test "review requires a complete fresh project before checkout and again immediately before session", %{issues: [issue | _], root: root} do
    review = %{issue | state: "Yolo Review"}
    expected = %{issue | id: "new-work"}
    blocked = %{review | blocked_by: [%{id: expected.id, state: expected.state}]}

    base = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      session: fn _, _, _, _ -> flunk("no session while work or failed query exists") end
    ]

    for answer <- [{:ok, [blocked, expected]}, {:error, :rate_limited}] do
      assert {:error, _} = run_group("review", [review], [], Keyword.put(base, :project, fn -> answer end))
      assert {:ok, %{"processed" => nil}} = Store.read("review")
    end

    Process.put(:project_checks, 0)

    changed = fn ->
      count = Process.get(:project_checks)
      Process.put(:project_checks, count + 1)
      {:ok, if(count == 0, do: [review], else: [blocked, expected])}
    end

    assert {:error, :yolo_review_waiting} = run_group("review", [review], [], Keyword.put(base, :project, changed))
    assert Process.get(:project_checks) == 2
  end

  test "withdrawal retains other members but cannot mark the withdrawn observation processed", %{issues: issues, root: root} do
    first = hd(issues)
    Process.put(:withdraw_member, false)
    fetch = fn _ -> {:ok, if(Process.get(:withdraw_member), do: [%{first | delegate_id: nil} | tl(issues)], else: issues)} end

    session = fn _, _, _, _ ->
      Process.put(:withdraw_member, true)

      Enum.each(tl(issues), fn issue ->
        assert :ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "actual decision"}, fetch: fn _ -> {:ok, [issue]} end, before_action: fn _ -> :ok end)
      end)

      {:ok, %{session_id: "shared"}}
    end

    opts = [
      fetch: fetch,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: session
    ]

    assert :ok = run_group("incoming", issues, issues, opts)
    {:ok, record} = Store.read("incoming")
    {:ok, _, original} = Observation.capture(issues, %{}, scan: &scan/1)
    refute record["processed"] == original
    {:ok, _, retained} = Observation.capture(tl(issues), %{}, scan: &scan/1)
    assert record["processed"] == retained
  end

  test "delegation-only PO mutations also require fresh ownership and comments", %{issues: [first | _] = issues} do
    payload = %{"query" => "mutation { issueUpdate(id: \"#{first.id}\", input: { delegateId: null }) { success } }"}

    Scope.with_scope("incoming", issues, "run", fn ->
      assert {:error, :new_comment} = CommentActionGuard.check(payload, fetch_issue: fn _ -> {:ok, [first]} end, guard: fn _ -> {:error, :new_comment} end)
      assert {:error, :yolo_delegation_changed} = CommentActionGuard.check(payload, fetch_issue: fn _ -> {:ok, [%{first | delegate_id: nil}]} end)
    end)
  end

  test "final incomplete observations stay open and pending actions appear in the next prompt", %{issues: issues, root: root} do
    assert :ok = Yolo.Operations.run("pending", %{"origin_ids" => [hd(issues).id], "title" => "recover exact action"}, fn _ -> :ok end)

    for result <- [{:error, :offline}, {:ok, []}] do
      Process.put(:after_turn, false)

      opts = [
        fetch: fn _ -> if(Process.get(:after_turn), do: result, else: {:ok, issues}) end,
        lease: fn _, fun -> fun.() end,
        scan: &scan/1,
        workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
        unchanged: fn _ -> true end,
        checkpoint: fn _ -> {:ok, %{}} end,
        session: fn _, prompt, _, _ ->
          assert prompt =~ "recover exact action"
          Process.put(:after_turn, true)
          {:ok, %{session_id: "incomplete"}}
        end
      ]

      assert {:error, _} = run_group("incoming", issues, issues, opts)
      assert {:ok, %{"processed" => nil}} = Store.read("incoming")
    end
  end

  test "runner errors never consume an observation", %{issues: issues, root: root} do
    defaults = [
      fetch: fn _ -> {:ok, issues} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ -> {:ok, %{session_id: "s"}} end
    ]

    for override <- [
          [fetch: fn _ -> {:error, :offline} end],
          [fetch: fn _ -> {:ok, []} end],
          [checkpoint: fn _ -> {:error, :offline} end],
          [before_action: fn _ -> {:error, :offline} end],
          [session: fn _, _, _, _ -> {:error, :offline} end]
        ] do
      assert {:error, _} = run_group("incoming", issues, issues, Keyword.merge(defaults, override))
      assert {:ok, %{"processed" => nil}} = Store.read("incoming")
    end

    File.write!(Store.path("incoming"), "corrupt")
    assert {:error, :yolo_state_corrupt} = run_group("incoming", issues, issues)
  end

  test "dispatch receipts survive member changes, no-op exits, status roundtrips and restart", %{issues: [first, second | _]} do
    alias SymphonyElixir.Yolo.Delivery
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    start = fn group, _ ->
      {:ok, record} = Store.read(group)
      :ok = Delivery.reserve(group, "started", record["observations"])
      send(self(), :dispatched)
      {:error, :session_exited_without_decision}
    end

    opts = [scan: &scan/1, start: start]
    tick(state, [first], opts)
    assert_receive :dispatched
    tick(state, [first], opts)
    refute_receive :dispatched
    tick(state, [%{first | state: "Todo"}], opts)
    refute_receive :dispatched
    tick(state, [first, second], opts)
    assert_receive :dispatched
    {:ok, record} = Store.read("incoming")
    {:ok, observed, _} = Observation.capture([first, second], %{}, scan: &scan/1)
    assert Delivery.pending([first, second], observed, record) == []
    for members <- [[first], [second], [second, first]], do: tick(state, members, opts)
    refute_receive :dispatched
    tick(state, [%{first | description: "changed requirement"}], opts)
    assert_receive :dispatched
    tick(state, [%{first | description: "changed requirement"}], opts)
    refute_receive :dispatched
  end

  test "unchanged legacy completions survive migration and group membership changes", %{issues: [first, second | _]} do
    alias SymphonyElixir.Relay.Store, as: Digest
    alias SymphonyElixir.Yolo.Delivery
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    legacy_issue = Map.take(first, [:id, :title, :description, :state, :assignee_id, :delegate_id, :blocked_by, :project_id, :team_id]) |> Map.put(:labels, [])
    legacy = %{first.id => %{"signal" => "old", "semantic" => Digest.digest({legacy_issue, []})}}
    {:ok, record} = Store.read("incoming")
    :ok = Store.write("incoming", Map.merge(record, %{"observations" => legacy, "processed" => Observation.fingerprint(legacy)}))

    start = fn group, _ ->
      {:ok, record} = Store.read(group)
      {:ok, observations, _} = Observation.capture([first, second], %{}, scan: &scan/1)
      send(self(), {:pending, Delivery.pending([first, second], observations, record)})
      {:error, :not_started}
    end

    opts = [scan: &scan/1, start: start]
    tick(state, [first], opts)
    refute_receive {:pending, _}
    tick(state, [first, second], opts)
    assert_receive {:pending, [^second]}
    {:ok, record} = Store.read("incoming")
    {:ok, changed, _} = Observation.capture([%{first | title: "Changed"}], %{}, scan: &scan/1)
    assert Delivery.pending([first], changed, record) == [first]
  end

  test "fresh predecessor status alone unlocks backlog exactly once and errors stay closed", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:predecessor, "Test (AI)")
    dependencies = fn members -> {:ok, Enum.map(members, &%{&1 | blocked_by: [%{id: "fix", state: Process.get(:predecessor)}]})} end

    opts = [
      dependencies: dependencies,
      scan: &scan/1,
      start: fn group, _ ->
        {:ok, record} = Store.read(group)
        :ok = Delivery.reserve(group, "run", record["observations"])
        send(self(), :dispatched)
        {:error, :done}
      end
    ]

    for _ <- 1..3, do: tick(state, [issue], opts)
    refute_receive :dispatched
    Process.put(:predecessor, "Review")
    tick(state, [issue], opts)
    assert_receive :dispatched
    for _ <- 1..3, do: tick(state, [issue], opts)
    refute_receive :dispatched
    tick(state, [issue], Keyword.put(opts, :dependencies, fn _ -> {:error, :partial_relations} end))
    refute_receive :dispatched

    removed = Keyword.put(opts, :dependencies, &{:ok, &1})
    tick(state, [issue], removed)
    assert_receive :dispatched
    tick(state, [issue], removed)
    refute_receive :dispatched
    Process.put(:predecessor, "Test (AI)")
    tick(state, [issue], opts)
    refute_receive :dispatched
    Process.put(:predecessor, "Review")
    tick(state, [issue], opts)
    assert_receive :dispatched
    tick(state, [issue], opts)
    refute_receive :dispatched
  end

  for state_name <- ["Backlog", "Yolo Review"] do
    test "observed blocking and release reopen #{state_name} once even when the final snapshot repeats", %{issues: [issue | _]} do
      alias SymphonyElixir.Yolo.Delivery
      issue = %{issue | state: unquote(state_name), blocked_by: [%{id: "fix", state: "Review"}]}
      state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

      opts = [
        scan: &scan/1,
        start: fn group, _ ->
          {:ok, record} = Store.read(group)
          :ok = Delivery.reserve(group, "run", record["observations"])
          send(self(), :dispatched)
          {:error, :session_exited_without_decision}
        end
      ]

      tick(state, [issue], opts)
      assert_receive :dispatched
      tick(state, [issue], opts)
      refute_receive :dispatched
      blocked = %{issue | blocked_by: [%{id: "fix", state: "Test (AI)"}]}
      for _ <- 1..2, do: tick(state, [blocked], opts)
      refute_receive :dispatched
      # All runtime state is fresh; the observed wait must survive in the journal.
      tick(%Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}, [issue], opts)
      assert_receive :dispatched
      for _ <- 1..2, do: tick(state, [issue], opts)
      refute_receive :dispatched
    end
  end

  test "a released chain is redelivered together without repeating an unrelated review", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    origin = %{issue | state: "Yolo Review", blocked_by: [%{id: "fix", state: "Yolo Review"}]}
    fix = %{issue | id: "fix", state: "Yolo Review", blocked_by: [%{id: "external", state: "Review"}]}
    unrelated = %{issue | id: "unrelated", state: "Yolo Review"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    opts = [
      scan: &scan/1,
      runner: fn group, members, _ ->
        {:ok, record} = Store.read(group)
        ids = Enum.map(members, & &1.id)
        :ok = Delivery.reserve(group, "run", Map.take(record["observations"], ids))
        send(self(), {:dispatched, ids})
      end,
      start: fn _, callback ->
        callback.()
        {:error, :session_exited}
      end
    ]

    tick(state, [origin, fix, unrelated], opts)
    assert_receive {:dispatched, ["fix", "member0", "unrelated"]}
    tick(state, [origin, %{fix | blocked_by: [%{id: "external", state: "Test (AI)"}]}, unrelated], opts)
    refute_receive {:dispatched, _}
    tick(state, [origin, fix, unrelated], opts)
    assert_receive {:dispatched, ["fix", "member0"]}
    tick(state, [origin, fix, unrelated], opts)
    refute_receive {:dispatched, _}
  end

  test "dependency reads require complete pagination and actual predecessor states" do
    alias SymphonyElixir.Yolo.Dependencies
    node = fn id, state -> %{"id" => id, "type" => "blocks", "issue" => %{"id" => id, "identifier" => id, "state" => %{"name" => state, "type" => "started"}}} end

    query = fn _, %{after: cursor} ->
      {nodes, page} =
        if cursor == nil do
          {[node.("b", "Yolo Review")], %{"hasNextPage" => true, "endCursor" => "next"}}
        else
          {[node.("a", "Test (AI)")], %{"hasNextPage" => false}}
        end

      {:ok, %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => nodes, "pageInfo" => page}}}}}
    end

    assert {:ok, [%{id: "a", state: "Test (AI)"}, %{id: "b", state: "Yolo Review"}]} = Dependencies.blockers("origin", query: query)

    for response <- [%{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}, %{"nodes" => [%{"id" => "bad", "type" => "blocks"}], "pageInfo" => %{"hasNextPage" => false}}] do
      assert {:error, _} = Dependencies.blockers("origin", query: fn _, _ -> {:ok, %{"data" => %{"issue" => %{"inverseRelations" => response}}}} end)
    end
  end

  test "review dependency components reject cycles and unrelated work cannot deadlock a chain", %{issues: [issue | _]} do
    a = %{issue | id: "a", state: "Yolo Review", blocked_by: [%{id: "b", state: "Yolo Review"}]}
    b = %{issue | id: "b", state: "Yolo Review", blocked_by: [%{id: "c", state: "Yolo Review"}]}
    c = %{issue | id: "c", state: "Yolo Review"}
    backlog = %{issue | id: "later", blocked_by: [%{id: "a", state: "Yolo Review"}]}
    assert Group.groups([a, backlog, c, b]) == %{"review" => [c, b, a]}
    assert Group.groups([a, b, %{c | blocked_by: [%{id: "a", state: "Yolo Review"}]}]) == %{}
    assert Group.groups([a, b, %{c | blocked_by: [%{id: "external", state: "BLOCKER"}]}]) == %{}
  end

  test "Yolo Review raw transitions cannot bypass acceptance or go backwards", %{issues: [issue | _]} do
    issue = %{issue | state: "Yolo Review"}

    for target <- ["BLOCKER", "Fertig", "Test (AI)", "Review"] do
      mutation = %{"query" => "mutation { issueUpdate(id: \"#{issue.id}\", input: {stateId: \"target\"}) { success } }"}

      query = fn _, _ ->
        {:ok, %{"data" => %{"issue" => %{"id" => issue.id, "team" => %{"states" => %{"nodes" => [%{"id" => "target", "name" => target}], "pageInfo" => %{"hasNextPage" => false}}}}}}}
      end

      assert {:error, reason} = CommentActionGuard.check(mutation, query: query, fetch_issue: fn _ -> {:ok, [issue]} end)
      assert reason == if(target == "Review", do: :yolo_review_handoff_required, else: :yolo_review_monotone)
    end
  end
end
