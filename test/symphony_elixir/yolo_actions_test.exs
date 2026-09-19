defmodule SymphonyElixir.YoloActionsTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.{ActionScope, ActionTool, Admission, API, Followup, GeneratedLabel, Handoff, Operations}
  alias SymphonyElixir.Yolo.{Completion, Coordinator, Group, Relations, Runner, Scope, Store}

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
        %Issue{
          id: "origin#{i}",
          identifier: "PRO-#{i}",
          title: "Requirement #{i}",
          description: "Original #{i}",
          url: "https://linear.app/test/#{i}",
          state: name,
          assignee_id: "human",
          delegate_id: "pai",
          assigned_to_worker: true,
          in_project_scope: true,
          project_context_id: context.id,
          workspace_id: context.settings.tracker.app["workspace_id"],
          project_id: "project",
          team_id: "team"
        }
      end

    Process.put(:action_db, %{
      issues: Map.new(issues, &{&1.id, &1}),
      created: %{},
      relations: [],
      labels: [%{"id" => "generated", "name" => "symphony-generated", "team" => %{"id" => "team"}}],
      calls: [],
      fail: nil,
      workpads: %{}
    })

    %{issues: issues, context: context, root: root}
  end

  defp db, do: Process.get(:action_db)
  defp change(fun), do: Process.put(:action_db, fun.(db()))
  defp connection(nodes), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}
  defp ok(field, value), do: {:ok, %{"data" => %{field => value}}}

  defp query(document, variables) do
    vars = Jason.decode!(Jason.encode!(variables))
    [_, name] = Regex.run(~r/(?:query|mutation) (\w+)/, document)
    change(&%{&1 | calls: &1.calls ++ [{name, vars}]})
    result = respond(name, document, vars)
    if db().fail == name, do: {:error, :response_lost}, else: result
  end

  defp respond("DeleteDerivedTestFixture", _, %{"id" => id}) do
    change(&%{&1 | created: Map.delete(&1.created, id)})
    ok("issueDelete", %{"success" => true})
  end

  defp respond("YoloStates", _, _), do: ok("team", %{"states" => connection(Enum.map(["Backlog", "Umsetzungsticket erstellt", "Todo (AI)"], &%{"id" => &1, "name" => &1}))})
  defp respond("YoloGeneratedLabel", _, _), do: ok("issueLabels", connection(db().labels))

  defp respond("YoloGeneratedLabelCreate", _, %{"input" => input}) do
    label = %{"id" => input["id"], "name" => input["name"], "team" => %{"id" => input["teamId"]}}
    change(&%{&1 | labels: [label]})
    ok("issueLabelCreate", %{"success" => true, "issueLabel" => label})
  end

  defp respond("YoloCreatedIssue", _, %{"id" => id}), do: ok("issues", connection(if(db().created[id], do: [db().created[id]], else: [])))

  defp respond("YoloCreatedLabels", _, %{"id" => id}), do: ok("issue", %{"labels" => connection(Enum.map(db().created[id]["labelIds"], &%{"id" => &1}))})

  defp respond("YoloCreate", _, %{"input" => input}) do
    refute Map.has_key?(db().created, input["id"]), "must reconcile a lost create response before another create"

    created =
      Map.merge(input, %{
        "state" => %{"id" => input["stateId"], "name" => input["stateId"]},
        "assignee" => if(input["assigneeId"], do: %{"id" => input["assigneeId"]}),
        "delegate" => if(input["delegateId"], do: %{"id" => input["delegateId"]}),
        "identifier" => "PRO-99",
        "url" => "https://linear.app/test/99",
        "team" => %{"id" => input["teamId"]},
        "project" => %{"id" => input["projectId"]}
      })

    change(&%{&1 | created: Map.put(&1.created, input["id"], created)})
    ok("issueCreate", %{"success" => true, "issue" => created})
  end

  defp respond("YoloRelations", document, %{"id" => id}) do
    inverse = String.contains?(document, "inverseRelations")
    nodes = Enum.filter(db().relations, &(get_in(&1, [if(inverse, do: "relatedIssue", else: "issue"), "id"]) == id))
    ok("issue", %{if(inverse, do: "inverseRelations", else: "relations") => connection(nodes)})
  end

  defp respond("YoloRelation", _, %{"input" => input}) do
    edge = %{"id" => input["id"], "type" => input["type"], "issue" => %{"id" => input["issueId"]}, "relatedIssue" => %{"id" => input["relatedIssueId"]}}
    change(&%{&1 | relations: &1.relations ++ [edge]})
    ok("issueRelationCreate", %{"success" => true, "issueRelation" => edge})
  end

  defp respond("YoloUpdate", _, %{"id" => id, "input" => input}) do
    issue = db().issues[id]

    if issue do
      updated =
        Enum.reduce(input, issue, fn
          {"stateId", value}, acc -> %{acc | state: value}
          {"assigneeId", value}, acc -> %{acc | assignee_id: value}
          {"delegateId", value}, acc -> %{acc | delegate_id: value}
        end)

      change(&%{&1 | issues: Map.put(&1.issues, id, updated)})
    end

    ok("issueUpdate", %{"success" => true, "issue" => %{"id" => id}})
  end

  defp opts do
    [
      query: &query/2,
      fetch: fn ids -> {:ok, Enum.flat_map(ids, fn id -> if db().issues[id], do: [db().issues[id]], else: [] end)} end,
      before_action: fn _ -> :ok end,
      comments: fn id -> {:ok, [%{id: "workpad", body: Map.get(db().workpads, id, "## Symphony Workpad\n\nExisting evidence")}]} end,
      workpad: fn id, body ->
        change(&%{&1 | workpads: Map.put(&1.workpads, id, body)})
        :ok
      end
    ]
  end

  defp args(issues, kind \\ "aggregate"),
    do: %{
      "kind" => kind,
      "origin_ids" => Enum.map(issues, & &1.id),
      "operation_key" => "finding-one",
      "title" => "Combined work",
      "description" => "Requirements",
      "validation" => "- [ ] Behaviour checked"
    }

  defp group(issues, fun), do: Scope.with_scope("incoming", issues, "run", fun)
  defp writes(name), do: Enum.filter(db().calls, &(elem(&1, 0) == name))
  defp relation(from, to), do: %{"id" => "#{from}:#{to}", "type" => "blocks", "issue" => %{"id" => from}, "relatedIssue" => %{"id" => to}}

  test "aggregation preserves requirements and both dependency directions independent of start mode", %{issues: issues} do
    change(&%{&1 | relations: [relation("predecessor", hd(issues).id), relation(List.last(issues).id, "successor"), relation(hd(issues).id, List.last(issues).id)]})

    group(issues, fn ->
      assert {:ok, created} = Followup.invoke(args(issues), opts())
      ticket = db().created[created["id"]]
      assert ticket["delegateId"] == "pai"
      assert ticket["assigneeId"] == "human"
      assert ticket["stateId"] == "Backlog"
      assert ticket["labelIds"] == ["generated"]
      for issue <- issues, do: assert(ticket["description"] =~ issue.description)
      assert Enum.all?(db().issues, fn {_, issue} -> issue.state == "Umsetzungsticket erstellt" end)
      assert Enum.any?(db().relations, &(get_in(&1, ["issue", "id"]) == "predecessor" and get_in(&1, ["relatedIssue", "id"]) == created["id"]))
      assert Enum.any?(db().relations, &(get_in(&1, ["issue", "id"]) == created["id"] and get_in(&1, ["relatedIssue", "id"]) == "successor"))
      assert {:ok, ^created} = Followup.invoke(args(issues), opts())
      assert length(writes("YoloCreate")) == 1
      assert length(writes("YoloRelation")) == 5
      assert {:ok, []} = Operations.pending(Enum.map(issues, & &1.id))
      assert {:error, {:yolo_existing_aggregation, _}} = Followup.invoke(args(tl(issues)), opts())
    end)
  end

  test "lost creation and relation responses recover the same issue without early origin closure", %{issues: issues} do
    group(issues, fn ->
      change(&%{&1 | fail: "YoloCreate"})
      assert {:error, :response_lost} = Followup.invoke(args(issues), opts())
      assert Enum.map(Map.values(db().issues), & &1.state) |> Enum.sort() == ["Backlog", "Definiert", "Todo"]
      change(&%{&1 | fail: "YoloRelation"})
      assert {:error, :response_lost} = Followup.invoke(args(issues), opts())
      assert writes("YoloUpdate") == []
      change(&%{&1 | fail: nil})
      assert {:ok, _} = Followup.invoke(args(issues), opts())
      assert length(writes("YoloCreate")) == 1
      assert length(writes("YoloRelation")) == 3
    end)
  end

  for prefix <- ["", "ordered-", "backslash-", "inline-link-"] do
    test "observed Linear #{prefix}markdown serialization permits one aggregation and derived cleanup", ctx do
      alias SymphonyElixir.TestRun.Derived
      issues = Enum.map(ctx.issues, &%{&1 | url: "https://linear.app/test/issue/#{&1.identifier}"})
      change(&%{&1 | issues: Map.new(issues, fn issue -> {issue.id, issue} end)})
      {plan, _} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")
      original = File.read!("test/fixtures/linear_markdown/#{unquote(prefix)}intent.md")
      returned = File.read!("test/fixtures/linear_markdown/#{unquote(prefix)}returned.md")
      request = %{args(issues) | "description" => original, "validation" => "Behaviour checked"}

      group(issues, fn ->
        change(&%{&1 | fail: "YoloCreate"})
        assert {:error, :response_lost} = Followup.invoke(request, opts())
        [{id, ticket}] = Map.to_list(db().created)
        normalized = String.replace(ticket["description"], original, returned)
        change(&%{&1 | fail: nil, created: %{id => Map.put(ticket, "description", normalized)}})
        assert {:ok, [pending]} = Derived.inspect_fixtures("probe", plan, opts())
        refute pending["complete"]
        assert writes("YoloUpdate") == []
        assert {:ok, created} = Followup.invoke(request, opts())
        assert created["id"] == id
        assert {:ok, [done]} = Derived.inspect_fixtures("probe", plan, opts())
        assert done["complete"]
        assert {:ok, [cleaned]} = Derived.inspect_fixtures("cleanup", plan, opts())
        assert cleaned["deleted"]
        assert length(writes("YoloCreate")) == 1
      end)
    end
  end

  for prefix <- ["backslash-", "inline-link-"], lost <- [false, true] do
    test "#{prefix}follow-up with lost reply=#{lost} completes creation, handoff and cleanup once", ctx do
      alias SymphonyElixir.TestRun.Derived
      source = %{hd(ctx.issues) | state: "Review", url: "https://linear.app/test/issue/PRO-0"}
      change(&%{&1 | issues: %{source.id => source}})
      {plan, _} = derived_run(ctx.context, ctx.root, [source], "po_followup", true)
      original = File.read!("test/fixtures/linear_markdown/#{unquote(prefix)}intent.md")
      returned = File.read!("test/fixtures/linear_markdown/#{unquote(prefix)}returned.md")
      request = %{args([source], "followup") | "description" => original, "validation" => "Requirements checked"}

      query = fn document, variables ->
        result = query(document, variables)

        if String.contains?(document, "mutation YoloCreate(") do
          change(fn db ->
            created = Map.new(db.created, fn {id, ticket} -> {id, Map.update!(ticket, "description", &String.replace(&1, original, returned))} end)
            %{db | created: created}
          end)
        end

        result
      end

      options = Keyword.put(opts(), :query, query)

      Scope.with_scope("review", [source], "run", fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"members" => [source.id]}))

        if unquote(lost) do
          change(&%{&1 | fail: "YoloCreate"})
          assert {:error, :response_lost} = Followup.invoke(request, options)
          assert {:error, :yolo_handoff_not_ready} = Handoff.invoke(%{"issue_id" => source.id, "report" => "Open fix"}, options)
          assert {:ok, [pending]} = Derived.inspect_fixtures("probe", plan, options)
          refute pending["complete"]
          change(&%{&1 | fail: nil})
        end

        assert {:ok, created} = Followup.invoke(request, options)
        assert db().created[created["id"]]["assignee"]["id"] == "human"
        assert db().created[created["id"]]["delegate"]["id"] == "pai"
        assert {:ok, [done]} = Derived.inspect_fixtures("probe", plan, options)
        assert done["complete"]
        assert :ok = Handoff.invoke(%{"issue_id" => source.id, "report" => "Geprüft; offener verknüpfter Fix #{created["identifier"]}"}, options)
        assert db().issues[source.id].state == "Review"
        assert db().issues[source.id].assignee_id == "human"
        assert db().issues[source.id].delegate_id == nil
        assert {:ok, [cleaned]} = Derived.inspect_fixtures("cleanup", plan, options)
        assert cleaned["deleted"]
        assert length(writes("YoloCreate")) == 1
        assert length(writes("DeleteDerivedTestFixture")) == 1
      end)
    end
  end

  for prefix <- ["backslash-", "inline-link-"] do
    test "changed #{prefix}requirements refuse creation confirmation, probe, handoff and cleanup", ctx do
      alias SymphonyElixir.TestRun.Derived
      source = %{hd(ctx.issues) | state: "Review", url: "https://linear.app/test/issue/PRO-0"}
      change(&%{&1 | issues: %{source.id => source}})
      {plan, _} = derived_run(ctx.context, ctx.root, [source], "po_followup", true)
      original = File.read!("test/fixtures/linear_markdown/#{unquote(prefix)}intent.md")
      returned = File.read!("test/fixtures/linear_markdown/#{unquote(prefix)}returned.md")
      request = %{args([source], "followup") | "description" => original, "validation" => "Requirements checked"}

      Scope.with_scope("review", [source], "run", fn ->
        change(&%{&1 | fail: "YoloCreate"})
        assert {:error, :response_lost} = Followup.invoke(request, opts())
        [{id, ticket}] = Map.to_list(db().created)
        serialized = String.replace(ticket["description"], original, returned)

        edits =
          if unquote(prefix) == "inline-link-" do
            [
              String.replace(serialized, "[Ursprung]", "[Anderer Auftrag]"),
              String.replace(serialized, "/PRO-807/", "/PRO-809/"),
              String.replace(serialized, "/prolok/", "/foreign/"),
              String.replace(serialized, "Follow-up: verified", "Follow-up: ignored")
            ]
          else
            [
              String.replace(serialized, "Python >=3.12", "Python >=3.13"),
              String.replace(serialized, ~S(bereit\\n), ~S(bereit\\t)),
              String.replace(serialized, ~S(bereit\\n), ~S(bereit\\\\n)),
              String.replace(serialized, "docs/README.md", "docs/OTHER.md"),
              String.replace(serialized, "prolok/issue/PRO-797/", "prolok/issue/PRO-799/")
            ]
          end

        for edited <- edits do
          change(&%{&1 | fail: nil, created: %{id => Map.put(ticket, "description", edited)}})
          assert {:error, :yolo_created_issue_changed} = Followup.invoke(request, opts())
          assert {:error, :test_derived_fixture_changed} = Derived.inspect_fixtures("probe", plan, opts())
          assert {:error, :test_derived_fixture_changed} = Derived.inspect_fixtures("cleanup", plan, opts())
          assert {:error, :yolo_handoff_not_ready} = Handoff.invoke(%{"issue_id" => source.id, "report" => "Open fix"}, opts())
        end

        assert writes("YoloUpdate") == []
        assert writes("YoloRelation") == []
        assert writes("DeleteDerivedTestFixture") == []
        assert length(writes("YoloCreate")) == 1
      end)
    end
  end

  test "restart after partial origin closure resumes the recorded aggregate from remaining members", %{issues: issues} do
    group(issues, fn ->
      change(&%{&1 | fail: "YoloUpdate"})
      assert {:error, :response_lost} = Followup.invoke(args(issues), opts())
    end)

    change(&%{&1 | fail: nil})
    group(tl(issues), fn -> assert {:ok, _} = Followup.invoke(args(issues), opts()) end)
    assert length(writes("YoloCreate")) == 1
  end

  test "scheduler recovers aggregation after the last origin update response is lost", %{issues: issues, root: root} do
    labels = [~s(skip "freigabe implementierung"), ~s(skip "freigabe review")]
    issues = Enum.map(issues, &%{&1 | labels: labels})
    change(&%{&1 | issues: Map.new(issues, fn issue -> {issue.id, issue} end)})
    last_id = List.last(issues).id

    query = fn document, variables ->
      result = query(document, variables)
      if String.contains?(document, "mutation YoloUpdate") and variables[:id] == last_id, do: {:error, :response_lost}, else: result
    end

    group(issues, fn ->
      assert {:error, :response_lost} = Followup.invoke(args(issues), Keyword.put(opts(), :query, query))
    end)

    assert Enum.all?(db().issues, fn {_, issue} -> issue.state == "Umsetzungsticket erstellt" end)
    [{target_id, _}] = Map.to_list(db().created)
    target = %{hd(issues) | id: target_id, state: "Backlog"}
    refute Operations.target_ready?(target_id)
    parent = self()

    options =
      Keyword.merge(opts(),
        scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
        start: fn "incoming", callback ->
          callback.()
          {:error, :fixture_finished}
        end,
        runner: fn "incoming", members, all ->
          assert Enum.sort(Enum.map(members, & &1.id)) == Enum.sort(Enum.map(issues, & &1.id))

          run_opts =
            Keyword.merge(opts(),
              lease: fn _, callback -> callback.() end,
              scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
              workspace: fn _, _ -> {:ok, %{path: root, sha: "sha"}} end,
              unchanged: fn _ -> true end,
              checkpoint: fn _ -> {:ok, %{}} end,
              session: fn _, _, _, _ ->
                assert {:ok, %{"id" => ^target_id}} = Followup.invoke(args(issues), opts())
                for member <- members, do: assert(:ok = Completion.invoke(%{"issue_id" => member.id, "result" => "Aggregation bestätigt"}, opts()))
                {:ok, %{session_id: "recovered"}}
              end
            )

          assert :ok = Runner.run("incoming", members, all, run_opts)
          send(parent, :aggregation_recovered)
        end
      )

    # A restarted poll contains only the new Backlog target, since all origins
    # have already left the candidate statuses.
    state = %Orchestrator.State{max_concurrent_agents: 1, codex_totals: %{}}
    blocked = Keyword.put(options, :start, fn _, _ -> flunk("changed or unavailable sources must not start recovery") end)
    closed = db().issues

    for update <- [fn issue -> %{issue | delegate_id: nil} end, fn issue -> %{issue | description: "human edit"} end] do
      change(&%{&1 | issues: Map.new(closed, fn {id, issue} -> {id, update.(issue)} end)})
      Coordinator.tick(state, [target], blocked)
    end

    change(&%{&1 | issues: closed})
    Coordinator.tick(state, [target], Keyword.put(blocked, :fetch, fn _ -> {:error, :offline} end))
    {:ok, record} = Store.read("incoming")
    :ok = Store.write("incoming", Map.put(record, "retry_at", System.system_time(:millisecond) + 30_000))
    Coordinator.tick(state, [target], Keyword.put(blocked, :fetch, fn _ -> flunk("retry cooldown") end))
    :ok = Store.write("incoming", record)
    Coordinator.tick(state, [target], options)
    assert_receive :aggregation_recovered
    assert Operations.target_ready?(target_id)
    assert length(writes("YoloCreate")) == 1
    assert length(writes("YoloRelation")) == 3
    assert length(writes("YoloUpdate")) == 3
    assert Group.groups(Map.values(db().issues)) == %{}
  end

  test "ordered-list edits block reconciliation and cleanup without closing origins", ctx do
    alias SymphonyElixir.TestRun.Derived
    {plan, _} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")
    original = File.read!("test/fixtures/linear_markdown/ordered-intent.md")
    returned = File.read!("test/fixtures/linear_markdown/ordered-returned.md")
    request = %{args(ctx.issues) | "description" => original}

    group(ctx.issues, fn ->
      change(&%{&1 | fail: "YoloCreate"})
      assert {:error, :response_lost} = Followup.invoke(request, opts())
      [{id, ticket}] = Map.to_list(db().created)
      normalized = String.replace(ticket["description"], original, returned)

      for edited <- [
            String.replace(normalized, "1. docs/", "2. docs/"),
            String.replace(normalized, "2. Die", "3. Die"),
            String.replace(normalized, "1. docs/", "1) docs/"),
            String.replace(normalized, "Keine Implementierung", "Implementierung"),
            String.replace(normalized, "docs/README.md", "docs/OTHER.md")
          ] do
        change(&%{&1 | fail: nil, created: %{id => Map.put(ticket, "description", edited)}})
        assert {:error, :yolo_created_issue_changed} = Followup.invoke(request, opts())
        assert {:error, :test_derived_fixture_changed} = Derived.inspect_fixtures("probe", plan, opts())
        assert {:error, :test_derived_fixture_changed} = Derived.inspect_fixtures("cleanup", plan, opts())
      end

      assert writes("YoloUpdate") == []
      assert writes("DeleteDerivedTestFixture") == []
      assert length(writes("YoloCreate")) == 1
      assert {:ok, [intent]} = Operations.pending(Enum.map(ctx.issues, & &1.id))
      refute intent["done"]
    end)
  end

  test "member completion refuses linked aggregation until the durable action finishes", %{issues: issues} do
    group(issues, fn ->
      {:ok, record} = Store.read("incoming")
      :ok = Store.write("incoming", Map.put(record, "attempt", %{"members" => Enum.map(issues, & &1.id)}))
      change(&%{&1 | fail: "YoloUpdate"})
      assert {:error, :response_lost} = Followup.invoke(args(issues), opts())
      assert length(writes("YoloCreate")) == 1
      assert length(writes("YoloRelation")) == 3
      assert {:ok, [intent]} = Operations.pending(Enum.map(issues, & &1.id))

      for issue <- issues do
        assert {:error, {:yolo_operations_pending, [key]}} = Completion.invoke(%{"issue_id" => issue.id, "result" => "linked"}, opts())
        assert key == intent["key"]
      end

      assert {:ok, record} = Store.read("incoming")
      refute record["attempt"]["completed"]
      change(&%{&1 | fail: nil})
      assert {:ok, _} = Followup.invoke(args(issues), opts())
      for issue <- issues, do: assert(:ok = Completion.invoke(%{"issue_id" => issue.id, "result" => "action confirmed"}, opts()))
      assert Completion.ready?("incoming", issues)
      assert length(writes("YoloCreate")) == 1
    end)
  end

  test "real edits still stop both action reconciliation and derived cleanup", ctx do
    alias SymphonyElixir.TestRun.Derived
    {plan, _} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")
    request = args(ctx.issues)

    group(ctx.issues, fn ->
      change(&%{&1 | fail: "YoloCreate"})
      assert {:error, :response_lost} = Followup.invoke(request, opts())
      [{id, ticket}] = Map.to_list(db().created)

      for key <- ~w(id title description project team assignee delegate state) do
        edit = if is_map(ticket[key]), do: %{"id" => "foreign"}, else: "foreign"
        change(&%{&1 | fail: nil, created: %{id => Map.put(ticket, key, edit)}})
        action_error = if key == "id", do: :yolo_created_issue_unconfirmed, else: :yolo_created_issue_changed
        derived_error = if key == "id", do: :yolo_created_issue_unconfirmed, else: :test_derived_fixture_changed
        assert {:error, ^action_error} = Followup.invoke(request, opts())
        assert {:error, ^derived_error} = Derived.inspect_fixtures("probe", plan, opts())
        assert {:error, ^derived_error} = Derived.inspect_fixtures("cleanup", plan, opts())
      end

      assert writes("YoloUpdate") == []
      assert writes("DeleteDerivedTestFixture") == []
      assert length(writes("YoloCreate")) == 1
      change(&%{&1 | created: %{id => ticket}})
      assert {:ok, [cleaned]} = Derived.inspect_fixtures("cleanup", plan, opts())
      assert cleaned["deleted"]
      assert {:ok, [intent]} = Operations.pending(Enum.map(ctx.issues, & &1.id))
      refute intent["done"]
    end)
  end

  test "follow-up assignment matrix is identical in regular and PO workers", %{issues: [issue | _], context: context} do
    for yolo <- [false, true], agent <- [nil, "pai"], po <- [false, true] do
      ProjectContext.bind(%{context | yolo_agent_id: agent, yolo: yolo})
      # Follow-ups in an ordinary active phase need only their bound source.
      source = %{issue | state: "In Arbeit (AI)", delegate_id: agent}
      change(&%{&1 | issues: %{source.id => source}})
      request = %{args([source], "followup") | "operation_key" => inspect({yolo, agent, po})}

      run = fn ->
        response = ActionTool.execute(request, opts())
        assert response["success"]
        id = Jason.decode!(response["output"])["issue"]["id"]
        created = db().created[id]
        assert created["delegateId"] == if(yolo and agent, do: agent)
        assert created["assigneeId"] == if(yolo and agent, do: "human")
        assert created["stateId"] == "Backlog"
      end

      if po and agent, do: group([source], run), else: WriteContext.with_context(%{issue_id: source.id}, run)
    end
  end

  test "cycle after aggregation refuses relation writes and preserves origins", %{issues: [first, second | _]} do
    change(&%{&1 | relations: [relation(first.id, "middle"), relation("middle", second.id)]})
    group([first, second], fn -> assert {:error, :yolo_dependency_cycle} = Followup.invoke(args([first, second]), opts()) end)
    assert writes("YoloRelation") == []
    assert writes("YoloUpdate") == []
  end

  test "generated label creation is reconciled, ambiguity and incomplete reads fail closed" do
    change(&%{&1 | labels: [], fail: "YoloGeneratedLabelCreate"})
    assert {:error, :response_lost} = GeneratedLabel.resolve("team", opts())
    change(&%{&1 | fail: nil})
    assert {:ok, id} = GeneratedLabel.resolve("team", opts())
    assert Ecto.UUID.cast(id) == {:ok, id}
    assert length(writes("YoloGeneratedLabelCreate")) == 1
    change(&%{&1 | labels: &1.labels ++ [%{"id" => "duplicate", "team" => nil}]})
    assert {:error, :yolo_generated_label_ambiguous} = GeneratedLabel.resolve("team", opts())
    assert {:error, :yolo_response_incomplete} = API.query("query", %{}, query: fn _, _ -> {:ok, %{"errors" => [%{"message" => "rate limit"}]}} end)
    assert {:error, :offline} = API.query("query", %{}, query: fn _, _ -> {:error, :offline} end)
  end

  test "handoff keeps Review/BLOCKER, preserves workpad and stops agent ownership", %{issues: [issue | _]} do
    for state <- ["Review", "BLOCKER"] do
      source = %{issue | state: state}
      change(&%{&1 | issues: %{source.id => source}})

      group([source], fn ->
        {:ok, record} = Store.read("incoming")
        :ok = Store.write("incoming", Map.put(record, "attempt", %{"members" => [source.id]}))
        assert :ok = Handoff.invoke(%{"issue_id" => source.id, "report" => "Tests checked; open fix PRO-99."}, opts())
      end)

      assert db().issues[source.id].delegate_id == nil
      assert db().issues[source.id].assignee_id == "human"
      assert db().issues[source.id].state == state
      assert db().workpads[source.id] =~ "Existing evidence"
      assert db().workpads[source.id] =~ "open fix PRO-99"
    end
  end

  test "pending creations, new comments and withdrawn ownership block handoff", %{issues: [issue | _]} do
    issue = %{issue | state: "Review"}
    change(&%{&1 | issues: %{issue.id => issue}})

    group([issue], fn ->
      assert {:error, :new_input} = Handoff.invoke(%{"issue_id" => issue.id, "report" => "checked"}, Keyword.put(opts(), :before_action, fn _ -> {:error, :new_input} end))
      assert :ok = Operations.run("pending", args([issue], "followup"), fn _ -> :ok end)
      assert {:error, :yolo_handoff_not_ready} = Handoff.invoke(%{"issue_id" => issue.id, "report" => "checked"}, opts())
      assert writes("YoloUpdate") == []
      change(&%{&1 | issues: %{issue.id => %{issue | delegate_id: nil}}})
      assert {:error, :yolo_action_scope_changed} = ActionScope.sources([issue.id], opts())
    end)

    assert {:error, :yolo_action_scope_changed} = ActionScope.sources([issue.id], opts())
    assert {:error, :invalid_yolo_handoff} = Handoff.invoke(%{}, opts())
    assert {:error, :invalid_yolo_followup} = Followup.invoke(%{}, opts())
    refute ActionTool.execute(%{})["success"]
    assert ActionTool.mcp_call(%{})["isError"]
  end

  test "operation identity cannot change after intent and corrupt journals never become empty", %{issues: issues} do
    assert :ok = Operations.run("fixed", args(issues), fn _ -> :ok end)
    assert {:error, :yolo_operation_changed_or_corrupt} = Operations.run("fixed", %{}, fn _ -> flunk("changed") end)
    File.write!(Operations.path("fixed"), "broken")
    assert {:error, :yolo_operation_changed_or_corrupt} = Operations.pending(Enum.map(issues, & &1.id))

    for issue <- issues do
      assert Group.name(%{issue | state: "Umsetzungsticket erstellt"}) == nil
    end
  end

  test "incomplete lookup and write answers cannot confirm an issue, label, state or relation" do
    incomplete = [query: fn _, _ -> {:ok, %{"data" => %{}}} end]
    offline = [query: fn _, _ -> {:error, :offline} end]
    assert {:error, :yolo_created_issue_unconfirmed} = API.issue("id", incomplete)
    assert {:error, :offline} = API.issue("id", offline)
    assert {:error, :yolo_created_issue_unconfirmed} = API.issue("id", query: fn _, _ -> ok("issues", connection([%{"id" => "wrong"}])) end)
    assert {:error, :yolo_write_unconfirmed} = API.update("id", %{}, incomplete)
    assert {:error, :offline} = API.update("id", %{}, offline)
    assert {:error, :yolo_page_incomplete} = API.state("team", "Backlog", incomplete)
    assert {:error, {:yolo_state_unavailable, "Missing"}} = API.state("team", "Missing", opts())
    assert {:error, :offline} = GeneratedLabel.resolve("team", offline)
    assert {:error, :offline} = API.pages("query", %{}, ["items"], offline)
    assert {:error, :offline} = Relations.transfer(["source"], "target", offline)
    assert {:error, :offline} = Relations.validate([Relations.edge("a", "b", "blocks")], offline)
    assert {:error, :offline} = Relations.ensure(Relations.edge("a", "b", "related"), offline)
  end

  test "dependency traversal handles diamonds and treats related links as symmetric" do
    edges = [relation("b", "c"), relation("b", "d"), relation("c", "e"), relation("d", "e"), relation("e", "b")]
    change(&%{&1 | relations: edges})
    assert :ok = Relations.validate([Relations.edge("a", "b", "blocks")], opts())
    assert :ok = Relations.ensure(Relations.edge("a", "b", "related"), opts())
    assert :ok = Relations.ensure(Relations.edge("b", "a", "related"), opts())
    assert length(writes("YoloRelation")) == 1
  end

  test "changed source and ambiguous generated labels prevent creation", %{issues: [issue | _] = issues} do
    group(issues, fn ->
      assert {:error, :invalid_yolo_followup} = Followup.invoke(%{args(issues) | "title" => ""}, opts())
      assert {:error, :invalid_yolo_followup} = Followup.invoke(Map.put(args(issues), "blocked_by", 1), opts())
      assert {:error, :offline} = Followup.invoke(args(issues), Keyword.put(opts(), :fetch, fn _ -> {:error, :offline} end))
      assert {:error, :offline} = Followup.invoke(args(issues), Keyword.put(opts(), :query, fn _, _ -> {:error, :offline} end))
      change(&%{&1 | fail: "YoloCreate"})
      assert {:error, :response_lost} = Followup.invoke(args(issues), opts())
      change(&%{&1 | fail: nil, issues: Map.put(&1.issues, issue.id, %{issue | description: "human edit"})})
      assert {:error, :yolo_followup_sources_changed} = Followup.invoke(args(issues), opts())
      assert writes("YoloUpdate") == []
      change(&%{&1 | issues: Map.put(&1.issues, issue.id, issue)})
      change(&%{&1 | created: Map.new(&1.created, fn {id, node} -> {id, Map.put(node, "title", "external edit")} end)})
      assert {:error, :yolo_created_issue_changed} = Followup.invoke(args(issues), opts())
      assert length(writes("YoloCreate")) == 1
      current_context = ProjectContext.current()
      ProjectContext.bind(%{current_context | test_instance: %{}})
      System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")

      try do
        assert {:error, :invalid_yolo_followup} = Followup.invoke(args(issues), opts())
      after
        System.delete_env("SYMPHONY_TEST_RUN_STAGE")
        ProjectContext.bind(current_context)
      end
    end)
  end

  test "late source changes and comment errors stop relations and final closure", %{issues: issues} do
    for boundary <- ["YoloCreate", "YoloRelation"] do
      request = Map.put(args(issues, "followup"), "operation_key", boundary)

      check = fn _ ->
        if writes(boundary) != [], do: {:error, :new_comment}, else: :ok
      end

      group(issues, fn ->
        assert {:error, :new_comment} = Followup.invoke(request, Keyword.put(opts(), :before_action, check))
      end)
    end

    assert writes("YoloUpdate") == []
  end

  test "partial aggregation cannot resume from unowned or externally changed origins", %{issues: issues} do
    group(issues, fn ->
      change(&%{&1 | fail: "YoloUpdate"})
      assert {:error, :response_lost} = Followup.invoke(args(issues), opts())
    end)

    change(&%{&1 | fail: nil})

    group(tl(issues), fn ->
      assert {:error, :offline} = Followup.invoke(args(issues), Keyword.put(opts(), :fetch, fn _ -> {:error, :offline} end))
      first = hd(issues)
      change(&%{&1 | issues: Map.put(&1.issues, first.id, first)})
      assert {:error, :yolo_aggregation_resume_scope_changed} = Followup.invoke(args(issues), opts())
    end)
  end

  test "handoff records no success on lost update, missing report or state changes", %{issues: [issue | _]} do
    issue = %{issue | state: "Review"}
    change(&%{&1 | issues: %{issue.id => issue}})

    group([issue], fn ->
      request = %{"kind" => "handoff", "issue_id" => issue.id, "report" => "actual evidence"}
      assert {:error, :yolo_handoff_not_ready} = Handoff.invoke(%{request | "report" => " "}, opts())
      assert {:error, :offline} = Handoff.invoke(request, Keyword.put(opts(), :comments, fn _ -> {:error, :offline} end))
      change(&%{&1 | fail: "YoloUpdate"})
      assert {:error, :response_lost} = Handoff.invoke(request, opts())
      change(&%{&1 | fail: nil, issues: %{issue.id => issue}})
      {:ok, record} = Store.read("incoming")
      :ok = Store.write("incoming", Map.put(record, "attempt", %{"members" => [issue.id]}))
      assert ActionTool.execute(request, opts())["success"]
      # Same report is already in the workpad; a retry must not duplicate it.
      change(&%{&1 | issues: %{issue.id => issue}})
      assert :ok = Handoff.invoke(request, opts())
      assert length(String.split(db().workpads[issue.id], "### YOLO-Übergabe")) == 2
    end)

    assert :ok = Operations.run("empty", %{}, fn intent -> Operations.save(Map.put(intent, "done", true)) end)
  end

  test "missing human configuration and incomplete post-create reads never claim success", %{issues: [issue | _], context: context} do
    source = %{issue | state: "In Arbeit (AI)"}
    change(&%{&1 | issues: %{source.id => source}})
    ProjectContext.bind(%{context | yolo: true, human_handoff_id: nil})

    WriteContext.with_context(%{issue_id: source.id}, fn ->
      assert {:error, :yolo_human_unavailable} = Followup.invoke(args([source], "followup"), opts())
    end)

    ProjectContext.bind(context)

    group([source], fn ->
      query = fn document, variables ->
        if String.contains?(document, "query YoloCreatedIssue"), do: ok("issues", connection([])), else: query(document, variables)
      end

      assert {:error, :yolo_created_issue_unconfirmed} = Followup.invoke(args([source], "followup"), Keyword.put(opts(), :query, query))
    end)
  end

  test "human edits during creation and the last link are retained for a new decision", %{issues: issues} do
    group(issues, fn ->
      for boundary <- ["mutation YoloCreate", "mutation YoloRelation"] do
        request = %{args([hd(issues)], "followup") | "operation_key" => boundary}
        change(&%{&1 | issues: Map.new(issues, fn i -> {i.id, i} end)})

        query = fn document, variables ->
          result = query(document, variables)

          if String.contains?(document, boundary) do
            first = hd(issues)
            change(&%{&1 | issues: Map.put(&1.issues, first.id, %{first | description: "changed during remote action"})})
          end

          result
        end

        assert {:error, :yolo_followup_sources_changed} = Followup.invoke(request, Keyword.put(opts(), :query, query))
      end
    end)

    assert writes("YoloUpdate") == []
  end

  test "unfinished creation cannot enter PO admission and external BLOCKER can hand it to a human", %{issues: [issue | _]} do
    issue = %{issue | state: "BLOCKER"}
    change(&%{&1 | issues: %{issue.id => issue}})

    assert :ok =
             Operations.run("pending", args([issue], "followup"), fn intent ->
               child = %{issue | id: intent["issue_id"], state: "Backlog"}
               refute Admission.eligible?(child)
               :ok
             end)

    group([issue], fn ->
      {:ok, record} = Store.read("incoming")
      :ok = Store.write("incoming", Map.put(record, "attempt", %{"members" => [issue.id]}))
      assert :ok = Handoff.invoke(%{"issue_id" => issue.id, "report" => "Externer Zugriff fehlt; Anlage muss durch den Betreiber abgeglichen werden."}, opts())
    end)

    assert db().issues[issue.id].state == "BLOCKER"
    assert db().issues[issue.id].delegate_id == nil
    assert db().workpads[issue.id] =~ "pending"
    assert {:ok, [_]} = Operations.pending([issue.id])
  end

  test "generated label must be confirmed before origin closure", %{issues: issues} do
    group(issues, fn ->
      query = fn document, variables ->
        result = query(document, variables)
        if String.contains?(document, "YoloCreate("), do: change(&%{&1 | created: Map.new(&1.created, fn {id, ticket} -> {id, Map.put(ticket, "labelIds", [])} end)})
        result
      end

      assert {:error, :yolo_created_issue_changed} = Followup.invoke(args(issues), Keyword.put(opts(), :query, query))
      assert writes("YoloUpdate") == []
    end)
  end

  defp derived_run(context, root, issues, scenario, yolo \\ false) do
    alias SymphonyElixir.Linear.DurableState
    state = Path.join(root, "test-run-state")
    source = %{"sha" => "fixture-sha", "source_sha256" => "fixture-source"}
    instance = %{"name" => "dev", "source" => source, "manifest" => %{"projects" => %{"symphony-test" => %{"project_id" => "project"}}}}
    context = %{context | name: "symphony-test", test_instance: instance, yolo: yolo}
    ProjectContext.bind(context)
    Application.put_env(:symphony_elixir, :test_instance_state_root, state)
    Application.put_env(:symphony_elixir, :project_contexts, [context])
    path = Path.join(root, "test-plan.json")
    plan = %{"run_id" => "derived-proof", "evidence" => "live", "instance" => "dev", "source" => source, "scenario" => scenario, "yolo" => yolo}
    :ok = DurableState.write(path, plan)
    System.put_env("SYMPHONY_TEST_RUN_PLAN", path)
    System.put_env("SYMPHONY_TEST_RUN_STAGE", "run")

    binding = %{
      "root" => context.root,
      "workspace_root" => context.settings.workspace.root,
      "app" => Map.take(context.settings.tracker.app, ~w(workspace_id client_id user_id)),
      "project" => instance["manifest"]["projects"][context.name]
    }

    journal = %{
      "run_id" => plan["run_id"],
      "source" => source,
      "scenario" => scenario,
      "owner" => %{"instance" => "dev", "plan_path" => path},
      "binding" => %{context.name => binding},
      "fixtures" =>
        Enum.map(
          issues,
          &%{"id" => &1.id, "project" => context.name, "po_aggregation" => scenario == "po_aggregation", "po_followup" => scenario == "po_followup", "created" => true, "deleted" => false}
        )
    }

    journal_path = Path.join([state, "runs", plan["run_id"], "fixtures.json"])
    :ok = DurableState.write(journal_path, journal)
    {_, 0} = System.cmd("git", ["init", "-q", context.root])

    on_exit(fn ->
      System.delete_env("SYMPHONY_TEST_RUN_PLAN")
      System.delete_env("SYMPHONY_TEST_RUN_STAGE")
      Application.delete_env(:symphony_elixir, :test_instance_state_root)
      Application.delete_env(:symphony_elixir, :project_contexts)
    end)

    {plan, journal_path}
  end

  test "real action path journals derived fixtures before creation and cleans lost replies safely", ctx do
    alias SymphonyElixir.TestRun.Derived
    {plan, _} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")

    group(ctx.issues, fn ->
      change(&%{&1 | fail: "YoloCreate"})
      assert {:error, :response_lost} = Followup.invoke(args(ctx.issues), opts())
      assert {:ok, [pending]} = Derived.inspect_fixtures("probe", plan, opts())
      refute pending["complete"]
      id = pending["input"]["id"]
      refute Operations.target_ready?(id)
      change(&%{&1 | fail: nil})
      assert {:ok, created} = Followup.invoke(args(ctx.issues), opts())
      assert created["id"] == id
      assert Operations.target_ready?(id)
      assert {:ok, [done]} = Derived.inspect_fixtures("probe", plan, opts())
      assert done["complete"]
      assert length(done["relations"]) == 3
      assert {:ok, [cleaned]} = Derived.inspect_fixtures("cleanup", plan, opts())
      assert cleaned["deleted"]
      assert {:ok, [^cleaned]} = Derived.inspect_fixtures("cleanup", plan, opts())
      assert db().created == %{}
      assert length(writes("YoloCreate")) == 1
    end)
  end

  test "derived follow-up assignment follows bound start mode and never authorizes child starts", ctx do
    alias SymphonyElixir.TestRun.Derived
    [issue | _] = ctx.issues
    {plan, _} = derived_run(ctx.context, ctx.root, [issue], "po_followup", true)

    group([issue], fn ->
      assert {:ok, created} = Followup.invoke(args([issue], "followup"), opts())
      assert db().created[created["id"]]["delegateId"] == "pai"
      assert db().created[created["id"]]["assigneeId"] == "human"
      assert {:ok, [receipt]} = Derived.inspect_fixtures("probe", plan, opts())
      assert receipt["complete"]
      refute SymphonyElixir.TestRun.start_allowed?(%{issue | id: created["id"], state: "Backlog"})
      assert {:error, :test_derived_fixture_changed} = Followup.invoke(%{args([issue], "followup") | "operation_key" => "second"}, opts())
    end)
  end

  test "derived scope rejects foreign origins, mode, binding, corrupt state and a second intent", ctx do
    alias SymphonyElixir.Linear.DurableState
    alias SymphonyElixir.TestRun.Derived
    {plan, path} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")
    request = args(ctx.issues)
    assert Derived.allowed?(request)
    refute Derived.allowed?(%{request | "origin_ids" => ["foreign"]})
    refute Derived.allowed?(Map.put(request, "blocked_by", ["foreign"]))
    refute Derived.allowed?(%{request | "kind" => "followup"})
    {:ok, journal} = DurableState.read(path)

    for changed <- [%{journal | "source" => %{}}, %{journal | "binding" => %{}}, %{journal | "fixtures" => nil}] do
      :ok = DurableState.write(path, changed)
      refute Derived.allowed?(request)
    end

    :ok = DurableState.write(path, journal)
    :ok = DurableState.write(Config.test_run_plan(), Map.put(plan, "yolo", true))
    refute Derived.allowed?(request)
    :ok = DurableState.write(Config.test_run_plan(), plan)
    File.write!(path, "corrupt")
    assert {:error, :test_derived_outside_scope} = Derived.register(%{"request" => request})
    assert {:ok, []} = Derived.inspect_fixtures("probe", plan, opts())
  end

  test "derived cleanup preserves changed tickets, unexpected workspaces and failed deletions", ctx do
    alias SymphonyElixir.TestRun.Derived
    {plan, _} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")
    group(ctx.issues, fn -> assert {:ok, _} = Followup.invoke(args(ctx.issues), opts()) end)
    [{id, ticket}] = Map.to_list(db().created)
    change(&%{&1 | created: %{id => Map.put(ticket, "title", "human edit")}})
    assert {:error, :test_derived_fixture_changed} = Derived.inspect_fixtures("cleanup", plan, opts())
    change(&%{&1 | created: %{id => ticket}})
    workspace = Path.join(ProjectContext.current().settings.workspace.root, ticket["identifier"])
    File.mkdir_p!(workspace)
    assert {:error, :test_derived_cleanup_unconfirmed} = Derived.inspect_fixtures("cleanup", plan, opts())
    File.rmdir!(workspace)
    change(&%{&1 | fail: "DeleteDerivedTestFixture"})
    assert {:error, :response_lost} = Derived.inspect_fixtures("cleanup", plan, opts())
    change(&%{&1 | fail: nil})
    assert {:ok, [receipt]} = Derived.inspect_fixtures("cleanup", plan, opts())
    assert receipt["deleted"]
  end

  test "missing or corrupt derived receipts never authorize cleanup or become successful probes", ctx do
    alias SymphonyElixir.Linear.DurableState
    alias SymphonyElixir.TestRun.Derived
    {plan, _} = derived_run(ctx.context, ctx.root, ctx.issues, "po_aggregation")
    group(ctx.issues, fn -> assert {:ok, _} = Followup.invoke(args(ctx.issues), opts()) end)
    [path] = Path.wildcard(Path.join([ctx.root, "test-run-state", "runs", plan["run_id"], "derived", "*.json"]))
    {:ok, receipt} = DurableState.read(path)
    {:ok, intent} = DurableState.read(Operations.path(receipt["key"]))
    File.write!(path, "corrupt")
    assert {:error, :test_derived_fixture_changed} = Derived.register(intent)
    assert {:error, _} = Derived.inspect_fixtures("cleanup", plan, opts())

    for altered <- [Map.put(receipt, "source", %{}), Map.put(receipt, "project", "foreign"), Map.put(receipt, "origins", ["foreign"])] do
      :ok = DurableState.write(path, altered)
      assert {:error, :test_derived_fixture_changed} = Derived.inspect_fixtures("cleanup", plan, opts())
    end

    :ok = DurableState.write(path, receipt)
    offline = Keyword.put(opts(), :query, fn _, _ -> {:error, :offline} end)
    assert {:error, :offline} = Derived.inspect_fixtures("probe", plan, offline)
    change(&%{&1 | created: %{}})
    assert {:ok, [missing]} = Derived.inspect_fixtures("probe", plan, opts())
    refute missing["complete"]
    File.write!(Operations.path(receipt["key"]), "corrupt")
    refute Operations.target_ready?(receipt["input"]["id"])
    assert {:error, _} = Derived.inspect_fixtures("cleanup", plan, opts())
    assert writes("DeleteDerivedTestFixture") == []
  end

  test "incomplete label verification cannot close origins or release a generated target", %{issues: issues} do
    group(issues, fn ->
      query = fn document, variables ->
        if String.contains?(document, "query YoloCreatedLabels"), do: {:error, :rate_limited}, else: query(document, variables)
      end

      assert {:error, :rate_limited} = Followup.invoke(args(issues), Keyword.put(opts(), :query, query))
      [{id, _}] = Map.to_list(db().created)
      refute Operations.target_ready?(id)
      assert writes("YoloUpdate") == []
      assert writes("YoloRelation") == []
    end)
  end

  test "complete pagination follows cursors and rejects a repeated or missing cursor" do
    query = fn _, vars ->
      if vars[:after] == nil,
        do: ok("items", %{"nodes" => [%{"id" => "one"}], "pageInfo" => %{"hasNextPage" => true, "endCursor" => "next"}}),
        else: ok("items", connection([%{"id" => "two"}]))
    end

    assert {:ok, [%{"id" => "one"}, %{"id" => "two"}]} = API.pages("query", %{}, ["items"], query: query)

    for info <- [%{"hasNextPage" => true}, %{"hasNextPage" => true, "endCursor" => "repeat"}] do
      assert {:error, :yolo_page_incomplete} = API.pages("query", %{}, ["items"], query: fn _, _ -> ok("items", %{"nodes" => [], "pageInfo" => info}) end)
    end

    assert {:error, :yolo_page_incomplete} = API.pages("query", %{}, ["items"], query: fn _, _ -> ok("items", nil) end)
  end
end
