defmodule SymphonyElixir.RelayOwnershipTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ScriptSupport
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.{ProjectContext, Relay}

  test "manual helpers resolve the local selection before their fresh issue lookup" do
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    relay = %{"consumer_id" => "manual", "state_root" => Path.join(root, "manual-relay")}
    context = put_in(context.settings.tracker.relay, relay)
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      query = payload[:query] || payload["query"]

      data =
        if query =~ "SymphonyHumanAssignees" do
          send(parent, :verified)
          %{"users" => %{"nodes" => [%{"id" => "human", "email" => "dev@example.com", "app" => false}], "pageInfo" => %{"hasNextPage" => false}}}
        else
          assert ProjectContext.current().assignee_ids == ["human"]

          %{
            "issues" => %{
              "nodes" => [
                %{
                  "id" => "manual",
                  "identifier" => "PRO-1",
                  "title" => "Manual",
                  "state" => %{"name" => "In Arbeit (AI)"},
                  "project" => %{"slugId" => "project"},
                  "assignee" => %{"id" => "human", "email" => "dev@example.com", "app" => false}
                }
              ]
            }
          }
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    path = Workflow.workflow_file_path()

    ProjectContext.with_context(context, fn ->
      assert {:ok, %{workflow_step: "In Arbeit (AI)", prompt: prompt}} =
               ScriptSupport.manual_prompt_context(path, path, path, "PRO-1", root)

      assert is_binary(prompt)
      assert_receive :verified
      assert {:ok, _} = ScriptSupport.manual_prompt_context(path, path, path, "PRO-1", root)
      refute_receive :verified
    end)
  end

  test "two locally verified assignees execute without owners" do
    root = Path.dirname(Workflow.workflow_file_path())
    relay = %{"consumer_id" => "one", "state_root" => Path.join(root, "local-assignees")}

    context =
      %ProjectContext{settings: put_in(Config.settings!().tracker.relay, relay)}
      |> Map.put(:assignee_ids, ["human-a", "human-b"])

    ProjectContext.with_context(context, fn ->
      for id <- ["human-a", "human-b"] do
        assert :ok = Relay.execution_allowed(%Issue{assignee_id: id, assigned_to_worker: true})
      end
    end)
  end

  test "running workers stop when the current assignee is no longer local" do
    root = Path.dirname(Workflow.workflow_file_path())
    relay = %{"consumer_id" => "one", "state_root" => Path.join(root, "running-owner")}
    settings = put_in(Config.settings!().tracker.relay, relay)
    context = %ProjectContext{settings: settings, assignee_ids: ["human-a"]}
    issue = %Issue{id: "running-owner", identifier: "PRO-1", title: "Owner", state: "In Arbeit (AI)", assignee_id: "human-a", assigned_to_worker: true}

    for yolo <- [false, true], assignee <- ["human-b", nil, settings.tracker.app["user_id"]] do
      Application.put_env(:symphony_elixir, :yolo, yolo)
      pid = spawn(fn -> receive do: (:stop -> :ok) end)
      monitor = Process.monitor(pid)

      try do
        ProjectContext.with_context(context, fn ->
          state = %Orchestrator.State{
            running: %{issue.id => %{pid: pid, ref: nil, identifier: issue.identifier, issue: issue, run_mode: :regular, started_at: DateTime.utc_now()}},
            claimed: MapSet.new([issue.id]),
            codex_totals: %{}
          }

          kept = Orchestrator.reconcile_issue_states_for_test([issue], state)
          assert Map.has_key?(kept.running, issue.id)
          changed = %{issue | assignee_id: assignee}
          stopped = Orchestrator.reconcile_issue_states_for_test([changed], kept)
          refute Map.has_key?(stopped.running, issue.id)
          refute MapSet.member?(stopped.claimed, issue.id)
          assert_receive {:DOWN, ^monitor, :process, ^pid, _}
        end)
      after
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
      end
    end
  end

  test "dispatch, retry refresh, leases and manual helpers require a local human even with yolo" do
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    relay = %{"consumer_id" => "observer", "state_root" => Path.join(root, "relay-owner"), "owners" => %{"human" => "executor"}}
    context = put_in(context.settings.tracker.relay, relay)
    context = %{context | assignee_ids: ["another-human"]}
    issue = %Issue{id: "issue-owner", identifier: "PRO-716", title: "Owner", state: "In Arbeit (AI)", assignee_id: "human", assigned_to_worker: true}
    state = %Orchestrator.State{}

    for yolo <- [false, true] do
      Application.put_env(:symphony_elixir, :yolo, yolo)

      ProjectContext.with_context(context, fn ->
        assert {:error, :relay_requires_authorized_human} = Relay.execution_allowed(issue)
        refute Orchestrator.should_dispatch_issue_for_test(issue, state)
        fetch = fn _ -> {:ok, [issue]} end
        assert {:skip, ^issue} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetch)
        assert {:error, :relay_requires_authorized_human} = IssueLease.run(issue, fn -> flunk("nonlocal assignee started") end)
        unassigned = %{issue | assigned_to_worker: false}
        assert {:error, :relay_requires_authorized_human} = Relay.execution_allowed(unassigned)
      end)

      memory = put_in(context.settings.tracker.kind, "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      ProjectContext.with_context(memory, fn ->
        assert {:error, :relay_requires_authorized_human} =
                 ScriptSupport.manual_prompt_context(Workflow.workflow_file_path(), "unused", "unused", issue.identifier, root)
      end)
    end

    # The verified local selection alone authorizes execution; contradictory
    # leftover OWNERS values cannot change routing or consumer identity.
    changed = %{context | assignee_ids: ["human"]}

    ProjectContext.with_context(changed, fn ->
      assert :ok = Relay.execution_allowed(issue)
      assert {:ok, ^issue} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn _ -> {:ok, [issue]} end)
    end)

    broken = put_in(changed.settings.tracker.relay["consumer_id"], "different")

    ProjectContext.with_context(broken, fn ->
      assert {:error, :relay_identity_change_requires_handoff} = Relay.execution_allowed(issue)
    end)
  end
end
