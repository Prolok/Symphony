defmodule SymphonyElixir.OpenClawRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.{Completion, Coordinator, OpenClaw, Runner, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, ToolBridge, Transport}

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

    opts = [
      fetch: fn ids -> {:ok, Enum.filter(issues, &(&1.id in ids))} end,
      lease: fn _, callback -> callback.() end,
      scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
      workspace: fn _, _ -> {:ok, %{path: root, sha: "merged-sha"}} end,
      unchanged: fn _ -> true end,
      checkpoint: fn _ -> {:ok, %{}} end,
      before_action: fn _ -> :ok end,
      session: fn _, _, _, _ -> flunk("OpenClaw must not fall back to Codex") end
    ]

    %{root: root, context: context, issues: issues, opts: opts}
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
    :ok = :gen_tcp.send(socket, Jason.encode!(%{token: binding["token"], request: request}) <> "\n")
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
    :gen_tcp.close(socket)
    Jason.decode!(bytes)
  end

  defp request(method, params \\ %{}), do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  defp descriptor(context, id), do: Path.join([context.settings.workspace.root, "yolo-runs", id, "tools.json"])

  test "activated path uses real MCP dispatch and only completes after member decisions", %{issues: issues, context: context, opts: opts} do
    parent = self()

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

        for text <- ["workflow_sha256", "linear_workspace_id", "human_handoff_id", "comment_inputs", "recorded_operations", "member0", "member1", "member2", "merged-sha", "WORKFLOW", "LinearBridge"] do
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
    assert :ok = Runner.run("incoming", issues, issues, Keyword.merge(opts, transport: transport(handler), tool_opts: tool_opts))
    assert_receive {:submitted, id}
    refute File.exists?(descriptor(context, id))
    assert {:ok, %{"state" => "completed", "writable" => false}} = Journal.read("incoming")
    assert {:ok, record} = Store.read("incoming")
    assert is_binary(record["processed"])
    assert map_size(record["attempt"]["completed"]) == 3
    assert {:error, :yolo_group_changed} = Runner.run("incoming", issues, issues, opts)
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

    for {response, error} <- [{"broken", :openclaw_invalid_response}, {"{\"agents\":[]}", :openclaw_agent_not_found}] do
      assert {:error, ^error} =
               Gateway.preflight("po",
                 transport: fn
                   ["--version"] -> {:ok, "2026.9.4"}
                   _ -> {:ok, response}
                 end
               )
    end

    assert {:error, :openclaw_gateway_unavailable} =
             Gateway.preflight("po",
               transport: fn
                 ["--version"] -> {:ok, "2026.9.4"}
                 _ -> {:error, :openclaw_gateway_unavailable}
               end
             )
  end

  test "tool bridge rejects revoked members, changed comments, foreign tools and expired authority", %{issues: [issue | _] = issues, root: root, opts: opts} do
    id = Ecto.UUID.generate()
    order = %{"id" => id, "group" => "incoming", "members" => [], "state" => "accepted", "writable" => true}
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
    assert :ok = Journal.write(Map.put(order, "state", "failed"))
    assert {:ok, _} = SymphonyElixir.WorkerCapacity.start_child(nil, "Test (AI)", fn -> :ok end)
  end
end
