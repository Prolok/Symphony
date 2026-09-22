defmodule SymphonyElixir.YoloAdmissionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ProjectContext, Yolo.Admission}

  defp prepare(issue, opts \\ []), do: Admission.prepare(issue, Keyword.put_new(opts, :dependencies, &{:ok, &1}))

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(Path.dirname(Workflow.workflow_file_path()), Workflow.workflow_file_path(), %{})
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.yolo_agent, "Pai")
    ProjectContext.bind(context)

    node = %{
      "id" => Ecto.UUID.generate(),
      "identifier" => "PRO-1",
      "project" => %{"slugId" => "project"},
      "team" => %{"id" => "team"},
      "delegate" => %{"id" => "pai"}
    }

    issue = Client.relay_issue(node)
    %{context: context, issue: issue}
  end

  test "assigns first verified human and adds only missing labels, then retries without another write", %{issue: issue} do
    parent = self()
    {:ok, state} = Agent.start_link(fn -> issue end)
    labels = [~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")]

    query = fn document, variables ->
      if document =~ "SymphonyYoloLabels" do
        nodes = Enum.with_index(labels, fn name, i -> %{"id" => "label#{i}", "name" => name, "team" => nil} end)
        {:ok, %{"data" => %{"issueLabels" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}}
      else
        assert variables.input == %{assigneeId: "human", addedLabelIds: ["label0", "label1"]}
        send(parent, :write)
        Agent.update(state, &%{&1 | assignee_id: "human", assigned_to_worker: true, labels: ["existing" | Enum.map(labels, fn l -> String.downcase(l) end)]})
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => issue.id}}}}}
      end
    end

    opts = [query: query, fetch: fn _ -> {:ok, [Agent.get(state, & &1)]} end]
    assert {:ok, updated} = prepare(issue, opts)
    assert "existing" in updated.labels
    assert_receive :write
    assert {:ok, ^updated} = prepare(issue, opts)
    refute_receive :write
    Agent.stop(state)
  end

  test "withdrawal, foreign ownership and foreign project prevent writes", %{issue: issue} do
    foreign = %{issue | assignee_id: "foreign", assigned_to_worker: false}

    for changed <- [%{issue | delegate_id: nil}, foreign, %{issue | in_project_scope: false}] do
      opts = [fetch: fn _ -> {:ok, [changed]} end, query: fn _, _ -> flunk("unexpected write") end]
      assert {:error, :yolo_admission_changed} = prepare(issue, opts)
    end
  end

  test "missing, ambiguous and incomplete labels cannot claim admission", %{issue: issue} do
    for nodes <- [[], [%{"id" => "one", "name" => ~s(Skip "Freigabe Review"), "team" => nil}, %{"id" => "two", "name" => ~s(Skip "Freigabe Review"), "team" => nil}]] do
      query = fn _, _ -> {:ok, %{"data" => %{"issueLabels" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}} end
      opts = [fetch: fn _ -> {:ok, [issue]} end, query: query]
      assert {:error, :yolo_skip_labels_unavailable_or_ambiguous} = prepare(issue, opts)
    end

    opts = [fetch: fn _ -> {:ok, [issue]} end, query: fn _, _ -> {:ok, %{}} end]
    assert {:error, :yolo_labels_incomplete} = prepare(issue, opts)
  end

  test "labels beyond the candidate page are fully checked without redundant mutation", %{issue: issue} do
    issue = %{issue | labels: Enum.map(1..50, &"label#{&1}"), assignee_id: "human", assigned_to_worker: true}

    query = fn document, variables ->
      assert document =~ "SymphonyYoloIssueLabels"
      first = {[~s(Skip "Freigabe Implementierung")], true, "next"}
      second = {[~s(Skip "Freigabe Review")], false, nil}
      {names, more, cursor} = if variables.after, do: second, else: first
      {:ok, %{"data" => %{"issue" => %{"labels" => %{"nodes" => Enum.map(names, &%{"name" => &1}), "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}}}}}
    end

    opts = [fetch: fn _ -> {:ok, [issue]} end, query: query]
    assert {:ok, ready} = prepare(issue, opts)
    refute Admission.needed?(ready)
    assert {:ok, ^ready} = prepare(ready)

    incomplete = %{"data" => %{"issue" => %{"labels" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}}}}

    for result <- [{:error, :offline}, {:ok, %{}}, {:ok, incomplete}] do
      assert {:error, _} = prepare(issue, Keyword.put(opts, :query, fn _, _ -> result end))
    end
  end

  test "label pagination and failed writes retain unadmitted work", %{issue: issue} do
    labels = [~s(Skip "Freigabe Implementierung"), ~s(Skip "Freigabe Review")]

    for failure <- [{:error, :offline}, {:ok, %{"errors" => [%{"message" => "rejected"}]}}] do
      query = fn document, variables ->
        if document =~ "SymphonyYoloLabels" do
          second = not is_nil(variables.after)
          node = %{"id" => if(second, do: "second", else: "first"), "name" => Enum.at(labels, if(second, do: 1, else: 0))}
          {:ok, %{"data" => %{"issueLabels" => %{"nodes" => [node], "pageInfo" => %{"hasNextPage" => not second, "endCursor" => "next"}}}}}
        else
          failure
        end
      end

      assert {:error, _} = prepare(issue, fetch: fn _ -> {:ok, [issue]} end, query: query)
    end

    for response <- [{:error, :offline}, {:ok, %{"data" => %{"issueLabels" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true}}}}}] do
      assert {:error, _} = prepare(issue, fetch: fn _ -> {:ok, [issue]} end, query: fn _, _ -> response end)
    end
  end
end
