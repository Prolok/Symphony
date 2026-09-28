defmodule SymphonyElixir.YoloRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Config, ProjectContext, WaitMarker, Yolo}

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.Budget
  alias SymphonyElixir.Linear.CommentActionGuard
  alias SymphonyElixir.Linear.Description
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.Yolo.{BlockerBrake, Completion, Coordinator, Escalation, Group, Impulse}
  alias SymphonyElixir.Yolo.{Observation, Operations, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Journal

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

  defp init_review_git(root, context) do
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)
  end

  defp inbox(versions \\ %{}), do: %{"versions" => versions, "last_successful_scan" => "now", "scan_error" => nil}
  defp scan(_), do: {:ok, inbox()}

  defp fixture_delivery_end(group, run_id) do
    {:ok, record} = Store.read(group)
    Store.write(group, Map.put(record, "delivery_ends", Map.put(record["delivery_ends"] || %{}, run_id, true)))
  end

  defp agent_session(issue, id, time) do
    %{
      "id" => id,
      "createdAt" => time,
      "appUser" => %{"id" => "pai"},
      "issue" => %{"id" => issue.id},
      "sourceComment" => nil,
      "comment" => %{"id" => "root-#{id}", "issue" => %{"id" => issue.id}, "isArtificialAgentSessionRoot" => true}
    }
  end

  defp history_observe(issues, record, opts) do
    Impulse.observe(issues, record, Keyword.put_new(opts, :sessions, fn _ -> {:ok, []} end))
  end

  test "a short withdrawal and redelegation becomes one durable review impulse", %{issues: [issue | _]} do
    history = fn id, fields ->
      Map.merge(
        %{"id" => id, "createdAt" => "2026-09-24T12:00:00Z", "fromDelegate" => nil, "toDelegate" => nil, "fromPriority" => nil, "toPriority" => nil, "actor" => nil, "botActor" => nil},
        fields
      )
    end

    baseline = history.("baseline", %{})
    withdrawn = history.("withdrawn", %{"fromDelegate" => %{"id" => "pai"}})
    restored = history.("restored", %{"toDelegate" => %{"id" => "pai"}})
    event = fn position -> %{"generation" => "relay-generation", "position" => position, "event_id" => "event-#{position}"} end
    issue = %{issue | relay_event: event.(1)}
    assert {:ok, record} = history_observe([issue], %{}, history: fn _ -> {:ok, [baseline]} end)
    assert Impulse.generations(record)[issue.id] == 0

    issue = %{issue | relay_event: event.(3)}
    history_page = fn _ -> {:ok, [restored, withdrawn, baseline]} end
    assert {:ok, resumed} = history_observe([issue], record, history: history_page)
    assert Impulse.generations(resumed)[issue.id] == 1
    assert get_in(resumed, ["impulses", issue.id, "reason"]) == "delegated_again"

    assert {:ok, ^resumed} =
             history_observe([issue], resumed, history: fn _ -> flunk("replayed event must not query history") end)

    assert {:error, :yolo_history_gap} =
             history_observe([%{issue | relay_event: event.(4)}], resumed, history: fn _ -> {:ok, [withdrawn]} end)
  end

  test "a coalesced withdrawal and redelegation uses the new agent session once", %{issues: [issue | _]} do
    event = fn position -> %{"generation" => "relay", "position" => position, "event_id" => "event-#{position}"} end

    root = fn id ->
      %{
        "id" => id,
        "createdAt" => "2026-09-28T06:23:55Z",
        "updatedAt" => "2026-09-28T06:27:58Z",
        "fromDelegate" => nil,
        "toDelegate" => nil,
        "actor" => %{"id" => "human", "app" => false},
        "botActor" => nil
      }
    end

    first = agent_session(issue, "session-1", "2026-09-28T06:00:00Z")
    second = agent_session(issue, "session-2", "2026-09-28T06:27:58Z")
    issue = %{issue | relay_event: event.(1)}
    history = fn _ -> {:ok, [root.("merged")]} end
    assert {:ok, baseline} = Impulse.observe([issue], %{}, history: history, sessions: fn _ -> {:ok, [first]} end)
    assert Impulse.generations(baseline)[issue.id] == 0

    issue = %{issue | relay_event: event.(2)}
    opts = [history: history, sessions: fn _ -> {:ok, [second, first]} end]
    assert {:ok, resumed} = Impulse.observe([issue], baseline, opts)
    assert get_in(resumed, ["impulses", issue.id, "reason"]) == "delegated_again"
    assert Impulse.generations(resumed)[issue.id] == 1
    replay_opts = [history: fn _ -> flunk("unchanged relay must not read history") end, sessions: fn _ -> flunk("unchanged relay must not read sessions") end]
    for _ <- 1..10, do: assert({:ok, ^resumed} = Impulse.observe([issue], resumed, replay_opts))
    assert {:ok, replayed} = Impulse.observe([%{issue | relay_event: event.(3)}], resumed, opts)
    assert Impulse.generations(replayed)[issue.id] == 1

    explicit = root.("explicit") |> Map.put("toDelegate", %{"id" => "pai"})
    together = Keyword.put(opts, :history, fn _ -> {:ok, [explicit, root.("merged")]} end)
    assert {:ok, combined} = Impulse.observe([issue], baseline, together)
    assert Impulse.generations(combined)[issue.id] == 1
    assert get_in(combined, ["impulses", issue.id, "reason"]) == "delegated_again"
  end

  test "a new session with the same timestamp and a smaller id is observed once", %{issues: [issue | _]} do
    at = "2026-09-28T06:27:58Z"
    first = agent_session(issue, "z-session", at)
    second = agent_session(issue, "a-session", at)
    history = fn _ -> {:ok, [%{"id" => "merged", "createdAt" => at, "updatedAt" => at, "fromDelegate" => nil, "toDelegate" => nil}]} end
    event = fn n -> %{"generation" => "relay", "position" => n, "event_id" => "event-#{n}"} end
    issue = %{issue | relay_event: event.(1)}

    assert {:ok, baseline} = Impulse.observe([issue], %{}, history: history, sessions: fn _ -> {:ok, [first]} end)
    assert Impulse.generations(baseline)[issue.id] == 0

    issue = %{issue | relay_event: event.(2)}
    opts = [history: history, sessions: fn _ -> {:ok, [second, first]} end]
    assert {:ok, observed} = Impulse.observe([issue], baseline, opts)
    assert Impulse.generations(observed)[issue.id] == 1
    assert get_in(observed, ["impulses", issue.id, "reason"]) == "delegated_again"

    assert {:ok, replayed} = Impulse.observe([%{issue | relay_event: event.(3)}], observed, opts)
    assert Impulse.generations(replayed)[issue.id] == 1
  end

  test "a visible withdrawal waits for redelegation and an unchanged issue stays quiet", %{issues: [issue | _]} do
    base = %{"id" => "base", "createdAt" => "2026-09-28T06:00:00Z", "fromDelegate" => nil, "toDelegate" => nil}
    withdrawn = %{base | "id" => "withdrawn", "createdAt" => "2026-09-28T06:23:55Z", "fromDelegate" => %{"id" => "pai"}}
    first = agent_session(issue, "session-1", "2026-09-28T06:00:00Z")
    second = agent_session(issue, "session-2", "2026-09-28T06:27:58Z")
    event = fn n -> %{"generation" => "relay", "position" => n, "event_id" => "event-#{n}"} end
    issue = %{issue | relay_event: event.(1)}
    base_history = fn _ -> {:ok, [base]} end
    withdrawn_history = fn _ -> {:ok, [withdrawn, base]} end
    first_session = fn _ -> {:ok, [first]} end
    two_sessions = fn _ -> {:ok, [second, first]} end
    base_opts = [history: base_history, sessions: first_session]
    withdrawn_opts = [history: withdrawn_history, sessions: first_session]
    restored_opts = [history: withdrawn_history, sessions: two_sessions]
    assert {:ok, baseline} = Impulse.observe([issue], %{}, base_opts)

    issue = %{issue | delegate_id: nil, relay_event: event.(2)}
    assert {:ok, withdrawn_record} = Impulse.observe([issue], baseline, withdrawn_opts)
    assert Impulse.generations(withdrawn_record)[issue.id] == 0

    issue = %{issue | delegate_id: "pai", relay_event: event.(3)}
    assert {:ok, restored} = Impulse.observe([issue], withdrawn_record, restored_opts)
    assert Impulse.generations(restored)[issue.id] == 1
    assert get_in(restored, ["impulses", issue.id, "reason"]) == "delegated_again"

    assert {:ok, unchanged} = Impulse.observe([%{issue | relay_event: event.(4)}], restored, restored_opts)
    assert Impulse.generations(unchanged)[issue.id] == 1
    assert get_in(unchanged, ["impulses", issue.id, "reason"]) == "no_relevant_history"
  end

  test "agent sessions require complete pages and a bound delegation root", %{issues: [issue | _]} do
    base = %{"id" => "base", "createdAt" => "2026-09-28T06:00:00Z"}
    first = agent_session(issue, "session-1", "2026-09-28T06:00:00Z")
    mention = agent_session(issue, "mention", "2026-09-28T06:20:00Z") |> Map.put("sourceComment", %{"id" => "trigger"})
    foreign = agent_session(issue, "foreign", "2026-09-28T06:21:00Z") |> put_in(["issue", "id"], "other")
    second = agent_session(issue, "session-2", "2026-09-28T06:27:58Z")
    event = fn n -> %{"generation" => "relay", "position" => n, "event_id" => "event-#{n}"} end
    issue = %{issue | relay_event: event.(1)}
    history = fn _ -> {:ok, [base]} end
    assert {:ok, baseline} = Impulse.observe([issue], %{}, history: history, sessions: fn _ -> {:ok, [first]} end)

    changed = %{issue | relay_event: event.(2)}

    assert {:error, :yolo_session_gap} =
             Impulse.observe([changed], baseline,
               history: history,
               sessions: fn _ -> {:ok, [second]} end
             )

    legacy_ids = update_in(baseline, ["impulses", issue.id], &Map.delete(&1, "session_head_ids"))

    assert {:ok, migrated_ids} =
             Impulse.observe([changed], legacy_ids,
               history: history,
               sessions: fn _ -> {:ok, [second, first]} end
             )

    assert Impulse.generations(migrated_ids)[issue.id] == 0
    assert get_in(migrated_ids, ["impulses", issue.id, "session_head_ids"]) == ["session-2"]

    assert {:error, :yolo_history_incomplete} =
             Impulse.observe([changed], baseline,
               history: history,
               sessions: fn _ -> {:ok, [%{second | "id" => nil}, first]} end
             )

    assert {:ok, unrelated} =
             Impulse.observe([%{issue | relay_event: event.(2)}], baseline,
               history: fn _ -> {:ok, [base]} end,
               sessions: fn _ -> {:ok, [foreign, mention, first]} end
             )

    assert Impulse.generations(unrelated)[issue.id] == 0

    query = fn document, variables ->
      if String.contains?(document, "YoloIssueHistory") do
        {:ok, %{"data" => %{"issue" => %{"history" => %{"nodes" => [base], "pageInfo" => %{"hasNextPage" => false}}}}}}
      else
        {nodes, page} =
          if variables[:after] == nil,
            do: {[second, mention], %{"hasNextPage" => true, "endCursor" => "page-1"}},
            else: {[foreign, first], %{"hasNextPage" => false, "endCursor" => nil}}

        {:ok, %{"data" => %{"issue" => %{"agentSessions" => %{"nodes" => nodes, "pageInfo" => page}}}}}
      end
    end

    assert {:ok, resumed} = Impulse.observe([%{issue | relay_event: event.(2)}], baseline, query: query)
    assert Impulse.generations(resumed)[issue.id] == 1
    assert get_in(resumed, ["impulses", issue.id, "session_head"]) == "session-2"

    legacy = update_in(baseline, ["impulses", issue.id], &Map.delete(&1, "session_head"))
    assert {:ok, migrated} = Impulse.observe([%{issue | relay_event: event.(2)}], legacy, query: query)
    assert Impulse.generations(migrated)[issue.id] == 0
    assert get_in(migrated, ["impulses", issue.id, "session_head"]) == "session-2"

    incomplete = fn document, _ ->
      relation =
        if String.contains?(document, "YoloIssueHistory"),
          do: {"history", [base], false},
          else: {"agentSessions", [second], true}

      {field, nodes, more} = relation
      {:ok, %{"data" => %{"issue" => %{field => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more}}}}}}
    end

    changed = %{issue | relay_event: event.(2)}
    assert {:error, :yolo_page_incomplete} = Impulse.observe([changed], baseline, query: incomplete)

    assert {:error, :yolo_history_incomplete} =
             Impulse.observe([changed], baseline,
               history: history,
               sessions: fn _ -> {:ok, [%{second | "comment" => nil}]} end
             )
  end

  test "relay snapshot establishes history baseline before the first event", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.relay, %{"consumer_id" => "test"}))

    baseline = %{
      "id" => "baseline",
      "createdAt" => "2026-09-24T12:00:00Z",
      "fromDelegate" => nil,
      "toDelegate" => nil,
      "fromPriority" => nil,
      "toPriority" => nil,
      "actor" => nil,
      "botActor" => nil
    }

    reassigned = %{baseline | "id" => "reassigned", "toDelegate" => %{"id" => "pai"}}
    assert {:ok, record} = history_observe([issue], %{}, history: fn _ -> {:ok, [baseline]} end)
    assert get_in(record, ["impulses", issue.id, "history_head"]) == "baseline"
    event = %{"generation" => "relay", "position" => 1, "event_id" => "event-1"}
    history_page = fn _ -> {:ok, [reassigned, baseline]} end
    assert {:ok, resumed} = history_observe([%{issue | relay_event: event}], record, history: history_page)
    assert Impulse.generations(resumed)[issue.id] == 1
  end

  test "history input stays conservative across missing, malformed and unverified baselines", %{issues: [issue | _]} do
    assert {:ok, idle} = Impulse.observe([%{issue | relay_event: nil}], %{})
    assert get_in(idle, ["impulses", issue.id, "reason"]) == "no_relay_event"

    event = fn position -> %{"generation" => "relay", "position" => position, "event_id" => "event-#{position}"} end
    issue = %{issue | relay_event: event.(1)}
    node = %{"id" => "assigned", "createdAt" => "2026-09-24T12:00:00Z", "toDelegate" => %{"id" => "pai"}}

    query = fn _, _ ->
      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "history" => %{"nodes" => [node], "pageInfo" => %{"hasNextPage" => false}},
             "agentSessions" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}
           }
         }
       }}
    end

    assert {:ok, baseline} = Impulse.observe([issue], %{}, query: query)
    assert Impulse.generations(baseline)[issue.id] == 0
    assert {:error, :yolo_history_incomplete} = history_observe([issue], %{}, history: fn _ -> {:ok, [%{"id" => "invalid"}]} end)

    prior = %{"impulses" => %{issue.id => %{"history_head" => nil, "generation" => 0, "relay" => event.(0)}}}
    assert {:ok, resumed} = history_observe([issue], prior, history: fn _ -> {:ok, [node]} end)
    assert Impulse.generations(resumed)[issue.id] == 1

    prior = %{"impulses" => %{issue.id => %{"reason" => "no_relay_event", "generation" => 0, "relay" => event.(0)}}}
    assert {:ok, ignored} = history_observe([issue], prior, history: fn _ -> {:ok, [node]} end)
    assert Impulse.generations(ignored)[issue.id] == 0
  end

  test "only a verified human priority increase creates an impulse", %{issues: [issue | _]} do
    base = %{
      "id" => "baseline",
      "createdAt" => "2026-09-24T12:00:00Z",
      "fromDelegate" => nil,
      "toDelegate" => nil,
      "fromPriority" => nil,
      "toPriority" => nil,
      "actor" => nil,
      "botActor" => nil
    }

    event = fn position -> %{"generation" => "relay-generation", "position" => position, "event_id" => "event-#{position}"} end
    issue = %{issue | relay_event: event.(1)}
    {:ok, baseline} = history_observe([issue], %{}, history: fn _ -> {:ok, [base]} end)

    cases = [
      {0, 2, %{"id" => "human", "app" => false}, nil, 1},
      {3, 1, %{"id" => "human", "app" => false}, nil, 1},
      {2, 1, %{"id" => "bot", "app" => true}, nil, 0},
      {2, 1, nil, %{"id" => "bot"}, 0},
      {1, 4, %{"id" => "human", "app" => false}, nil, 0},
      {2, 2, %{"id" => "human", "app" => false}, nil, 0}
    ]

    for {from, to, actor, bot, expected} <- cases do
      change = %{base | "id" => "change", "fromPriority" => from, "toPriority" => to, "actor" => actor, "botActor" => bot}

      history_page = fn _ -> {:ok, [change, base]} end
      assert {:ok, record} = history_observe([%{issue | relay_event: event.(2)}], baseline, history: history_page)

      assert Impulse.generations(record)[issue.id] == expected
    end
  end

  test "coordinator retries a pending notification only after a fresh eligible lookup", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_yolo_agent, "pai"))
    issue = %{issue | url: "https://linear.example/PRO-0"}
    proposal = %{"escalation" => %{"cause" => "Route fehlt", "attempts" => "Review abgeschlossen", "proposal" => "Route prüfen", "decision" => "Benachrichtigen"}}
    missing = [escalation_route: fn _, _ -> {:error, :openclaw_normal_channel_unavailable} end]
    assert {:error, :openclaw_normal_channel_unavailable} = Escalation.notify(issue, proposal, missing)
    assert {:ok, true} = Escalation.pending(issue.id)

    state = %Orchestrator.State{max_concurrent_agents: 0, codex_totals: %{}}

    base = [
      start: fn _, _ -> flunk("notification retry must not start a review") end,
      escalation_route: fn _, _ -> {:ok, %{"channel" => "bound", "to" => "human"}} end,
      escalation_send: fn _, _, _ ->
        send(self(), :notification_sent)
        {:ok, %{"messageId" => "sent"}}
      end
    ]

    tick(state, [issue], Keyword.put(base, :fetch, fn _ -> {:error, :refresh_unavailable} end))
    assert {:ok, true} = Escalation.pending(issue.id)
    tick(state, [issue], Keyword.put(base, :fetch, fn _ -> {:ok, []} end))
    assert {:ok, true} = Escalation.pending(issue.id)
    tick(state, [issue], Keyword.put(base, :fetch, fn _ -> {:ok, [%{issue | state: "Review", delegate_id: nil}]} end))
    assert {:ok, true} = Escalation.pending(issue.id)
    refute_receive :notification_sent

    handed_over = %{issue | state: "Yolo Review", delegate_id: nil}
    tick(state, [handed_over], Keyword.put(base, :fetch, fn _ -> {:ok, [handed_over]} end))
    assert_receive :notification_sent
    assert {:ok, false} = Escalation.pending(issue.id)

    revised = put_in(proposal, ["escalation", "decision"], "Andere Frage")
    assert {:error, :openclaw_normal_channel_unavailable} = Escalation.notify(issue, revised, missing)
    assert {:ok, true} = Escalation.pending(issue.id)

    tick(
      state,
      [issue],
      Keyword.merge(base,
        fetch: fn _ -> {:ok, [issue]} end,
        escalation_route: fn _, _ -> {:error, :route_still_missing} end
      )
    )

    assert {:ok, true} = Escalation.pending(issue.id)

    tick(state, [handed_over], Keyword.put(base, :fetch, fn _ -> {:ok, [handed_over]} end))
    assert_receive :notification_sent
    assert {:ok, false} = Escalation.pending(issue.id)

    key = "escalation:" <> issue.id
    {:ok, record} = Store.read(key)
    :ok = Store.write(key, Map.put(record, "messages", []))
    assert tick(state, [issue], base).yolo_runs == %{}
  end

  test "session-backed redelegation restarts an ended delivery once after restart", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    baseline = %{
      "id" => "before",
      "createdAt" => "2026-09-24T12:00:00Z",
      "fromDelegate" => nil,
      "toDelegate" => nil,
      "fromPriority" => nil,
      "toPriority" => nil,
      "actor" => nil,
      "botActor" => nil
    }

    merged = Map.put(baseline, "updatedAt", "2026-09-24T12:04:00Z")
    first = agent_session(issue, "session-1", "2026-09-24T12:00:00Z")
    second = agent_session(issue, "session-2", "2026-09-24T12:04:00Z")
    event = fn position -> %{"generation" => "relay", "position" => position, "event_id" => "event-#{position}"} end
    Process.put(:history_nodes, [baseline])
    Process.put(:session_nodes, [first])

    opts = [
      scan: &scan/1,
      history: fn _ -> {:ok, Process.get(:history_nodes)} end,
      sessions: fn _ -> {:ok, Process.get(:session_nodes)} end,
      start: fn group, _ ->
        {:ok, record} = Store.read(group)
        :ok = Delivery.reserve(group, "ended-run", record["observations"])
        :ok = fixture_delivery_end(group, "ended-run")
        send(self(), :review_started)
        {:error, :fixture_end}
      end
    ]

    issue = %{issue | relay_event: event.(1)}
    tick(state, [issue], opts)
    assert_receive :review_started
    tick(state, [issue], opts)
    refute_receive :review_started

    Process.put(:history_nodes, [merged])
    Process.put(:session_nodes, [second, first])
    issue = %{issue | relay_event: event.(3)}
    tick(%{state | running: %{issue.id => %{}}}, [issue], opts)
    refute_receive :review_started
    tick(%Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}, [issue], opts)
    assert_receive :review_started
    for _ <- 1..3, do: tick(state, [issue], opts)
    refute_receive :review_started
    tick(state, [%{issue | delegate_id: nil}], opts)
    refute_receive :review_started
  end

  test "missing history evidence defers dispatch with a durable reason", %{issues: [issue | _]} do
    issue = %{issue | relay_event: %{"generation" => "relay", "position" => 1, "event_id" => "event-1"}}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    opts = [scan: &scan/1, history: fn _ -> {:error, :history_offline} end, start: fn _, _ -> flunk("history is required") end]

    assert tick(state, [issue], opts).yolo_runs == %{}
    assert {:ok, record} = Store.read("incoming")
    assert record["waiting_reason"] == ":history_offline"
    assert record["observations"] == %{}
  end

  test "new source-bound operator duty after technical work is delivered once", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    first = operator_workpad("first", "a")
    Process.put(:operator_versions, %{"first" => first})
    Process.put(:operator_current, %{"workpad" => "first"})

    opts = [
      scan: fn _ -> {:ok, Map.put(inbox(Process.get(:operator_versions)), "current", Process.get(:operator_current))} end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:operator_versions)[Process.get(:operator_current)["workpad"]]["source"]["body"]}]} end,
      start: fn "blocker", _ ->
        send(self(), :operator_started)
        {:error, :observed_start}
      end
    ]

    tick(state, [issue], opts)
    assert_receive :operator_started
    complete_operator_observation(issue)
    for _ <- 1..2, do: tick(state, [issue], opts)
    refute_receive :operator_started

    for phase <- ["In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)"] do
      tick(state, [%{issue | state: phase}], opts)
    end

    second = operator_workpad("second", "b")
    Process.put(:operator_versions, %{"first" => first, "second" => second})
    Process.put(:operator_current, %{"workpad" => "second"})
    changed = %{issue | last_comment_signal: %{relay_epoch: 2}}
    tick(state, [changed], opts)
    assert_receive :operator_started
    complete_operator_observation(issue)

    # The only durable restart input is the journal; no in-memory run survives.
    for epoch <- 3..5 do
      chatter = put_in(second, ["source", "body"], second["source"]["body"] <> "\n### Verlauf\n\nFortschritt #{epoch}\n")
      Process.put(:operator_versions, Map.put(Process.get(:operator_versions), "chatter", chatter))
      Process.put(:operator_current, %{"workpad" => "chatter"})
      tick(state, [%{issue | last_comment_signal: %{relay_epoch: epoch}}], opts)
      refute_receive :operator_started
    end

    # Removal and restoration of an old duty cannot reopen either decision.
    removed = put_in(second, ["source", "body"], "## Symphony Workpad\n\nErgebnis dokumentiert.\n")
    Process.put(:operator_versions, Map.put(Process.get(:operator_versions), "removed", removed))

    for {epoch, key} <- [{6, "removed"}, {7, "first"}] do
      Process.put(:operator_current, %{"workpad" => key})
      tick(state, [%{issue | last_comment_signal: %{relay_epoch: epoch}}], opts)
      refute_receive :operator_started
    end
  end

  test "operator delivery keeps active claims and failed snapshots closed", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    state = %Orchestrator.State{max_concurrent_agents: 2, codex_totals: %{}}
    duty = operator_workpad("new", "b")
    snapshot = Map.put(inbox(%{"new" => duty}), "current", %{"workpad" => "new"})
    start = fn _, _ -> flunk("reserved or unknown operator work must not start") end
    opts = [scan: fn _ -> {:ok, snapshot} end, start: start]

    for busy <- [%{state | claimed: MapSet.new([issue.id])}, %{state | running: %{issue.id => %{}}}] do
      assert tick(busy, [issue], opts).yolo_runs == %{}
    end

    pid = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    active = %{pid: pid, ids: [issue.id], issues: [issue], event: %{}}
    assert tick(%{state | yolo_runs: %{"blocker" => active}}, [issue], opts).yolo_runs == %{"blocker" => active}

    {:ok, observations, _} = Observation.capture([issue], %{}, scan: opts[:scan])
    assert :ok = Yolo.Delivery.reserve("blocker", "newer-run", observations)
    {:ok, before} = Store.read("blocker")
    assert tick(state, [issue], opts).yolo_runs == %{}
    assert {:ok, after_poll} = Store.read("blocker")
    assert after_poll["deliveries"] == before["deliveries"]

    changed = %{issue | last_comment_signal: %{relay_epoch: "new"}}

    for response <- [{:error, :offline}, {:error, :rate_limited}, {:ok, %{snapshot | "scan_error" => "partial"}}, {:ok, Map.delete(snapshot, "current")}] do
      assert tick(state, [changed], Keyword.put(opts, :scan, fn _ -> response end)).yolo_runs == %{}
      assert {:ok, waiting} = Store.read("blocker")
      assert Map.delete(waiting, "waiting_reason") == Map.delete(after_poll, "waiting_reason")
      assert is_binary(waiting["waiting_reason"])
    end
  end

  test "operator runner confirms only delivered duty and leaves new input open", %{issues: [issue | _], root: root} do
    issue = %{issue | state: "BLOCKER"}
    first = operator_workpad("first", "a")
    Process.put(:operator_snapshot, Map.put(inbox(%{"first" => first}), "current", %{"workpad" => "first"}))

    opts = [
      fetch: fn _ -> {:ok, [issue]} end,
      lease: fn _, fun -> fun.() end,
      scan: fn _ -> {:ok, Process.get(:operator_snapshot)} end,
      workpad_comments: fn _ ->
        snapshot = Process.get(:operator_snapshot)
        {:ok, [%{id: "workpad", body: snapshot["versions"][snapshot["current"]["workpad"]]["source"]["body"]}]}
      end,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ ->
        send(self(), :operator_decision)
        assert :ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "Prüfung ausgeführt"}, fetch: fn _ -> {:ok, [issue]} end, before_action: fn _ -> :ok end)
        {:ok, %{session_id: "operator"}}
      end
    ]

    assert :ok = run_group("blocker", [issue], [issue], opts)
    assert_receive :operator_decision
    assert {:error, :yolo_group_changed} = run_group("blocker", [issue], [issue], opts)
    refute_receive :operator_decision

    second = operator_workpad("second", "b")
    Process.put(:operator_snapshot, Map.put(inbox(%{"first" => first, "second" => second}), "current", %{"workpad" => "second"}))
    {:ok, second_observations, _} = Observation.capture([issue], %{}, scan: opts[:scan])
    {:ok, prior_record} = Store.read("blocker")
    assert second_observations[issue.id]["source"] != prior_record["observations"][issue.id]["source"]
    assert Yolo.Delivery.pending([issue], second_observations, prior_record) == [issue]
    blocked = Keyword.put(opts, :checkpoint, fn _ -> {:error, :new_input_requires_processing} end)
    assert {:error, :new_input_requires_processing} = run_group("blocker", [issue], [issue], blocked)
    refute_receive :operator_decision
    {:ok, blocked_record} = Store.read("blocker")
    assert :ok = Store.write("blocker", Map.merge(blocked_record, %{"checkout_cleanup_blocked" => false, "attempt" => Map.put(blocked_record["attempt"], "checkout_cleanup", "removed")}))
    assert :ok = run_group("blocker", [issue], [issue], opts)
    assert_receive :operator_decision
    assert {:error, :yolo_group_changed} = run_group("blocker", [issue], [issue], opts)
    refute_receive :operator_decision
  end

  test "operator runner releases a delivery when its source-bound cause disappears before reservation", %{issues: [issue | _], root: root} do
    issue = %{issue | state: "BLOCKER"}
    duty = operator_workpad("duty", "a")
    snapshot = Map.put(inbox(%{"duty" => duty}), "current", %{"workpad" => "duty"})
    Process.put(:brake_reads, 0)

    comments = fn _ ->
      reads = Process.get(:brake_reads) + 1
      Process.put(:brake_reads, reads)
      body = if reads == 1, do: duty["source"]["body"], else: "## Symphony Workpad\n"
      {:ok, [%{id: "workpad", body: body}]}
    end

    opts = [
      fetch: fn _ -> {:ok, [issue]} end,
      lease: fn _, fun -> fun.() end,
      scan: fn _ -> {:ok, snapshot} end,
      workpad_comments: comments,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ -> flunk("failed reservation must not start the PO session") end
    ]

    assert {:error, :blocker_cause_missing} = run_group("blocker", [issue], [issue], opts)
    assert Process.get(:brake_reads) == 2
  end

  test "operator runner surfaces a failed delivery release after a corrupt journal", %{issues: [issue | _], root: root} do
    issue = %{issue | state: "BLOCKER"}
    duty = operator_workpad("duty", "a")
    snapshot = Map.put(inbox(%{"duty" => duty}), "current", %{"workpad" => "duty"})

    opts = [
      fetch: fn _ -> {:ok, [issue]} end,
      lease: fn _, fun -> fun.() end,
      scan: fn _ -> {:ok, snapshot} end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: duty["source"]["body"]}]} end,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, session_opts ->
        File.write!(Store.path("blocker"), "corrupt")
        send(self(), {:release, session_opts[:on_session_start_failure].()})
        {:error, :prestart}
      end
    ]

    assert {:error, :prestart} = run_group("blocker", [issue], [issue], opts)
    assert_receive {:release, {:error, :yolo_state_corrupt}}
  end

  test "only complete confirmed operator workpads extend BLOCKER semantics", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    duty = operator_workpad("duty", "a")
    snapshot = Map.put(inbox(%{"duty" => duty}), "current", %{"workpad" => "duty"})
    assert {:ok, [_]} = Yolo.OperatorHandoff.evidence(issue, snapshot)
    assert {:ok, []} = Yolo.OperatorHandoff.evidence(%{issue | state: "Test (AI)"}, snapshot)

    for version <- [
          %{duty | "origin" => "integration"},
          %{duty | "origin" => "changed_app_output"},
          Map.put(duty, "advisory_suppressed", true),
          put_in(duty, ["source", "body"], "Normaler Eigenkommentar")
        ] do
      assert {:ok, []} = Yolo.OperatorHandoff.evidence(issue, put_in(snapshot, ["versions", "duty"], version))
    end

    body = duty["source"]["body"]

    for malformed <- [
          String.replace(body, String.duplicate("a", 64), "timestamp"),
          String.replace(body, "Test (AI)", "Fertig"),
          String.replace(body, "\"version\":1", "\"version\":2"),
          String.replace(body, "\"version\":1", "\"version\":1.0"),
          String.replace(body, "\"action\":", "\"unexpected\":"),
          body <> body,
          body <> "\n```symphony-operator-handoff\n",
          String.replace(body, "\n```\n", "\n")
        ] do
      broken = put_in(snapshot, ["versions", "duty", "source", "body"], malformed)
      assert {:error, :yolo_operator_handoff_incomplete} = Yolo.OperatorHandoff.evidence(issue, broken)
    end

    missing = %{snapshot | "current" => %{"workpad" => "missing"}}
    assert {:error, :yolo_operator_handoff_incomplete} = Yolo.OperatorHandoff.evidence(issue, missing)
    duplicate = put_in(duty, ["source", "id"], "other")
    multiple = snapshot |> put_in(["versions", "other"], duplicate) |> put_in(["current", "other"], "other")
    assert {:error, :yolo_operator_handoff_incomplete} = Yolo.OperatorHandoff.evidence(issue, multiple)

    # A corrected current version is usable even if an old draft was malformed.
    old = put_in(duty, ["source", "body"], String.replace(body, "\"version\":1", "\"version\":0"))
    with_history = put_in(snapshot, ["versions", "old"], old)
    assert Yolo.OperatorHandoff.evidence(issue, with_history) == Yolo.OperatorHandoff.evidence(issue, snapshot)

    formatted = String.replace(body, "Isolierten Unterbrechungstest", " Isolierten  Unterbrechungstest")
    formatted = put_in(snapshot, ["versions", "duty", "source", "body"], formatted)
    assert Yolo.OperatorHandoff.evidence(issue, formatted) == Yolo.OperatorHandoff.evidence(issue, snapshot)
  end

  test "only the current Pai confirmation wakes a waiting review once", %{issues: [issue | _]} do
    issue = %{issue | state: "Yolo Review", last_comment_signal: %{relay_epoch: "duty"}}
    duty = operator_workpad("duty", "a")
    duty = put_in(duty, ["source", "body"], String.replace(duty["source"]["body"], "Test (AI)", "Yolo Review"))
    snapshot = inbox(%{"duty" => duty}) |> Map.put("current", %{"workpad" => "duty"})
    assert {:ok, digest} = Yolo.OperatorHandoff.current(issue, snapshot)
    assert is_binary(digest)
    assert {:ok, nil} = Yolo.OperatorHandoff.confirmation(issue, snapshot, digest)

    capture = fn member, seen -> Observation.capture([member], seen, scan: fn _ -> {:ok, snapshot} end) end
    assert {:ok, before, _} = capture.(issue, %{})
    source = before[issue.id]["source"]

    confirmation = %{"version" => 1, "handoff_digest" => digest, "result" => "Neustart erfolgreich", "evidence" => "Messung 30 Minuten bestanden"}
    body = "```symphony-operator-confirmation\n#{Jason.encode!(confirmation)}\n```"
    comment = %{"key" => "answer", "origin" => "integration", "deleted" => false, "source" => %{"id" => "answer", "body" => body, "user" => %{"id" => "pai", "app" => true}}}
    answered = snapshot |> put_in(["versions", "answer"], comment) |> put_in(["current", "answer"], "answer")

    for {name, altered} <- [
          {"other_app", put_in(answered, ["versions", "answer", "source", "user", "id"], "other")},
          {"plain", put_in(answered, ["versions", "answer", "source", "body"], "Pai: Neustart erfolgreich")},
          {"wrong_digest", put_in(answered, ["versions", "answer", "source", "body"], String.replace(body, digest, String.duplicate("b", 64)))},
          {"malformed", put_in(answered, ["versions", "answer", "source", "body"], String.replace(body, "\"evidence\":", "\"missing\":"))},
          {"edited", put_in(answered, ["versions", "answer", "source", "editedAt"], "2026-09-28T13:00:00Z")},
          {"deleted", put_in(answered, ["versions", "answer", "deleted"], true)}
        ] do
      member = %{issue | last_comment_signal: %{relay_epoch: name}}
      assert {:ok, observed, _} = Observation.capture([member], before, scan: fn _ -> {:ok, altered} end)
      assert observed[issue.id]["source"] == source
    end

    next_duty = operator_workpad("next", "b")
    next_duty = put_in(next_duty, ["source", "body"], String.replace(next_duty["source"]["body"], "Test (AI)", "Yolo Review"))
    next_snapshot = answered |> put_in(["versions", "next"], next_duty) |> put_in(["current", "workpad"], "next")
    next_issue = %{issue | last_comment_signal: %{relay_epoch: "next"}}
    assert {:ok, still_waiting, _} = Observation.capture([next_issue], before, scan: fn _ -> {:ok, next_snapshot} end)
    assert still_waiting[issue.id]["source"] == source

    answered_issue = %{issue | last_comment_signal: %{relay_epoch: "answer"}}
    assert {:ok, after_answer, _} = Observation.capture([answered_issue], before, scan: fn _ -> {:ok, answered} end)
    refute after_answer[issue.id]["source"] == source

    for {name, altered} <- [
          {"deleted_after_answer", put_in(answered, ["versions", "answer", "deleted"], true)},
          {"edited_after_answer", put_in(answered, ["versions", "answer", "source", "body"], "Pai: Neustart erfolgreich")},
          {"next_duty_after_answer", next_snapshot}
        ] do
      member = %{issue | last_comment_signal: %{relay_epoch: name}}
      assert {:ok, observed, _} = Observation.capture([member], after_answer, scan: fn _ -> {:ok, altered} end)
      assert observed[issue.id]["source"] == after_answer[issue.id]["source"]
    end

    assert {:ok, next_digest} = Yolo.OperatorHandoff.current(issue, next_snapshot)
    next_confirmation = %{confirmation | "handoff_digest" => next_digest}
    next_body = "```symphony-operator-confirmation\n#{Jason.encode!(next_confirmation)}\n```"

    edited_old_answer =
      next_snapshot
      |> put_in(["versions", "answer", "source", "body"], next_body)
      |> put_in(["versions", "answer", "source", "editedAt"], "2026-09-28T13:00:00Z")

    old_edit_issue = %{issue | last_comment_signal: %{relay_epoch: "old-edit"}}

    assert {:ok, after_old_edit, _} =
             Observation.capture([old_edit_issue], after_answer, scan: fn _ -> {:ok, edited_old_answer} end)

    assert after_old_edit[issue.id]["source"] == after_answer[issue.id]["source"]

    next_comment = %{comment | "key" => "answer2", "source" => %{comment["source"] | "id" => "answer2", "body" => next_body}}
    next_answered = next_snapshot |> put_in(["versions", "answer2"], next_comment) |> put_in(["current", "answer2"], "answer2")
    next_answer_issue = %{issue | last_comment_signal: %{relay_epoch: "answer2"}}

    assert {:ok, after_next_answer, _} =
             Observation.capture([next_answer_issue], after_answer, scan: fn _ -> {:ok, next_answered} end)

    refute after_next_answer[issue.id]["source"] == after_answer[issue.id]["source"]

    decided_before = %{"processed" => Observation.fingerprint(before), "observations" => before, "decisions" => %{issue.id => before[issue.id]["semantic"]}}
    assert Yolo.Delivery.pending([answered_issue], before, decided_before) == []
    assert Yolo.Delivery.pending([answered_issue], after_answer, decided_before) == [answered_issue]

    copy = %{comment | "key" => "copy", "source" => %{comment["source"] | "id" => "copy"}}
    duplicate = answered |> put_in(["versions", "copy"], copy) |> put_in(["current", "copy"], "copy")
    repeat_issue = %{issue | last_comment_signal: %{relay_epoch: "copy"}}
    assert {:ok, repeated, _} = Observation.capture([repeat_issue], after_answer, scan: fn _ -> {:ok, duplicate} end)
    assert repeated[issue.id]["source"] == after_answer[issue.id]["source"]

    decided_after = %{"processed" => Observation.fingerprint(after_answer), "observations" => after_answer, "decisions" => %{issue.id => after_answer[issue.id]["semantic"]}}
    assert Yolo.Delivery.pending([repeat_issue], repeated, decided_after) == []
    assert Yolo.Delivery.pending([next_answer_issue], after_next_answer, decided_after) == [next_answer_issue]
  end

  defp operator_workpad(key, source) do
    duty = %{
      "version" => 1,
      "action" => "Isolierten Unterbrechungstest ausführen",
      "head_sha" => String.duplicate(source, 40),
      "source_sha256" => String.duplicate(source, 64),
      "expected" => "Annahme, Unterbrechung und genau eine Folgeentscheidung belegen",
      "resume_state" => "Test (AI)"
    }

    %{
      "key" => key,
      "origin" => "own",
      "deleted" => false,
      "source" => %{"id" => "workpad", "body" => "## Symphony Workpad\n\n### Betreiberauftrag\n\n```symphony-operator-handoff\n#{Jason.encode!(duty)}\n```\n"}
    }
  end

  defp complete_operator_observation(issue) do
    {:ok, record} = Store.read("blocker")
    semantic = record["observations"][issue.id]["semantic"]
    :ok = Store.write("blocker", Map.merge(record, %{"processed" => Observation.fingerprint(record["observations"]), "decisions" => %{issue.id => semantic}}))
  end

  test "public defaults preserve empty reads and admitted issues, and reject corrupt dispatch", %{issues: [issue | _]} do
    assert {:ok, []} = Yolo.Dependencies.refresh([])
    assert {:ok, ^issue} = Yolo.Admission.prepare(issue)
    path = Journal.path("incoming")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "corrupt")
    assert {:error, :openclaw_journal_corrupt} = Yolo.Delivery.reconcile("incoming")
    assert {:error, :openclaw_journal_corrupt} = Yolo.Runner.run("incoming", [issue], [issue])
  end

  test "failed and malformed dependency snapshots cannot become actionable", %{issues: [issue | _]} do
    assert {:error, :offline} = Yolo.Dependencies.refresh([issue], query: fn _, _ -> {:error, :offline} end)

    query = fn _, _ ->
      {:ok, %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => [%{"id" => "missing-type"}], "pageInfo" => %{"hasNextPage" => false}}}}}}
    end

    assert {:error, :yolo_dependencies_incomplete} = Yolo.Dependencies.actionable([issue], query: query)
  end

  test "foreground refresh loads fresh blockers for a relay-stamped review issue", %{issues: [issue | _]} do
    review = %{
      issue
      | state: "Yolo Review",
        blocked_by: [],
        relations_complete: true,
        last_comment_signal: %{relay_epoch: "current"}
    }

    query = fn document, _ ->
      assert document =~ "YoloBlockers"

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "inverseRelations" => %{
               "nodes" => [
                 %{
                   "id" => "relation",
                   "type" => "blocks",
                   "issue" => %{"id" => "fix", "identifier" => "PRO-2", "state" => %{"name" => "Review", "type" => "completed"}}
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }}
    end

    assert {:ok, [%{blocked_by: [%{id: "fix", state_type: "completed"}]}]} =
             Yolo.Dependencies.refresh([review], query: query, wait_comments: fn _ -> {:ok, []} end)
  end

  test "relay-stamped review runner reaches workspace creation without a dependency start exception", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review", last_comment_signal: %{relay_epoch: "current"}}

    query = fn document, _ ->
      assert document =~ "YoloBlockers"
      {:ok, %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
    end

    opts = [
      fetch: fn _ -> {:ok, [%{review | last_comment_signal: nil}]} end,
      lease: fn _, callback -> callback.() end,
      query: query,
      wait_comments: fn _ -> {:ok, []} end,
      scan: &scan/1,
      project: fn -> {:ok, [review]} end,
      workspace: fn _, _ -> {:error, :synthetic_create_failure} end
    ]

    assert {:error, :synthetic_create_failure} = Yolo.Runner.run("review", [review], [review], opts)
  end

  test "coordinator keeps complete relay blockers without a background lookup", %{issues: [issue | _]} do
    review = %{
      issue
      | state: "Yolo Review",
        blocked_by: [],
        relations_complete: true,
        last_comment_signal: %{relay_epoch: "current"}
    }

    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    opts = [
      query: fn document, _ ->
        if document =~ "YoloBlockers", do: flunk("complete relay snapshot must not query blockers")
        {:error, :unexpected_query}
      end,
      wait_comments: fn _ -> {:ok, []} end,
      scan: &scan/1,
      start: fn _, _ -> {:error, :capacity} end
    ]

    assert %Orchestrator.State{} = Coordinator.tick(state, [review], opts)
  end

  test "coordinator uses fallback without relay despite a stale relay epoch", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review", blocked_by: [], relations_complete: true, last_comment_signal: %{relay_epoch: "epoch-1"}}
    state = %Orchestrator.State{max_concurrent_agents: 0, codex_totals: %{}}
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    opts = [
      wait_comments: fn _ ->
        Agent.update(reads, &(&1 + 1))
        {:ok, []}
      end,
      scan: &scan/1,
      start: fn _, _ -> {:error, :capacity} end
    ]

    state = Coordinator.tick(state, [review], opts)
    _state = Coordinator.tick(state, [review], opts)
    assert Agent.get(reads, & &1) == 2
  end

  test "relay marker cache follows comment epochs and its safety interval", %{issues: [issue | _], context: context} do
    review = %{issue | state: "Yolo Review", blocked_by: [], relations_complete: true, last_comment_signal: %{relay_epoch: "first"}}
    {:ok, comments} = Agent.start_link(fn -> [] end)
    {:ok, reads} = Agent.start_link(fn -> 0 end)
    {:ok, target_state} = Agent.start_link(fn -> "Review" end)
    empty_relations = %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}

    opts = [
      relay_background: true,
      relay_ready: fn _ -> true end,
      background_now: fn -> Process.get(:marker_now, 0) end,
      wait_comments: fn _ ->
        Agent.update(reads, &(&1 + 1))
        {:ok, Agent.get(comments, & &1)}
      end,
      query: fn _, _ -> {:ok, empty_relations} end,
      resolve: fn identifier, _ ->
        {:ok, %{id: identifier, identifier: identifier, state: Agent.get(target_state, & &1), marker: true}}
      end
    ]

    assert {:ok, [_], cache} = Yolo.Dependencies.refresh_background([review], %{}, opts)
    Agent.update(comments, fn _ -> ["## Symphony Workpad\nWartet auf: PRI-1", "Wartet auf: PRI-99"] end)
    assert {:ok, [%{blocked_by: []}], cache} = Yolo.Dependencies.refresh_background([review], cache, opts)
    assert Agent.get(reads, & &1) == 1

    changed = %{review | last_comment_signal: %{relay_epoch: "second"}}
    assert {:ok, [updated], cache} = Yolo.Dependencies.refresh_background([changed], cache, opts)
    assert [%{identifier: "PRI-1"}] = updated.blocked_by
    assert Agent.get(reads, & &1) == 2

    described = %{changed | description: "Wartet auf: PRI-2"}
    assert {:ok, [%{blocked_by: targets}], cache} = Yolo.Dependencies.refresh_background([described], cache, opts)
    assert Enum.map(targets, & &1.identifier) == ["PRI-2", "PRI-1"]
    assert Agent.get(reads, & &1) == 2
    Agent.update(target_state, fn _ -> "Merge (AI)" end)
    assert {:ok, [%{blocked_by: [%{state: "Merge (AI)"}]}], cache} = Yolo.Dependencies.refresh_background([changed], cache, opts)
    assert Agent.get(reads, & &1) == 2

    withdrawn = %{changed | delegate_id: nil}
    assert {:ok, [^withdrawn], cache} = Yolo.Dependencies.refresh_background([withdrawn], cache, opts)
    assert {:ok, [redelegated], cache} = Yolo.Dependencies.refresh_background([changed], cache, opts)
    assert [%{identifier: "PRI-1"}] = redelegated.blocked_by
    assert Agent.get(reads, & &1) == 2

    Process.put(:marker_now, 899_999)
    assert {:ok, [_], cache} = Yolo.Dependencies.refresh_background([changed], cache, opts)
    assert Agent.get(reads, & &1) == 2
    Process.put(:marker_now, 900_000)
    assert {:ok, [_], cache} = Yolo.Dependencies.refresh_background([changed], cache, opts)
    assert Agent.get(reads, & &1) == 3

    app = Config.settings!().tracker.app

    on_exit(fn ->
      Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "5000"})
      Budget.pressure(app)
    end)

    Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "999"})
    assert Budget.pressure(app) == :critical
    Process.put(:marker_now, 1_800_000)
    assert {:ok, [_], cache} = Yolo.Dependencies.refresh_background([changed], cache, opts)
    assert Agent.get(reads, & &1) == 3
    Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "5000"})
    assert Budget.pressure(app) == :normal

    fallback = %{changed | last_comment_signal: nil}
    assert {:ok, [_], cache} = Yolo.Dependencies.refresh_background([fallback], cache, opts)
    assert {:ok, [_], _} = Yolo.Dependencies.refresh_background([fallback], cache, opts)
    assert Agent.get(reads, & &1) == 5

    degraded_context = put_in(context.settings.tracker.relay, %{"endpoint" => "https://relay.test"})
    ProjectContext.bind(degraded_context)
    degraded_opts = Keyword.put(opts, :relay_ready, fn _ -> false end)
    assert {:ok, [_], cache} = Yolo.Dependencies.refresh_background([changed], cache, degraded_opts)
    assert {:ok, [_], _} = Yolo.Dependencies.refresh_background([changed], cache, degraded_opts)
    assert Agent.get(reads, & &1) == 7
  end

  test "a later dependency failure retains earlier completed marker scans", %{issues: [first, second | _]} do
    first = %{first | last_comment_signal: %{relay_epoch: "first"}, blocked_by: [], relations_complete: true}
    second = %{second | last_comment_signal: %{relay_epoch: "second"}, blocked_by: [], relations_complete: true}
    {:ok, reads} = Agent.start_link(fn -> %{} end)

    opts = [
      relay_background: true,
      relay_ready: fn _ -> true end,
      background_now: fn -> 0 end,
      wait_comments: fn id ->
        Agent.update(reads, &Map.update(&1, id, 1, fn count -> count + 1 end))
        if id == second.id, do: {:error, :offline}, else: {:ok, ["## Symphony Workpad\n"]}
      end
    ]

    assert {:error, :offline, cache} = Yolo.Dependencies.refresh_background([first, second], %{}, opts)
    assert Agent.get(reads, & &1) == %{first.id => 1, second.id => 1}
    assert {:error, :offline, _cache} = Yolo.Dependencies.refresh_background([first, second], cache, opts)
    assert Agent.get(reads, & &1) == %{first.id => 1, second.id => 2}

    state = Coordinator.tick(%Orchestrator.State{max_concurrent_agents: 0, codex_totals: %{}}, [first, second], opts)
    assert Map.has_key?(state.yolo_marker_cache, {ProjectContext.current().id, first.id})
    assert Agent.get(reads, & &1) == %{first.id => 2, second.id => 3}
    _state = Coordinator.tick(state, [first, second], opts)
    assert Agent.get(reads, & &1) == %{first.id => 2, second.id => 4}
  end

  test "a target lookup failure retains the completed workpad marker scan", %{issues: [issue | _]} do
    issue = %{
      issue
      | description: "Wartet auf: PRI-1",
        last_comment_signal: %{relay_epoch: "first"},
        blocked_by: [],
        relations_complete: true
    }

    {:ok, reads} = Agent.start_link(fn -> 0 end)

    opts = [
      relay_background: true,
      relay_ready: fn _ -> true end,
      background_now: fn -> 0 end,
      wait_comments: fn _ ->
        Agent.update(reads, &(&1 + 1))
        {:ok, ["## Symphony Workpad\nWartet auf: PRI-2"]}
      end,
      resolve: fn _, _ -> {:error, :linear_budget_reserved} end
    ]

    assert {:error, :linear_budget_reserved, cache} = Yolo.Dependencies.refresh_background([issue], %{}, opts)
    assert Map.has_key?(cache, {ProjectContext.current().id, issue.id})

    ready = Keyword.put(opts, :resolve, fn identifier, _ -> {:ok, %{id: identifier, identifier: identifier, state: "Review", marker: true}} end)
    assert {:ok, [%{blocked_by: targets}], _cache} = Yolo.Dependencies.refresh_background([issue], cache, ready)
    assert Enum.map(targets, & &1.identifier) == ["PRI-1", "PRI-2"]
    assert Agent.get(reads, & &1) == 1
  end

  test "foreign target is queried once across contexts and relay state releases the wait", %{issues: [issue | _], context: source} do
    foreign = put_in(source.settings.tracker.app["workspace_id"], "foreign")
    foreign = put_in(foreign.settings.tracker.project_slug, "target-project")

    contexts =
      for index <- 1..3 do
        context = put_in(foreign.settings.tracker.project_slug, if(index == 2, do: "target-project", else: "other-#{index}"))
        %{context | id: "foreign-#{index}"}
      end

    issue = %{
      issue
      | state: "Yolo Review",
        description: "Wartet auf: PRI-892",
        blocked_by: [],
        relations_complete: true,
        last_comment_signal: %{relay_epoch: "source"}
    }

    another = %{issue | id: "second-waiting-issue", identifier: "PRO-998"}

    {:ok, lookups} = Agent.start_link(fn -> 0 end)
    {:ok, target_state} = Agent.start_link(fn -> "Merge (AI)" end)
    {:ok, relay_state} = Agent.start_link(fn -> :unavailable end)
    target = %{"id" => "foreign-target", "identifier" => "PRI-892", "project" => %{"slugId" => "target-project"}, "team" => %{"key" => "PRI"}}
    response = fn state -> %{"data" => %{"issues" => %{"nodes" => [Map.put(target, "state", %{"name" => state})], "pageInfo" => %{"hasNextPage" => false}}}} end

    opts = [
      contexts: [source | contexts],
      budget_background: false,
      relay_background: true,
      relay_ready: fn _ -> true end,
      background_now: fn -> Process.get(:target_now, 0) end,
      wait_comments: fn _ -> {:ok, []} end,
      query: fn _, _ ->
        Agent.update(lookups, &(&1 + 1))
        {:ok, response.(Agent.get(target_state, & &1))}
      end,
      target_relay: fn context, ["foreign-target"] ->
        assert context.id == "foreign-2"

        case Agent.get(relay_state, & &1) do
          :unavailable -> {:error, :relay_unavailable}
          {:out_of_scope, state} -> {:ok, [{{"generation", 1}, %{id: "foreign-target", identifier: "PRI-892", state: state, in_project_scope: false}}]}
          state -> {:ok, [{{"generation", 1}, %{id: "foreign-target", identifier: "PRI-892", state: state, in_project_scope: true}}]}
        end
      end,
      report_error: fn _, _, _ -> flunk("temporary target failure must not write a Workpad error") end
    ]

    {cache, _} =
      Enum.reduce(0..11, {%{}, nil}, fn tick, {cache, _} ->
        Process.put(:target_now, tick * 5_000)
        assert {:ok, updated, cache} = Yolo.Dependencies.refresh_background([issue, another], cache, opts)
        assert Enum.all?(updated, &match?([%{state: "Merge (AI)"}], &1.blocked_by))
        {cache, updated}
      end)

    assert Agent.get(lookups, & &1) == 1
    Agent.update(relay_state, fn _ -> {:out_of_scope, "Fertig"} end)
    Process.put(:target_now, 60_000)
    assert {:ok, [unchanged], cache} = Yolo.Dependencies.refresh_background([issue], cache, opts)
    assert [%{state: "Merge (AI)"}] = unchanged.blocked_by
    Agent.update(relay_state, fn _ -> "Yolo Review" end)
    Process.put(:target_now, 65_000)
    assert {:ok, [released], cache} = Yolo.Dependencies.refresh_background([issue], cache, opts)
    assert [%{state: "Yolo Review"}] = released.blocked_by
    assert Agent.get(lookups, & &1) == 1

    Agent.update(relay_state, fn _ -> :unavailable end)
    Agent.update(target_state, fn _ -> "Review" end)
    Process.put(:target_now, 299_999)
    assert {:ok, [still_known], cache} = Yolo.Dependencies.refresh_background([issue], cache, opts)
    assert [%{state: "Yolo Review"}] = still_known.blocked_by
    Process.put(:target_now, 300_000)
    assert {:ok, [fallback], cache} = Yolo.Dependencies.refresh_background([issue], cache, opts)
    assert [%{state: "Review"}] = fallback.blocked_by
    assert Agent.get(lookups, & &1) == 2

    failure = Keyword.put(opts, :query, fn _, _ -> {:error, :linear_app_request_unavailable} end)
    Process.put(:target_now, 600_000)
    assert {:ok, [last_known], cache} = Yolo.Dependencies.refresh_background([issue], cache, failure)
    assert [%{state: "Review"}] = last_known.blocked_by

    reserved = Keyword.put(opts, :query, fn _, _ -> {:error, :linear_budget_reserved} end)
    Process.put(:target_now, 900_000)
    assert {:ok, [last_known], cache} = Yolo.Dependencies.refresh_background([issue], cache, reserved)
    assert [%{state: "Review"}] = last_known.blocked_by

    assert Map.has_key?(cache, {:wait_target, "foreign", "PRI-892"})
    cleared = %{issue | description: ""}
    assert {:ok, [%{blocked_by: []}], cleared_cache} = Yolo.Dependencies.refresh_background([cleared], cache, opts)
    refute Map.has_key?(cleared_cache, {:wait_target, "foreign", "PRI-892"})
  end

  test "changed relay identifier invalidates the old marker binding immediately", %{issues: [issue | _], context: source} do
    foreign = source |> put_in([Access.key(:settings), Access.key(:tracker), Access.key(:app), "workspace_id"], "foreign")
    foreign = put_in(foreign.settings.tracker.project_slug, "target-project")
    waiting = %{issue | description: "Wartet auf: PRI-892"}
    target = %{"id" => "foreign-target", "identifier" => "PRI-892", "project" => %{"slugId" => "target-project"}, "team" => %{"key" => "PRI"}, "state" => %{"name" => "Merge (AI)"}}
    {:ok, lookups} = Agent.start_link(fn -> 0 end)

    opts = [
      contexts: [source, foreign],
      background_now: fn -> 0 end,
      query: fn _, _ ->
        Agent.get_and_update(lookups, fn count ->
          nodes = if count == 0, do: [target], else: []
          response = %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}
          {{:ok, response}, count + 1}
        end)
      end,
      target_relay: fn _, ["foreign-target"] ->
        {:ok, [{{"generation", 1}, %{id: "foreign-target", identifier: "PRI-999", state: "Yolo Review", in_project_scope: true}}]}
      end,
      report_error: fn _, identifier, reason ->
        send(self(), {:wait_error, identifier, reason})
        :ok
      end
    ]

    assert {:ok, [%{state: "Merge (AI)"}], cache} = WaitMarker.resolve_targets_background(waiting, [], %{}, opts)

    assert {:error, {:wait_marker_unresolved, "PRI-892", :wait_target_unresolved}, _} =
             WaitMarker.resolve_targets_background(waiting, [], cache, opts)

    assert_receive {:wait_error, "PRI-892", :wait_target_unresolved}
    assert Agent.get(lookups, & &1) == 2
  end

  test "background lookup keeps ambiguous foreign targets visible and caches the error", %{issues: [issue | _], context: source} do
    first = source |> put_in([Access.key(:settings), Access.key(:tracker), Access.key(:app), "workspace_id"], "foreign-a") |> Map.put(:id, "foreign-a")
    second = source |> put_in([Access.key(:settings), Access.key(:tracker), Access.key(:app), "workspace_id"], "foreign-b") |> Map.put(:id, "foreign-b")
    waiting = %{issue | description: "Wartet auf: PRI-892"}
    target = %{"identifier" => "PRI-892", "project" => %{"slugId" => "project"}, "team" => %{"key" => "PRI"}, "state" => %{"name" => "Merge (AI)"}}
    response = fn nodes -> %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}} end

    report = fn _, identifier, reason ->
      send(self(), {:wait_error, identifier, reason})
      :ok
    end

    across_workspaces = [
      contexts: [source, first, second],
      background_now: fn -> 0 end,
      report_error: report,
      query: fn _, _ ->
        workspace = ProjectContext.current().settings.tracker.app["workspace_id"]
        {:ok, response.([Map.put(target, "id", "target-#{workspace}")])}
      end
    ]

    assert {:error, {:wait_marker_unresolved, "PRI-892", :wait_target_ambiguous}, cache} =
             WaitMarker.resolve_targets_background(waiting, [], %{}, across_workspaces)

    assert map_size(cache) == 3
    assert_receive {:wait_error, "PRI-892", :wait_target_ambiguous}

    Process.put(:ambiguous_target_lookups, 0)

    within_workspace = [
      contexts: [source, first],
      background_now: fn -> Process.get(:target_now, 0) end,
      report_error: report,
      query: fn _, _ ->
        Process.put(:ambiguous_target_lookups, Process.get(:ambiguous_target_lookups) + 1)
        foreign = Map.put(target, "id", "foreign-target")
        {:ok, response.([foreign, foreign])}
      end
    ]

    assert {:error, {:wait_marker_unresolved, "PRI-892", :wait_target_ambiguous}, cache} =
             WaitMarker.resolve_targets_background(waiting, [], %{}, within_workspace)

    assert_receive {:wait_error, "PRI-892", :wait_target_ambiguous}
    Process.put(:target_now, 60_000)

    assert {:error, {:wait_marker_unresolved, "PRI-892", :wait_target_ambiguous}, _} =
             WaitMarker.resolve_targets_background(waiting, [], cache, within_workspace)

    assert Process.get(:ambiguous_target_lookups) == 1
    refute_receive {:wait_error, "PRI-892", :wait_target_ambiguous}
  end

  test "background wait reports use the real Workpad path once per safety interval", %{issues: [issue | _], context: source} do
    ProjectContext.bind(put_in(source.settings.tracker.kind, "memory"))
    previous_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_comments, previous_comments)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_recipient)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    foreign = source |> put_in([Access.key(:settings), Access.key(:tracker), Access.key(:app), "workspace_id"], "foreign") |> Map.put(:id, "foreign")
    body = "## Symphony Workpad\n\n### Plan\n\n- [ ] Ziel prüfen.\n\n### Validierung\n\n- [ ] Zielbeleg.\n\n### Verlauf\n"
    response = fn nodes -> {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}} end

    for {case_name, contexts, nodes, reason} <- [
          {:no_foreign, [source], [], :wait_target_unresolved},
          {:unknown, [source, foreign], [], :wait_target_unresolved},
          {:ambiguous, [source, foreign], [%{"id" => "one"}, %{"id" => "two"}], :wait_target_ambiguous}
        ] do
      id = "#{issue.id}-#{case_name}"

      waiting = %{
        issue
        | id: id,
          state: "Yolo Review",
          description: "Wartet auf: PRI-999",
          blocked_by: [],
          relations_complete: true,
          last_comment_signal: %{relay_epoch: "stable"}
      }

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{id => [%{id: "workpad-#{case_name}", body: body}]})
      Process.put(:wait_report_now, 0)

      opts = [
        contexts: contexts,
        relay_background: true,
        relay_ready: fn _ -> true end,
        background_now: fn -> Process.get(:wait_report_now) end,
        wait_comments: fn _ -> {:ok, []} end,
        query: fn _, _ ->
          send(self(), {:wait_target_query, id})
          response.(nodes)
        end
      ]

      cache =
        Enum.reduce(0..11, %{}, fn tick, cache ->
          Process.put(:wait_report_now, tick * 5_000)

          assert {:error, {:wait_marker_unresolved, "PRI-999", ^reason}, updated} =
                   Yolo.Dependencies.refresh_background([waiting], cache, opts)

          updated
        end)

      messages = elem(Process.info(self(), :messages), 1)
      assert Enum.count(messages, &match?({:memory_tracker_fetch_issue_comments, ^id}, &1)) == 1
      assert Enum.count(messages, &match?({:memory_tracker_comment_update, ^id, _, _}, &1)) == 1
      assert Enum.count(messages, &match?({:wait_target_query, ^id}, &1)) == if(case_name == :no_foreign, do: 0, else: 1)

      Process.put(:wait_report_now, 300_000)

      assert {:error, {:wait_marker_unresolved, "PRI-999", ^reason}, after_interval} =
               Yolo.Dependencies.refresh_background([waiting], cache, opts)

      messages = elem(Process.info(self(), :messages), 1)
      assert Enum.count(messages, &match?({:memory_tracker_fetch_issue_comments, ^id}, &1)) == 2
      assert Enum.count(messages, &match?({:memory_tracker_comment_update, ^id, _, _}, &1)) == 1
      assert Enum.count(messages, &match?({:wait_target_query, ^id}, &1)) == if(case_name == :no_foreign, do: 0, else: 2)

      if case_name == :no_foreign do
        terminal = %{waiting | state: "Review"}

        assert {:ok, [^terminal], released_cache} =
                 Yolo.Dependencies.refresh_background([terminal], after_interval, opts)

        refute Map.has_key?(released_cache, {:wait_report, id, "PRI-999"})

        Process.put(:wait_report_now, 305_000)
        changed = %{waiting | description: "Wartet auf: PRI-998"}

        assert {:error, {:wait_marker_unresolved, "PRI-998", :wait_target_unresolved}, changed_cache} =
                 Yolo.Dependencies.refresh_background([changed], after_interval, opts)

        ambiguous =
          Keyword.merge(opts,
            contexts: [source, foreign],
            query: fn _, _ -> response.([%{"id" => "one"}, %{"id" => "two"}]) end
          )

        assert {:error, {:wait_marker_unresolved, "PRI-998", :wait_target_ambiguous}, ambiguous_cache} =
                 Yolo.Dependencies.refresh_background([changed], changed_cache, ambiguous)

        messages = elem(Process.info(self(), :messages), 1)
        assert Enum.count(messages, &match?({:memory_tracker_comment_update, ^id, _, _}, &1)) == 3
        assert Enum.count(messages, &match?({:memory_tracker_fetch_issue_comments, ^id}, &1)) == 4
        [%{body: updated_body}] = Application.get_env(:symphony_elixir, :memory_tracker_comments)[id]
        assert updated_body =~ "Wartemarker-Fehler PRI-998: :wait_target_unresolved"
        assert updated_body =~ "Wartemarker-Fehler PRI-998: :wait_target_ambiguous"

        corrected = %{waiting | description: "Wartet auf: PRI-892"}
        target = %{"id" => "resolved", "identifier" => "PRI-892", "project" => %{"slugId" => "project"}, "team" => %{"key" => "PRI"}, "state" => %{"name" => "Review"}}
        resolved = Keyword.put(ambiguous, :query, fn _, _ -> response.([target]) end)

        assert {:ok, [%{blocked_by: [%{id: "resolved"}]}], corrected_cache} =
                 Yolo.Dependencies.refresh_background([corrected], ambiguous_cache, resolved)

        refute Map.has_key?(corrected_cache, {:wait_report, id, "PRI-998"})
        refute Map.has_key?(corrected_cache, {:wait_report, id, "PRI-999"})
        assert {:ok, [], empty_cache} = Yolo.Dependencies.refresh_background([], corrected_cache, resolved)
        refute Enum.any?(Map.keys(empty_cache), &match?({:wait_report, ^id, _}, &1))
      end
    end
  end

  test "failed background reports are throttled and marker changes clear their report", %{issues: [issue | _], context: source} do
    ProjectContext.bind(put_in(source.settings.tracker.kind, "memory"))
    previous_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :memory_tracker_comments, previous_comments)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, previous_recipient)
    end)

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    waiting = %{issue | description: "Wartet auf: PRI-999"}

    opts = [
      contexts: [source],
      background_now: fn -> Process.get(:wait_report_now) end,
      report_comments: fn _ ->
        send(self(), :report_read)
        {:error, :offline}
      end
    ]

    cache =
      Enum.reduce(0..11, %{}, fn tick, cache ->
        Process.put(:wait_report_now, tick * 5_000)

        assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :offline}, updated} =
                 WaitMarker.resolve_targets_background(waiting, [], cache, opts)

        updated
      end)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 1
    Process.put(:wait_report_now, 300_000)

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :offline}, cache} =
             WaitMarker.resolve_targets_background(waiting, [], cache, opts)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 2

    Process.put(:wait_report_now, 305_000)
    assert {:ok, [], cleared} = WaitMarker.resolve_targets_background(%{waiting | description: ""}, [], cache, opts)

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :offline}, restored} =
             WaitMarker.resolve_targets_background(waiting, [], cleared, opts)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 3

    changed = %{waiting | description: "Wartet auf: PRI-998"}

    assert {:error, {:wait_marker_unresolved, "PRI-998", :wait_target_unresolved, :offline}, changed_cache} =
             WaitMarker.resolve_targets_background(changed, [], restored, opts)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 4

    foreign = source |> put_in([Access.key(:settings), Access.key(:tracker), Access.key(:app), "workspace_id"], "foreign") |> Map.put(:id, "foreign")

    ambiguous =
      Keyword.merge(opts,
        contexts: [source, foreign],
        query: fn _, _ ->
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "nodes" => [%{"id" => "one"}, %{"id" => "two"}],
                 "pageInfo" => %{"hasNextPage" => false}
               }
             }
           }}
        end
      )

    assert {:error, {:wait_marker_unresolved, "PRI-998", :wait_target_ambiguous, :offline}, _} =
             WaitMarker.resolve_targets_background(changed, [], changed_cache, ambiguous)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 5

    assert {:error, {:wait_marker_unresolved, "PRI-998", :wait_target_unresolved, :offline}, _} =
             WaitMarker.resolve_targets_background(changed, [], %{}, opts)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 6
  end

  test "failed Workpad write is reported once per background interval", %{issues: [issue | _], context: source} do
    ProjectContext.bind(put_in(source.settings.tracker.kind, "memory"))
    waiting = %{issue | description: "Wartet auf: PRI-999"}
    body = "## Symphony Workpad\n\n### Plan\n\n- [ ] Ziel prüfen.\n\n### Validierung\n\n- [ ] Zielbeleg.\n\n### Verlauf\n"

    opts = [
      contexts: [source],
      background_now: fn -> Process.get(:wait_report_now) end,
      report_comments: fn _ ->
        send(self(), :report_read)
        {:ok, [%{id: "missing", body: body}]}
      end
    ]

    cache =
      Enum.reduce(0..11, %{}, fn tick, cache ->
        Process.put(:wait_report_now, tick * 5_000)

        assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :comment_not_found}, updated} =
                 WaitMarker.resolve_targets_background(waiting, [], cache, opts)

        updated
      end)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 1
    Process.put(:wait_report_now, 300_000)

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :comment_not_found}, _} =
             WaitMarker.resolve_targets_background(waiting, [], cache, opts)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 2
  end

  test "Workpad without a comment ID keeps the marker unresolved and throttles report reads", %{issues: [issue | _], context: source} do
    waiting = %{issue | description: "Wartet auf: PRI-999"}

    opts = [
      contexts: [source],
      background_now: fn -> Process.get(:wait_report_now) end,
      report_comments: fn _ ->
        send(self(), :report_read)
        {:ok, [%{body: "## Symphony Workpad\n"}]}
      end
    ]

    cache =
      Enum.reduce(0..11, %{}, fn tick, cache ->
        Process.put(:wait_report_now, tick * 5_000)

        assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :workpad_comment_missing_id}, updated} =
                 WaitMarker.resolve_targets_background(waiting, [], cache, opts)

        updated
      end)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 1
    Process.put(:wait_report_now, 300_000)

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, :workpad_comment_missing_id}, _} =
             WaitMarker.resolve_targets_background(waiting, [], cache, opts)

    assert Enum.count(elem(Process.info(self(), :messages), 1), &(&1 == :report_read)) == 2
  end

  test "first transient target failure is throttled without a Workpad error", %{issues: [issue | _], context: source} do
    foreign = put_in(source.settings.tracker.app["workspace_id"], "foreign")

    waiting = %{
      issue
      | state: "Yolo Review",
        description: "Wartet auf: PRI-892",
        blocked_by: [],
        relations_complete: true,
        last_comment_signal: %{relay_epoch: "source"}
    }

    {:ok, lookups} = Agent.start_link(fn -> 0 end)
    {:ok, availability} = Agent.start_link(fn -> :error end)

    target = %{
      "id" => "foreign-target",
      "identifier" => "PRI-892",
      "project" => %{"slugId" => "project"},
      "team" => %{"key" => "PRI"},
      "state" => %{"name" => "Yolo Review"}
    }

    opts = [
      contexts: [source, foreign],
      budget_background: false,
      relay_background: true,
      relay_ready: fn _ -> true end,
      background_now: fn -> Process.get(:target_now, 0) end,
      wait_comments: fn _ -> {:ok, []} end,
      query: fn _, _ ->
        Agent.update(lookups, &(&1 + 1))

        case Agent.get(availability, & &1) do
          :error -> {:error, :linear_app_request_unavailable}
          :ok -> {:ok, %{"data" => %{"issues" => %{"nodes" => [target], "pageInfo" => %{"hasNextPage" => false}}}}}
        end
      end,
      report_error: fn _, _, _ -> flunk("transient failure must not write a Workpad error") end
    ]

    cache =
      Enum.reduce(0..11, %{}, fn tick, cache ->
        Process.put(:target_now, tick * 5_000)

        assert {:error, :linear_app_request_unavailable, updated} =
                 Yolo.Dependencies.refresh_background([waiting], cache, opts)

        updated
      end)

    assert Agent.get(lookups, & &1) == 1
    Agent.update(availability, fn _ -> :ok end)
    Process.put(:target_now, 300_000)
    assert {:ok, [recovered], _} = Yolo.Dependencies.refresh_background([waiting], cache, opts)
    assert [%{state: "Yolo Review"}] = recovered.blocked_by
    assert Agent.get(lookups, & &1) == 2
  end

  test "permanent operation recovery backs off and changed source wakes it", %{issues: [issue | _]} do
    intent = %{"key" => "followup:test", "request" => %{"kind" => "followup", "origin_ids" => [issue.id]}, "issue_id" => Ecto.UUID.generate(), "done" => false}
    assert :ok = Operations.save(intent)
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    state = %Orchestrator.State{}

    opts = [
      lease: fn _, callback -> callback.() end,
      recovery_now: fn -> Agent.get(clock, & &1) end,
      invoke: fn _, _ ->
        Agent.update(attempts, &(&1 + 1))
        {:error, :yolo_created_issue_changed}
      end
    ]

    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    assert Agent.get(attempts, & &1) == 1
    assert {:ok, first} = Store.read("incoming")
    assert first["operation_retries"][intent["key"]]["retry_at"] == 30_000

    Agent.update(clock, fn _ -> 30_000 end)
    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    assert Agent.get(attempts, & &1) == 2
    assert {:ok, second} = Store.read("incoming")
    assert second["operation_retries"][intent["key"]]["retry_at"] == 330_000
    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    assert Agent.get(attempts, & &1) == 2

    Agent.update(clock, fn _ -> 330_000 end)
    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    assert {:ok, third_retry} = Store.read("incoming")
    assert third_retry["operation_retries"][intent["key"]]["retry_at"] == 930_000
    Agent.update(clock, fn _ -> 930_000 end)
    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    assert {:ok, fourth_retry} = Store.read("incoming")
    assert fourth_retry["operation_retries"][intent["key"]]["retry_at"] == 1_830_000

    changed = %{issue | last_comment_signal: %{relay_epoch: "new"}}
    state = Yolo.Recovery.resume_with_state(state, [changed], opts)
    assert Agent.get(attempts, & &1) == 5
    assert {:ok, third} = Store.read("incoming")
    assert third["operation_retries"][intent["key"]]["retry_at"] == 960_000

    edited = %{changed | title: "New origin title"}
    _state = Yolo.Recovery.resume_with_state(state, [edited], opts)
    assert Agent.get(attempts, & &1) == 6

    success =
      Keyword.put(opts, :invoke, fn _, _ ->
        Agent.update(attempts, &(&1 + 1))
        Operations.save(Map.merge(intent, %{"done" => true, "result" => %{"id" => intent["issue_id"]}}))
        {:ok, %{id: intent["issue_id"]}}
      end)

    restarted = %Orchestrator.State{}
    restarted = Yolo.Recovery.resume_with_state(restarted, [edited], success)
    assert Agent.get(attempts, & &1) == 7
    _ = Yolo.Recovery.resume_with_state(restarted, [edited], success)
    assert Agent.get(attempts, & &1) == 7
    assert {:ok, %{"done" => true}} = DurableState.read(Operations.path(intent["key"]))
  end

  for {name, fragment} <- [
        {"blockiert", "Folgefix blockiert den Ursprung"},
        {"Relay", "Relay-Epoche"},
        {"Budget", "Budget-Zusammenfassung"},
        {"Linear-Link", "https://linear.app/prolok/issue/PRO-923"},
        {"Timeout", "Timeout"}
      ] do
    test "created issue description fragments with #{name} keep permanent recovery backoff", %{issues: [issue | _]} do
      fragment = unquote(fragment)
      expected = "Ein Absatz vor der Liste.\n- #{fragment}\n"
      actual = "Ein Absatz vor der Liste.\n\n#{fragment}\n"
      refute Description.equivalent?(expected, actual)
      difference = Description.first_difference(expected, actual)
      assert difference.expected_fragment =~ fragment
      reason = {:yolo_created_issue_changed, Map.put(difference, :field, "description")}

      intent = %{"key" => "followup:fragment", "request" => %{"kind" => "followup", "origin_ids" => [issue.id]}, "issue_id" => Ecto.UUID.generate(), "done" => false}
      assert :ok = Operations.save(intent)
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      opts = [lease: fn _, callback -> callback.() end, recovery_now: fn -> Agent.get(clock, & &1) end, invoke: fn _, _ -> {:error, reason} end]

      state = Yolo.Recovery.resume_with_state(%Orchestrator.State{}, [issue], opts)
      assert {:ok, first} = Store.read("incoming")
      assert first["operation_retries"][intent["key"]]["retry_at"] == 30_000

      Agent.update(clock, fn _ -> 30_000 end)
      state = Yolo.Recovery.resume_with_state(state, [issue], opts)
      assert {:ok, second} = Store.read("incoming")
      assert second["operation_retries"][intent["key"]]["retry_at"] == 330_000

      Agent.update(clock, fn _ -> 330_000 end)
      _state = Yolo.Recovery.resume_with_state(state, [issue], opts)
      assert {:ok, third} = Store.read("incoming")
      assert third["operation_retries"][intent["key"]]["retry_at"] == 930_000
    end
  end

  test "transport, rate limit and relay recovery errors retain thirty-second retries but missing state backs off", %{issues: [issue | _]} do
    intent = %{"key" => "followup:transient", "request" => %{"kind" => "followup", "origin_ids" => [issue.id]}, "issue_id" => Ecto.UUID.generate(), "done" => false}
    assert :ok = Operations.save(intent)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    {:ok, failure} = Agent.start_link(fn -> :transport_error end)

    opts = [
      lease: fn _, callback -> callback.() end,
      recovery_now: fn -> Agent.get(clock, & &1) end,
      invoke: fn _, _ -> {:error, Agent.get(failure, & &1)} end
    ]

    transient_reasons = [
      :transport_error,
      :rate_limited,
      :relay_not_ready,
      :linear_app_request_unavailable,
      %Req.TransportError{reason: :timeout},
      {:relay_not_ready, :offline, "connection details"},
      {:linear_api_request, :linear_app_request_unavailable},
      {:linear_api_request, {:linear_app_rate_limited, %{retry_after_ms: 1_000}}},
      {:linear_api_status, 200, %{classification: "rate_limited"}},
      {:linear_api_status, 400, %{classification: "rate_limited"}},
      {:linear_api_status, 403, %{classification: "rate_limited"}},
      {:linear_api_status, 503, %{classification: "server_error"}},
      {:wait_marker_unresolved, "PRI-173", {:linear_api_request, :linear_app_request_unavailable}},
      {:wait_marker_unresolved, "PRI-173", :wait_target_unresolved, {:linear_api_request, :linear_app_request_unavailable}}
    ]

    state =
      Enum.reduce(transient_reasons, %Orchestrator.State{}, fn reason, state ->
        Enum.reduce(1..2, state, fn _, state ->
          Agent.update(failure, fn _ -> reason end)
          state = Yolo.Recovery.resume_with_state(state, [issue], opts)
          now = Agent.get(clock, & &1)
          assert {:ok, record} = Store.read("incoming")
          assert record["operation_retries"][intent["key"]]["retry_at"] == now + 30_000
          Agent.update(clock, &(&1 + 30_000))
          state
        end)
      end)

    assert MapSet.member?(state.yolo_operation_retries, {"incoming", intent["key"]})

    Agent.update(failure, fn _ -> {:yolo_state_unavailable, "Backlog"} end)
    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    now = Agent.get(clock, & &1)
    assert {:ok, first_missing} = Store.read("incoming")
    assert first_missing["operation_retries"][intent["key"]]["retry_at"] == now + 30_000
    Agent.update(clock, &(&1 + 30_000))
    _state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    now = Agent.get(clock, & &1)
    assert {:ok, repeated_missing} = Store.read("incoming")
    assert repeated_missing["operation_retries"][intent["key"]]["retry_at"] == now + 300_000

    Agent.update(clock, fn _ -> repeated_missing["operation_retries"][intent["key"]]["retry_at"] end)
    Agent.update(failure, fn _ -> "Timeout in ticket title" end)
    state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    now = Agent.get(clock, & &1)
    assert {:ok, first_text} = Store.read("incoming")
    assert first_text["operation_retries"][intent["key"]]["retry_at"] == now + 30_000
    Agent.update(clock, &(&1 + 30_000))
    _state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    now = Agent.get(clock, & &1)
    assert {:ok, repeated_text} = Store.read("incoming")
    assert repeated_text["operation_retries"][intent["key"]]["retry_at"] == now + 300_000
  end

  test "recovery leaves an intent pending when its group lock or state is unavailable", %{issues: [issue | _]} do
    intent = %{"key" => "followup:unavailable", "request" => %{"kind" => "followup", "origin_ids" => [issue.id]}, "issue_id" => Ecto.UUID.generate(), "done" => false}
    assert :ok = Operations.save(intent)
    state = %Orchestrator.State{}
    opts = [invoke: fn _, _ -> flunk("unavailable group must not invoke an intent") end]

    assert ^state = Store.lock("incoming", fn -> Yolo.Recovery.resume_with_state(state, [issue], opts) end)
    File.mkdir_p!(Path.dirname(Store.path("incoming")))
    File.write!(Store.path("incoming"), "invalid state")
    assert ^state = Yolo.Recovery.resume_with_state(state, [issue], opts)
  end

  test "recovery keeps remaining intents pending when state becomes corrupt during an invocation", %{issues: [issue | _]} do
    for key <- ["followup:corrupt-1", "followup:corrupt-2"] do
      assert :ok = Operations.save(%{"key" => key, "request" => %{"kind" => "followup", "origin_ids" => [issue.id]}, "issue_id" => Ecto.UUID.generate(), "done" => false})
    end

    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    state = %Orchestrator.State{}

    opts = [
      lease: fn _, callback -> callback.() end,
      invoke: fn _, _ ->
        Agent.update(attempts, &(&1 + 1))
        File.mkdir_p!(Path.dirname(Store.path("incoming")))
        File.write!(Store.path("incoming"), "invalid state")
        {:error, :offline}
      end
    ]

    assert ^state = Yolo.Recovery.resume_with_state(state, [issue], opts)
    assert Agent.get(attempts, & &1) == 1
  end

  test "recovery does not claim a retry when durable persistence fails", %{issues: [issue | _]} do
    intent = %{"key" => "followup:persist", "request" => %{"kind" => "followup", "origin_ids" => [issue.id]}, "issue_id" => Ecto.UUID.generate(), "done" => false}
    assert :ok = Operations.save(intent)

    opts = [
      lease: fn _, callback -> callback.() end,
      invoke: fn _, _ -> {:error, :yolo_created_issue_changed} end,
      recovery_write: fn _, _ -> {:error, :persist_failed} end
    ]

    assert %Orchestrator.State{yolo_operation_retries: retries} =
             Yolo.Recovery.resume_with_state(%Orchestrator.State{}, [issue], opts)

    assert MapSet.size(retries) == 0
    assert {:ok, record} = Store.read("incoming")
    assert record["operation_retries"] == nil
  end

  test "relay blocker status types are reused and legacy entries are freshly checked", %{issues: [issue | _]} do
    app = Config.settings!().tracker.app

    on_exit(fn ->
      Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "5000"})
      Budget.pressure(app)
    end)

    Budget.record(app, :read, %{
      "x-ratelimit-requests-limit" => "5000",
      "x-ratelimit-requests-remaining" => "5000"
    })

    assert Budget.pressure(app) == :normal

    relay = %{
      issue
      | blocked_by: [%{id: "fix", identifier: "PRO-2", state: "Abgeschlossen", state_type: "completed"}],
        last_comment_signal: %{relay_epoch: "current"},
        relations_complete: true
    }

    no_query = fn _, _ -> flunk("complete relay blockers must not be read again") end
    opts = [relay_background: true, wait_comments: fn _ -> {:ok, []} end]

    assert {:ok, [ready]} = Yolo.Dependencies.refresh([relay], Keyword.put(opts, :query, no_query))
    assert Yolo.Dependencies.dispatchable?(ready)

    legacy = %{relay | blocked_by: [%{id: "fix", identifier: "PRO-2", state: "Abgeschlossen"}]}

    relation = %{
      "id" => "relation",
      "type" => "blocks",
      "issue" => %{"id" => "fix", "identifier" => "PRO-2", "state" => %{"name" => "Abgeschlossen", "type" => "completed"}}
    }

    query = fn document, _ ->
      assert document =~ "YoloBlockers"

      {:ok,
       %{
         "data" => %{
           "issue" => %{
             "inverseRelations" => %{
               "nodes" => [relation],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }
       }}
    end

    assert {:ok, [checked]} = Yolo.Dependencies.refresh([legacy], Keyword.put(opts, :query, query))

    truncated = %{relay | relations_complete: false}
    assert {:ok, [checked_truncated]} = Yolo.Dependencies.refresh([truncated], Keyword.put(opts, :query, query))
    assert checked_truncated.blocked_by == checked.blocked_by
    assert Yolo.Dependencies.dispatchable?(checked)

    foreground = opts |> Keyword.put(:query, query) |> Keyword.put(:relay_background, false)
    assert {:ok, [_]} = Yolo.Dependencies.refresh([legacy], foreground)
    Budget.record(app, :read, %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "999"})
    assert Budget.pressure(app) == :critical
    assert {:error, :linear_budget_reserved} = Yolo.Dependencies.refresh([legacy], Keyword.put(opts, :query, no_query))
  end

  test "an unavailable configured merge worker cannot authorize acceptance", %{issues: [issue | _], context: context, root: root} do
    path = System.get_env("PATH")
    ssh = Path.join(root, "ssh")
    File.write!(ssh, "#!/bin/sh\nprintf 'unavailable fixture worker\\n'\nexit 75\n")
    File.chmod!(ssh, 0o755)
    System.put_env("PATH", root <> ":" <> path)
    ProjectContext.bind(put_in(context.settings.worker.ssh_hosts, ["fixture-worker"]))

    try do
      assert {:error, {:workspace_presence_failed, "fixture-worker", 75, output}} = Yolo.MergeReadiness.check(issue)
      assert output =~ "unavailable fixture worker"
    after
      System.put_env("PATH", path)
    end
  end

  test "blocked backlog waits and only Yolo Review enters acceptance", %{issues: [issue | _]} do
    blocked = %{issue | blocked_by: [%{id: "fix", state: "In Arbeit (AI)"}]}
    assert Group.groups([blocked]) == %{}
    assert Group.groups([%{blocked | blocked_by: [%{id: "fix", state: "Review"}]}])["incoming"] != nil
    assert Group.name(%{issue | state: "Review"}) == nil
    assert Group.name(%{issue | state: "Yolo Review"}) == "review"
  end

  test "markers in description and workpad wait across bound workspaces until target merge", %{issues: [issue | _], context: context} do
    target_settings = %{context.settings | tracker: %{context.settings.tracker | app: Map.put(context.settings.tracker.app, "workspace_id", "other-workspace")}}
    target = %{context | id: context.id <> "-other", root: context.root <> "-other", settings: target_settings}
    waiting = %{issue | description: "Wartet auf: PRI-173"}
    comments = fn _ -> {:ok, ["## Symphony Workpad\n- [ ] Wartet auf: PRI-175"]} end

    query = fn document, variables ->
      if String.contains?(document, "YoloBlockers") do
        {:ok, %{"data" => %{"issue" => %{"inverseRelations" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}}}
      else
        assert ProjectContext.current().id == target.id

        {:ok,
         %{
           "data" => %{
             "issues" => %{
               "nodes" => [
                 %{
                   "id" => variables.number |> to_string(),
                   "identifier" => "#{variables.team}-#{variables.number}",
                   "project" => %{"slugId" => "project"},
                   "team" => %{"key" => "PRI"},
                   "state" => %{"name" => Process.get(:target_state)}
                 }
               ],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         }}
      end
    end

    opts = [contexts: [context, target], comments: comments, query: query]

    for state <- ["Backlog", "BLOCKER", "Planung", "Yolo Review"] do
      Process.put(:target_state, "Merge (AI)")
      assert {:ok, [blocked]} = Yolo.Dependencies.refresh([%{waiting | state: state}], opts)
      assert length(blocked.blocked_by) == 2
      assert Group.groups([blocked]) == %{}

      for merged <- ["Yolo Review", "Review", "Fertig"] do
        Process.put(:target_state, merged)
        assert {:ok, [released]} = Yolo.Dependencies.refresh([%{waiting | state: state}], opts)
        assert Map.has_key?(Group.groups([released]), Group.name(released))
      end
    end
  end

  test "unresolvable cross-workspace marker records a visible error", %{issues: [issue | _], context: context} do
    waiting = %{issue | description: "Wartet auf: PRI-999"}
    parent = self()

    report = fn _issue, identifier, reason ->
      send(parent, {:wait_error, identifier, reason})
      :ok
    end

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved}} =
             WaitMarker.targets(waiting, contexts: [context], comments: fn _ -> {:ok, []} end, report_error: report)

    assert_receive {:wait_error, "PRI-999", :wait_target_unresolved}
  end

  test "marker defaults and comment shapes preserve an empty wait", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.kind, "memory"))
    previous = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_comments, previous) end)
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => []})

    assert {:ok, []} = WaitMarker.targets(issue)
    assert {:ok, false} = WaitMarker.open?(issue)
    assert :continue = WaitMarker.planning_action(issue)

    comments = fn _ -> {:ok, [%{"body" => "ordinary"}, %{invalid: true}]} end
    assert {:ok, []} = WaitMarker.targets(issue, comments: comments)
    waiting = %{issue | description: "Wartet auf: PRI-173"}
    assert {:ok, true} = WaitMarker.open?(waiting, comments: comments, resolve: fn _, _ -> {:ok, %{state: "BLOCKER"}} end)
    merged = fn _, _ -> {:ok, %{state: "Review"}} end
    assert :continue = WaitMarker.planning_action(waiting, comments: comments, resolve: merged)
  end

  test "existing wait Workpad keeps its comment inbox and propagates read failures", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.kind, "memory"))
    previous = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_comments, previous) end)
    body = "## Symphony Workpad\n\n### Kommentareingang\n\n- Quelle bleibt erhalten.\n"
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => [%{id: "workpad", body: body}]})
    target = %{identifier: "PRI-173", state: "BLOCKER"}
    assert :ok = WaitMarker.record_wait(issue, [target])
    assert {:ok, [comment]} = Tracker.fetch_issue_comments(issue.id)
    assert comment.body =~ "Wartemarker offen: PRI-173"
    assert comment.body =~ "### Kommentareingang"
    assert {:error, :offline} = WaitMarker.targets(issue, comments: fn _ -> {:error, :offline} end)
  end

  test "marker resolution handles absent, incomplete and failed foreign lookups", %{issues: [issue | _], context: context} do
    target = put_in(context.settings.tracker.app["workspace_id"], "other-workspace")
    target = %{target | id: "target-context"}
    waiting = %{issue | description: "Wartet auf: PRI-173"}
    base = [contexts: [context, target], comments: fn _ -> {:ok, []} end, report_error: fn _, _, _ -> :ok end]
    absent = %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}}}}

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_unresolved}} =
             WaitMarker.targets(waiting, base ++ [query: fn _, _ -> {:ok, absent} end])

    assert {:error, :offline} =
             WaitMarker.targets(waiting, base ++ [query: fn _, _ -> {:error, :offline} end])

    assert {:error, :wait_target_lookup_incomplete} =
             WaitMarker.targets(waiting, base ++ [query: fn _, _ -> {:ok, %{"data" => %{"issues" => %{"nodes" => []}}}} end])

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_unresolved, :write_failed}} =
             WaitMarker.targets(waiting,
               contexts: [context],
               comments: fn _ -> {:ok, []} end,
               resolve: fn _, _ -> {:error, :wait_target_unresolved} end,
               report_error: fn _, _, _ -> {:error, :write_failed} end
             )
  end

  test "foreign team bindings reject malformed or unbound target issues", %{issues: [issue | _], context: context} do
    target = put_in(context.settings.tracker.app["workspace_id"], "other-workspace")
    target = put_in(target.settings.tracker.project_slug, nil)
    target = put_in(target.settings.tracker.team_key, "PRI")
    target = %{target | id: "foreign-team"}
    waiting = %{issue | description: "Wartet auf: PRI-173"}
    opts = [contexts: [context, target], comments: fn _ -> {:ok, []} end, report_error: fn _, _, _ -> :ok end]
    response = fn nodes -> {:ok, %{"data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}} end
    valid = %{"id" => "foreign", "identifier" => "PRI-173", "project" => %{"slugId" => "other"}, "team" => %{"key" => "PRI"}, "state" => %{"name" => "Review"}}

    assert {:ok, [%{id: "foreign", marker: true, state: "Review"}]} =
             WaitMarker.targets(waiting, opts ++ [query: fn _, _ -> response.([valid]) end])

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_ambiguous}} =
             WaitMarker.targets(waiting, opts ++ [query: fn _, _ -> response.([%{"id" => "incomplete"}]) end])

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_ambiguous}} =
             WaitMarker.targets(waiting, opts ++ [query: fn _, _ -> response.([valid, valid]) end])

    paginated = put_in(elem(response.([valid]), 1)["data"]["issues"]["pageInfo"]["hasNextPage"], true)

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_ambiguous}} =
             WaitMarker.targets(waiting, opts ++ [query: fn _, _ -> {:ok, paginated} end])

    invalid_scope = put_in(target.settings.tracker.team_key, nil)

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_unresolved}} =
             WaitMarker.targets(waiting, Keyword.put(opts, :contexts, [context, invalid_scope]) ++ [query: fn _, _ -> response.([valid]) end])
  end

  test "unresolvable marker creates a Workpad and ambiguous Workpads remain an error", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.kind, "memory"))
    previous = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_comments, previous) end)
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => []})
    waiting = %{issue | description: "Wartet auf: PRI-999"}

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved}} =
             WaitMarker.targets(waiting, resolve: fn _, _ -> {:error, :wait_target_unresolved} end)

    assert {:ok, [created]} = Tracker.fetch_issue_comments(issue.id)
    assert created.body =~ "Wartemarker-Fehler PRI-999"

    duplicate = %{issue.id => [%{id: "one", body: created.body}, %{id: "two", body: created.body}]}
    Application.put_env(:symphony_elixir, :memory_tracker_comments, duplicate)
    assert {:error, _} = WaitMarker.record_wait(issue, [%{identifier: "PRI-999", state: "BLOCKER"}])

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved, _}} =
             WaitMarker.targets(waiting, resolve: fn _, _ -> {:error, :wait_target_unresolved} end)
  end

  test "unresolvable marker writes the error into the existing Workpad", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.kind, "memory"))
    previous = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_comments, previous) end)
    body = "## Symphony Workpad\n\n### Plan\n\n- [ ] Ziel prüfen.\n\n### Validierung\n\n- [ ] Zielbeleg.\n\n### Verlauf\n"
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue.id => [%{id: "workpad", body: body}]})
    waiting = %{issue | description: "Wartet auf: PRI-999"}

    assert {:error, {:wait_marker_unresolved, "PRI-999", :wait_target_unresolved}} =
             WaitMarker.targets(waiting, contexts: [context], resolve: fn _, _ -> {:error, :wait_target_unresolved} end)

    assert {:ok, [comment]} = SymphonyElixir.Tracker.fetch_issue_comments(issue.id)
    assert comment.id == "workpad"
    assert comment.body =~ "Wartemarker-Fehler PRI-999"
  end

  test "an open marker creates the first Workpad before returning to Backlog", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.kind, "memory"))
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    waiting = %{issue | state: "Planung (AI)", description: "Wartet auf: PRI-173"}

    assert :wait =
             WaitMarker.planning_action(waiting,
               comments: fn _ -> {:ok, []} end,
               resolve: fn _, _ -> {:ok, %{identifier: "PRI-173", state: "BLOCKER"}} end
             )

    assert {:ok, [comment]} = Tracker.fetch_issue_comments(issue.id)
    assert comment.body =~ "## Symphony Workpad"
    assert comment.body =~ "Wartemarker offen: PRI-173"
    assert_receive {:memory_tracker_state_update, id, "Backlog"}
    assert id == issue.id
  end

  test "a marker matching two bound workspaces is ambiguous", %{issues: [issue | _], context: context} do
    targets =
      for suffix <- ["one", "two"] do
        target = put_in(context.settings.tracker.app["workspace_id"], "other-#{suffix}")
        %{target | id: "target-#{suffix}"}
      end

    query = fn _, _ ->
      {:ok,
       %{
         "data" => %{
           "issues" => %{
             "nodes" => [
               %{
                 "id" => ProjectContext.current().id,
                 "identifier" => "PRI-173",
                 "project" => %{"slugId" => "project"},
                 "team" => %{"key" => "PRI"},
                 "state" => %{"name" => "BLOCKER"}
               }
             ],
             "pageInfo" => %{"hasNextPage" => false}
           }
         }
       }}
    end

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_ambiguous}} =
             WaitMarker.targets(%{issue | description: "Wartet auf: PRI-173"},
               contexts: [context | targets],
               comments: fn _ -> {:ok, []} end,
               query: query,
               report_error: fn _, _, _ -> :ok end
             )
  end

  test "planning worker returns an open cross-workspace wait to Backlog with a note", %{issues: [issue | _]} do
    waiting = %{issue | state: "Planung (AI)", description: "Wartet auf: PRI-173"}
    parent = self()

    opts = [
      comments: fn _ -> {:ok, []} end,
      resolve: fn "PRI-173", _ -> {:ok, %{identifier: "PRI-173", state: "BLOCKER"}} end,
      note_wait: fn _, _ ->
        send(parent, :wait_noted)
        :ok
      end,
      update_state: fn id, state ->
        send(parent, {:state, id, state})
        :ok
      end
    ]

    assert :wait = WaitMarker.planning_action(waiting, opts)
    assert_receive :wait_noted
    assert_receive {:state, id, "Backlog"}
    assert id == issue.id
  end

  test "same BLOCKER cause hands off without a second run and sends one escalation across retries", %{issues: [issue | _], context: context} do
    context = put_in(context.settings.tracker.openclaw_yolo_agent, "pai")
    ProjectContext.bind(context)
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    body = "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang; fällig: Yolo Review\n"
    Process.put(:brake_body, body)
    parent = self()

    opts = [
      now: fn -> 1_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end,
      workpad_write: fn _, updated ->
        Process.put(:brake_body, updated)
        :ok
      end,
      escalation_route: fn _, _ -> {:ok, %{"channel" => "bound"}} end,
      escalation_send: fn _, message, _ ->
        send(parent, {:escalation, message})
        {:ok, %{"messageId" => "one"}}
      end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end,
      fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end
    ]

    assert :ok = BlockerBrake.reserve([issue], "first-run", opts)

    Process.put(
      :brake_body,
      body <>
        "\n### YOLO-Übergabe\n\nEskalation:\n```json\n" <>
        Jason.encode!(%{"cause" => "Hostzugang", "attempts" => "Probe fehlgeschlagen", "proposal" => "Zugang prüfen", "decision" => "Zugang freigeben"}) <> "\n```\n"
    )

    assert {:ok, []} = BlockerBrake.check([issue], opts)
    assert_receive {:escalation, message}
    assert message =~ "Versuche: Probe fehlgeschlagen"
    assert Process.get(:brake_body) =~ "BLOCKER-Schleifenbremse"
    assert {:ok, []} = BlockerBrake.check([issue], opts)
    refute_receive {:escalation, _}, 20
    persisted_body = Process.get(:brake_body)
    restart_opts = Keyword.put(opts, :workpad_comments, fn _ -> {:ok, [%{id: "workpad", body: persisted_body}]} end)
    restart = Task.async(fn -> ProjectContext.with_context(context, fn -> BlockerBrake.check([issue], restart_opts) end) end)
    assert {:ok, []} = Task.await(restart)
    refute_receive {:escalation, _}, 20
    assert {:ok, [^issue]} = BlockerBrake.check([issue], Keyword.put(opts, :now, fn -> 86_401_001 end))
    Process.put(:brake_body, String.replace(body, "Hostzugang", "Paketaktivierung"))
    assert {:ok, [^issue]} = BlockerBrake.check([issue], opts)
  end

  test "BLOCKER journal rejects missing causes and corrupt records", %{issues: [issue | _], context: context} do
    assert {:ok, []} = BlockerBrake.check([])
    assert :ok = BlockerBrake.reserve([], "unused")
    issue = %{issue | state: "BLOCKER"}
    body = "## Symphony Workpad\n\n### Verlauf\n\nNo operator duty.\n"
    opts = [workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end]
    assert {:error, :blocker_cause_missing} = BlockerBrake.check([issue], opts)
    assert {:error, :blocker_cause_missing} = BlockerBrake.reserve([issue], "run", opts)

    path = Path.join([context.settings.tracker.app["state_root"], "yolo", "blocker-causes", Base.encode16(:crypto.hash(:sha256, issue.id), case: :lower) <> ".json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "not-json")
    assert {:error, :blocker_cause_journal_corrupt} = BlockerBrake.release([issue], "run")

    assert {:error, :blocker_cause_journal_corrupt} =
             BlockerBrake.check([issue], Keyword.put(opts, :workpad_comments, fn _ -> {:ok, [%{id: "workpad", body: "## Symphony Workpad\n\n### Betreiberauftrag\n\nHostzugang prüfen."}]} end))
  end

  test "BLOCKER cause accepts structured escalation or plain validation and release clears reservations", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    escalation = %{"cause" => "Hostzugang", "attempts" => "Probe fehlgeschlagen", "proposal" => "Zugang prüfen", "decision" => "Freigabe"}
    structured = "## Symphony Workpad\n\n### YOLO-Übergabe\n\nEskalation:\n```json\n#{Jason.encode!(escalation)}\n```\n"
    opts = [now: fn -> 1_000 end, workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end]

    Process.put(:brake_body, structured)
    assert :ok = BlockerBrake.reserve([issue], "structured", opts)
    Process.put(:brake_body, "## Symphony Workpad\n\n### Validierung\n\nPlain requirement\n")
    assert :ok = BlockerBrake.reserve([issue], "plain", opts)
    assert :ok = BlockerBrake.release([issue], "plain")
    assert :ok = BlockerBrake.release([issue], "structured")
    assert {:ok, [^issue]} = BlockerBrake.check([issue], opts)

    for invalid <- ["{oops}", Jason.encode!(%{"cause" => "only-cause"})] do
      Process.put(:brake_body, "## Symphony Workpad\n\nEskalation:\n```json\n#{invalid}\n```\n")
      assert {:error, :blocker_cause_missing} = BlockerBrake.reserve([issue], "invalid", opts)
    end
  end

  test "BLOCKER handoff requires confirmed human assignment", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    body = "## Symphony Workpad\n\n### Betreiberauftrag\n\nHostzugang prüfen.\n"

    opts = [
      now: fn -> 1_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end,
      workpad_write: fn _, _ -> :ok end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end
    ]

    assert :ok = BlockerBrake.reserve([issue], "first", opts)

    assert {:error, :blocker_brake_handoff_unconfirmed} =
             BlockerBrake.check([issue], Keyword.put(opts, :fetch, fn _ -> {:ok, [issue]} end))

    assert {:error, :offline} =
             BlockerBrake.check([issue], Keyword.put(opts, :query, fn _, _ -> {:error, :offline} end))

    Process.put(:brake_fetches, 0)

    comments = fn _ ->
      reads = Process.get(:brake_fetches) + 1
      Process.put(:brake_fetches, reads)
      if reads == 2, do: {:error, :offline}, else: {:ok, [%{id: "workpad", body: body}]}
    end

    confirmed = Keyword.merge(opts, workpad_comments: comments, fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end)
    assert {:ok, []} = BlockerBrake.check([issue], confirmed)
  end

  test "a changed operator duty supersedes unchanged validation lines", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    initial = "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang\n\n### Betreiberauftrag\n\nAktion A\n"
    Process.put(:brake_body, initial)
    opts = [now: fn -> 1_000 end, workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end]

    assert :ok = BlockerBrake.reserve([issue], "first", opts)
    Process.put(:brake_body, String.replace(initial, "Aktion A", "Aktion B"))
    assert {:ok, [^issue]} = BlockerBrake.check([issue], opts)
  end

  test "handoff notes leave the operator duty cause unchanged", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    Process.put(:brake_body, "## Symphony Workpad\n\n### Betreiberauftrag\n\nHostzugang prüfen.\n")

    opts = [
      now: fn -> 1_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end,
      workpad_write: fn _, body ->
        Process.put(:brake_body, body)
        :ok
      end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end,
      fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end
    ]

    assert :ok = BlockerBrake.reserve([issue], "first", opts)
    assert {:ok, []} = BlockerBrake.check([issue], opts)
    assert Process.get(:brake_body) =~ "### BLOCKER-Übergabe"
    assert {:ok, []} = BlockerBrake.check([issue], opts)
  end

  test "the brake's own Verlauf note cannot create a new cause", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    Process.put(:brake_body, "## Symphony Workpad\n\n### Verlauf\n\n- Betreiber wartet auf Hostzugang.\n")

    opts = [
      now: fn -> 1_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end,
      workpad_write: fn _, body ->
        Process.put(:brake_body, body)
        :ok
      end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end,
      fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end
    ]

    assert :ok = BlockerBrake.reserve([issue], "first", opts)
    Process.put(:brake_body, Process.get(:brake_body) <> "- BLOCKER-Schleifenbremse: bisheriger Versuch dokumentiert.\n")
    assert {:ok, []} = BlockerBrake.check([issue], opts)
  end

  test "a missing escalation route still completes the human handoff", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_yolo_agent, "pai"))
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    Process.put(:brake_body, "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang\n")

    opts = [
      now: fn -> 1_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end,
      workpad_write: fn _, body ->
        Process.put(:brake_body, body)
        :ok
      end,
      escalation_route: fn _, _ -> {:error, :route_unavailable} end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end,
      fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end
    ]

    assert :ok = BlockerBrake.reserve([issue], "first", opts)
    assert {:ok, []} = BlockerBrake.check([issue], opts)
    assert Process.get(:brake_body) =~ "BLOCKER-Eskalationsweg nicht verfügbar"
  end

  test "coordinator does not deliver a repeated BLOCKER cause", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    body = "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang; fällig: Yolo Review\n"
    parent = self()

    opts = [
      now: fn -> 2_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end,
      workpad_write: fn _, updated ->
        send(parent, {:brake_note, updated})
        :ok
      end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end,
      fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end,
      scan: fn _ -> {:ok, Map.put(inbox(), "current", %{})} end,
      start: fn _, _ -> flunk("same BLOCKER must not start another PO run") end
    ]

    assert :ok = BlockerBrake.reserve([issue], "previous", opts)
    assert :ok = Journal.write(%{"id" => "previous", "group" => "blocker", "members" => [%{"id" => issue.id}], "state" => "completed"})
    assert Group.groups([issue]) == %{"blocker" => [issue]}
    assert SymphonyElixir.TestRun.start_allowed?(issue)
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    assert tick(state, [issue], opts).yolo_runs == %{}
    assert_receive {:brake_note, updated}
    assert updated =~ "PO-Lauf previous"
  end

  for recovery <- ~w(rejected fenced_interruption) do
    test "coordinator redelivers an unprocessed BLOCKER after #{recovery} recovery", %{issues: [issue | _]} do
      alias SymphonyElixir.Yolo.Delivery

      issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
      body = "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang; fällig: Yolo Review\n"

      opts = [
        now: fn -> 2_000 end,
        workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end,
        workpad_write: fn _, _ -> flunk("an unprocessed delivery must not escalate") end,
        scan: fn _ -> {:ok, Map.put(inbox(), "current", %{})} end,
        start: fn "blocker", _ ->
          send(self(), :redelivered)
          {:error, :observed_start}
        end
      ]

      {:ok, observations, _} = Observation.capture([issue], %{}, opts)
      assert :ok = Delivery.reserve("blocker", "first-run", observations)
      assert :ok = BlockerBrake.reserve([issue], "first-run", opts)
      {:ok, record} = Store.read("blocker")
      receipt = record["deliveries"][issue.id]

      order = %{
        "id" => "first-run",
        "group" => "blocker",
        "members" => [%{"id" => issue.id}],
        "state" => if(unquote(recovery) == "rejected", do: "rejected", else: "retired")
      }

      order =
        if unquote(recovery) == "fenced_interruption" do
          Map.put(order, "retirement", %{
            "kind" => "fenced_interruption",
            "attempt" => %{"id" => "first-run", "completed" => %{}},
            "deliveries" => %{issue.id => receipt}
          })
        else
          order
        end

      assert :ok = Journal.write(order)
      assert :ok = Delivery.reconcile("blocker")
      assert :ok = Delivery.reconcile("blocker")
      assert {:ok, [^issue]} = BlockerBrake.check([issue], opts)

      state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
      tick(state, [issue], opts)
      assert_receive :redelivered
    end
  end

  test "interruption releases only unfinished BLOCKER members of the retired generation", %{issues: [first, second, third]} do
    alias SymphonyElixir.Yolo.Delivery

    members = Enum.map([first, second, third], &%{&1 | state: "BLOCKER"})
    [first, second, third] = members
    body = "## Symphony Workpad\n\n### Betreiberauftrag\n\nHostzugang prüfen.\n"
    opts = [now: fn -> 2_000 end, workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end]
    {:ok, observations, _} = Observation.capture(members, %{}, scan: fn _ -> {:ok, Map.put(inbox(), "current", %{})} end)
    assert :ok = Delivery.reserve("blocker", "retired-run", observations)
    assert :ok = BlockerBrake.reserve(members, "retired-run", opts)
    {:ok, before} = Store.read("blocker")
    original = before["deliveries"]

    assert :ok = Delivery.reserve("blocker", "newer-run", Map.take(observations, [third.id]))
    assert :ok = BlockerBrake.reserve([third], "newer-run", opts)

    order = %{
      "id" => "retired-run",
      "group" => "blocker",
      "members" => Enum.map(members, &%{"id" => &1.id}),
      "state" => "retired",
      "retirement" => %{
        "kind" => "fenced_interruption",
        "attempt" => %{"id" => "retired-run", "completed" => %{second.id => "Entscheidung abgeschlossen"}},
        "deliveries" => original
      }
    }

    assert :ok = Journal.write(order)
    assert :ok = Delivery.reconcile("blocker")
    assert :ok = Delivery.reconcile("blocker")
    {:ok, after_reconcile} = Store.read("blocker")
    expected = Map.take(before["deliveries"], [second.id]) |> Map.put(third.id, %{"semantic" => observations[third.id]["semantic"], "run_id" => "newer-run"})
    assert after_reconcile["deliveries"] == expected
    assert {:ok, [^first]} = BlockerBrake.check([first], opts)

    blocked = Keyword.merge(opts, workpad_write: fn _, _ -> :ok end, query: fn _, _ -> {:error, :expected_handoff} end)
    assert {:error, :expected_handoff} = BlockerBrake.check([second], blocked)
    assert {:error, :expected_handoff} = BlockerBrake.check([third], blocked)
  end

  test "rejected BLOCKER reconciliation releases a reservation even when its receipt was already removed", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery

    issue = %{issue | state: "BLOCKER"}
    body = "## Symphony Workpad\n\n### Betreiberauftrag\n\nHostzugang prüfen.\n"
    opts = [now: fn -> 2_000 end, workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end]
    assert :ok = BlockerBrake.reserve([issue], "rejected-run", opts)
    assert :ok = Journal.write(%{"id" => "rejected-run", "group" => "blocker", "members" => [%{"id" => issue.id}], "state" => "rejected"})
    assert :ok = Delivery.reconcile("blocker")
    assert {:ok, [^issue]} = BlockerBrake.check([issue], opts)
  end

  test "malformed interruption proof keeps the BLOCKER reservation and delivery", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery

    issue = %{issue | state: "BLOCKER"}
    body = "## Symphony Workpad\n\n### Betreiberauftrag\n\nHostzugang prüfen.\n"
    opts = [now: fn -> 2_000 end, workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: body}]} end]
    {:ok, observations, _} = Observation.capture([issue], %{}, scan: fn _ -> {:ok, Map.put(inbox(), "current", %{})} end)
    assert :ok = Delivery.reserve("blocker", "retired-run", observations)
    assert :ok = BlockerBrake.reserve([issue], "retired-run", opts)
    {:ok, before} = Store.read("blocker")

    assert :ok =
             Journal.write(%{
               "id" => "retired-run",
               "group" => "blocker",
               "members" => [%{"id" => issue.id}],
               "state" => "retired",
               "retirement" => %{
                 "kind" => "fenced_interruption",
                 "attempt" => %{"id" => "different-run"},
                 "deliveries" => before["deliveries"]
               }
             })

    assert {:error, :openclaw_journal_corrupt} = Delivery.reconcile("blocker")
    assert {:ok, ^before} = Store.read("blocker")

    blocked = Keyword.merge(opts, workpad_write: fn _, _ -> :ok end, query: fn _, _ -> {:error, :expected_handoff} end)
    assert {:error, :expected_handoff} = BlockerBrake.check([issue], blocked)
  end

  test "an unresolved marker blocks a non-Backlog PO action", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    blocked = %{issue | blocked_by: [%{id: "foreign", state: "BLOCKER", marker: true}]}

    assert {:error, :yolo_dependency_blocked} =
             Yolo.Dependencies.actionable([issue], dependencies: fn _ -> {:ok, [blocked]} end)
  end

  test "coordinator logs a BLOCKER brake read failure without delivering", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    opts = [scan: fn _ -> {:ok, Map.put(inbox(), "current", %{})} end, workpad_comments: fn _ -> {:error, :offline} end, start: fn _, _ -> flunk("BLOCKER read failure must not deliver") end]

    assert tick(state, [issue], opts).yolo_runs == %{}
  end

  test "uncertain escalation send still hands off and is not sent again", %{issues: [issue | _], context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_yolo_agent, "pai"))
    issue = %{issue | state: "BLOCKER", url: "https://linear.example/PRO-0"}
    Process.put(:brake_body, "## Symphony Workpad\n\n### Validierung\n\n- [ ] Betreiber prüft Hostzugang; fällig: Yolo Review\n")
    parent = self()

    opts = [
      now: fn -> 1_000 end,
      workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: Process.get(:brake_body)}]} end,
      workpad_write: fn _, body ->
        Process.put(:brake_body, body)
        :ok
      end,
      escalation_route: fn _, _ -> {:ok, %{"channel" => "bound"}} end,
      escalation_send: fn _, _, _ ->
        send(parent, :send_attempt)
        {:error, :timeout}
      end,
      query: fn _, %{id: id} -> {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}} end,
      fetch: fn _ -> {:ok, [%{issue | delegate_id: nil, assignee_id: "human"}]} end
    ]

    assert :ok = BlockerBrake.reserve([issue], "first-run", opts)
    assert {:ok, []} = BlockerBrake.check([issue], opts)
    assert_receive :send_attempt
    assert Process.get(:brake_body) =~ "BLOCKER-Eskalationsversand unbestätigt"
    assert {:ok, []} = BlockerBrake.check([issue], opts)
    refute_receive :send_attempt, 20
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

  test "an incomplete dependency refresh cannot dispatch a partial group", %{issues: issues} do
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    assert tick(state, issues,
             dependencies: fn _ -> {:ok, tl(issues)} end,
             start: fn _, _ -> flunk("incomplete group must not start") end
           ).yolo_runs == %{}
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
      assert {:ok, waiting} = Store.read("review")
      assert Map.delete(waiting, "waiting_reason") == Map.delete(before_failure, "waiting_reason")
      assert is_binary(waiting["waiting_reason"])
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
    :ok = Store.write("review-readiness", Map.put(readiness, "members", %{"review:broken" => nil}))
    assert {:error, :yolo_readiness_corrupt} = ReviewReadiness.epoch("review")
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

    scheduled = Enum.map(issues, &%{&1 | last_comment_signal: %{relay_epoch: "relay-current"}})
    assert :ok = run_group("incoming", scheduled, scheduled, opts)
    assert_receive {:yolo_event, "incoming", %{session_id: "shared-session"}}
    assert {:ok, completed} = Store.read("incoming")
    assert completed["processed"] == fingerprint
    assert length(Map.keys(completed["attempt"]["completed"])) == 3
    # A later edit remains open, including across scheduler reconstruction.
    edited = [%{hd(issues) | description: "new request"} | tl(issues)]
    assert {:ok, _, next} = Observation.capture(edited, completed["observations"], scan: &scan/1)
    refute next == completed["processed"]
  end

  test "a failed final input check keeps a completed member unprocessed", %{issues: [issue | _], root: root} do
    opts = [
      fetch: fn _ -> {:ok, [issue]} end,
      lease: fn _, callback -> callback.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "merged-sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{inputs: []}} end,
      before_action: fn _ -> {:error, :new_input} end,
      session: fn _, _, _, session_opts ->
        session_opts[:on_message].(%{session_id: "checked-session", event: :session_started})
        assert :ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "Entscheidung belegt"}, fetch: fn _ -> {:ok, [issue]} end, before_action: fn _ -> :ok end)
        {:ok, %{session_id: "checked-session"}}
      end
    ]

    assert {:error, :new_input} = run_group("incoming", [issue], [issue], opts)
    assert {:ok, %{"processed" => nil}} = Store.read("incoming")
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
      {:ok, record} = Store.read("incoming")
      assert :ok = Store.write("incoming", Map.merge(record, %{"checkout_cleanup_blocked" => false, "attempt" => Map.put(record["attempt"], "checkout_cleanup", "removed")}))
    end
  end

  test "a newly ready review chain member prevents a partial launch", %{issues: [first, second | _], root: root} do
    first = %{first | state: "Yolo Review"}
    second = %{second | state: "Yolo Review", blocked_by: [%{id: first.id, state: "Yolo Review"}]}
    Process.put(:review_project_reads, 0)

    opts = [
      fetch: fn _ -> {:ok, [first]} end,
      lease: fn _, callback -> callback.() end,
      scan: &scan/1,
      project: fn ->
        reads = Process.get(:review_project_reads)
        Process.put(:review_project_reads, reads + 1)
        {:ok, if(reads == 0, do: [first], else: [first, second])}
      end,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{inputs: []}} end,
      session: fn _, _, _, _ -> flunk("incomplete review chain must not launch") end
    ]

    assert {:error, :yolo_review_waiting} = run_group("review", [first], [first], opts)
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
    issues = Enum.map(issues, &%{&1 | last_comment_signal: nil})

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

  test "member readiness is checked immediately before PO delivery", %{issues: [issue | _], root: root} do
    issue = %{issue | last_comment_signal: nil}

    opts = [
      fetch: fn _ -> {:ok, [issue]} end,
      lease: fn _, callback -> callback.() end,
      lease_ready: fn _ -> {:error, :synthetic_member_unavailable} end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{inputs: []}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ -> flunk("unready member must not be delivered") end
    ]

    assert {:error, :synthetic_member_unavailable} = run_group("incoming", [issue], [issue], opts)
  end

  test "a retry uses a fresh dependency field when its scheduled copy is missing", %{issues: [issue | _]} do
    scheduled = %{issue | blocked_by: nil}
    {:ok, record} = Store.read("incoming")

    :ok =
      Store.write(
        "incoming",
        Map.merge(record, %{"retry_at" => System.system_time(:millisecond) - 1, "relay_signals" => %{issue.id => Observation.relay_signal(issue)}})
      )

    assert {:error, :synthetic_nonstart} =
             run_group("incoming", [scheduled], [scheduled],
               fetch: fn _ -> {:ok, [issue]} end,
               lease: fn _, callback -> callback.() end,
               dependencies: fn _ -> flunk("a due retry reuses its dependency snapshot") end,
               scan: &scan/1,
               workspace: fn _, _ -> {:error, :synthetic_nonstart} end
             )
  end

  test "terminal local turn failure ends delivery without claiming a decision", %{issues: [issue | _], root: root} do
    alias SymphonyElixir.Yolo.Delivery

    opts = [
      fetch: fn _ -> {:ok, [issue]} end,
      lease: fn _, callback -> callback.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{inputs: []}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, session_opts ->
        session_opts[:on_message].(%{event: :turn_failed, session_id: "failed-session"})
        {:error, :turn_failed}
      end
    ]

    assert {:error, :turn_failed} = run_group("incoming", [issue], [issue], opts)
    assert {:ok, record} = Store.read("incoming")
    assert get_in(record, ["delivery_ends", record["attempt"]["id"]]) == true
    assert record["attempt"]["completed"] == nil

    {:ok, same, _} = Observation.capture([issue], %{}, scan: &scan/1)
    {:ok, changed, _} = Observation.capture([issue], %{}, scan: &scan/1, impulse_generations: %{issue.id => 1})
    assert Delivery.pending([issue], same, record) == []
    assert Delivery.pending([issue], changed, record) == [issue]
  end

  for damage <- [:attempt_mismatch, :state_corrupt] do
    @tag damage: damage
    test "terminal local failure keeps an unprovable delivery reserved (#{damage})", %{issues: [issue | _], root: root, damage: damage} do
      opts = [
        fetch: fn _ -> {:ok, [issue]} end,
        lease: fn _, callback -> callback.() end,
        scan: &scan/1,
        workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
        unchanged: fn _ -> true end,
        checkpoint: fn _ -> {:ok, %{inputs: []}} end,
        before_action: fn _ -> :ok end,
        session: fn _, _, _, session_opts ->
          case damage do
            :attempt_mismatch ->
              {:ok, record} = Store.read("incoming")
              :ok = Store.write("incoming", Map.put(record, "attempt", nil))

            :state_corrupt ->
              File.write!(Store.path("incoming"), "corrupt")
          end

          session_opts[:on_message].(%{event: :turn_failed, session_id: "failed-session"})
          {:error, :turn_failed}
        end
      ]

      assert {:error, _} = run_group("incoming", [issue], [issue], opts)
    end
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
      assert {:error, _} = run_group("review", [review], [review], Keyword.put(base, :project, fn -> answer end))
      assert {:ok, %{"processed" => nil}} = Store.read("review")
    end

    Process.put(:project_checks, 0)

    changed = fn ->
      count = Process.get(:project_checks)
      Process.put(:project_checks, count + 1)
      {:ok, if(count == 0, do: [review], else: [blocked, expected])}
    end

    assert {:error, :yolo_review_waiting} = run_group("review", [review], [review], Keyword.put(base, :project, changed))
    assert Process.get(:project_checks) == 2
  end

  test "failed PO starter spends at most one Linear request per retry over 30 simulated minutes", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:po_linear_reads, 0)
    Process.put(:po_scans, 0)

    read = fn -> Process.put(:po_linear_reads, Process.get(:po_linear_reads) + 1) end

    opts = [
      dependencies: fn issues ->
        if issues != [], do: read.()
        {:ok, issues}
      end,
      scan: fn _ ->
        read.()
        Process.put(:po_scans, Process.get(:po_scans) + 1)
        {:ok, inbox()}
      end,
      start: fn "review", _ ->
        assert {:error, :synthetic_po_failure} =
                 run_group("review", [review], [review],
                   dependencies: fn issues -> {:ok, issues} end,
                   fetch: fn _ ->
                     read.()
                     {:error, :synthetic_po_failure}
                   end,
                   lease: fn _, callback -> callback.() end
                 )

        {:error, :synthetic_po_failure}
      end
    ]

    tick(state, [review], opts)
    assert {:ok, %{"retry_at" => retry_at} = record} = Store.read("review")
    assert record["relay_signals"] == %{review.id => Observation.relay_signal(review)}
    assert retry_at > System.system_time(:millisecond)
    assert Process.get(:po_linear_reads) == 3
    assert Process.get(:po_scans) == 1

    {_deadline, retries} =
      Enum.reduce(5_000..1_800_000//5_000, {30_000, 0}, fn elapsed, {deadline, retries} ->
        due? = elapsed >= deadline

        if due? do
          {:ok, current} = Store.read("review")
          :ok = Store.write("review", %{current | "retry_at" => System.system_time(:millisecond) - 1})
        end

        before_reads = Process.get(:po_linear_reads)
        tick(state, [review], opts)
        assert Process.get(:po_linear_reads) - before_reads == if(due?, do: 1, else: 0)
        assert Process.get(:po_scans) == 1

        if due? do
          {:ok, current} = Store.read("review")
          count = retries + 2
          assert current["failure_count"] == count
          delay = min(30_000 * Integer.pow(2, min(count - 1, 5)), 900_000)
          assert (current["retry_at"] - System.system_time(:millisecond)) in (delay - 2_000)..delay
          {elapsed + delay, retries + 1}
        else
          {deadline, retries}
        end
      end)

    assert retries == 5
    assert Process.get(:po_linear_reads) == 3 + retries
  end

  test "a due retry holds the real app lease without preloading Linear before a failed fetch", %{issues: [issue | _]} do
    {:ok, record} = Store.read("incoming")

    record =
      Map.merge(record, %{
        "retry_at" => System.system_time(:millisecond) - 1,
        "relay_signals" => %{issue.id => Observation.relay_signal(issue)},
        "last_failure_reason" => ":synthetic_po_failure",
        "failure_count" => 1
      })

    assert :ok = Store.write("incoming", record)
    Process.put(:po_retry_fetches, 0)

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
      flunk("a failed retry must not enter the delegated lease's Linear checks")
    end)

    for _ <- 1..2 do
      assert {:error, :synthetic_po_failure} =
               run_group("incoming", [issue], [issue],
                 fetch: fn _ ->
                   Process.put(:po_retry_fetches, Process.get(:po_retry_fetches) + 1)
                   {:error, :synthetic_po_failure}
                 end
               )
    end

    assert Process.get(:po_retry_fetches) == 2
  end

  test "foreign relay comment and dependency status changes wake a failed PO group immediately", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review", blocked_by: [%{id: "fix", state: "Review"}]}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:po_issue, review)
    Process.put(:po_scans, 0)
    Process.put(:po_starts, 0)

    opts = [
      dependencies: fn issues -> {:ok, issues} end,
      scan: fn _ ->
        Process.put(:po_scans, Process.get(:po_scans) + 1)
        {:ok, inbox()}
      end,
      start: fn group, _ ->
        Process.put(:po_starts, Process.get(:po_starts) + 1)
        current = Process.get(:po_issue)

        assert {:error, :synthetic_po_failure} =
                 run_group(group, [current], [current],
                   fetch: fn _ -> {:error, :synthetic_po_failure} end,
                   lease: fn _, callback -> callback.() end
                 )

        {:error, :synthetic_po_failure}
      end
    ]

    tick(state, [review], opts)
    assert Process.get(:po_starts) == 1
    assert Process.get(:po_scans) == 1

    dependency = %{review | blocked_by: [%{id: "fix", state: "Fertig"}]}
    Process.put(:po_issue, dependency)
    tick(state, [dependency], opts)
    assert Process.get(:po_starts) == 2
    assert Process.get(:po_scans) == 2

    comment = %{dependency | last_comment_signal: %{relay_epoch: 1}}
    Process.put(:po_issue, comment)
    tick(state, [comment], opts)
    assert Process.get(:po_starts) == 3
    assert Process.get(:po_scans) == 3
    assert {:ok, %{"failure_count" => 1, "retry_at" => retry_at}} = Store.read("review")
    assert retry_at > System.system_time(:millisecond)

    planning = %{comment | state: "Planung"}
    Process.put(:po_issue, planning)
    tick(state, [planning], opts)
    assert Process.get(:po_starts) == 4
    assert Process.get(:po_scans) == 4
  end

  test "a persistent PO failure is logged once until its reason changes", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review"}
    Process.put(:po_failure, :first_failure)

    opts = [
      fetch: fn _ -> {:error, Process.get(:po_failure)} end,
      lease: fn _, callback -> callback.() end
    ]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        for _ <- 1..3, do: assert({:error, :first_failure} = run_group("review", [review], [review], opts))
        Process.put(:po_failure, :second_failure)
        assert {:error, :second_failure} = run_group("review", [review], [review], opts)
      end)

    assert length(Regex.scan(~r/YOLO group retry group=review/, log)) == 2
    assert {:ok, %{"failure_count" => 1, "last_failure_reason" => ":second_failure"}} = Store.read("review")
  end

  test "a failed PO starter keeps observations and spends no Linear requests over 30 simulated minutes", %{issues: [issue | _]} do
    review = %{issue | state: "Yolo Review"}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:po_scans, 0)
    Process.put(:po_starts, 0)
    Process.put(:po_linear_reads, 0)

    opts = [
      dependencies: fn issues ->
        if issues != [], do: Process.put(:po_linear_reads, Process.get(:po_linear_reads) + 1)
        {:ok, issues}
      end,
      scan: fn _ ->
        Process.put(:po_scans, Process.get(:po_scans) + 1)
        Process.put(:po_linear_reads, Process.get(:po_linear_reads) + 1)
        {:ok, inbox()}
      end,
      start: fn _, _ ->
        Process.put(:po_starts, Process.get(:po_starts) + 1)
        {:error, :starter_broken}
      end
    ]

    tick(state, [review], opts)
    assert {:ok, %{"observations" => observations, "retry_at" => retry_at}} = Store.read("review")
    assert is_map(observations[review.id])
    assert retry_at > System.system_time(:millisecond)
    assert Process.get(:po_linear_reads) == 2
    tick(state, [review], opts)
    assert Process.get(:po_scans) == 1
    assert Process.get(:po_starts) == 1

    {_deadline, retries} =
      Enum.reduce(5_000..1_800_000//5_000, {30_000, 0}, fn elapsed, {deadline, retries} ->
        due? = elapsed >= deadline

        if due? do
          {:ok, current} = Store.read("review")
          :ok = Store.write("review", %{current | "retry_at" => System.system_time(:millisecond) - 1})
        end

        before_reads = Process.get(:po_linear_reads)
        tick(state, [review], opts)
        assert Process.get(:po_linear_reads) == before_reads

        if due? do
          count = retries + 2
          {:ok, current} = Store.read("review")
          assert current["failure_count"] == count
          {elapsed + min(30_000 * Integer.pow(2, min(count - 1, 5)), 900_000), retries + 1}
        else
          {deadline, retries}
        end
      end)

    assert retries == 5
    assert Process.get(:po_scans) == 1
    assert Process.get(:po_starts) == 1 + retries
    assert Process.get(:po_linear_reads) == 2
  end

  test "a failed review retry keeps its fresh dependency snapshot when Relay is stale", %{issues: [issue | _]} do
    relay = %{issue | state: "Yolo Review", blocked_by: [%{id: "external", state: "Test (AI)"}]}
    refreshed = %{relay | blocked_by: [%{id: "external", state: "Review"}]}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:dependency_reads, 0)
    Process.put(:review_starts, 0)
    Process.put(:review_scans, 0)

    opts = [
      dependencies: fn issues ->
        if issues != [], do: Process.put(:dependency_reads, Process.get(:dependency_reads) + 1)
        {:ok, Enum.map(issues, &%{&1 | blocked_by: refreshed.blocked_by})}
      end,
      scan: fn _ ->
        Process.put(:review_scans, Process.get(:review_scans) + 1)
        {:ok, inbox()}
      end,
      start: fn "review", _ ->
        Process.put(:review_starts, Process.get(:review_starts) + 1)
        {:error, :synthetic_po_failure}
      end
    ]

    tick(state, [relay], opts)
    assert Process.get(:dependency_reads) == 1
    assert Process.get(:review_starts) == 1
    assert Process.get(:review_scans) == 1
    assert {:ok, %{"retry_at" => retry_at, "dependency_snapshot" => snapshot} = record} = Store.read("review")
    assert retry_at > System.system_time(:millisecond)
    assert get_in(snapshot, [issue.id, Access.at(0), "state"]) == "Review"

    tick(state, [relay], opts)
    assert Process.get(:dependency_reads) == 1
    assert Process.get(:review_starts) == 1
    assert Process.get(:review_scans) == 1

    :ok = Store.write("review", %{record | "retry_at" => System.system_time(:millisecond) - 1})
    tick(state, [relay], opts)
    assert Process.get(:dependency_reads) == 1
    assert Process.get(:review_starts) == 2
    assert Process.get(:review_scans) == 1
  end

  test "runner reuses the coordinator observation after a local startup failure", %{issues: [issue | _], root: root, context: context} do
    init_review_git(root, context)
    relay_issue = %{issue | last_comment_signal: %{relay_epoch: "current"}}
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    Process.put(:po_scans, 0)
    Process.put(:po_reads, 0)

    opts = [
      dependencies: fn issues ->
        if issues != [], do: Process.put(:po_reads, Process.get(:po_reads) + 1)
        {:ok, issues}
      end,
      scan: fn _ ->
        Process.put(:po_scans, Process.get(:po_scans) + 1)
        Process.put(:po_reads, Process.get(:po_reads) + 1)
        {:ok, inbox()}
      end,
      fetch: fn _ ->
        Process.put(:po_reads, Process.get(:po_reads) + 1)
        {:ok, [issue]}
      end,
      lease: fn _, callback -> callback.() end,
      workspace: fn _, _ -> {:error, :synthetic_create_failure} end
    ]

    start = fn _, _ ->
      assert {:error, :synthetic_create_failure} = run_group("incoming", [relay_issue], [relay_issue], opts)
      {:error, :synthetic_create_failure}
    end

    tick(state, [relay_issue], Keyword.put(opts, :start, start))
    assert Process.get(:po_scans) == 1
    assert {:ok, %{"observations" => observations, "retry_at" => retry_at}} = Store.read("incoming")
    assert is_map(observations[issue.id])
    assert retry_at > System.system_time(:millisecond)

    {:ok, record} = Store.read("incoming")
    :ok = Store.write("incoming", %{record | "retry_at" => System.system_time(:millisecond) - 1})
    before_reads = Process.get(:po_reads)
    tick(%Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}, [relay_issue], Keyword.put(opts, :start, start))
    assert Process.get(:po_scans) == 1
    assert Process.get(:po_reads) - before_reads == 1
  end

  test "failed review start removes its newly created checkout", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    workspace_root = Path.join(root, "worktrees")
    ProjectContext.bind(put_in(context.settings.workspace.root, workspace_root))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)
    project_checks = :ets.new(:project_checks, [:set, :private])
    :ets.insert(project_checks, {:count, 0})

    project = fn ->
      count = :ets.update_counter(project_checks, :count, 1)
      {:ok, if(count == 1, do: [review], else: [%{review | state: "Review"}])}
    end

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: project,
      checkpoint: fn _ -> {:ok, %{}} end,
      session: fn _, _, _, _ -> flunk("verify_start must reject this group") end
    ]

    assert {:error, :yolo_review_waiting} = run_group("review", [review], [review], opts)
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1
    assert {:ok, first} = Store.read("review")
    assert first["nonstart"]["count"] == 1
    assert first["attempt"]["checkout_cleanup"] == "removed"
    assert first["retry_at"] > System.system_time(:millisecond) + 20_000

    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    tick(state, [review], scan: &scan/1, start: fn _, _ -> flunk("retry must wait") end)
    :ok = Store.write("review", %{first | "retry_at" => nil})
    :ets.insert(project_checks, {:count, 0})
    assert {:error, :yolo_review_waiting} = run_group("review", [review], [review], opts)
    assert {:ok, second} = Store.read("review")
    assert second["nonstart"]["count"] == 2
    assert second["retry_at"] > System.system_time(:millisecond) + 50_000
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1

    for expected_count <- 3..7 do
      {:ok, current} = Store.read("review")
      :ok = Store.write("review", %{current | "retry_at" => nil})
      :ets.insert(project_checks, {:count, 0})
      assert {:error, :yolo_review_waiting} = run_group("review", [review], [review], opts)
      assert {:ok, repeated} = Store.read("review")
      assert repeated["nonstart"]["count"] == expected_count

      if expected_count >= 6 do
        assert repeated["retry_at"] > System.system_time(:millisecond) + 890_000
        assert repeated["retry_at"] <= System.system_time(:millisecond) + 900_000
      end
    end

    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1

    changed = %{review | title: "changed review"}

    tick(state, [changed],
      scan: &scan/1,
      start: fn group, _ ->
        send(self(), {:started, group})
        {:error, :capacity}
      end
    )

    assert_receive {:started, "review"}
    assert {:ok, reset} = Store.read("review")
    assert reset["nonstart"] == nil
  end

  test "incoming and blocker nonstarts remove their checkout and increase retry delay", %{issues: [issue | _], root: root, context: context} do
    init_review_git(root, context)
    duty = operator_workpad("duty", "a")
    snapshot = Map.put(inbox(%{"duty" => duty}), "current", %{"workpad" => "duty"})

    for {group, state} <- [{"incoming", "Backlog"}, {"blocker", "BLOCKER"}] do
      member = %{issue | state: state}
      Process.put({:nonstart_count, group}, 0)

      opts = [
        fetch: fn _ -> {:ok, [member]} end,
        lease: fn _, fun -> fun.() end,
        scan: fn _ -> {:ok, snapshot} end,
        workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: duty["source"]["body"]}]} end,
        checkpoint: fn _ ->
          count = Process.get({:nonstart_count, group}) + 1
          Process.put({:nonstart_count, group}, count)
          {:error, if(count == 1, do: :synthetic_nonstart, else: :synthetic_retry)}
        end,
        session: fn _, _, _, _ -> flunk("checkout must fail before session") end
      ]

      for expected_count <- 1..2 do
        assert {:error, reason} = run_group(group, [member], [member], opts)
        assert reason == if(expected_count == 1, do: :synthetic_nonstart, else: :synthetic_retry)
        assert {:ok, record} = Store.read(group)
        assert record["attempt"]["checkout_cleanup"] == "removed"
        assert record["nonstart"]["count"] == expected_count
        assert record["retry_at"] > System.system_time(:millisecond) + if(expected_count == 1, do: 20_000, else: 50_000)
        assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
        assert length(Regex.scan(~r/^worktree /m, listing)) == 1

        coordinator = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
        tick(coordinator, [member], scan: fn _ -> {:ok, snapshot} end, start: fn _, _ -> flunk("unchanged group must wait") end)
        assert {:ok, %{"retry_at" => retry_at}} = Store.read(group)
        assert retry_at == record["retry_at"]

        if expected_count == 1 do
          assert :ok = Store.write(group, %{record | "retry_at" => nil})
        else
          changed = %{member | title: "new group signal", last_comment_signal: %{relay_epoch: "new"}}
          next_duty = operator_workpad("next", "b")
          next_snapshot = Map.put(inbox(%{"duty" => duty, "next" => next_duty}), "current", %{"workpad" => "next"})
          group_snapshot = if(group == "blocker", do: next_snapshot, else: snapshot)

          tick(coordinator, [changed],
            scan: fn _ -> {:ok, group_snapshot} end,
            start: fn started_group, _ ->
              send(self(), {:started, started_group})
              {:error, :capacity}
            end
          )

          if group == "incoming", do: assert_receive({:started, ^group})
          assert {:ok, %{"nonstart" => nil, "retry_at" => nil}} = Store.read(group)
        end
      end
    end
  end

  test "dirty incoming and blocker nonstarts retain their checkout and block another start", %{issues: [issue | _], root: root, context: context} do
    init_review_git(root, context)
    duty = operator_workpad("duty", "a")
    snapshot = Map.put(inbox(%{"duty" => duty}), "current", %{"workpad" => "duty"})

    for {group, state} <- [{"incoming", "Backlog"}, {"blocker", "BLOCKER"}] do
      member = %{issue | state: state}

      opts = [
        fetch: fn _ -> {:ok, [member]} end,
        lease: fn _, fun -> fun.() end,
        scan: fn _ -> {:ok, snapshot} end,
        workpad_comments: fn _ -> {:ok, [%{id: "workpad", body: duty["source"]["body"]}]} end,
        workspace: fn _, run_id ->
          {:ok, workspace} = Yolo.Workspace.create(group, run_id)
          Process.put({:dirty_workspace, group}, workspace)
          {:ok, workspace}
        end,
        checkpoint: fn _ ->
          File.write!(Path.join(Process.get({:dirty_workspace, group}).path, "tracked"), "changed")
          {:error, :synthetic_nonstart}
        end,
        session: fn _, _, _, _ -> flunk("dirty checkout must not start") end
      ]

      assert {:error, :synthetic_nonstart} = run_group(group, [member], [member], opts)
      assert {:ok, record} = Store.read(group)
      assert record["checkout_cleanup_blocked"] == true
      assert record["attempt"]["checkout_cleanup"] == "blocked"
      assert File.dir?(Process.get({:dirty_workspace, group}).path)
      assert {:error, :yolo_checkout_cleanup_unconfirmed} = run_group(group, [member], [member], opts)
    end

    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 3
  end

  test "rejected review delivery releases its checkout", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn -> {:ok, [review]} end,
      checkpoint: fn _ -> {:ok, %{}} end,
      session: fn _, _, _, session_opts ->
        assert :ok = session_opts[:on_session_start_failure].()
        {:error, :prestart_rejected}
      end
    ]

    assert {:error, :prestart_rejected} = run_group("review", [review], [review], opts)
    assert {:ok, record} = Store.read("review")
    assert record["attempt"]["checkout_cleanup"] == "removed"
    assert record["deliveries"] == %{}
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1
  end

  test "dirty failed review checkout blocks another start", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)
    Process.put(:project_checks, 0)

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      workspace: fn group, id ->
        {:ok, workspace} = Yolo.Workspace.create(group, id)
        Process.put(:review_workspace, workspace)
        {:ok, workspace}
      end,
      project: fn ->
        count = Process.get(:project_checks) + 1
        Process.put(:project_checks, count)
        if count == 2, do: File.write!(Path.join(Process.get(:review_workspace).path, "tracked"), "changed")
        {:ok, if(count == 1, do: [review], else: [%{review | state: "Review"}])}
      end,
      checkpoint: fn _ -> {:ok, %{}} end,
      session: fn _, _, _, _ -> flunk("dirty checkout must not start") end
    ]

    assert {:error, :yolo_review_waiting} = run_group("review", [review], [review], opts)
    assert {:ok, record} = Store.read("review")
    assert record["checkout_cleanup_blocked"] == true
    assert record["attempt"]["checkout_cleanup"] == "blocked"
    assert {:error, :yolo_review_checkout_cleanup_unconfirmed} = run_group("review", [review], [review], opts)
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 2
  end

  test "interrupted cleanup cannot create another review checkout", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)
    run_id = Ecto.UUID.generate()
    assert {:ok, workspace} = Yolo.Workspace.create("review", run_id)
    assert {:ok, record} = Store.read("review")
    attempt = %{"id" => run_id, "members" => [review.id], "workspace" => workspace.path, "sha" => workspace.sha, "cleanup_contract" => 1}
    assert :ok = Store.write("review", Map.put(record, "attempt", attempt))

    assert {:error, :yolo_review_checkout_cleanup_unconfirmed} = run_group("review", [review], [review])
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 2
  end

  test "fenced retired review delivery permits replanning while retaining its checkout", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)
    run_id = Ecto.UUID.generate()
    assert {:ok, workspace} = Yolo.Workspace.create("review", run_id)
    assert {:ok, record} = Store.read("review")
    attempt = %{"id" => run_id, "members" => [review.id], "workspace" => workspace.path, "sha" => workspace.sha, "cleanup_contract" => 1, "checkout_cleanup" => "creating"}
    receipt = %{"run_id" => run_id, "semantic" => "original"}
    assert :ok = Store.write("review", Map.merge(record, %{"attempt" => attempt, "deliveries" => %{review.id => receipt}}))

    order = %{
      "id" => run_id,
      "group" => "review",
      "members" => [%{"id" => review.id}],
      "state" => "retired",
      "writable" => false,
      "retirement" => %{"kind" => "fenced_interruption", "attempt" => attempt, "deliveries" => %{review.id => receipt}}
    }

    assert :ok = DurableState.write(Journal.path("review"), order)
    opts = [lease: fn _, fun -> fun.() end, fetch: fn _ -> {:error, :synthetic_replan} end]
    assert {:error, :synthetic_replan} = run_group("review", [review], [review], opts)
    assert {:ok, after_reconcile} = Store.read("review")
    assert after_reconcile["deliveries"] == %{}
    assert after_reconcile["attempt"] == attempt
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 2

    assert :ok = DurableState.write(Journal.path("review"), put_in(order, ["retirement", "attempt", "id"], "other-run"))
    assert {:error, :yolo_review_checkout_cleanup_unconfirmed} = run_group("review", [review], [review], opts)

    assert :ok = DurableState.write(Journal.path("review"), put_in(order, ["retirement", "deliveries"], nil))
    assert {:error, :openclaw_journal_corrupt} = Yolo.Delivery.reconcile("review")
  end

  test "review retry keeps backoff for unchanged pending subset", %{issues: [first, second | _]} do
    first = %{first | state: "Yolo Review"}
    second = %{second | state: "Yolo Review"}
    assert {:ok, observations, _} = Observation.capture([first, second], %{}, scan: &scan/1)
    assert {:ok, record} = Store.read("review")
    retry_at = System.system_time(:millisecond) + 120_000

    record =
      Map.merge(record, %{
        "observations" => observations,
        "deliveries" => %{first.id => %{"run_id" => "earlier", "semantic" => observations[first.id]["semantic"]}},
        "delivery_ends" => %{"earlier" => true},
        "nonstart" => %{"fingerprint" => Observation.fingerprint(Map.take(observations, [second.id])), "members" => [second.id], "count" => 2},
        "retry_at" => retry_at
      })

    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    assert :ok = Store.write("review", Map.delete(record, "delivery_ends"))
    tick(state, [first, second], scan: &scan/1, start: fn _, _ -> flunk("unconfirmed delivery must wait") end)
    assert {:ok, waiting} = Store.read("review")
    assert waiting["waiting_reason"] == "delivery_end_unconfirmed"
    assert waiting["nonstart"] == record["nonstart"]
    assert waiting["retry_at"] == retry_at

    assert :ok = Store.write("review", record)
    tick(state, [first, second], scan: &scan/1, start: fn _, _ -> flunk("unchanged pending subset must wait") end)
    assert {:ok, unchanged} = Store.read("review")
    assert unchanged["nonstart"] == record["nonstart"]
    assert unchanged["retry_at"] == retry_at

    tick(state, [first, %{second | title: "changed review"}],
      scan: &scan/1,
      start: fn group, _ ->
        send(self(), {:started, group})
        {:error, :capacity}
      end
    )

    assert_receive {:started, "review"}
    assert {:ok, changed} = Store.read("review")
    assert changed["nonstart"] == nil
    assert changed["retry_at"] == nil
  end

  test "failed checkout creation without a worktree remains retryable", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn -> {:ok, [review]} end,
      workspace: fn _, _ -> {:error, :synthetic_create_failure} end
    ]

    for _ <- 1..2 do
      assert {:error, :synthetic_create_failure} = run_group("review", [review], [review], opts)
      assert {:ok, record} = Store.read("review")
      assert record["attempt"]["checkout_cleanup"] == "none"
      assert record["checkout_cleanup_blocked"] == false
      assert :ok = Store.write("review", %{record | "retry_at" => nil})
    end

    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1
  end

  test "journal write failure after checkout creation removes only the owned review checkout", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    init_review_git(root, context)

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn -> {:ok, [review]} end,
      store_write: fn _, _ -> {:error, :synthetic_journal_failure} end,
      session: fn _, _, _, _ -> flunk("journal failure must precede delivery") end
    ]

    assert {:error, :synthetic_journal_failure} = run_group("review", [review], [review], opts)
    assert {:ok, record} = Store.read("review")
    assert record["attempt"]["checkout_cleanup"] == "removed"
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1

    assert :ok = File.rm(Store.path("review"))

    assert {:error, :synthetic_journal_failure} =
             run_group("review", [review], [review], Keyword.put(opts, :workspace, fn _, _ -> {:ok, %{path: root, sha: "fixture"}} end))

    assert {:ok, %{"attempt" => %{"checkout_cleanup" => "blocked"}}} = Store.read("review")

    incoming = %{issue | state: "Backlog"}
    incoming_opts = Keyword.put(opts, :fetch, fn _ -> {:ok, [incoming]} end)

    assert {:error, :synthetic_journal_failure} =
             run_group("incoming", [incoming], [incoming], Keyword.put(incoming_opts, :workspace, fn _, _ -> {:ok, %{path: root, sha: "fixture"}} end))

    assert {:error, :yolo_checkout_cleanup_unconfirmed} =
             run_group("incoming", [incoming], [incoming], Keyword.put(incoming_opts, :workspace, fn _, _ -> {:error, :synthetic_creation_failure} end))
  end

  test "uncertain review journals retain their checkouts for recovery", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    init_review_git(root, context)

    for mode <- [:observed_rejection, :foreign_pending, :unconfirmed_order] do
      opts = [
        fetch: fn _ -> {:ok, [review]} end,
        lease: fn _, fun -> fun.() end,
        scan: &scan/1,
        project: fn -> {:ok, [review]} end,
        checkpoint: fn _ -> {:ok, %{}} end,
        session: fn _, _, _, session_opts ->
          assert {:ok, %{"attempt" => %{"id" => run_id}}} = Store.read("review")

          order =
            case mode do
              :observed_rejection -> %{"id" => run_id, "group" => "review", "members" => [], "state" => "rejected", "rejection" => %{}, "acceptance_observed" => true}
              :foreign_pending -> %{"id" => Ecto.UUID.generate(), "group" => "review", "members" => [], "state" => "accepted"}
              :unconfirmed_order -> %{"id" => run_id, "group" => "review", "members" => [], "state" => "accepted"}
            end

          assert :ok = DurableState.write(Journal.path("review"), order)
          assert :ok = session_opts[:on_session_start_failure].()
          {:error, :synthetic_delivery_failure}
        end
      ]

      assert {:error, :synthetic_delivery_failure} = run_group("review", [review], [review], opts)
      assert {:ok, %{"attempt" => %{"id" => run_id}}} = Store.read("review")
      path = Path.join([root, "worktrees", "yolo", "review", run_id])
      assert File.dir?(path)
      assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
      assert length(Regex.scan(~r/^worktree /m, listing)) == 2
      assert {_, 0} = System.cmd("git", ["worktree", "remove", path], cd: root)
      assert :ok = File.rm(Store.path("review"))
      assert :ok = File.rm(Journal.path("review"))
    end
  end

  test "caught review startup failure cleans its checkout", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    init_review_git(root, context)
    Process.put(:project_checks, 0)

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn ->
        checks = Process.get(:project_checks) + 1
        Process.put(:project_checks, checks)
        if checks == 1, do: {:ok, [review]}, else: throw(:synthetic_project_failure)
      end,
      checkpoint: fn _ -> {:ok, %{}} end,
      session: fn _, _, _, _ -> flunk("project failure must precede delivery") end
    ]

    assert {:error, {:yolo_review_start_caught, :throw, ":synthetic_project_failure"}} = run_group("review", [review], [review], opts)
    assert {:ok, %{"attempt" => %{"checkout_cleanup" => "removed"}}} = Store.read("review")
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1
  end

  test "exception after review checkout creation is recorded and cleaned", %{issues: [issue | _], root: root, context: context} do
    review = %{issue | state: "Yolo Review"}
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "worktrees")))
    assert {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    File.write!(Path.join(root, "tracked"), "merged")
    assert {_, 0} = System.cmd("git", ["add", "tracked"], cd: root)
    assert {_, 0} = System.cmd("git", ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"], cd: root)
    assert {_, 0} = System.cmd("git", ["remote", "add", "origin", root], cd: root)
    Process.put(:project_checks, 0)

    opts = [
      fetch: fn _ -> {:ok, [review]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn ->
        count = Process.get(:project_checks) + 1
        Process.put(:project_checks, count)
        if count == 1, do: {:ok, [review]}, else: raise("synthetic project failure")
      end,
      checkpoint: fn _ -> {:ok, %{}} end,
      session: fn _, _, _, _ -> flunk("failed project must not start") end
    ]

    assert {:error, {:yolo_review_start_exception, RuntimeError}} = run_group("review", [review], [review], opts)
    assert {:ok, record} = Store.read("review")
    assert record["failure"]["run_id"] == record["attempt"]["id"]
    assert record["attempt"]["checkout_cleanup"] == "removed"
    assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
    assert length(Regex.scan(~r/^worktree /m, listing)) == 1
  end

  test "incoming caught failures after checkout creation are cleaned", %{issues: [issue | _], root: root, context: context} do
    init_review_git(root, context)

    for {failure, expected} <- [
          {fn -> throw(:synthetic_start_failure) end, {:yolo_start_caught, :throw, ":synthetic_start_failure"}},
          {fn -> raise "synthetic start failure" end, {:yolo_start_exception, RuntimeError}}
        ] do
      opts = [
        fetch: fn _ -> {:ok, [issue]} end,
        lease: fn _, fun -> fun.() end,
        scan: &scan/1,
        unchanged: fn _ -> failure.() end,
        checkpoint: fn _ -> {:ok, %{}} end,
        session: fn _, _, _, _ -> flunk("failure must precede delivery") end
      ]

      assert {:error, ^expected} = run_group("incoming", [issue], [issue], opts)
      assert {:ok, %{"attempt" => %{"checkout_cleanup" => "removed"}}} = Store.read("incoming")
      assert {listing, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: root)
      assert length(Regex.scan(~r/^worktree /m, listing)) == 1
    end
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
      # Each case starts from the same pre-delivery journal; an actual uncertain
      # dispatch remains reserved, as the assertions below verify.
      File.rm(Store.path("incoming"))
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
      assert {:ok, %{"processed" => nil, "deliveries" => deliveries}} = Store.read("incoming")
      assert map_size(deliveries) == length(issues)
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

  @tag :review_regression
  test "a proven local pre-turn failure releases delivery but an uncertain turn does not", %{issues: issues, root: root} do
    opts = [
      fetch: fn _ -> {:ok, issues} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end
    ]

    # The real AppServer rejects this path before creating a thread or turn.
    assert {:error, {:invalid_workspace_cwd, _, _, _}} = run_group("incoming", issues, issues, opts)
    assert {:ok, record} = Store.read("incoming")
    assert (record["deliveries"] || %{}) == %{}

    # The synthetic root is deliberately outside yolo/incoming; reset only this
    # fixture before exercising the separate uncertain-delivery case.
    assert :ok = Store.write("incoming", Map.merge(record, %{"checkout_cleanup_blocked" => false, "attempt" => Map.put(record["attempt"], "checkout_cleanup", "removed")}))

    opts = Keyword.put(opts, :session, fn _, _, _, _ -> {:error, :response_lost_after_submission} end)
    assert {:error, :response_lost_after_submission} = run_group("incoming", issues, issues, opts)
    assert {:ok, record} = Store.read("incoming")
    assert map_size(record["deliveries"]) == length(issues)
    assert {:error, :yolo_group_changed} = run_group("incoming", issues, issues, opts)
  end

  test "dispatch receipts survive member changes, no-op exits, status roundtrips and restart", %{issues: [first, second | _]} do
    alias SymphonyElixir.Yolo.Delivery
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}

    start = fn group, _ ->
      {:ok, record} = Store.read(group)
      :ok = Delivery.reserve(group, "started", record["observations"])
      :ok = fixture_delivery_end(group, "started")
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

  test "technically ended delivery resumes only for a new impulse; uncertain delivery stays reserved", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, observations, _} = Observation.capture([issue], %{}, scan: &scan/1)
    receipt = %{"semantic" => observations[issue.id]["semantic"], "run_id" => "run"}

    record = %{
      "deliveries" => %{issue.id => receipt},
      "attempt" => %{"id" => "run", "session_end" => true, "members" => [issue.id]},
      "decisions" => %{}
    }

    assert Delivery.pending([issue], observations, record) == []
    {:ok, resumed, _} = Observation.capture([issue], %{}, scan: &scan/1, impulse_generations: %{issue.id => 1})
    assert Delivery.pending([issue], resumed, record) == [issue]
    assert Delivery.pending([issue], resumed, put_in(record, ["attempt", "session_end"], false)) == []
  end

  test "a confirmed wait does not suppress a new impulse for the same source", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, original, _} = Observation.capture([issue], %{}, scan: &scan/1)
    {:ok, raised, _} = Observation.capture([issue], %{}, scan: &scan/1, impulse_generations: %{issue.id => 1})

    record = %{
      "observations" => original,
      "deliveries" => %{issue.id => %{"semantic" => original[issue.id]["semantic"], "run_id" => "run"}},
      "delivery_ends" => %{"run" => true},
      "completed_sources" => %{issue.id => original[issue.id]["source"]}
    }

    assert Delivery.pending([issue], original, record) == []
    assert Delivery.pending([issue], raised, record) == [issue]
    preserved = Delivery.migrate(record, raised)
    assert get_in(preserved, ["completed_versions", issue.id]) == original[issue.id]["member_semantic"]
    assert Delivery.pending([issue], raised, Map.put(preserved, "observations", raised)) == [issue]
  end

  test "a confirmed member is reused when a partly completed delivery resumes", %{issues: [first, second | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, original, _} = Observation.capture([first, second], %{}, scan: &scan/1)
    generations = %{second.id => 1}
    {:ok, resumed, _} = Observation.capture([first, second], %{}, scan: &scan/1, impulse_generations: generations)

    receipts =
      Map.new([first, second], fn issue ->
        {issue.id, %{"semantic" => original[issue.id]["semantic"], "run_id" => "run"}}
      end)

    record = %{"observations" => original, "deliveries" => receipts, "delivery_ends" => %{"run" => true}, "completed_sources" => %{first.id => original[first.id]["source"]}}

    assert Delivery.pending([first, second], resumed, record) == [second]
  end

  test "confirmed source decision survives a changed review chain fingerprint", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    previous = %{"source" => "same-source", "member_semantic" => "same-member", "semantic" => "old-chain"}
    current = %{previous | "semantic" => "new-chain"}

    record = %{
      "observations" => %{issue.id => previous},
      "completed_sources" => %{issue.id => "same-source"},
      "completed_versions" => %{issue.id => "same-member"}
    }

    assert Delivery.pending([issue], %{issue.id => current}, record) == []

    decided = record |> Map.put("decision_sources", %{issue.id => "same-source"}) |> Map.put("decision_versions", %{issue.id => "same-member"})
    assert Delivery.pending([issue], %{issue.id => current}, decided) == []
  end

  test "a late terminal journal cannot end a newer delivery attempt" do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, record} = Store.read("incoming")
    record = Map.put(record, "attempt", %{"id" => "new", "session_end" => false})
    :ok = Store.write("incoming", record)
    :ok = Journal.write(%{"group" => "incoming", "id" => "old", "members" => [], "state" => "completed"})

    assert :ok = Delivery.reconcile("incoming")
    assert {:ok, ^record} = Store.read("incoming")
  end

  test "an unresolved delivery reserves its whole group while another member changes", %{issues: [first, second | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, observations, _} = Observation.capture([first, second], %{}, scan: &scan/1)
    receipt = %{"semantic" => observations[first.id]["semantic"], "run_id" => "uncertain"}
    record = %{"deliveries" => %{first.id => receipt}}

    assert Delivery.pending([first, second], observations, record) == []
    assert Delivery.waiting_reason([first, second], observations, record) == "delivery_end_unconfirmed"
  end

  for state <- ~w(completed failed cancelled retired) do
    test "archived #{state} order ends an old delivery and restores normal member selection", %{issues: [first, second | _]} do
      alias SymphonyElixir.Yolo.Delivery
      first = %{first | state: "Yolo Review"}
      second = %{second | state: "Yolo Review"}
      old = %{first.id => %{"semantic" => "old"}, second.id => %{"semantic" => "old"}}
      changed = %{first.id => %{"semantic" => "old"}, second.id => %{"semantic" => "new"}}
      {:ok, base} = Store.read("review")

      record =
        Map.merge(base, %{
          "attempt" => %{"id" => "new-run", "session_end" => true},
          "deliveries" => %{
            first.id => %{"run_id" => "old-run", "semantic" => "old"},
            second.id => %{"run_id" => "old-run", "semantic" => "old"}
          }
        })

      assert :ok = Store.write("review", record)
      assert :ok = Journal.write(%{"id" => "old-run", "group" => "review", "members" => Enum.map([first, second], &%{"id" => &1.id, "identifier" => &1.identifier}), "state" => unquote(state)})
      assert :ok = Journal.write(%{"id" => "new-run", "group" => "review", "members" => [], "state" => "completed"})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok = Delivery.reconcile("review")
          assert :ok = Delivery.reconcile("review")
        end)

      assert {:ok, healed} = Store.read("review")
      assert get_in(healed, ["delivery_ends", "old-run"]) == true
      refute Delivery.waiting_reason([first, second], changed, healed) == "delivery_end_unconfirmed"
      assert Delivery.pending([first, second], changed, healed) == [second]
      assert length(Regex.scan(~r/YOLO delivery end derived group=review .*run_id=old-run/, log)) == 2
      assert log =~ "order_state=#{unquote(state)}"
      assert Delivery.pending([first, second], old, healed) == []
    end
  end

  test "terminal current order ends a delivery from an earlier attempt", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, record} = Store.read("incoming")
    record = Map.merge(record, %{"attempt" => %{"id" => "other-run", "session_end" => true}, "deliveries" => %{issue.id => %{"run_id" => "old-run", "semantic" => "old"}}})
    assert :ok = Store.write("incoming", record)
    assert :ok = Journal.write(%{"id" => "old-run", "group" => "incoming", "members" => [%{"id" => issue.id, "identifier" => issue.identifier}], "state" => "failed"})

    assert :ok = Delivery.reconcile("incoming")
    assert {:ok, healed} = Store.read("incoming")
    assert get_in(healed, ["delivery_ends", "old-run"]) == true
  end

  test "missing old order keeps the group waiting and warns once per run", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, record} = Store.read("review")
    record = Map.merge(record, %{"attempt" => %{"id" => "other-run", "session_end" => true}, "deliveries" => %{issue.id => %{"run_id" => "missing-run", "semantic" => "old"}}})
    assert :ok = Store.write("review", record)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Delivery.reconcile("review")
        assert :ok = Delivery.reconcile("review")
      end)

    assert {:ok, waiting} = Store.read("review")
    assert get_in(waiting, ["delivery_ends", "missing-run"]) == nil
    assert get_in(waiting, ["delivery_end_warnings", "missing-run"]) == true
    assert Delivery.waiting_reason([issue], %{issue.id => %{"semantic" => "new"}}, waiting) == "delivery_end_unconfirmed"
    assert length(Regex.scan(~r/YOLO delivery end unconfirmed group=review .*run_id=missing-run/, log)) == 1
    assert log =~ "issue_id=#{issue.id} issue_identifier=unknown"
  end

  test "unreadable archive and mismatched member never supply an end mark", %{issues: [issue | _]} do
    alias SymphonyElixir.Relay.Store, as: Digest
    alias SymphonyElixir.Yolo.Delivery
    {:ok, record} = Store.read("review")
    record = Map.put(record, "deliveries", %{issue.id => %{"run_id" => "old-run", "semantic" => "old"}})
    assert :ok = Store.write("review", record)

    archive = Path.join(Journal.path("review") <> ".history", Digest.digest("old-run") <> ".json")
    File.mkdir_p!(Path.dirname(archive))
    File.write!(archive, "not JSON")
    assert :ok = Delivery.reconcile("review")
    assert {:ok, unreadable} = Store.read("review")
    assert get_in(unreadable, ["delivery_ends", "old-run"]) == nil

    assert :ok = DurableState.write(archive, %{"id" => "old-run", "group" => "review", "members" => [%{"id" => "other"}], "state" => "completed"})
    assert :ok = Delivery.reconcile("review")
    assert {:ok, mismatched} = Store.read("review")
    assert get_in(mismatched, ["delivery_ends", "old-run"]) == nil
    assert Delivery.waiting_reason([issue], %{issue.id => %{"semantic" => "new"}}, mismatched) == "delivery_end_unconfirmed"
  end

  test "archived order without a valid state keeps its delivery unresolved", %{issues: [issue | _]} do
    alias SymphonyElixir.Relay.Store, as: Digest
    alias SymphonyElixir.Yolo.Delivery
    {:ok, record} = Store.read("review")
    record = Map.put(record, "deliveries", %{issue.id => %{"run_id" => "old-run", "semantic" => "old"}})
    assert :ok = Store.write("review", record)

    archive = Path.join(Journal.path("review") <> ".history", Digest.digest("old-run") <> ".json")
    File.mkdir_p!(Path.dirname(archive))
    assert :ok = DurableState.write(archive, %{"id" => "old-run", "group" => "review", "members" => [%{"id" => issue.id}]})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Delivery.reconcile("review")
        assert :ok = Delivery.reconcile("review")
      end)

    assert {:ok, waiting} = Store.read("review")
    assert get_in(waiting, ["delivery_ends", "old-run"]) == nil
    assert Delivery.waiting_reason([issue], %{issue.id => %{"semantic" => "new"}}, waiting) == "delivery_end_unconfirmed"
    assert length(Regex.scan(~r/YOLO delivery end unconfirmed group=review .*run_id=old-run reason=:order_invalid/, log)) == 1
  end

  test "current nonterminal order keeps its delivery unresolved", %{issues: [issue | _]} do
    alias SymphonyElixir.Yolo.Delivery
    {:ok, record} = Store.read("review")
    record = Map.merge(record, %{"attempt" => %{"id" => "other-run", "session_end" => true}, "deliveries" => %{issue.id => %{"run_id" => "active-run", "semantic" => "old"}}})
    assert :ok = Store.write("review", record)
    assert :ok = Journal.write(%{"id" => "active-run", "group" => "review", "members" => [%{"id" => issue.id}], "state" => "running"})

    assert :ok = Delivery.reconcile("review")
    assert {:ok, ^record} = Store.read("review")
    assert Delivery.waiting_reason([issue], %{issue.id => %{"semantic" => "new"}}, record) == "delivery_end_unconfirmed"
  end

  test "review runner resumes only the open member of a ready chain", %{issues: [first, second | _], root: root} do
    first = %{first | state: "Yolo Review"}
    second = %{second | state: "Yolo Review", blocked_by: [%{id: first.id, state: "Yolo Review"}]}
    issues = [first, second]
    {:ok, old, _} = Observation.capture(issues, %{}, scan: &scan/1)
    {:ok, current, _} = Observation.capture(issues, %{}, scan: &scan/1, impulse_generations: %{second.id => 1})
    {:ok, record} = Store.read("review")
    receipts = Map.new(issues, fn issue -> {issue.id, %{"semantic" => old[issue.id]["semantic"], "run_id" => "earlier"}} end)

    record =
      Map.merge(record, %{
        "observations" => current,
        "impulses" => %{second.id => %{"generation" => 1, "reason" => "delegated_again"}},
        "deliveries" => receipts,
        "delivery_ends" => %{"earlier" => true},
        "completed_sources" => %{first.id => old[first.id]["source"]}
      })

    :ok = Store.write("review", record)

    opts = [
      fetch: fn _ -> {:ok, [second]} end,
      lease: fn _, fun -> fun.() end,
      scan: &scan/1,
      project: fn -> {:ok, issues} end,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, lead, _ ->
        assert lead.id == second.id
        send(self(), :open_member_reviewed)
        assert :ok = Completion.invoke(%{"issue_id" => second.id, "result" => "offen geprüft"}, handoff_completed: true, fetch: fn _ -> {:ok, [second]} end, before_action: fn _ -> :ok end)
        {:ok, %{session_id: "resumed"}}
      end
    ]

    assert :ok = run_group("review", [second], issues, opts)
    assert_receive :open_member_reviewed
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
        :ok = fixture_delivery_end(group, "run")
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
          :ok = fixture_delivery_end(group, "run")
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
        :ok = fixture_delivery_end(group, "run")
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

  test "an unchanged review still checks comments and delegated merge requires Yolo Review", %{issues: [issue | _]} do
    mutation = %{"query" => "mutation { issueUpdate(id: \"#{issue.id}\", input: {stateId: \"target\"}) { success } }"}

    query = fn target ->
      fn _, _ ->
        {:ok, %{"data" => %{"issue" => %{"id" => issue.id, "team" => %{"states" => %{"nodes" => [%{"id" => "target", "name" => target}], "pageInfo" => %{"hasNextPage" => false}}}}}}}
      end
    end

    review = %{issue | state: "Yolo Review"}

    Scope.with_scope("review", [review], "run", fn ->
      assert {:error, :new_comment} = CommentActionGuard.check(mutation, query: query.("Yolo Review"), fetch_issue: fn _ -> {:ok, [review]} end, guard: fn _ -> {:error, :new_comment} end)
    end)

    merged = %{issue | state: "Merge (AI)"}
    assert {:error, :delegated_merge_requires_yolo_review} = CommentActionGuard.check(mutation, query: query.("Review"), fetch_issue: fn _ -> {:ok, [merged]} end)
  end

  @tag :review_regression
  test "dirty merge is rejected before entering the monotone acceptance phase", %{issues: [issue | _], root: root, context: context} do
    ProjectContext.bind(put_in(context.settings.workspace.root, Path.join(root, "regular")))
    issue = %{issue | state: "Merge (AI)"}
    {:ok, workspace} = Workspace.create_for_issue(issue)
    System.cmd("git", ["init", "--quiet", workspace])
    File.write!(Path.join(workspace, "dirty.txt"), "changed in merge")
    mutation = %{"query" => "mutation { issueUpdate(id: \"#{issue.id}\", input: {stateId: \"target\"}) { success } }"}

    query = fn _, _ ->
      {:ok, %{"data" => %{"issue" => %{"id" => issue.id, "team" => %{"states" => %{"nodes" => [%{"id" => "target", "name" => "Yolo Review"}], "pageInfo" => %{"hasNextPage" => false}}}}}}}
    end

    options = [query: query, fetch_issue: fn _ -> {:ok, [issue]} end, guard: fn _ -> :ok end]
    assert {:error, :merge_workspace_requires_test} = CommentActionGuard.check(mutation, options)
    File.rm!(Path.join(workspace, "dirty.txt"))
    assert :ok = CommentActionGuard.check(mutation, options)
  end
end
