defmodule SymphonyElixir.YoloAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.{AppAuth, IssueLease, YoloAgent}
  alias SymphonyElixir.{ProjectContext, Relay}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "$LINEAR_ASSIGNEE")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=z@example.com, a@example.com, Z@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = put_in(context.settings.tracker.yolo_agent, "Pai")
    context = put_in(context.settings.tracker.relay, %{"consumer_id" => "yolo", "state_root" => Path.join(root, "relay")})
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    {:ok, context: context, root: root}
  end

  defp users do
    [%{"id" => "11111111-1111-4111-8111-111111111111", "email" => "a@example.com", "app" => false}, %{"id" => "ffffffff-ffff-4fff-8fff-ffffffffffff", "email" => "z@example.com", "app" => false}]
  end

  defp agent, do: %{"id" => "pai", "name" => "Pai", "app" => true, "active" => true, "isAssignable" => true, "supportsAgentSessions" => true}
  defp response(nodes, page \\ %{"hasNextPage" => false}), do: {:ok, %{status: 200, body: %{"data" => %{"users" => %{"nodes" => nodes, "pageInfo" => page}}}}}

  defp stub(agents) do
    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      if (payload[:query] || payload["query"]) =~ "SymphonyHumanAssignees", do: response(users()), else: response(agents)
    end)
  end

  test "agent configuration is optional and independent of the start switch", %{root: root} do
    for yolo <- [false, true], value <- [nil, "", "   ", "  Pai  "] do
      Application.put_env(:symphony_elixir, :yolo, yolo)
      path = Path.join(root, ".symphony/.env.local")
      if is_nil(value), do: File.rm(path), else: File.write!(path, "LINEAR_YOLO_AGENT=#{value}\n")
      assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})

      ProjectContext.with_context(context, fn ->
        assert Config.yolo?() == yolo
        assert Config.yolo_agent_name() == if(value == "  Pai  ", do: "Pai", else: nil)
        assert Config.yolo_agent_id() == nil
      end)
    end
  end

  test "first configured human survives sorted IDs, mixed email/ID aliases and runtime export", %{context: context} do
    stub([agent()])
    context = put_in(context.settings.tracker.assignee, "Z@example.com,a@example.com,ffffffff-ffff-4fff-8fff-ffffffffffff,z@example.com")
    assert {:ok, [resolved]} = Client.resolve_relay_contexts([context])
    assert resolved.assignee_ids == ["11111111-1111-4111-8111-111111111111", "ffffffff-ffff-4fff-8fff-ffffffffffff"]
    assert resolved.human_handoff_id == "ffffffff-ffff-4fff-8fff-ffffffffffff"
    assert resolved.yolo_agent_id == "pai"
    assert {:ok, [^resolved]} = Client.resolve_relay_contexts([resolved])
    resolved = %{resolved | yolo: true, env: Map.put(resolved.env, "LINEAR_YOLO_AGENT", "Pai")}
    System.put_env("SYMPHONY_WORKFLOW_FILE", resolved.workflow_path)

    ProjectContext.with_context(resolved, fn ->
      encoded = ProjectContext.runtime_env()["SYMPHONY_PROJECT_CONTEXT"]
      ProjectContext.bind(nil)
      assert :ok = ProjectContext.restore(encoded, Path.join(resolved.root, ".symphony"))
      assert Config.yolo?()
      assert Config.human_handoff_id() == "ffffffff-ffff-4fff-8fff-ffffffffffff"
      assert Config.yolo_agent_id() == "pai"
    end)
  end

  test "delegable apps do not require Linear agent sessions", %{context: context} do
    for candidate <- [%{agent() | "supportsAgentSessions" => false}, Map.delete(agent(), "supportsAgentSessions")] do
      stub([candidate])
      assert {:ok, [resolved]} = Client.resolve_relay_contexts([context])
      assert resolved.yolo_agent_id == candidate["id"]
      assert resolved.human_handoff_id == "ffffffff-ffff-4fff-8fff-ffffffffffff"
    end
  end

  test "lookup requests assignment capability from the bound workspace", %{context: context} do
    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      query = payload[:query] || payload["query"]

      if query =~ "SymphonyHumanAssignees" do
        response(users())
      else
        assert query =~ "isAssignable"
        response([Map.delete(agent(), "supportsAgentSessions")])
      end
    end)

    assert {:ok, [_]} = Client.resolve_relay_contexts([context])
  end

  test "unknown, ambiguous, nondelegable, inactive and incomplete identities fail closed", %{context: context} do
    for {agents, error} <- [
          {[], :linear_yolo_agent_not_found},
          {[agent(), %{agent() | "id" => "pai-two"}], :linear_yolo_agent_ambiguous},
          {[%{agent() | "isAssignable" => false}], :linear_yolo_agent_invalid},
          {[%{agent() | "isAssignable" => nil}], :linear_yolo_agent_invalid},
          {[%{agent() | "isAssignable" => "true"}], :linear_yolo_agent_invalid},
          {[Map.delete(agent(), "isAssignable")], :linear_yolo_agent_invalid},
          {[%{agent() | "active" => false}], :linear_yolo_agent_invalid},
          {[Map.delete(agent(), "active")], :linear_yolo_agent_invalid},
          {[%{agent() | "app" => false}], :linear_yolo_agent_invalid},
          {[Map.delete(agent(), "app")], :linear_yolo_agent_invalid},
          {[%{agent() | "id" => ""}], :linear_yolo_agent_invalid},
          {[Map.delete(agent(), "id")], :linear_yolo_agent_invalid},
          {[%{agent() | "name" => "Other"}], :linear_yolo_agent_invalid},
          {[Map.delete(agent(), "name")], :linear_yolo_agent_invalid}
        ] do
      stub(agents)
      assert {:error, {^error, "Pai"}} = Client.resolve_relay_contexts([context])
    end
  end

  test "agent lookup paginates completely and rejects partial or looping responses", %{context: context} do
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      if (payload[:query] || payload["query"]) =~ "SymphonyHumanAssignees" do
        response(users())
      else
        cursor = (payload[:variables] || payload["variables"])["after"] || (payload[:variables] || payload["variables"])[:after]
        send(parent, {:page, cursor})
        if cursor, do: response([agent()]), else: response([], %{"hasNextPage" => true, "endCursor" => "second"})
      end
    end)

    assert {:ok, [_]} = Client.resolve_relay_contexts([context])
    assert_receive {:page, nil}
    assert_receive {:page, "second"}

    for result <- [
          response([agent()], %{}),
          response([agent()], %{"hasNextPage" => true, "endCursor" => "same"}),
          {:ok, %{status: 200, body: %{"errors" => [%{"message" => "partial"}], "data" => %{"users" => %{"nodes" => [agent()], "pageInfo" => %{"hasNextPage" => false}}}}}}
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        if (payload[:query] || payload["query"]) =~ "SymphonyHumanAssignees", do: response(users()), else: result
      end)

      assert {:error, _} = Client.resolve_relay_contexts([context])
    end
  end

  test "missing and ambiguous humans cannot fall back to another user", %{context: context} do
    Application.put_env(:symphony_elixir, :yolo, true)

    assert {:error, :linear_yolo_agent_requires_human_assignee} =
             AppAuth.validate(%{context.settings.tracker | assignee: nil})

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> response([hd(users()), %{hd(users()) | "id" => "duplicate"}]) end)
    assert {:error, :relay_requires_verified_humans} = Client.resolve_relay_contexts([context])
    foreign = put_in(context.settings.tracker.app["workspace_id"], "another-workspace")
    assert {:error, :linear_yolo_agent_workspace_mismatch} = Client.resolve_relay_contexts([context, foreign])
  end

  test "withdrawal stops dispatch and a running worker with the same human", %{context: context} do
    context = %{context | assignee_ids: ["ffffffff-ffff-4fff-8fff-ffffffffffff"], human_handoff_id: "ffffffff-ffff-4fff-8fff-ffffffffffff", yolo_agent_id: "pai"}

    ProjectContext.with_context(context, fn ->
      node = %{
        "id" => "delegated",
        "identifier" => "PRO-1",
        "title" => "Delegated",
        "state" => %{"name" => "In Arbeit (AI)"},
        "project" => %{"slugId" => "project"},
        "assignee" => %{"id" => "ffffffff-ffff-4fff-8fff-ffffffffffff", "email" => "z@example.com", "app" => false},
        "delegate" => %{"id" => "pai"}
      }

      issue = Client.relay_issue(node)
      assert issue.delegate_id == "pai"
      assert issue.assignee_id == "ffffffff-ffff-4fff-8fff-ffffffffffff"
      assert YoloAgent.delegated?(issue)
      assert :ok = Relay.execution_allowed(issue)
      withdrawn = Client.relay_issue(Map.put(node, "delegate", nil))
      refute YoloAgent.continued?(issue, withdrawn)
      fetch = fn _ -> {:ok, [withdrawn]} end
      assert {:skip, ^withdrawn} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetch)
      pid = spawn(fn -> receive do: (:stop -> :ok) end)
      monitor = Process.monitor(pid)

      state = %Orchestrator.State{
        running: %{issue.id => %{pid: pid, ref: nil, identifier: issue.identifier, issue: issue, run_mode: :regular, started_at: DateTime.utc_now()}},
        claimed: MapSet.new([issue.id]),
        codex_totals: %{}
      }

      try do
        assert Map.has_key?(Orchestrator.reconcile_issue_states_for_test([issue], state).running, issue.id)
        refute Map.has_key?(Orchestrator.reconcile_issue_states_for_test([withdrawn], state).running, issue.id)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      after
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
      end
    end)
  end

  test "retry retains delegated ownership across capacity waits and releases revoked work", %{context: context} do
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.kind, "memory")
    context = put_in(context.settings.tracker.relay, nil)
    context = put_in(context.settings.tracker.active_states, ["In Arbeit (AI)"])

    issue = %Issue{
      id: "retry-delegated",
      identifier: "PRO-7",
      title: "Delegated retry",
      state: "In Arbeit (AI)",
      assignee_id: "human",
      delegate_id: "pai",
      assigned_to_worker: true,
      in_project_scope: true
    }

    previous = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    on_exit(fn -> Application.put_env(:symphony_elixir, :memory_tracker_issues, previous) end)

    ProjectContext.with_context(context, fn ->
      token = make_ref()
      entry = %{attempt: 1, retry_token: token, identifier: issue.identifier, delegate_id: "pai"}
      state = %Orchestrator.State{max_concurrent_agents: 0, claimed: MapSet.new([issue.id]), retry_attempts: %{issue.id => entry}, codex_totals: %{}}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      assert {:noreply, waiting} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)
      assert waiting.retry_attempts[issue.id].delegate_id == "pai"
      assert MapSet.member?(waiting.claimed, issue.id)
      Process.cancel_timer(waiting.retry_attempts[issue.id].timer_ref)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{issue | delegate_id: nil}])
      assert {:noreply, released} = Orchestrator.handle_info({:retry_issue, issue.id, waiting.retry_attempts[issue.id].retry_token}, waiting)
      assert released.retry_attempts == %{}
      refute MapSet.member?(released.claimed, issue.id)
      assert released.running == %{}
    end)
  end

  test "cache includes delegated PO work and foreign-human pipeline blockers without authorizing them", %{context: context} do
    context = %{context | assignee_ids: ["local"], human_handoff_id: "local", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.assignee, "local")

    nodes =
      for {id, state, assignee, delegate} <- [
            {"backlog", "Backlog", nil, "pai"},
            {"todo", "Todo", nil, "pai"},
            {"defined", "Definiert", nil, "pai"},
            {"review", "Review", "local", "pai"},
            {"foreign", "In Arbeit (AI)", "foreign", "pai"},
            {"human", "Backlog", "local", nil},
            {"dialog", "Todo (Dialog-AI)", "local", "pai"}
          ] do
        %{
          "id" => id,
          "identifier" => "PRO-1",
          "title" => id,
          "state" => %{"name" => state},
          "project" => %{"slugId" => "project"},
          "delegate" => if(delegate, do: %{"id" => delegate}),
          "assignee" => if(assignee, do: %{"id" => assignee, "app" => false})
        }
      end

    assert {:ok, found} = Client.relay_candidates([context], nodes)
    issues = found[context.id]
    assert Enum.sort(Enum.map(issues, & &1.id)) == ~w(backlog defined dialog foreign review todo)
    assert Enum.find(issues, &(&1.id == "foreign")).assigned_to_worker == false
    refute Enum.find(issues, &(&1.id == "backlog")).assigned_to_worker
    assert {:ok, empty} = Client.relay_candidates([context], [put_in(hd(nodes), ["project", "slugId"], "elsewhere")])
    assert empty[context.id] == []
    restricted = put_in(context.settings.tracker.app["allowed_issue_ids"], ["todo"])
    assert {:ok, limited} = Client.relay_candidates([restricted], nodes)
    assert Enum.map(limited[context.id], & &1.id) == ["todo"]
  end

  test "agent binding and assignee ordering are restart-bound", %{context: context, root: root} do
    File.write!(Path.join(root, ".symphony/.env.local"), "LINEAR_YOLO_AGENT=Pai\n")
    {:ok, original} = ProjectContext.load(root, context.workflow_path, %{})

    original = %{
      original
      | yolo_agent_id: "pai",
        human_handoff_id: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        assignee_ids: ["11111111-1111-4111-8111-111111111111", "ffffffff-ffff-4fff-8fff-ffffffffffff"]
    }

    File.write!(Path.join(root, ".symphony/.env.local"), "LINEAR_YOLO_AGENT=Other\n")
    assert ProjectContext.refresh(original) == original
    File.write!(Path.join(root, ".symphony/.env.local"), "LINEAR_YOLO_AGENT=Pai\nLINEAR_ASSIGNEE=a@example.com,z@example.com\n")
    assert ProjectContext.refresh(original) == original
    File.write!(Path.join(root, ".symphony/.env.local"), "LINEAR_YOLO_AGENT=Pai\nPUBLIC_EXTRA=accepted\n")
    refreshed = ProjectContext.refresh(original)
    assert refreshed.env["PUBLIC_EXTRA"] == "accepted"
    assert refreshed.yolo_agent_id == "pai"
    assert refreshed.human_handoff_id == "ffffffff-ffff-4fff-8fff-ffffffffffff"
  end

  test "agent receives workspace events; human execution stays local", %{context: context, root: root} do
    File.write!(Path.join(root, ".symphony/.env.local"), "LINEAR_RELAY_KEY=fixture-relay-key\n")
    relay = Map.merge(context.settings.tracker.relay, %{"endpoint" => "https://relay.test", "key_env" => "LINEAR_RELAY_KEY", "reconcile_ms" => 300_000})
    context = %{context | yolo: false, assignee_ids: ["local"], human_handoff_id: "local", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.relay, relay)
    assert {:ok, session} = Relay.open([context])
    assert session.record["subscription"]["assigneeIds"] == []
    assert session.contexts == [context]
    unresolved = %{context | assignee_ids: nil, human_handoff_id: nil, yolo_agent_id: nil}
    [restored] = Relay.resolved_contexts(session, [unresolved])
    assert restored == context

    ProjectContext.with_context(context, fn ->
      foreign = %Issue{delegate_id: "pai", assignee_id: "foreign"}
      assert {:error, :relay_requires_authorized_human} = Relay.execution_allowed(foreign)
    end)
  end

  test "a delegated lease rechecks removal after dispatch before any work", %{context: context} do
    context = %{context | assignee_ids: ["ffffffff-ffff-4fff-8fff-ffffffffffff"], human_handoff_id: "ffffffff-ffff-4fff-8fff-ffffffffffff", yolo_agent_id: "pai"}
    issue = %Issue{id: "lease-delegation", identifier: "PRO-1", assignee_id: "ffffffff-ffff-4fff-8fff-ffffffffffff", delegate_id: "pai"}

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert (payload[:query] || payload["query"]) =~ "IssuesById"
      {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [%{"id" => issue.id, "delegate" => nil}]}}}}}
    end)

    ProjectContext.with_context(context, fn ->
      assert {:error, :yolo_delegation_changed} = IssueLease.run(issue, fn -> flunk("revoked work started") end)
    end)
  end

  test "agent lookup and delegated leases preserve transport failures", %{context: context} do
    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      if (payload[:query] || payload["query"]) =~ "SymphonyHumanAssignees", do: response(users()), else: {:error, :offline}
    end)

    assert {:error, _} = Client.resolve_relay_contexts([context])
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    issue = %Issue{id: "lease-ready", identifier: "PRO-1", assignee_id: "human", delegate_id: "pai"}

    ProjectContext.with_context(context, fn ->
      assert {:error, _} = IssueLease.run(issue, fn -> flunk("offline lease started") end)
    end)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      data =
        if (payload[:query] || payload["query"]) =~ "IssuesById" do
          %{
            "issues" => %{
              "nodes" => [%{"id" => issue.id, "project" => %{"slugId" => "project"}, "delegate" => %{"id" => "pai"}, "assignee" => %{"id" => "human", "email" => "z@example.com", "app" => false}}]
            }
          }
        else
          %{"issue" => %{"comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    ProjectContext.with_context(context, fn ->
      assert :ok = IssueLease.run(issue, fn -> :ok end)
    end)
  end
end
