defmodule SymphonyElixir.YoloRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ProjectContext, WaitMarker, Yolo}

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Linear.CommentActionGuard
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.Yolo.{BlockerBrake, Completion, Coordinator, Group, Observation, Operations, Scope, Store}
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

  defp inbox(versions \\ %{}), do: %{"versions" => versions, "last_successful_scan" => "now", "scan_error" => nil}
  defp scan(_), do: {:ok, inbox()}

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
      assert Store.read("blocker") == {:ok, after_poll}
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
    blocked = Keyword.put(opts, :checkpoint, fn _ -> {:error, :new_input_requires_processing} end)
    assert {:error, :new_input_requires_processing} = run_group("blocker", [issue], [issue], blocked)
    refute_receive :operator_decision
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

    assert {:error, {:wait_marker_unresolved, "PRI-173", :offline}} =
             WaitMarker.targets(waiting, base ++ [query: fn _, _ -> {:error, :offline} end])

    assert {:error, {:wait_marker_unresolved, "PRI-173", :wait_target_lookup_incomplete}} =
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
    assert Group.groups([issue]) == %{"blocker" => [issue]}
    assert SymphonyElixir.TestRun.start_allowed?(issue)
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    assert tick(state, [issue], opts).yolo_runs == %{}
    assert_receive {:brake_note, updated}
    assert updated =~ "PO-Lauf previous"
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
