defmodule SymphonyElixir.OpenClawRuntimeTest do
  use SymphonyElixir.TestSupport
  alias Mix.Tasks.Openclaw.Recover, as: RecoverCommand
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.{Completion, Coordinator, OpenClaw, ReviewContract, Runner, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, Recovery, ToolBridge, Transport}

  defp run_group(group, issues, project, opts), do: Runner.run(group, issues, project, Keyword.put_new(opts, :dependencies, &{:ok, &1}))
  defp tick(state, issues, opts), do: Coordinator.tick(state, issues, Keyword.put_new(opts, :dependencies, &{:ok, &1}))

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\nLINEAR_YOLO_AGENT=Pai\nOPENCLAW_YOLO_AGENT=po\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    context = put_in(context.settings.workspace.root, Path.join(root, "workspaces"))
    ProjectContext.bind(context)

    issues =
      for {state, index} <- Enum.with_index(["Backlog", "Todo", "Definiert"]) do
        Client.relay_issue(%{
          "id" => "member#{index}",
          "identifier" => "PRO-#{index}",
          "title" => "Member #{index}",
          "state" => %{"name" => state},
          "assignee" => %{"id" => "human", "email" => "human@example.com", "app" => false},
          "delegate" => %{"id" => "pai"},
          "project" => %{"id" => "project-id", "slugId" => "project"},
          "team" => %{"id" => "team"},
          "labels" => %{"nodes" => Enum.map([~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")], &%{"name" => &1})}
        })
      end

    checkout = Path.join(root, "proof-checkout")
    File.mkdir_p!(checkout)
    System.cmd("git", ["init", "--quiet", checkout])
    File.write!(Path.join(checkout, "proof.txt"), "fixture")
    System.cmd("git", ["add", "."], cd: checkout)
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "fixture"], cd: checkout)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: checkout)
    workspace = %{path: checkout, sha: String.trim(sha)}

    opts = [
      dependencies: &{:ok, &1},
      fetch: fn ids -> {:ok, Enum.filter(issues, &(&1.id in ids))} end,
      lease: fn _, callback -> callback.() end,
      scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
      workspace: fn _, _ -> {:ok, workspace} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ -> flunk("OpenClaw must not fall back to Codex") end
    ]

    %{root: root, context: context, issues: issues, opts: opts, workspace: workspace}
  end

  defp synthetic_linear(_, _, _), do: {:ok, %{"data" => %{"viewer" => %{"id" => "synthetic"}}}}

  defp rpc(method, params, handler), do: handler.(method, Jason.decode!(params))

  defp transport(handler) do
    fn
      ["--version"] ->
        {:ok, "OpenClaw 2026.9.4\n"}

      ["gateway", "call", "agents.list" | _] ->
        {:ok, Jason.encode!(%{agents: [%{id: "po"}]})}

      ["gateway", "call", method, "--params", params, "--json", "--timeout", "10000", "--port", "18789"] ->
        case rpc(method, params, handler) do
          {:error, _} = error -> error
          response -> {:ok, Jason.encode!(response)}
        end
    end
  end

  defp bridge_call(descriptor, request) do
    binding = descriptor |> File.read!() |> Jason.decode!()
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, binding["port"], [:binary, packet: :line, active: false], 1000)
    proof = Map.merge(binding["checkout"], %{"cwd" => binding["checkout"]["workspace"], "git_root" => binding["checkout"]["workspace"], "clean" => true})
    :ok = :gen_tcp.send(socket, Jason.encode!(%{token: binding["token"], checkout: proof, request: request}) <> "\n")
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)
    Jason.decode!(bytes)
  end

  defp request(method, params \\ %{}), do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  defp descriptor(context, id), do: Path.join([context.settings.workspace.root, "yolo-runs", id, "tools.json"])

  test "activated path uses real MCP dispatch and only completes after member decisions", %{issues: issues, context: context, opts: opts, workspace: workspace} do
    parent = self()
    skill = Path.join(workspace.path, ".codex/skills/sym-yolo-review/SKILL.md")
    File.mkdir_p!(Path.dirname(skill))
    File.write!(skill, "Synthetic project acceptance instructions")
    System.cmd("git", ["add", "."], cd: workspace.path)
    System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "skill"], cd: workspace.path)
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: workspace.path)
    workspace = %{workspace | sha: String.trim(sha)}
    ProjectContext.bind(%{context | root: workspace.path})
    opts = Keyword.put(opts, :workspace, fn _, _ -> {:ok, workspace} end)

    handler = fn
      "agent", params ->
        id = params["idempotencyKey"]
        assert {:ok, order} = Journal.read("incoming")
        assert order["id"] == id
        assert order["state"] == "intent"
        assert order["payload_sha256"] == OpenClaw.digest(params["message"])
        assert params["message"] =~ "Übernimm erforderliche Betreiberprüfungen selbst"
        assert params["message"] =~ "isolierte Testbereitstellung"
        assert params["message"] =~ "Keine Ersatzbindung, keine direkten Linear-Zugänge"
        refute params["message"] =~ "Arbeite ausschließlich im Prüfcheckout"
        assert params["agentId"] == "po"
        assert params["sessionKey"] =~ "agent:po:symphony:"
        assert params["sessionKey"] =~ ":incoming:#{id}"
        assert params["deliver"] == false

        for text <- [
              "workflow_sha256",
              "linear_workspace_id",
              "human_handoff_id",
              "comment_inputs",
              "recorded_operations",
              "member0",
              "member1",
              "member2",
              workspace.sha,
              "WORKFLOW",
              "LinearBridge",
              "Synthetic project acceptance instructions"
            ] do
          assert params["message"] =~ text
        end

        tools = bridge_call(descriptor(context, id), request("tools/list"))["result"]["tools"]
        assert Enum.sort(Enum.map(tools, & &1["name"])) == ~w(linear_graphql symphony_comments symphony_test symphony_yolo_action symphony_yolo_complete)
        response = bridge_call(descriptor(context, id), request("tools/call", %{name: "linear_graphql", arguments: %{query: "query { viewer { id } }"}}))
        refute response["result"]["isError"]

        for issue <- issues do
          result = bridge_call(descriptor(context, id), request("tools/call", %{name: "symphony_yolo_complete", arguments: %{issue_id: issue.id, result: "Entscheidung und Prüfbeleg #{issue.id}"}}))
          refute result["result"]["isError"]
        end

        send(parent, {:submitted, id})
        %{"runId" => id, "status" => "accepted"}

      "agent.wait", %{"runId" => id} ->
        %{"runId" => id, "status" => "ok", "startedAt" => 1, "endedAt" => 2}
    end

    tool_opts = [fetch: opts[:fetch], before_action: opts[:before_action], linear_client: &synthetic_linear/3]

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = run_group("incoming", issues, issues, Keyword.merge(opts, transport: transport(handler), tool_opts: tool_opts))
      end)

    assert_receive {:submitted, id}

    for issue <- issues, event <- ~w(submitted acceptance ended) do
      assert logs =~ "OpenClaw PO event=#{event} project_root=#{context.id} issue_id=#{issue.id} issue_identifier=#{issue.identifier} run_id=#{id} session_id=agent:po:symphony:"
    end

    refute File.exists?(descriptor(context, id))
    assert {:ok, %{"state" => "completed", "writable" => false} = completed} = Journal.read("incoming")
    assert Journal.receipt("incoming", completed["session_id"])["id"] == id
    assert Journal.receipt("incoming", "other-session") == nil
    assert {:ok, record} = Store.read("incoming")
    assert is_binary(record["processed"])
    assert map_size(record["attempt"]["completed"]) == 3
    assert {:error, :yolo_group_changed} = run_group("incoming", issues, issues, opts)
  end

  test "preflight failures retain every member's issue and session context", %{issues: issues, context: context, opts: opts} do
    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :openclaw_binary_missing} =
                 run_group("incoming", issues, issues, Keyword.put(opts, :transport, fn _ -> {:error, :openclaw_binary_missing} end))
      end)

    assert {:ok, nil} = Journal.read("incoming")
    {:ok, record} = Store.read("incoming")
    id = record["attempt"]["id"]

    for issue <- issues do
      assert logs =~ "OpenClaw PO event=failed project_root=#{context.id} issue_id=#{issue.id} issue_identifier=#{issue.identifier} run_id=#{id} session_id=agent:po:symphony:"
    end

    assert logs =~ "state=local_error reason=openclaw_binary_missing"
    assert logs =~ "action=OpenClaw-Aufruf fehlgeschlagen"
  end

  test "blank selection never calls OpenClaw through start, poll, replay or lease checks", %{context: context, issues: issues, opts: opts} do
    denied = fn _ -> flunk("unexpected OpenClaw process boundary") end

    for value <- [nil, "", "   "] do
      # Load a fresh bound context for each optional value, independent of host env.
      File.write!(Path.join(context.root, ".symphony/.env.local"), "OPENCLAW_YOLO_AGENT=#{value}\n")
      {:ok, loaded} = ProjectContext.load(context.root, context.workflow_path, %{})
      tracker = %{context.settings.tracker | openclaw_yolo_agent: loaded.settings.tracker.openclaw_yolo_agent}
      settings = %{context.settings | tracker: tracker}
      loaded = %{loaded | settings: settings}
      loaded = %{loaded | yolo_agent_id: "pai", assignee_ids: ["human"], human_handoff_id: "human"}

      ProjectContext.with_context(loaded, fn ->
        {:ok, record} = Store.read("incoming")
        Store.write("incoming", record |> Map.put("processed", nil) |> Map.drop(~w(deliveries decisions)))

        session = fn _, _, _, _ ->
          Enum.each(issues, fn issue -> assert :ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "internal"}, opts) end)
          {:ok, %{session_id: "codex"}}
        end

        assert :ok = run_group("incoming", issues, issues, Keyword.merge(opts, session: session, transport: denied))
        state = %Orchestrator.State{max_concurrent_agents: 1}
        assert tick(state, issues, Keyword.put(opts, :transport, denied)).yolo_runs == %{}
        assert :ok = Journal.member_available(hd(issues).id)
        assert :ok = Coordinator.stop(%{})
      end)
    end
  end

  test "lost acceptance, restart and disabled config keep one durable reservation", %{issues: issues, context: context, opts: opts} do
    parent = self()

    handler = fn
      "agent", params ->
        send(parent, {:submitted, params["idempotencyKey"]})
        {:error, :connection_lost}

      "agent.wait", _ ->
        %{"status" => "timeout"}
    end

    interrupted = Keyword.merge(opts, transport: transport(handler), openclaw_wait: fn _ -> throw(:simulated_crash) end)
    assert catch_throw(run_group("incoming", issues, issues, interrupted)) == :simulated_crash
    assert_receive {:submitted, id}
    assert {:ok, order} = Journal.read("incoming")
    assert order["id"] == id
    assert order["state"] == "unknown"
    refute order["writable"]

    for _ <- 1..3 do
      assert {:error, :openclaw_unresolved_order} = run_group("incoming", issues, issues, interrupted)
    end

    refute_receive {:submitted, _}
    assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    disabled = put_in(context.settings.tracker.openclaw_yolo_agent, nil)

    ProjectContext.with_context(disabled, fn ->
      recovery_opts = [
        transport: fn _ -> flunk("disabled recovery must not access OpenClaw") end,
        recovery_lock: fn _, _, fun -> fun.() end,
        openclaw_wait: fn _ -> throw(:still_reserved) end
      ]

      assert catch_throw(OpenClaw.recover(order, recovery_opts)) == :still_reserved
      assert {:error, :openclaw_unresolved_order} = Journal.available("incoming")
      state = %Orchestrator.State{max_concurrent_agents: 1}
      sleeper = spawn(fn -> receive do: (:finish -> :ok) end)
      on_exit(fn -> Process.exit(sleeper, :kill) end)
      restored = tick(state, issues, start: fn "incoming", _ -> {:ok, sleeper} end)
      assert restored.claimed == MapSet.new(issues, & &1.id)
      assert map_size(restored.yolo_runs) == 1
    end)

    recovery = fn
      "sessions.abort", params ->
        assert params["runId"] == id
        %{"ok" => true}

      "agent.wait", %{"runId" => ^id} ->
        %{"runId" => id, "status" => "error", "endedAt" => 3}
    end

    recovery_opts = [transport: transport(recovery), recovery_lock: fn _, _, fun -> fun.() end]
    assert {:error, :openclaw_run_failed_or_cancelled} = OpenClaw.recover(order, recovery_opts)
    assert :ok = Journal.available("incoming")
    assert {:ok, record} = Store.read("incoming")
    assert record["processed"] == nil
  end

  test "timeout and abort acknowledgement do not prove external termination", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params -> %{"runId" => params["idempotencyKey"], "status" => "accepted"}
      "sessions.abort", _ -> %{"ok" => true}
      "agent.wait", %{"runId" => id} -> %{"runId" => id, "status" => "timeout"}
    end

    opts = Keyword.merge(opts, transport: transport(handler), openclaw_timeout_seconds: 0, openclaw_wait: fn _ -> throw(:pending) end)
    assert catch_throw(run_group("incoming", issues, issues, opts)) == :pending
    assert {:ok, %{"state" => "cancel_pending", "writable" => false, "abort_acknowledged" => true}} = Journal.read("incoming")
    assert {:error, :openclaw_unresolved_order} = Journal.available("incoming")
  end

  test "accepted but partial work is never processed", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params -> %{"runId" => params["idempotencyKey"], "status" => "accepted"}
      "agent.wait", %{"runId" => id} -> %{"runId" => id, "status" => "ok", "endedAt" => 2}
    end

    assert {:error, :yolo_group_incomplete_or_workspace_changed} = run_group("incoming", issues, issues, Keyword.put(opts, :transport, transport(handler)))
    assert {:ok, %{"processed" => nil}} = Store.read("incoming")
  end

  for {scenario, state, writable} <- [{:accepted, "accepted", true}, {:lost, "unknown", false}, {:cancelled, "cancel_pending", false}] do
    @tag scenario: scenario, expected_state: state, expected_writable: writable
    test "pending execution evidence preserves #{scenario} authority", %{issues: issues, opts: opts, context: context} = test do
      handler = fn
        "agent", params ->
          if test.scenario == :lost, do: {:error, :connection_lost}, else: %{"runId" => params["idempotencyKey"], "status" => "accepted"}

        "sessions.abort", _ ->
          %{"ok" => true}

        "agent.wait", %{"runId" => id} ->
          %{"runId" => id, "status" => "ok", "startedAt" => 1, "endedAt" => 2, "yielded" => true}
      end

      wait = fn _ ->
        assert {:ok, order} = Journal.read("incoming")
        assert order["acceptance_observed"] == true
        assert order["writable"] == test.expected_writable
        assert order["state"] == test.expected_state
        assert {:error, :openclaw_unresolved_order} = Journal.available("incoming")
        response = bridge_call(descriptor(context, order["id"]), request("tools/list"))
        assert is_map(response["result"]) == test.expected_writable
        throw(:observed)
      end

      opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: wait, openclaw_timeout_seconds: if(test.scenario == :cancelled, do: 0, else: 3600))
      assert catch_throw(run_group("incoming", issues, issues, opts)) == :observed
    end
  end

  test "stale completion cannot complete a newer attempt", %{issues: [issue | _] = issues, opts: opts} do
    {:ok, record} = Store.read("incoming")
    :ok = Store.write("incoming", Map.put(record, "attempt", %{"id" => "new", "members" => [issue.id]}))

    Scope.with_scope("incoming", issues, "old", fn ->
      assert {:error, :yolo_attempt_unavailable} = Completion.invoke(%{"issue_id" => issue.id, "result" => "stale"}, opts)
    end)
  end

  test "terminal parsing rejects mismatched, yielded, pending and missing evidence" do
    order = %{"id" => "run"}

    for reply <- [
          %{"runId" => "other", "status" => "ok", "endedAt" => 1},
          %{"runId" => "run", "status" => "ok"},
          %{"runId" => "run", "status" => "ok", "endedAt" => 1, "yielded" => true},
          %{"runId" => "run", "status" => "error", "endedAt" => 1, "pendingError" => true}
        ] do
      assert :pending = OpenClaw.terminal({:ok, reply}, order)
    end
  end

  test "gateway errors are explicit, synthetic and cannot fall back" do
    assert_raise RuntimeError, ~r/forbidden in standard tests/, fn -> Transport.command(["--version"]) end
    missing = fn _ -> {:error, :openclaw_binary_missing} end
    assert {:error, :openclaw_binary_missing} = Gateway.preflight("po", transport: missing)
    assert {:error, :openclaw_version_unsupported} = Gateway.preflight("po", transport: fn _ -> {:ok, "2026.1.1"} end)

    cases = [
      {"broken", :openclaw_invalid_response},
      {"{\"agents\":[]}", :openclaw_agent_not_found},
      {"{}", :openclaw_protocol_mismatch}
    ]

    for {response, error} <- cases do
      assert {:error, ^error} =
               Gateway.preflight("po",
                 transport: fn
                   ["--version"] -> {:ok, "2026.9.4"}
                   _ -> {:ok, response}
                 end
               )
    end

    assert {:error, :openclaw_abort_unconfirmed} = Gateway.cancel(%{}, transport: fn _ -> {:ok, "{}"} end)
    assert {:error, :connection_lost} = Gateway.cancel(%{}, transport: fn _ -> {:error, :connection_lost} end)

    assert {:error, :openclaw_gateway_unavailable} =
             Gateway.preflight("po",
               transport: fn
                 ["--version"] -> {:ok, "2026.9.4"}
                 _ -> {:error, :openclaw_gateway_unavailable}
               end
             )
  end

  test "tool bridge rejects revoked members, changed comments, foreign tools and expired authority", %{issues: [issue | _] = issues, root: root, opts: opts, context: context, workspace: workspace} do
    id = Ecto.UUID.generate()

    order = %{
      "id" => id,
      "group" => "incoming",
      "members" => [],
      "state" => "accepted",
      "writable" => true,
      "workspace" => workspace.path,
      "sha" => workspace.sha,
      "project_id" => context.id,
      "session_id" => "session"
    }

    assert :ok = Journal.write(order)
    {:ok, record} = Store.read("incoming")
    Store.write("incoming", Map.put(record, "attempt", %{"id" => id, "members" => [issue.id]}))
    {:ok, source} = Agent.start_link(fn -> {issue, :ok} end)
    tool_opts = [fetch: fn _ -> {:ok, [elem(Agent.get(source, & &1), 0)]} end, before_action: fn _ -> elem(Agent.get(source, & &1), 1) end]

    Scope.with_scope("incoming", issues, id, fn ->
      {:ok, bridge} = ToolBridge.start(order, Path.join(root, "bridge-test"), tool_opts)

      try do
        foreign = bridge_call(bridge.descriptor, request("tools/call", %{name: "symphony_merge", arguments: %{}}))
        assert foreign["error"]
        complete = request("tools/call", %{name: "symphony_yolo_complete", arguments: %{issue_id: issue.id, result: "checked"}})

        for changed <- [
              {%{issue | delegate_id: nil}, :ok},
              {%{issue | assigned_to_worker: false}, :ok},
              {issue, {:error, :new_comment}},
              {issue, {:error, :edited_comment}},
              {issue, {:error, :deleted_comment}}
            ] do
          Agent.update(source, fn _ -> changed end)
          assert bridge_call(bridge.descriptor, complete)["result"]["isError"]
        end

        Agent.update(source, fn _ -> {issue, :ok} end)
        refute bridge_call(bridge.descriptor, complete)["result"]["isError"]
        {:ok, _} = Journal.update(order, %{"writable" => false})
        assert bridge_call(bridge.descriptor, request("tools/list"))["error"]
        assert bridge_call(bridge.descriptor, complete)["error"]
      after
        ToolBridge.stop(bridge)
        Agent.stop(source)
      end
    end)

    assert Completion.ready?("incoming", [issue])
    refute Keyword.has_key?(opts, :transport)
  end

  test "withdrawal requests external cancellation while retaining leases and capacity", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params -> %{"runId" => params["idempotencyKey"], "status" => "accepted"}
      "agent.wait", _ -> %{"status" => "timeout"}
    end

    opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: fn _ -> throw(:suspended) end)
    assert catch_throw(run_group("incoming", issues, issues, opts)) == :suspended
    parent = self()

    watcher =
      spawn(fn ->
        receive do: (:openclaw_cancel -> send(parent, :cancel_requested))
        receive do: (:finish -> :ok)
      end)

    on_exit(fn -> Process.exit(watcher, :kill) end)
    run = %{pid: watcher, ids: Enum.map(issues, & &1.id), issues: issues}
    state = %Orchestrator.State{max_concurrent_agents: 1, yolo_runs: %{"incoming" => run}}
    withdrawn = Enum.map(issues, &%{&1 | delegate_id: nil})
    result = tick(state, withdrawn, start: fn _, _ -> flunk("replacement start") end)
    assert_receive :cancel_requested
    assert result.yolo_runs["incoming"].pid == watcher
    assert result.claimed == MapSet.new(issues, & &1.id)
    assert Process.alive?(watcher)
  end

  test "transport loss revokes tool authority without releasing the accepted run", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params -> %{"runId" => params["idempotencyKey"], "status" => "accepted"}
      "agent.wait", _ -> {:error, :connection_lost}
    end

    opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: fn _ -> throw(:lost) end)
    assert catch_throw(run_group("incoming", issues, issues, opts)) == :lost
    assert {:ok, %{"state" => "unknown", "writable" => false, "error" => "connection_lost"}} = Journal.read("incoming")
  end

  test "an orphaned external reservation blocks global capacity before any recovery poll", %{context: context} do
    context = put_in(context.settings.agent.max_concurrent_agents, 1)
    start_supervised!({SymphonyElixir.WorkerCapacity, contexts: [context]})
    order = %{"id" => "orphan", "group" => "incoming", "members" => [], "state" => "unknown"}
    assert :ok = Journal.write(order)
    assert {:error, :worker_capacity} = SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn -> flunk("slot freed") end)
    assert {:ok, _} = Journal.update(order, %{"state" => "failed"})
    assert {:ok, _} = SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn -> :ok end)
  end

  test "corrupt reservations fail closed across scheduling, reconciliation and shared capacity", %{issues: issues, context: context} do
    order = %{"id" => "orphan", "group" => "incoming", "members" => [], "state" => "unknown"}
    assert :ok = Journal.write(order)
    File.write!(Journal.path("incoming"), "broken")
    assert {:error, :openclaw_journal_corrupt} = Journal.read("incoming")
    assert {:error, :openclaw_journal_corrupt} = Journal.update(order, %{"writable" => false})
    assert {:error, :openclaw_journal_corrupt} = Journal.pending()
    sleeper = spawn(fn -> receive do: (:finish -> :ok) end)
    on_exit(fn -> Process.exit(sleeper, :kill) end)
    run = %{pid: sleeper, ids: Enum.map(issues, & &1.id), issues: issues}
    state = %Orchestrator.State{max_concurrent_agents: 1, yolo_runs: %{"incoming" => run}}
    result = tick(state, issues, start: fn _, _ -> flunk("unsafe replacement") end)
    assert result.max_concurrent_agents == 0
    assert result.yolo_runs["incoming"].pid == sleeper
    start_supervised!({SymphonyElixir.WorkerCapacity, contexts: [context]})
    assert {:error, :worker_capacity} = SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn -> flunk("unsafe worker") end)
  end

  test "failed recovery starts retain members and shutdown revokes the durable binding", %{issues: issues} do
    members = Enum.map(issues, &%{"id" => &1.id, "identifier" => &1.identifier, "state" => &1.state})
    order = %{"id" => "orphan", "group" => "incoming", "members" => members, "state" => "accepted", "writable" => true}
    assert :ok = Journal.write(order)
    state = %Orchestrator.State{max_concurrent_agents: 1}
    result = tick(state, issues, start: fn _, _ -> {:error, :max_children} end)
    assert result.max_concurrent_agents == 0
    assert result.claimed == MapSet.new(issues, & &1.id)
    sleeper = spawn(fn -> receive do: (:finish -> :ok) end)
    ref = Process.monitor(sleeper)
    assert :ok = Coordinator.stop(%{"incoming" => %{pid: sleeper}})
    assert_receive {:DOWN, ^ref, :process, ^sleeper, :shutdown}
    assert {:ok, %{"writable" => false, "cancel_requested" => true}} = Journal.read("incoming")
  end

  test "stale recovery cannot change another generation" do
    old = %{"id" => "old", "group" => "incoming", "members" => [], "state" => "accepted"}
    assert :ok = Journal.write(%{old | "id" => "new"})
    assert {:error, :openclaw_generation_changed} = Journal.update(old, %{"state" => "completed"})
    assert {:error, :openclaw_generation_changed} = OpenClaw.recover(old)
    assert {:ok, %{"id" => "new", "state" => "accepted"}} = Journal.read("incoming")
  end

  test "missing ownership prevents submission and unreadable skill never supplies acceptance evidence", %{issues: issues, context: context, workspace: workspace} do
    ProjectContext.with_context(%{context | yolo_agent_id: nil}, fn ->
      Scope.with_scope("incoming", issues, "unverified", fn ->
        assert {:error, :openclaw_requires_verified_linear_yolo_agent} =
                 OpenClaw.run(%{path: context.root, sha: "sha"}, "prompt", issues, "unverified", transport: fn _ -> flunk("unverified agent") end)
      end)
    end)

    skill = Path.join(workspace.path, ".codex/skills/sym-yolo-review/SKILL.md")
    File.mkdir_p!(skill)
    assert %{"error" => "yolo_review_skill_unavailable_or_unbound"} = ReviewContract.load(workspace, "run")
  end

  test "repeated transport failures keep the same order until terminal proof and publish lifecycle events", %{issues: issues, context: context} do
    handler = fn
      "agent", params ->
        %{"runId" => params["idempotencyKey"], "status" => "accepted"}

      "agent.wait", %{"runId" => id} ->
        count = Process.get(:status_count, 0)
        Process.put(:status_count, count + 1)
        if count < 2, do: {:error, :connection_lost}, else: %{"runId" => id, "status" => "ok", "endedAt" => 3}
    end

    id = Ecto.UUID.generate()

    Scope.with_scope("incoming", issues, id, fn ->
      assert {:ok, %{session_id: session}} =
               OpenClaw.run(%{path: context.root, sha: "sha"}, "prompt", issues, id, transport: transport(handler), openclaw_wait: fn _ -> :ok end, recipient: self())

      for event <- [:submitted, :acceptance, :uncertain, :ended] do
        assert_receive {:yolo_event, "incoming", %{event: ^event, session_id: ^session}}
      end

      refute_receive {:yolo_event, "incoming", %{event: :uncertain}}
    end)

    assert Process.get(:status_count) == 3
  end

  test "cancellation messages target the accepted run and require terminal proof", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params ->
        send(self(), :openclaw_cancel)
        %{"runId" => params["idempotencyKey"], "status" => "accepted"}

      "sessions.abort", params ->
        send(self(), {:aborted, params["runId"]})
        %{"ok" => true}

      "agent.wait", %{"runId" => id} ->
        %{"runId" => id, "status" => "error", "endedAt" => 3}
    end

    assert {:error, :openclaw_run_failed_or_cancelled} = run_group("incoming", issues, issues, Keyword.put(opts, :transport, transport(handler)))
    assert {:ok, %{"id" => id, "state" => "failed", "writable" => false, "abort_acknowledged" => true}} = Journal.read("incoming")
    assert_receive {:aborted, ^id}
  end

  for trigger <- [:message, :deadline] do
    @tag cancel_trigger: trigger
    test "#{trigger} cancellation publishes a reservation despite repeated wait timeouts", %{issues: issues, opts: opts, cancel_trigger: trigger} do
      handler = fn
        "agent", params ->
          if trigger == :message, do: send(self(), :openclaw_cancel)
          %{"runId" => params["idempotencyKey"], "status" => "accepted"}

        "sessions.abort", _ ->
          %{"ok" => true}

        "agent.wait", _ ->
          %{"status" => "timeout"}
      end

      wait = fn _ ->
        count = Process.get(:reservation_polls, 0)
        Process.put(:reservation_polls, count + 1)
        if count == 2, do: throw(:still_reserved)
      end

      opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: wait, recipient: self(), openclaw_timeout_seconds: if(trigger == :deadline, do: -1, else: 3600))
      assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :still_reserved
      assert {:ok, %{"state" => "cancel_pending", "writable" => false} = order} = Journal.read("incoming")
      assert_receive {:yolo_event, "incoming", %{external: %{reserved: true, execution_state: "cancel_pending"}} = message}
      assert message.external == OpenClaw.observation(order)
      assert message.external.missing_evidence == "terminal_original_required"
      refute_receive {:yolo_event, "incoming", %{external: %{reserved: true}}}

      run = %{pid: self(), ids: Enum.map(issues, & &1.id), issues: issues, started_at: DateTime.utc_now(), event: %{}}
      entries = %{"incoming" => run} |> Coordinator.event("incoming", message) |> Coordinator.entries()
      assert Enum.all?(entries, &(&1.external.reserved and &1.turn_count == 0))
      assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    end
  end

  for status <- ~w(accepted running) do
    test "late #{status} evidence updates the displayed recovery requirement once", %{issues: issues, opts: opts} do
      status = unquote(status)

      handler = fn
        "agent", _ -> {:error, :connection_lost}
        "agent.wait", %{"runId" => id} -> %{"runId" => id, "status" => status}
      end

      wait = fn _ ->
        count = Process.get(:evidence_polls, 0)
        Process.put(:evidence_polls, count + 1)
        if count == 2, do: throw(:still_reserved)
      end

      opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: wait, recipient: self())
      assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :still_reserved
      assert_receive {:yolo_event, "incoming", %{external: %{missing_evidence: "terminal_or_pre_acceptance_original_required"}}}
      assert_receive {:yolo_event, "incoming", %{external: %{reserved: true, missing_evidence: "terminal_original_required"}} = message}
      assert {:ok, order} = Journal.read("incoming")
      assert message.external == OpenClaw.observation(order)
      refute_receive {:yolo_event, "incoming", %{external: %{missing_evidence: "terminal_original_required"}}}
    end
  end

  test "journal replacement during observation cannot overwrite the new order even on cancellation", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params ->
        %{"runId" => params["idempotencyKey"], "status" => "accepted"}

      "agent.wait", _ ->
        {:ok, current} = Journal.read("incoming")
        :ok = DurableState.write(Journal.path("incoming"), Map.put(current, "id", "new-generation"))
        {:error, :connection_lost}
    end

    wait = fn _ ->
      if Process.get(:waited) do
        throw(:stale_reservation)
      else
        Process.put(:waited, true)
        send(self(), :openclaw_cancel)
      end
    end

    opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: wait)
    assert {:error, :openclaw_generation_changed} = run_group("incoming", issues, issues, opts)
    assert {:ok, %{"id" => "new-generation", "state" => "accepted"}} = Journal.read("incoming")
  end

  test "tool bridge keeps idle bindings and supports the MCP handshake", %{root: root, workspace: workspace, context: context} do
    order = %{
      "id" => "handshake",
      "group" => "incoming",
      "members" => [],
      "state" => "accepted",
      "writable" => true,
      "workspace" => workspace.path,
      "sha" => workspace.sha,
      "project_id" => context.id,
      "session_id" => "session"
    }

    :ok = Journal.write(order)
    {:ok, bridge} = ToolBridge.start(order, Path.join(root, "handshake"))

    try do
      Process.sleep(550)
      assert bridge_call(bridge.descriptor, request("ping"))["result"] == %{}
      assert bridge_call(bridge.descriptor, request("ping", %{padding: String.duplicate("ä", 20_000)}))["result"] == %{}
      response = bridge_call(bridge.descriptor, request("initialize"))
      assert response["result"]["serverInfo"]["name"] == "symphony-linear"
    after
      ToolBridge.stop(bridge)
    end
  end

  test "live knowledge question is confined to the review fixture" do
    alias SymphonyElixir.TestRun.PoHandoff
    plan = %{"scenario" => "po_handoff", "openclaw_knowledge_question" => "Synthetic knowledge question?"}
    review = PoHandoff.fixture(%{"initial_state" => "Yolo Review", "title" => "fixture"}, plan)
    assert review["description"] =~ plan["openclaw_knowledge_question"]
    assert review["description"] =~ "Nenne Antwort und Quelle"
    blocker = PoHandoff.fixture(%{"initial_state" => "BLOCKER", "title" => "fixture"}, plan)
    refute blocker["description"] =~ plan["openclaw_knowledge_question"]
  end

  defp uncertain_order(issues, opts) do
    handler = fn
      "agent", _ -> {:error, :connection_lost}
      "agent.wait", _ -> %{"status" => "timeout"}
    end

    opts = Keyword.merge(opts, transport: transport(handler), openclaw_wait: fn _ -> throw(:reserved) end)
    assert catch_throw(run_group("incoming", issues, issues, opts)) == :reserved
    {:ok, order} = Journal.read("incoming")
    order
  end

  defp rejection_evidence(order) do
    %{
      "version" => 1,
      "binding" => Map.take(order, ~w(id group project_id agent linear_agent_id linear_workspace_id session_id payload_sha256 workspace sha members)),
      "gateway_version" => "2026.9.4",
      "request" => %{
        "request_id" => "2:11111111-2222-4333-8444-555555555555",
        "method" => "agent",
        "run_id" => order["id"],
        "session_id" => order["session_id"],
        "agent" => order["agent"],
        "payload_sha256" => order["payload_sha256"],
        "cwd" => order["workspace"]
      },
      "response" => %{"request_id" => "2:11111111-2222-4333-8444-555555555555", "phase" => "pre_acceptance", "code" => "INVALID_REQUEST", "reason" => "cwd_reserved"},
      "execution_check" => %{
        "run_id" => order["id"],
        "session_id" => order["session_id"],
        "no_active_or_foreign_execution" => true,
        "basis" => "correlated_original_rejection",
        "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      "source_sha256" => String.duplicate("a", 64),
      "execution_source_sha256" => String.duplicate("b", 64),
      "reviewer" => "operator"
    }
  end

  defp terminal_evidence(order) do
    history =
      File.read!(Path.expand("../fixtures/openclaw/terminal-history.json", __DIR__))
      |> String.replace("__SESSION_KEY__", order["session_id"])
      |> String.replace("__RUN_ID__", order["id"])
      |> Jason.decode!()

    bytes = Jason.encode!(history)

    evidence = %{
      "version" => 2,
      "kind" => "terminal_original",
      "gateway_version" => "2026.9.4",
      "binding" => rejection_evidence(order)["binding"],
      "physical_session_id" => history["sessionId"],
      "message_id" => "original-message",
      "source_sha256" => OpenClaw.digest(bytes),
      "execution_source_sha256" => OpenClaw.digest(bytes),
      "reviewer" => "operator",
      "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    opts = [
      sources: %{"source" => bytes, "execution_source" => bytes},
      status: fn _ -> {:ok, %{"status" => "timeout"}} end,
      history: fn _ -> {:ok, history} end
    ]

    {evidence, opts}
  end

  test "accepted executed run survives cache loss and restart until terminal originals release it", %{issues: issues, opts: opts, context: context} do
    handler = fn
      "agent", params ->
        refute bridge_call(descriptor(context, params["idempotencyKey"]), request("tools/list"))["error"]
        %{"runId" => params["idempotencyKey"], "status" => "accepted"}

      "agent.wait", _ ->
        {:error, :openclaw_gateway_unavailable}
    end

    interrupted = Keyword.merge(opts, transport: transport(handler), openclaw_wait: fn _ -> throw(:lost) end)
    assert catch_throw(Runner.run("incoming", issues, issues, interrupted)) == :lost
    {:ok, order} = Journal.read("incoming")
    assert order["execution_observed"] == true
    {:ok, decisions} = Store.read("incoming")
    {evidence, recovery_opts} = terminal_evidence(order)
    assert {:ok, %{"state" => "completed"}} = Recovery.resolve(evidence, false, recovery_opts)
    assert {:ok, ^order} = Journal.read("incoming")
    assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    assert {:ok, finished} = Recovery.resolve(evidence, true, recovery_opts)
    assert finished["terminal"]["endedAt"] == 2000
    assert finished["before_recovery"]["error"] == "openclaw_gateway_unavailable"
    refute finished["writable"]
    assert finished["acceptance_observed"] and finished["execution_observed"]
    assert {:ok, ^finished} = Recovery.resolve(evidence, true, recovery_opts)
    assert {:error, :openclaw_run_failed_or_cancelled} = OpenClaw.recover(order, transport: fn _ -> flunk("no new external work") end)
    assert {:ok, ^decisions} = Store.read("incoming")
    assert {:ok, []} = Journal.pending()
    assert :ok = Journal.member_available(hd(issues).id)
    following = %{order | "id" => Ecto.UUID.generate()}
    assert :ok = Journal.write(following)
    assert {:ok, ^finished} = Recovery.resolve(evidence, true, recovery_opts)
    assert {:ok, ^following} = Journal.read("incoming")
    assert {:ok, ^finished} = Journal.history("incoming", order["id"])
  end

  defp executed_order(issues, opts) do
    order = uncertain_order(issues, opts)
    {:ok, order} = Journal.update(order, %{"acceptance_observed" => true, "execution_observed" => true})
    order
  end

  defp replace_terminal_history({evidence, opts}, history) do
    bytes = Jason.encode!(history)
    evidence = Map.merge(evidence, %{"source_sha256" => OpenClaw.digest(bytes), "execution_source_sha256" => OpenClaw.digest(bytes)})
    {evidence, Keyword.merge(opts, sources: %{"source" => bytes, "execution_source" => bytes}, history: fn _ -> {:ok, history} end)}
  end

  test "conversation history releases only after the correlated terminal record", %{issues: issues, opts: opts} do
    order = executed_order(issues, opts)
    {_, recovery_opts} = package = terminal_evidence(order)
    history = Jason.decode!(recovery_opts[:sources]["source"])
    [terminal] = history["messages"]
    user = %{"role" => "user", "content" => "Process the assigned tickets"}
    progress = terminal |> put_in(["__openclaw", "id"], "progress-message") |> put_in(["__openclaw", "runTerminal"], false)
    pending = Map.merge(history, %{"messages" => [user, progress], "totalMessages" => 2})
    {pending_evidence, pending_opts} = replace_terminal_history(package, pending)

    assert {:error, :openclaw_terminal_record_invalid} = Recovery.resolve(pending_evidence, true, pending_opts)
    assert {:ok, ^order} = Journal.read("incoming")
    assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)

    complete = Map.merge(history, %{"messages" => [user, progress, terminal], "totalMessages" => 3})
    {evidence, recovery_opts} = replace_terminal_history(package, complete)
    assert {:ok, finished} = Recovery.resolve(evidence, true, recovery_opts)
    assert finished["state"] == "completed"
    assert finished["terminal"]["messageId"] == "original-message"
    assert finished["terminal"]["endedAt"] == 2000
    assert :ok = Journal.member_available(hd(issues).id)
  end

  test "unsupported evidence versions keep executed orders reserved without gateway reads", %{issues: issues, opts: opts} do
    order = executed_order(issues, opts)
    {evidence, recovery_opts} = terminal_evidence(order)
    recovery_opts = Keyword.merge(recovery_opts, status: fn _ -> flunk("invalid version must not poll") end, history: fn _ -> flunk("invalid version must not read history") end)

    for changed <- [Map.delete(evidence, "version"), Map.put(evidence, "version", 3), Map.put(evidence, "version", "2")] do
      assert {:error, :openclaw_recovery_evidence_invalid} = Recovery.resolve(changed, true, recovery_opts)
      assert {:ok, ^order} = Journal.read("incoming")
      assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    end
  end

  test "terminal originals reject incomplete, nonterminal, foreign and active history", %{issues: issues, opts: opts} do
    order = executed_order(issues, opts)
    {evidence, recovery_opts} = package = terminal_evidence(order)
    history = Jason.decode!(recovery_opts[:sources]["source"])
    [record] = history["messages"]

    bad = [
      %{},
      Map.delete(history, "sessionInfo"),
      Map.put(history, "messages", []),
      Map.put(history, "hasMore", true),
      Map.delete(history, "hasMore"),
      Map.put(history, "offset", 1),
      Map.put(history, "totalMessages", 2),
      Map.put(history, "sessionKey", "foreign"),
      Map.put(history, "sessionId", "replacement-session"),
      put_in(history, ["sessionInfo", "sessionId"], "replacement-session"),
      put_in(history, ["sessionInfo", "lastRunId"], "new-generation"),
      put_in(history, ["sessionInfo", "key"], "foreign"),
      put_in(history, ["sessionInfo", "status"], "Review"),
      put_in(history, ["sessionInfo", "status"], "running"),
      put_in(history, ["sessionInfo", "endedAt"], nil),
      put_in(history, ["sessionInfo", "endedAt"], 999),
      put_in(history, ["sessionInfo", "hasActiveRun"], true),
      update_in(history, ["sessionInfo"], &Map.delete(&1, "hasActiveRun")),
      put_in(history, ["sessionInfo", "activeRunIds"], [order["id"]]),
      update_in(history, ["sessionInfo"], &Map.delete(&1, "activeRunIds")),
      put_in(history, ["sessionInfo", "hasActiveSubagentRun"], true),
      put_in(history, ["sessionInfo", "subagentRunState"], "interrupted"),
      put_in(history, ["sessionInfo", "abortedLastRun"], true),
      Map.put(history, "inFlightRun", %{"runId" => "foreign"}),
      Map.put(history, "pendingInputs", %{"items" => [], "total" => 1}),
      Map.delete(history, "pendingInputs"),
      Map.put(history, "yielded", true),
      put_in(history, ["sessionInfo", "pendingError"], true),
      Map.put(history, "messages", [Map.delete(record, "__openclaw")]),
      Map.put(history, "messages", [put_in(record, ["__openclaw", "runTerminal"], false)]),
      Map.put(history, "messages", [put_in(record, ["__openclaw", "runId"], "foreign")]),
      Map.put(history, "messages", [put_in(record, ["__openclaw", "mirrorOrigin"], "text")]),
      Map.put(history, "messages", [put_in(record, ["__openclaw", "mirrorIdentity"], nil)]),
      Map.put(history, "messages", [put_in(record, ["__openclaw", "mirrorSourceFingerprint"], nil)]),
      Map.put(history, "messages", [put_in(record, ["__openclaw", "yielded"], true)]),
      Map.merge(history, %{"messages" => [put_in(record, ["__openclaw", "id"], "another-terminal"), record], "totalMessages" => 2})
    ]

    for bad_history <- bad do
      {bad_evidence, bad_opts} = replace_terminal_history(package, bad_history)
      assert {:error, _} = Recovery.resolve(bad_evidence, true, bad_opts)
      assert {:ok, ^order} = Journal.read("incoming")
      assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    end

    for field <- ~w(id group project_id agent linear_agent_id linear_workspace_id session_id payload_sha256 workspace sha members) do
      assert {:error, _} = Recovery.resolve(put_in(evidence, ["binding", field], "foreign"), true, recovery_opts)
      assert {:ok, ^order} = Journal.read("incoming")
    end

    for changed <- [
          Map.delete(evidence, "message_id"),
          Map.put(evidence, "reviewer", ""),
          Map.put(evidence, "gateway_version", "other"),
          Map.put(evidence, "source_sha256", String.duplicate("0", 64)),
          Map.put(evidence, "execution_source_sha256", nil),
          Map.put(evidence, "checked_at", "2020-01-01T00:00:00Z"),
          Map.put(evidence, "physical_session_id", "foreign")
        ] do
      assert {:error, _} = Recovery.resolve(changed, true, recovery_opts)
    end

    assert {:error, _} = Recovery.resolve(evidence, true, Keyword.delete(recovery_opts, :sources))
    assert {:error, _} = Recovery.resolve(evidence, true, Keyword.put(recovery_opts, :sources, %{"source" => String.duplicate("x", 1_048_577)}))
    assert {:ok, ^order} = Journal.read("incoming")
  end

  test "fresh counterproof, authority and observed execution remain mandatory", %{issues: issues, opts: opts} do
    order = uncertain_order(issues, opts)
    {evidence, recovery_opts} = terminal_evidence(order)
    assert {:error, :openclaw_recovery_conflict} = Recovery.resolve(evidence, true, recovery_opts)
    {:ok, _} = Journal.update(order, %{"acceptance_observed" => true})
    assert {:error, :openclaw_recovery_conflict} = Recovery.resolve(evidence, true, recovery_opts)
    {:ok, order} = Journal.update(order, %{"execution_observed" => true, "state" => "running", "writable" => true})
    assert {:error, :openclaw_recovery_conflict} = Recovery.resolve(evidence, true, recovery_opts)
    {:ok, order} = Journal.update(order, %{"state" => "cancel_pending", "writable" => false})

    for reply <- [
          {:error, :openclaw_gateway_unavailable},
          {:ok, %{"status" => "running", "runId" => order["id"]}},
          {:ok, %{"status" => "timeout", "runId" => "foreign"}},
          {:ok, %{"status" => "timeout", "startedAt" => 1}},
          {:ok, %{"status" => "timeout", "yielded" => true}},
          {:ok, %{"status" => "timeout", "pendingError" => true}}
        ] do
      assert {:error, _} = Recovery.resolve(evidence, true, Keyword.put(recovery_opts, :status, fn _ -> reply end))
    end

    history = Jason.decode!(recovery_opts[:sources]["source"])

    for reply <- [
          {:error, :openclaw_gateway_unavailable},
          {:ok, Map.put(history, "sessionId", "replacement")},
          {:ok, put_in(history, ["sessionInfo", "hasActiveRun"], true)},
          {:ok, put_in(history, ["sessionInfo", "endedAt"], 3000)}
        ] do
      assert {:error, _} = Recovery.resolve(evidence, true, Keyword.put(recovery_opts, :history, fn _ -> reply end))
    end

    assert {:ok, ^order} = Journal.read("incoming")
  end

  test "terminal recovery serializes polls and cancellation and does not replay historical decisions", %{issues: issues, opts: opts, context: context} do
    order = executed_order(issues, opts)
    {evidence, recovery_opts} = terminal_evidence(order)
    {:ok, decisions} = Store.read("incoming")
    decisions = put_in(decisions, ["attempt", "completed"], %{hd(issues).id => "historical decision"})
    :ok = Store.write("incoming", decisions)
    parent = self()

    recovery =
      Task.async(fn ->
        ProjectContext.with_context(context, fn ->
          Recovery.resolve(
            evidence,
            true,
            Keyword.put(recovery_opts, :history, fn bound ->
              send(parent, {:confirming, self()})
              receive do: (:continue -> recovery_opts[:history].(bound))
            end)
          )
        end)
      end)

    assert_receive {:confirming, pid}, 2000

    racers =
      for changes <- [%{"state" => "cancel_pending", "cancel_requested" => true}, %{"state" => "failed", "terminal" => %{"endedAt" => 3}}] do
        Task.async(fn -> ProjectContext.with_context(context, fn -> Journal.update(order, changes) end) end)
      end

    send(pid, :continue)
    assert {:ok, finished} = Task.await(recovery)
    for racer <- racers, do: assert(Task.await(racer) == {:ok, finished})
    assert {:ok, ^decisions} = Store.read("incoming")
    assert {:ok, ^finished} = Recovery.resolve(evidence, true, Keyword.put(recovery_opts, :history, fn _ -> flunk("idempotent") end))
    assert {:error, _} = Recovery.resolve(Map.put(evidence, "reviewer", "changed"), true, recovery_opts)
    refute Journal.writable?("incoming", order["id"])
  end

  defp recover_evidence(evidence, apply? \\ false, opts \\ []) do
    opts = Keyword.put_new(opts, :status, fn _ -> {:ok, %{"status" => "timeout"}} end)
    Recovery.resolve(evidence, apply?, opts)
  end

  test "recovered observer releases one shared slot and leases while retaining current Review and later work", %{issues: issues, opts: opts, context: context} do
    context = put_in(context.settings.agent.max_concurrent_agents, 1)
    ProjectContext.bind(context)
    order = executed_order(issues, opts)
    {evidence, recovery_opts} = terminal_evidence(order)
    start_supervised!({SymphonyElixir.WorkerCapacity, contexts: [context]})
    parent = self()
    current = Enum.map(issues, &%{&1 | state: "Review", delegate_id: nil})

    watcher_opts = [
      fetch: fn ids -> {:ok, Enum.filter(current, &(&1.id in ids))} end,
      transport:
        transport(fn
          "sessions.abort", _ -> %{"ok" => true}
          "agent.wait", _ -> %{"status" => "timeout"}
          _, _ -> flunk("recovery must not submit or read history automatically")
        end),
      openclaw_wait: fn _ ->
        send(parent, {:reserved_observer, self()})
        receive do: (:resume -> :ok)
      end
    ]

    state = Coordinator.tick(%Orchestrator.State{max_concurrent_agents: 1, external_poll: true}, [], watcher_opts)
    assert_receive {:reserved_observer, pid}, 2000
    ref = Process.monitor(pid)
    assert SymphonyElixir.WorkerCapacity.count(nil) == 1
    assert {:error, :worker_capacity} = SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn -> flunk("reserved") end)

    for entry <- Coordinator.entries(state.yolo_runs) do
      assert entry.state == "Review"
      assert entry.external.original_group == "incoming"
      assert entry.external.reserved and entry.external.resumed and entry.external.current_state_known
      assert entry.external.missing_evidence == "terminal_original_required"
    end

    stale = %{worker_pid: self(), external: %{reserved: false}}
    assert Coordinator.event(state.yolo_runs, "incoming", stale) == state.yolo_runs
    unknown = Coordinator.tick(state, [], Keyword.put(watcher_opts, :fetch, fn _ -> {:error, :unavailable} end))
    assert Enum.all?(Coordinator.entries(unknown.yolo_runs), &(&1.state == "Unbekannt" and not &1.external.current_state_known))
    assert {:ok, _} = Recovery.resolve(evidence, true, recovery_opts)
    send(pid, :resume)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2000
    # The normal monitor and reconciliation remove the same observer exactly once.
    state = Coordinator.tick(state, [], watcher_opts)
    assert state.yolo_runs == %{} and state.claimed == MapSet.new()
    assert Coordinator.tick(state, [], watcher_opts).yolo_runs == %{}
    assert :ok = Journal.member_available(hd(issues).id)
    assert {:ok, _} = Recovery.resolve(evidence, true, recovery_opts)

    assert {:ok, next} =
             SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn ->
               send(parent, :regular_started)
               receive do: (:finish -> :ok)
             end)

    assert_receive :regular_started
    assert SymphonyElixir.WorkerCapacity.count(nil) == 1
    assert {:error, :worker_capacity} = SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn -> flunk("double release") end)
    send(next, :finish)
    assert Enum.all?(current, &(&1.state == "Review" and is_nil(&1.delegate_id)))
  end

  test "failed and cancelled originals keep their technical result", %{issues: issues, opts: opts} do
    for {status, state} <- [{"failed", "failed"}, {"timeout", "failed"}, {"killed", "cancelled"}] do
      # Each original is distinct work; unchanged deliveries must remain suppressed.
      issues = Enum.map(issues, &%{&1 | title: &1.title <> " " <> status})
      opts = Keyword.put(opts, :fetch, fn ids -> {:ok, Enum.filter(issues, &(&1.id in ids))} end)
      order = executed_order(issues, opts)
      {_, recovery_opts} = package = terminal_evidence(order)
      history = Jason.decode!(recovery_opts[:sources]["source"]) |> put_in(["sessionInfo", "status"], status)
      {evidence, recovery_opts} = replace_terminal_history(package, history)
      assert {:ok, %{"state" => ^state}} = Recovery.resolve(evidence, true, recovery_opts)
      assert {:error, :openclaw_run_failed_or_cancelled} = OpenClaw.recover(order, transport: fn _ -> flunk("terminal") end)
    end
  end

  test "failed terminal persistence keeps the order and other projects or members reserved", %{issues: issues, opts: opts, context: context} do
    order = executed_order(issues, opts)
    {evidence, recovery_opts} = terminal_evidence(order)
    foreign = %{order | "id" => Ecto.UUID.generate(), "group" => "blocker", "members" => [%{"id" => "foreign-member"}]}
    assert :ok = Journal.write(foreign)

    ProjectContext.with_context(%{context | id: "another-project"}, fn ->
      assert {:error, :openclaw_recovery_evidence_invalid} = Recovery.resolve(evidence, true, recovery_opts)
    end)

    path = Journal.path("incoming")
    saved = path <> ".original"

    denied_opts =
      Keyword.put(recovery_opts, :history, fn bound ->
        # Simulate a target filesystem fault after the locked read, before the
        # atomic rename. Preserve the original bytes outside the faulted target.
        File.rename!(path, saved)
        File.mkdir!(path)
        recovery_opts[:history].(bound)
      end)

    try do
      assert {:error, :runtime_state_persist_failed} = Recovery.resolve(evidence, true, denied_opts)
      assert {:ok, ^order} = DurableState.read(saved)
      assert {:error, :openclaw_journal_corrupt} = Journal.member_available(hd(issues).id)
    after
      File.rmdir!(path)
      File.rename!(saved, path)
    end

    assert {:ok, ^order} = Journal.read("incoming")
    assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    assert {:ok, _} = Recovery.resolve(evidence, true, recovery_opts)
    assert {:ok, ^foreign} = Journal.read("blocker")
    assert {:error, :openclaw_member_reserved} = Journal.member_available("foreign-member")
  end

  test "restarted coordinator publishes the unresolved reservation and operator action", %{issues: issues, opts: opts} do
    uncertain_order(issues, opts)

    handler = fn
      "sessions.abort", _ -> %{"ok" => true}
      "agent.wait", _ -> %{"status" => "timeout"}
    end

    start = fn "incoming", callback ->
      assert catch_throw(callback.()) == :observed
      {:error, :synthetic_stop}
    end

    tick(%Orchestrator.State{max_concurrent_agents: 1}, issues,
      start: start,
      transport: transport(handler),
      openclaw_wait: fn _ -> throw(:observed) end
    )

    assert_receive {:yolo_event, "incoming", %{event: :recovered, message: message, external: external}}
    assert message =~ "reserviert. Betreiber:"
    assert external.missing_evidence == "terminal_or_pre_acceptance_original_required"
  end

  test "typed pre-acceptance rejection releases only this generation, retains history and permits a new attempt", %{issues: issues, opts: opts} do
    transport = fn
      ["--version"] ->
        {:ok, "2026.9.4"}

      ["gateway", "call", "agents.list" | _] ->
        {:ok, ~s({"agents":[{"id":"po"}]})}

      ["gateway", "call", "agent", "--params", raw | _] ->
        {:ok,
         Jason.encode!(%{
           "symphony_openclaw_rejection" => 1,
           "method" => "agent",
           "phase" => "pre_acceptance",
           "code" => "INVALID_REQUEST",
           "reason" => "cwd_reserved",
           "request_sha256" => OpenClaw.digest(raw),
           "ignored" => "SECRET"
         })}

      _ ->
        flunk("a non-start must never poll or cancel")
    end

    opts = Keyword.merge(opts, transport: transport, recipient: self())
    assert {:error, :openclaw_request_rejected_before_acceptance} = run_group("incoming", issues, issues, opts)
    assert_receive {:yolo_event, "incoming", %{event: :failed, message: message}}
    assert message =~ "Vor Annahme abgelehnt (INVALID_REQUEST/cwd_reserved)"
    assert {:ok, rejected} = Journal.read("incoming")
    assert rejected["state"] == "rejected"
    refute rejected["terminal"]
    refute rejected["writable"]
    refute Jason.encode!(rejected) =~ "SECRET"
    assert {:ok, []} = Journal.pending()
    assert :ok = Journal.member_available(hd(issues).id)
    assert {:ok, record} = Store.read("incoming")
    assert record["processed"] == nil
    assert record["retry_at"] > System.system_time(:millisecond)
    assert {:ok, ^rejected} = Journal.update(rejected, %{"state" => "accepted", "writable" => true})
    assert {:error, :openclaw_request_rejected_before_acceptance} = run_group("incoming", issues, issues, opts)
    assert {:ok, next} = Journal.read("incoming")
    refute next["id"] == rejected["id"]
    assert {:ok, ^rejected} = Journal.history("incoming", rejected["id"])
    assert {:error, :openclaw_generation_changed} = Journal.update(rejected, %{"state" => "unknown"})
  end

  test "operator recovery dry run, restart and repeated import preserve the original evidence", %{issues: issues, opts: opts} do
    order = uncertain_order(issues, opts)
    evidence = rejection_evidence(order)
    assert {:ok, %{"state" => "rejected"}} = recover_evidence(evidence)
    assert {:ok, ^order} = Journal.read("incoming")
    assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
    assert {:ok, recovered} = recover_evidence(evidence, true)
    assert recovered["before_recovery"]["state"] == "unknown"
    assert recovered["rejection"]["code"] == "INVALID_REQUEST"
    refute recovered["terminal"]
    # A restarted observer sees the terminal journal and performs no external call.
    resolved_opts = [transport: fn _ -> flunk("resolved") end]
    assert {:error, :openclaw_request_rejected_before_acceptance} = OpenClaw.recover(order, resolved_opts)
    assert {:ok, ^recovered} = recover_evidence(evidence, true, status: fn _ -> flunk("idempotent") end)
    assert :ok = Journal.available("incoming")
    new = uncertain_order(issues, opts)
    assert new["id"] != order["id"]
    assert {:ok, ^recovered} = Journal.history("incoming", order["id"])
    assert {:ok, ^recovered} = recover_evidence(evidence, true)
    assert {:ok, ^new} = Journal.read("incoming")
    changed = Map.put(evidence, "reviewer", "another-operator")
    assert {:error, :openclaw_generation_changed} = recover_evidence(changed, true)
    assert {:ok, ^new} = Journal.read("incoming")
  end

  test "recovery denies uncorrelated evidence and conflicting execution", %{issues: issues, opts: opts} do
    order = uncertain_order(issues, opts)
    evidence = rejection_evidence(order)

    bad = [
      Map.delete(evidence, "response"),
      put_in(evidence, ["response", "request_id"], "foreign-request"),
      put_in(evidence, ["response", "reason"], "timeout"),
      put_in(evidence, ["binding", "project_id"], "foreign"),
      put_in(evidence, ["binding", "sha"], "other"),
      put_in(evidence, ["execution_check", "basis"], "missing_session"),
      put_in(evidence, ["execution_check", "no_active_or_foreign_execution"], false),
      put_in(evidence, ["execution_check", "checked_at"], nil),
      put_in(evidence, ["execution_check", "checked_at"], "invalid-time"),
      put_in(evidence, ["execution_check", "checked_at"], "2020-01-01T00:00:00Z")
    ]

    for proof <- bad do
      assert {:error, _} = recover_evidence(proof, true)
      assert {:ok, ^order} = Journal.read("incoming")
    end

    for response <- [
          {:error, :connection_lost},
          {:ok, %{"status" => "running", "runId" => order["id"]}},
          {:ok, %{"status" => "timeout", "startedAt" => 1}},
          {:ok, %{"status" => "timeout", "runId" => "foreign"}},
          {:ok, %{"status" => "ok", "runId" => order["id"], "endedAt" => 2}}
        ] do
      assert {:error, :openclaw_recovery_conflict} = recover_evidence(evidence, true, status: fn _ -> response end)
    end

    assert {:ok, record} = Store.read("incoming")

    for attempt <- [nil, %{"id" => "foreign-attempt"}] do
      :ok = Store.write("incoming", Map.put(record, "attempt", attempt))
      assert {:error, :openclaw_recovery_conflict} = recover_evidence(evidence, true)
      assert {:ok, ^order} = Journal.read("incoming")
    end

    Store.write("incoming", put_in(record, ["attempt", "completed"], %{hd(issues).id => "action"}))
    assert {:error, :openclaw_recovery_conflict} = recover_evidence(evidence, true)
    Store.write("incoming", record)
    assert {:ok, _} = Journal.update(order, %{"acceptance_observed" => true})
    assert {:error, :openclaw_recovery_conflict} = recover_evidence(evidence, true)
    assert {:error, :openclaw_unresolved_order} = Journal.write(%{order | "id" => "replacement"})
    assert {:error, :openclaw_rejection_conflicts_with_execution} = Journal.update(order, %{"state" => "rejected", "rejection" => %{}})
  end

  test "concurrent recovery serializes with cancellation and preserves terminal evidence", %{issues: issues, opts: opts, context: context} do
    order = uncertain_order(issues, opts)
    evidence = rejection_evidence(order)
    parent = self()

    recovery =
      Task.async(fn ->
        ProjectContext.with_context(context, fn ->
          recover_evidence(evidence, true,
            status: fn _ ->
              send(parent, {:checking, self()})
              receive do: (:continue -> {:ok, %{"status" => "timeout"}})
            end
          )
        end)
      end)

    assert_receive {:checking, pid}, 2000
    cancel = Task.async(fn -> ProjectContext.with_context(context, fn -> Journal.update(order, %{"state" => "cancel_pending", "cancel_requested" => true}) end) end)
    send(pid, :continue)
    assert {:ok, recovered} = Task.await(recovery)
    assert {:ok, ^recovered} = Task.await(cancel)
    assert {:ok, ^recovered} = Journal.read("incoming")
  end

  test "measured checkout rejects knowledge workspace, changed SHA, dirt, inaccessible root and foreign binding", %{issues: issues, opts: opts, workspace: workspace} do
    order = uncertain_order(issues, opts)
    proof = Map.merge(Map.take(order, ~w(id project_id session_id workspace sha)), %{"cwd" => workspace.path, "git_root" => workspace.path, "clean" => true})
    alias SymphonyElixir.Yolo.OpenClaw.Checkout
    assert {:ok, measured} = Checkout.verify(order, proof)
    assert measured["payload_sha256"] == order["payload_sha256"]
    assert {:error, :openclaw_checkout_unverified} = Checkout.verify(order, nil)

    original_path = System.get_env("PATH")

    try do
      System.put_env("PATH", Path.join(workspace.path, "missing-executables"))
      assert {:error, :openclaw_checkout_unverified} = Checkout.verify(order, proof)
    after
      restore_env("PATH", original_path)
    end

    for changed <- [
          Map.put(proof, "cwd", "/knowledge"),
          Map.put(proof, "git_root", "/knowledge"),
          Map.put(proof, "sha", "wrong"),
          Map.put(proof, "id", "other"),
          Map.put(proof, "project_id", "other"),
          Map.put(proof, "clean", false)
        ] do
      assert {:error, :openclaw_checkout_unverified} = Checkout.verify(order, changed)
    end

    File.write!(Path.join(workspace.path, "proof.txt"), "dirty")
    assert {:error, :openclaw_checkout_unverified} = Checkout.verify(order, proof)
    File.rm_rf!(workspace.path)
    assert {:error, :openclaw_checkout_unverified} = Checkout.verify(order, proof)
  end

  test "interrupted archival never replaces the current generation and can resume", %{issues: issues, opts: opts} do
    order = uncertain_order(issues, opts)
    assert {:ok, previous} = recover_evidence(rejection_evidence(order), true)
    following = %{order | "id" => Ecto.UUID.generate()}
    archive = Journal.path("incoming") <> ".history"
    File.write!(archive, "unavailable directory")
    assert {:error, _} = Journal.write(following)
    assert {:ok, ^previous} = Journal.read("incoming")
    File.rm!(archive)
    # Model the durable boundary after archive sync, before current replacement.
    assert :ok = DurableState.write(Path.join(archive, Digest.digest(previous["id"]) <> ".json"), previous)
    assert {:ok, ^previous} = Journal.read("incoming")
    conflicting = Map.put(previous, "error", "conflicting-history")
    archive_path = Path.join(archive, Digest.digest(previous["id"]) <> ".json")
    assert :ok = DurableState.write(archive_path, conflicting)
    assert {:error, :openclaw_history_conflict} = Journal.write(following)
    assert {:ok, ^previous} = Journal.read("incoming")
    assert {:ok, ^conflicting} = Journal.history("incoming", previous["id"])
    assert :ok = DurableState.write(archive_path, previous)
    assert :ok = Journal.write(following)
    assert {:ok, ^previous} = Journal.history("incoming", previous["id"])
    assert {:ok, ^following} = Journal.read("incoming")
    assert {:error, :openclaw_immutable_order} = Journal.update(following, %{"sha" => "wrong"})
    assert {:ok, _} = Journal.update(following, %{"state" => "failed"})
    assert {:error, :openclaw_generation_reused} = Journal.write(following)
    assert {:error, :openclaw_generation_reused} = Journal.write(previous)
  end

  test "operator command refuses malformed packages and mismatched source hashes without exposing contents", %{root: root} do
    command = RecoverCommand
    assert_raise Mix.Error, ~r/openclaw_recovery_input_invalid/, fn -> command.run([]) end
    path = Path.join(root, "evidence.json")
    File.write!(path, "[]")
    args = ["--project", root, "--evidence", path]
    assert_raise Mix.Error, ~r/openclaw_recovery_input_invalid/, fn -> command.run(args) end
    source = Path.join(root, "private-source")
    File.write!(source, "SENSITIVE synthetic operator evidence")
    File.write!(path, Jason.encode!(%{"source_file" => source, "source_sha256" => String.duplicate("a", 64)}))
    assert_raise Mix.Error, ~r/^OpenClaw recovery refused: openclaw_recovery_input_invalid$/, fn -> command.run(args ++ ["--apply"]) end
    assert {:ok, nil} = Journal.read("incoming")
  end

  test "default recovery cannot release a reservation when the real gateway boundary is denied", %{issues: issues, opts: opts} do
    order = uncertain_order(issues, opts)

    assert_raise RuntimeError, ~r/OpenClaw process access forbidden in standard tests/, fn ->
      Recovery.resolve(rejection_evidence(order))
    end

    assert {:ok, ^order} = Journal.read("incoming")
    assert {:error, :openclaw_member_reserved} = Journal.member_available(hd(issues).id)
  end

  test "journal write authority follows the current generation and revocation", %{issues: issues, opts: opts} do
    refute Journal.writable?("incoming", "missing")
    order = uncertain_order(issues, opts)
    refute Journal.writable?("incoming", order["id"])
    assert {:ok, running} = Journal.update(order, %{"state" => "running", "writable" => true})
    assert Journal.writable?("incoming", running["id"])
    refute Journal.writable?("incoming", "foreign")
    assert {:ok, _} = Journal.update(running, %{"state" => "cancel_pending", "writable" => false})
    refute Journal.writable?("incoming", running["id"])
  end

  test "journal lock failure cannot authorize cancellation or erase a later corruption", %{issues: issues, opts: opts, root: root} do
    original_path = System.get_env("PATH")

    handler = fn
      "agent", params -> %{"runId" => params["idempotencyKey"], "status" => "accepted"}
      "agent.wait", %{"runId" => id} -> %{"runId" => id, "status" => "running"}
      "sessions.abort", _ -> flunk("failed journal transition must not send an external abort")
    end

    wait = fn _ ->
      assert {:ok, %{"state" => "accepted", "writable" => true, "acceptance_observed" => true}} = Journal.read("incoming")

      if Process.get(:lock_failure_observed) do
        restore_env("PATH", original_path)
        File.write!(Journal.path("incoming"), "corrupt-journal")
      else
        Process.put(:lock_failure_observed, true)
        System.put_env("PATH", Path.join(root, "missing-executables"))
        send(self(), :openclaw_cancel)
      end
    end

    try do
      assert {:error, :openclaw_journal_corrupt} =
               run_group("incoming", issues, issues, Keyword.merge(opts, transport: transport(handler), openclaw_wait: wait))

      assert File.read!(Journal.path("incoming")) == "corrupt-journal"
      assert {:error, :openclaw_journal_corrupt} = Journal.member_available(hd(issues).id)
    after
      restore_env("PATH", original_path)
    end
  end

  test "recovered legacy rejection reports a released reservation without inventing a reason", %{issues: issues, opts: opts} do
    order = uncertain_order(issues, opts)
    assert {:ok, _} = Journal.update(order, %{"state" => "rejected", "rejection" => %{}})

    assert {:error, :openclaw_request_rejected_before_acceptance} =
             OpenClaw.recover(order, recipient: self(), transport: fn _ -> flunk("terminal journal must not call the gateway") end)

    assert_receive {:yolo_event, "incoming", %{message: "Vor Annahme abgelehnt; Reservierung freigegeben."}}
    assert :ok = Journal.member_available(hd(issues).id)
  end

  test "operator command reloads isolated project configuration and idempotently reports a recovered package", %{issues: issues, opts: opts, root: root, context: context} do
    {:ok, reloaded} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = put_in(context.settings.tracker.app["state_root"], reloaded.settings.tracker.app["state_root"])
    ProjectContext.bind(context)
    order = uncertain_order(issues, opts)
    source = "synthetic correlated rejection"
    execution_source = "synthetic operator execution check"

    evidence =
      rejection_evidence(order)
      |> Map.put("source_sha256", OpenClaw.digest(source))
      |> Map.put("execution_source_sha256", OpenClaw.digest(execution_source))

    assert {:ok, recovered} = recover_evidence(evidence, true)
    path = Path.join(root, "evidence.json")
    package = Map.merge(evidence, %{"source_file" => "rejection.txt", "execution_source_file" => "execution.txt"})
    File.write!(path, Jason.encode!(package))
    File.write!(Path.join(root, "rejection.txt"), source)
    File.write!(Path.join(root, "execution.txt"), execution_source)

    helper = "priv/linear_app/issue_lease.py"
    File.mkdir_p!(Path.dirname(Path.join(root, helper)))
    File.cp!(Path.join(SymphonyElixir.RuntimePaths.workflow_dir(), helper), Path.join(root, helper))
    isolated = %{context | env: Map.put(context.env, "SYMPHONY_ROOT_DIR", root)}

    ProjectContext.with_context(isolated, fn ->
      for {extra, mode} <- [{[], "dry_run"}, {["--apply"], "applied"}] do
        output = ExUnit.CaptureIO.capture_io(fn -> RecoverCommand.run(["--project", root, "--evidence", path] ++ extra) end)
        result = Jason.decode!(String.trim(output))
        assert result["mode"] == mode
        assert result["id"] == order["id"]
        assert result["state"] == "rejected"
        assert result["recovery"] == recovered["recovery"]
        refute output =~ source
        refute output =~ execution_source
      end
    end)

    assert {:ok, ^recovered} = Journal.read("incoming")
  end
end
