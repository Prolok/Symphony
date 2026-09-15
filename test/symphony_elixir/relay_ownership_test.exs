defmodule SymphonyElixir.RelayOwnershipTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ScriptSupport
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.{ProjectContext, Relay}

  test "running workers stop when the current assignee belongs to another consumer" do
    root = Path.dirname(Workflow.workflow_file_path())
    relay = %{"consumer_id" => "one", "state_root" => Path.join(root, "running-owner"), "owners" => %{"human-a" => "one", "human-b" => "two"}}
    settings = put_in(Config.settings!().tracker.relay, relay)
    context = %ProjectContext{settings: settings}
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

  test "dispatch, retry refresh, leases and manual helpers obey the same owner even with yolo" do
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    relay = %{"consumer_id" => "observer", "state_root" => Path.join(root, "relay-owner"), "owners" => %{"human" => "executor"}}
    context = put_in(context.settings.tracker.relay, relay)
    issue = %Issue{id: "issue-owner", identifier: "PRO-716", title: "Owner", state: "In Arbeit (AI)", assignee_id: "human", assigned_to_worker: true}
    state = %Orchestrator.State{}

    for yolo <- [false, true] do
      Application.put_env(:symphony_elixir, :yolo, yolo)

      ProjectContext.with_context(context, fn ->
        assert {:error, :relay_other_executor} = Relay.execution_allowed(issue)
        refute Orchestrator.should_dispatch_issue_for_test(issue, state)
        fetch = fn _ -> {:ok, [issue]} end
        assert {:skip, ^issue} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fetch)
        assert {:error, :relay_other_executor} = IssueLease.run(issue, fn -> flunk("observer started") end)
        unassigned = %{issue | assigned_to_worker: false}
        assert {:error, :relay_requires_authorized_human} = Relay.execution_allowed(unassigned)
      end)

      memory = put_in(context.settings.tracker.kind, "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      ProjectContext.with_context(memory, fn ->
        assert {:error, :relay_other_executor} =
                 ScriptSupport.manual_prompt_context(Workflow.workflow_file_path(), "unused", "unused", issue.identifier, root)
      end)
    end

    # A coordinated owner change authorizes the new machine without changing the
    # human assignee or either machine's stable identity.
    changed = put_in(context.settings.tracker.relay["owners"], %{"human" => "observer"})

    ProjectContext.with_context(changed, fn ->
      assert :ok = Relay.execution_allowed(issue)
      assert {:ok, ^issue} = Orchestrator.revalidate_issue_for_dispatch_for_test(issue, fn _ -> {:ok, [issue]} end)
    end)

    broken = put_in(context.settings.tracker.relay["consumer_id"], "different")

    ProjectContext.with_context(broken, fn ->
      assert {:error, :relay_identity_change_requires_handoff} = Relay.execution_allowed(issue)
    end)
  end
end
