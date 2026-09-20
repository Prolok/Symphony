defmodule SymphonyElixir.OpenClawRuntimeTest do
  use SymphonyElixir.TestSupport
  alias Mix.Tasks.Openclaw.Recover, as: RecoverCommand
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.{Completion, Coordinator, OpenClaw, Runner, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, Recovery, ToolBridge, Transport}

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
    opts = Keyword.put(opts, :workspace, fn _, _ -> {:ok, workspace} end)

    handler = fn
      "agent", params ->
        id = params["idempotencyKey"]
        assert {:ok, order} = Journal.read("incoming")
        assert order["id"] == id
        assert order["state"] == "intent"
        assert order["payload_sha256"] == OpenClaw.digest(params["message"])
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
        assert :ok = Runner.run("incoming", issues, issues, Keyword.merge(opts, transport: transport(handler), tool_opts: tool_opts))
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
    assert {:error, :yolo_group_changed} = Runner.run("incoming", issues, issues, opts)
  end

  test "preflight failures retain every member's issue and session context", %{issues: issues, context: context, opts: opts} do
    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :openclaw_binary_missing} =
                 Runner.run("incoming", issues, issues, Keyword.put(opts, :transport, fn _ -> {:error, :openclaw_binary_missing} end))
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
        Store.write("incoming", Map.put(record, "processed", nil))

        session = fn _, _, _, _ ->
          Enum.each(issues, fn issue -> assert :ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "internal"}, opts) end)
          {:ok, %{session_id: "codex"}}
        end

        assert :ok = Runner.run("incoming", issues, issues, Keyword.merge(opts, session: session, transport: denied))
        state = %Orchestrator.State{max_concurrent_agents: 1}
        assert Coordinator.tick(state, issues, Keyword.put(opts, :transport, denied)).yolo_runs == %{}
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
    assert catch_throw(Runner.run("incoming", issues, issues, interrupted)) == :simulated_crash
    assert_receive {:submitted, id}
    assert {:ok, order} = Journal.read("incoming")
    assert order["id"] == id
    assert order["state"] == "unknown"
    refute order["writable"]

    for _ <- 1..3 do
      assert {:error, :openclaw_unresolved_order} = Runner.run("incoming", issues, issues, interrupted)
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
      restored = Coordinator.tick(state, issues, start: fn "incoming", _ -> {:ok, sleeper} end)
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
    assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :pending
    assert {:ok, %{"state" => "cancel_pending", "writable" => false, "abort_acknowledged" => true}} = Journal.read("incoming")
    assert {:error, :openclaw_unresolved_order} = Journal.available("incoming")
  end

  test "accepted but partial work is never processed", %{issues: issues, opts: opts} do
    handler = fn
      "agent", params -> %{"runId" => params["idempotencyKey"], "status" => "accepted"}
      "agent.wait", %{"runId" => id} -> %{"runId" => id, "status" => "ok", "endedAt" => 2}
    end

    assert {:error, :yolo_group_incomplete_or_workspace_changed} = Runner.run("incoming", issues, issues, Keyword.put(opts, :transport, transport(handler)))
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
      assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :observed
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
    assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :suspended
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
    result = Coordinator.tick(state, withdrawn, start: fn _, _ -> flunk("replacement start") end)
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
    assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :lost
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
    result = Coordinator.tick(state, issues, start: fn _, _ -> flunk("unsafe replacement") end)
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
    result = Coordinator.tick(state, issues, start: fn _, _ -> {:error, :max_children} end)
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

  test "missing verified ownership and unreadable project skill prevent submission", %{issues: issues, context: context, opts: opts, workspace: workspace} do
    ProjectContext.with_context(%{context | yolo_agent_id: nil}, fn ->
      Scope.with_scope("incoming", issues, "unverified", fn ->
        assert {:error, :openclaw_requires_verified_linear_yolo_agent} =
                 OpenClaw.run(%{path: context.root, sha: "sha"}, "prompt", issues, "unverified", transport: fn _ -> flunk("unverified agent") end)
      end)
    end)

    skill = Path.join(workspace.path, ".codex/skills/sym-yolo-review/SKILL.md")
    File.mkdir_p!(skill)
    assert_raise File.Error, fn -> Runner.run("incoming", issues, issues, opts) end
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

    assert {:error, :openclaw_run_failed_or_cancelled} = Runner.run("incoming", issues, issues, Keyword.put(opts, :transport, transport(handler)))
    assert {:ok, %{"id" => id, "state" => "failed", "writable" => false, "abort_acknowledged" => true}} = Journal.read("incoming")
    assert_receive {:aborted, ^id}
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
    assert {:error, :openclaw_generation_changed} = Runner.run("incoming", issues, issues, opts)
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
    review = PoHandoff.fixture(%{"initial_state" => "Review", "title" => "fixture"}, plan)
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
    assert catch_throw(Runner.run("incoming", issues, issues, opts)) == :reserved
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

  defp recover_evidence(evidence, apply? \\ false, opts \\ []) do
    opts = Keyword.put_new(opts, :status, fn _ -> {:ok, %{"status" => "timeout"}} end)
    Recovery.resolve(evidence, apply?, opts)
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

    Coordinator.tick(%Orchestrator.State{max_concurrent_agents: 1}, issues,
      start: start,
      transport: transport(handler),
      openclaw_wait: fn _ -> throw(:observed) end
    )

    assert_receive {:yolo_event, "incoming", %{event: :recovered, message: message}}
    assert message =~ "reserviert. Betreiber:"
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
    assert {:error, :openclaw_request_rejected_before_acceptance} = Runner.run("incoming", issues, issues, opts)
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
    assert {:error, :openclaw_request_rejected_before_acceptance} = Runner.run("incoming", issues, issues, opts)
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
               Runner.run("incoming", issues, issues, Keyword.merge(opts, transport: transport(handler), openclaw_wait: wait))

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
