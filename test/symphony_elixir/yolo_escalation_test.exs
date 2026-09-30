defmodule SymphonyElixir.YoloEscalationTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.CommentVersion
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.Escalation
  alias SymphonyElixir.Yolo.Store

  @agent "b57e9f80-53ce-4d96-9180-370f03d60d16"
  @profile "https://linear.app/test/profiles/pai"

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

  defp opt_in(context) do
    tracker = %{context.settings.tracker | trusted_agent_ids: [@agent], escalation_trusted_agent_id: @agent}
    %{context | yolo_agent_id: @agent, settings: %{context.settings | tracker: tracker}, trusted_binding: CommentVersion.digest([tracker.app, tracker.trusted_agent_ids])}
  end

  defp recipient_query(context, change \\ & &1) do
    fn document, vars ->
      assert document =~ "YoloEscalationRecipient"
      assert vars.filter == %{"id" => %{"eq" => @agent}}
      user = %{"id" => @agent, "url" => @profile, "app" => true, "active" => true, "isMentionable" => true, "organization" => %{"id" => context.settings.tracker.app["workspace_id"]}}
      {:ok, %{"data" => %{"users" => %{"nodes" => [change.(user)], "pageInfo" => %{"hasNextPage" => false}}}}}
    end
  end

  test "trusted escalation addresses only the agent, removes only delegation and reconciles rendered mentions", %{context: context, issue: issue} do
    ProjectContext.bind(opt_in(context))
    Process.put(:agent_notes, [])

    options = [
      query: recipient_query(context),
      comments: fn _ -> {:ok, Process.get(:agent_notes)} end,
      escalation_comment: fn _, body ->
        assert body =~ @profile
        assert body =~ @agent
        refute body =~ "human"
        refute body =~ "Mensch"
        send(self(), :note_created)
        Process.put(:agent_notes, [%{body: String.replace(body, @profile, "[Pai](linear://userMention/#{@agent})")}])
        {:error, :response_lost}
      end
    ]

    update = fn _, input, _ ->
      assert input == %{delegateId: nil}
      :ok
    end

    assert :ok = Escalation.handover(issue, request(), options, update)
    assert_receive :note_created
    assert :ok = Escalation.handover(issue, request(), options, update)
    refute_receive :note_created

    [%{body: rendered}] = Process.get(:agent_notes)

    for mention <- [@profile, "[Pai](#{@profile})", "[Pai](linear://userMention/#{@agent})"] do
      body = String.replace(rendered, "[Pai](linear://userMention/#{@agent})", mention)
      Process.put(:agent_notes, [%{body: body}])
      assert :ok = Escalation.handover(issue, request(), options, update)
      refute_receive :note_created
    end

    assert {:ok, owner} = Escalation.owner(options)
    assert owner =~ @agent
    refute owner =~ @profile
    refute owner =~ "human"

    # A different question or recipient cannot acknowledge this proposal.
    changes = [
      fn body -> String.replace(body, @agent, "another-agent") end,
      fn body -> String.replace(body, "linear://userMention/#{@agent}", "linear://userMention/human") end,
      fn body -> String.replace(body, "[Pai](linear://userMention/#{@agent})", "") end,
      fn body -> String.replace(body, "[Pai](linear://userMention/#{@agent})", "[Pai](linear://userMention/#{@agent}) [Tilo](linear://userMention/human)") end,
      fn body -> String.replace(body, request()["escalation"]["decision"], "Andere Frage") end
    ]

    [note] = Process.get(:agent_notes)

    for change <- changes do
      Process.put(:agent_notes, [%{note | body: change.(note.body)}])
      unconfirmed = Keyword.put(options, :escalation_comment, fn _, _ -> :ok end)

      assert {:error, :yolo_escalation_comment_unconfirmed} =
               Escalation.handover(issue, request(), unconfirmed, fn _, _, _ -> flunk("unconfirmed note") end)
    end
  end

  test "an explicitly non-mentionable app is addressed by its verified UUID", %{context: context, issue: issue} do
    ProjectContext.bind(opt_in(context))
    query = recipient_query(context, &Map.merge(&1, %{"isMentionable" => false, "url" => nil}))

    options = [
      query: query,
      comments: fn _ -> {:ok, Process.get(:fallback_notes, [])} end,
      escalation_comment: fn _, body ->
        Process.put(:fallback_notes, [%{body: body}])
        :ok
      end
    ]

    assert :ok =
             Escalation.handover(issue, request(), options, fn _, input, _ ->
               assert input == %{delegateId: nil}
               :ok
             end)

    [%{body: body}] = Process.get(:fallback_notes)
    assert body =~ "Trusted Agent `#{@agent}`"
    refute body =~ @profile
    refute body =~ "human"

    changed = String.replace(body, "`#{@agent}`", "`#{@agent}` – [Tilo](linear://userMention/human)")
    Process.put(:fallback_notes, [%{body: changed}])
    unconfirmed = Keyword.put(options, :escalation_comment, fn _, _ -> :ok end)

    assert {:error, :yolo_escalation_comment_unconfirmed} =
             Escalation.handover(issue, request(), unconfirmed, fn _, _, _ -> flunk("unconfirmed fallback note") end)
  end

  test "unverified or changed trust binding fails before every escalation effect", %{context: context, issue: issue} do
    verified = opt_in(context)

    options = [
      query: fn _, _ -> flunk("unverified query") end,
      comments: fn _ -> flunk("unverified comments") end,
      escalation_route: fn _, _ -> flunk("unverified route") end,
      escalation_send: fn _, _, _ -> flunk("unverified send") end
    ]

    for invalid <- [%{verified | trusted_binding: nil}, put_in(verified.settings.tracker.app["workspace_id"], "foreign"), put_in(verified.settings.tracker.trusted_agent_ids, [])] do
      ProjectContext.bind(invalid)

      expected =
        if invalid.settings.tracker.trusted_agent_ids == [],
          do: :linear_escalation_trusted_agent_not_trusted,
          else: :linear_escalation_trusted_agent_unverified

      assert {:error, ^expected} = Escalation.handover(issue, request(), options, fn _, _, _ -> flunk("unverified mutation") end)
      assert {:error, ^expected} = Escalation.owner(options)
      assert {:error, ^expected} = Escalation.notify(issue, request(), options)
      assert {:error, ^expected} = Escalation.retry_pending(issue, options)
      assert {:error, ^expected} = Escalation.pending_routes(issue.id)
      assert {:error, ^expected} = Escalation.pending(issue.id)
    end
  end

  test "recipient resolution rejects humans, stale apps, foreign identity and malformed profile responses", %{context: context, issue: issue} do
    ProjectContext.bind(opt_in(context))

    for change <- [
          &Map.put(&1, "app", false),
          &Map.put(&1, "active", false),
          &put_in(&1, ["organization", "id"], "foreign"),
          &Map.put(&1, "id", "other"),
          &Map.put(&1, "url", nil),
          &Map.put(&1, "isMentionable", nil)
        ] do
      options = [query: recipient_query(context, change), comments: fn _ -> flunk("invalid recipient must not write") end]

      assert {:error, :linear_escalation_trusted_agent_unconfirmed} =
               Escalation.handover(issue, request(), options, fn _, _, _ -> flunk("invalid recipient update") end)
    end

    assert {:error, :offline} = Escalation.recipient(query: fn _, _ -> {:error, :offline} end)

    assert {:error, :yolo_response_incomplete} =
             Escalation.recipient(query: fn _, _ -> {:ok, %{"errors" => [%{"message" => "partial"}]}} end)
  end

  test "trusted opt-in suppresses configured OpenClaw and old pending messages without changing their journal", %{context: context, issue: issue} do
    context = %{context | yolo_agent_id: @agent}
    ProjectContext.bind(context)
    assert {:error, :route_missing} = Escalation.notify(issue, request(), escalation_route: fn _, _ -> {:error, :route_missing} end)
    assert {:ok, true} = Escalation.pending(issue.id)
    assert {:ok, before} = Store.read("escalation:" <> issue.id)
    ProjectContext.bind(opt_in(context))

    options = [
      query: fn _, _ -> flunk("suppression needs no profile access") end,
      escalation_route: fn _, _ -> flunk("suppressed route") end,
      escalation_send: fn _, _, _ -> flunk("suppressed send") end
    ]

    assert :ok = Escalation.notify(issue, request(), options)
    assert :ok = Escalation.retry_pending(issue, options)
    assert {:ok, false} = Escalation.pending(issue.id)
    assert {:ok, []} = Escalation.pending_routes(issue.id)
    assert {:ok, ^before} = Store.read("escalation:" <> issue.id)
    # A fresh escalation also writes no notification intent.
    fresh = %{issue | id: "fresh"}
    assert :ok = Escalation.notify(fresh, request(), options)
    assert {:ok, record} = Store.read("escalation:" <> fresh.id)
    refute Map.has_key?(record, "messages")
  end

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

  test "retrying one pending proposal leaves another proposal journalled", %{issue: issue} do
    missing = [escalation_route: fn _, _ -> {:error, :openclaw_normal_channel_unavailable} end]
    revised = put_in(request(), ["escalation", "decision"], "Andere Entscheidung")
    assert {:error, :openclaw_normal_channel_unavailable} = Escalation.notify(issue, request(), missing)
    assert {:error, :openclaw_normal_channel_unavailable} = Escalation.notify(issue, revised, missing)
    assert {:ok, routes} = Escalation.pending_routes(issue.id)
    assert length(routes) == 2
    [{first_id, _} | _] = routes

    send_message = fn destination, _, _ ->
      send(self(), {:sent, destination["idempotencyKey"]})
      {:ok, %{"messageId" => "confirmed"}}
    end

    opts = [escalation_route: &route/2, escalation_send: send_message]
    assert :ok = Escalation.retry_pending(issue, Keyword.put(opts, :notification_id, first_id))
    assert_receive {:sent, ^first_id}
    refute_receive {:sent, _}
    assert {:ok, [{other_id, _}]} = Escalation.pending_routes(issue.id)
    refute other_id == first_id
    assert :ok = Escalation.retry_pending(issue, Keyword.put(opts, :notification_id, other_id))
    assert_receive {:sent, ^other_id}
    assert {:ok, []} = Escalation.pending_routes(issue.id)
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

  test "handover requires a configured human and confirms the visible question", %{issue: issue, context: context} do
    no_update = fn _, _, _ -> flunk("unconfirmed note must not change assignment") end
    ProjectContext.bind(%{context | human_handoff_id: nil})
    assert {:error, :yolo_escalation_handoff_unconfirmed} = Escalation.handover(issue, request(), [], no_update)
    ProjectContext.bind(context)

    for {create_result, expected} <- [
          {:ok, :yolo_escalation_comment_unconfirmed},
          {{:error, :write_failed}, :write_failed}
        ] do
      opts = [comments: fn _ -> {:ok, []} end, escalation_comment: fn _, _ -> create_result end]
      assert {:error, ^expected} = Escalation.handover(issue, request(), opts, no_update)
    end

    Process.put(:comment_reads, 0)

    fetch = fn _ ->
      reads = Process.get(:comment_reads) + 1
      Process.put(:comment_reads, reads)
      if reads == 1, do: {:ok, []}, else: {:error, :read_failed}
    end

    assert {:error, :read_failed} =
             Escalation.handover(issue, request(), [comments: fetch, escalation_comment: fn _, _ -> :ok end], no_update)
  end
end
