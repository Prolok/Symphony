defmodule SymphonyElixir.YoloEscalationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.Escalation
  alias SymphonyElixir.Yolo.Store

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    context = put_in(context.settings.tracker.openclaw_yolo_agent, "po")
    ProjectContext.bind(context)
    %{context: context, issue: %{id: "issue", identifier: "PRO-1", url: "https://linear.app/test/PRO-1"}}
  end

  defp request do
    %{
      "escalation" => %{
        "cause" => "Testumgebung fehlt",
        "attempts" => "Lokale Prüfungen bestanden",
        "proposal" => "Freigegebenen Testexecutor bereitstellen",
        "decision" => "Diesen konkreten Bereitstellungsschritt mit OK bestätigen"
      }
    }
  end

  defp route("po", _), do: {:ok, %{"sessionKey" => "agent:po:main", "channel" => "signal", "to" => "approved-human"}}

  test "a proposal uses the normal target once across restart and preserves its correlation", %{issue: issue} do
    send = fn destination, message, _ ->
      assert destination["to"] == "approved-human"
      assert destination["sessionKey"] == "agent:po:main"
      assert message =~ issue.url
      for key <- ~w(cause attempts decision), do: assert(message =~ request()["escalation"][key])
      assert message =~ destination["idempotencyKey"]
      send(self(), {:notification, destination["idempotencyKey"]})
      {:ok, %{"messageId" => "message-1", "channel" => "signal"}}
    end

    opts = [escalation_route: &route/2, escalation_send: send]
    assert :ok = Escalation.notify(issue, request(), opts)
    assert_receive {:notification, original}
    for _ <- 1..3, do: assert(:ok = Escalation.notify(issue, request(), opts))
    refute_receive {:notification, _}
    changed = put_in(request(), ["escalation", "proposal"], "Anderen konkret freigegebenen Teststand bereitstellen")
    assert :ok = Escalation.notify(issue, changed, opts)
    assert_receive {:notification, different}
    refute original == different
  end

  test "unknown send remains reserved and does not resubmit after a lost response", %{issue: issue} do
    opts = [
      escalation_route: &route/2,
      escalation_send: fn _, _, _ ->
        send(self(), :send)
        {:error, :response_lost}
      end
    ]

    assert {:error, :yolo_escalation_delivery_unconfirmed} = Escalation.notify(issue, request(), opts)
    assert_receive :send
    assert {:error, :yolo_escalation_delivery_unconfirmed} = Escalation.notify(issue, request(), opts)
    refute_receive :send
  end

  test "missing target and incomplete proposals do not send; disabled OpenClaw has no access", %{issue: issue, context: context} do
    opts = [escalation_route: fn _, _ -> {:error, :missing_target} end, escalation_send: fn _, _, _ -> flunk("unexpected send") end]
    assert {:error, :missing_target} = Escalation.notify(issue, request(), opts)
    assert {:ok, true} = Escalation.pending(issue.id)
    assert {:error, :missing_target} = Escalation.retry_pending(issue, opts)

    send = fn _, _, _ ->
      send(self(), :route_repaired)
      {:ok, %{"messageId" => "repair-1", "channel" => "signal"}}
    end

    assert :ok = Escalation.retry_pending(issue, escalation_route: &route/2, escalation_send: send)
    assert_receive :route_repaired
    assert {:ok, false} = Escalation.pending(issue.id)
    assert :ok = Escalation.retry_pending(issue, escalation_route: &route/2, escalation_send: send)
    refute_receive :route_repaired
    assert {:error, :yolo_escalation_incomplete} = Escalation.notify(issue, %{}, opts)
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_yolo_agent, nil))
    assert :ok = Escalation.notify(issue, request(), escalation_route: fn _, _ -> flunk("disabled access") end)
    assert {:error, :openclaw_yolo_agent_unavailable} = Escalation.retry_pending(issue)
  end

  test "corrupt notification journal stays visible", %{issue: issue} do
    key = "escalation:" <> issue.id
    {:ok, record} = Store.read(key)
    :ok = Store.write(key, Map.put(record, "messages", []))
    assert {:error, :yolo_escalation_journal_corrupt} = Escalation.pending(issue.id)
    assert {:error, :yolo_escalation_journal_corrupt} = Escalation.retry_pending(issue)
  end
end
