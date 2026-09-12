defmodule SymphonyElixir.ProjectContractsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.LocalState
  alias SymphonyElixir.{ProjectContext, ProjectSelection}

  setup do
    root = Path.dirname(Workflow.workflow_file_path())

    contexts =
      for name <- ["One", "Two"] do
        project = Path.join(root, name)
        File.mkdir_p!(Path.join(project, ".symphony"))
        File.write!(Path.join(project, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
        {:ok, context} = ProjectContext.load(project, Workflow.workflow_file_path(), %{})
        %{context | settings: %{context.settings | tracker: %{context.settings.tracker | project_slug: name}}}
      end

    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    {:ok, contexts: contexts, root: root}
  end

  test "manual selection uses cwd or a qualifier and refuses ambiguous identifiers", %{contexts: [one, two] = contexts} do
    SymphonyElixir.TestSupport.stub_linear_client(fn _payload, _headers ->
      context = ProjectContext.current()
      {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [issue_node(context)]}}}}}
    end)

    assert {:error, {:ambiguous_issue_identifier, "PRO-1", ["One", "Two"]}} = ProjectSelection.resolve("PRO-1", contexts)
    assert {:ok, ^one, %{identifier: "PRO-1"}} = ProjectSelection.resolve("PRO-1", contexts, one.root)
    assert {:ok, ^two, _} = ProjectSelection.resolve("Two:PRO-1", contexts, one.root)
    duplicate_names = Enum.map(contexts, &%{&1 | name: "same"})
    assert {:error, {:ambiguous_or_unknown_project, "same"}} = ProjectSelection.resolve("same:PRO-1", duplicate_names)
    assert {:ok, %{id: id}, _} = ProjectSelection.resolve(two.root <> ":PRO-1", duplicate_names)
    assert id == two.id
  end

  test "one failed project lookup prevents guessing a match from another project", %{contexts: [one, _] = contexts} do
    SymphonyElixir.TestSupport.stub_linear_client(fn _payload, _headers ->
      if ProjectContext.current().id == one.id,
        do: {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [issue_node(one)]}}}}},
        else: {:error, :controlled_unavailable}
    end)

    assert {:error, {:project_lookup_failed, [_]}} = ProjectSelection.resolve("PRO-1", contexts)
  end

  test "full project slugs match Linear's short slugId in polling and reconciliation", %{contexts: [one, _]} do
    context = %{one | settings: %{one.settings | tracker: %{one.settings.tracker | project_slug: "one-7d8cc05658e6"}}}
    node = put_in(issue_node(context), ["project", "slugId"], "7d8cc05658e6")

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _headers ->
      variables = payload["variables"] || payload[:variables]
      conditions = variables.filter["or"] |> hd() |> Map.fetch!("and")
      assert %{"project" => %{"slugId" => %{"eq" => "7d8cc05658e6"}}} in conditions
      {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [node], "pageInfo" => %{"hasNextPage" => false}}}}}}
    end)

    assert {:ok, candidates} = Client.fetch_project_candidates([context])
    assert [%{assigned_to_worker: true}] = candidates[context.id]

    ProjectContext.with_context(context, fn ->
      assert Client.normalize_issue_for_test(node, "dev@example.com").assigned_to_worker
      refute Client.normalize_issue_for_test(put_in(node, ["project", "slugId"], "another"), "dev@example.com").assigned_to_worker
    end)
  end

  test "human verification rejects app accounts and checks every page", %{contexts: contexts} do
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _headers ->
      variables = payload["variables"] || payload[:variables]
      send(parent, {:human_page, variables.after})

      {nodes, page} =
        case variables.after do
          nil -> {[], %{"hasNextPage" => true, "endCursor" => "next"}}
          "next" -> {[%{"id" => "app-user", "email" => "dev@example.com", "app" => true}], %{"hasNextPage" => false}}
        end

      {:ok, %{status: 200, body: %{"data" => %{"users" => %{"nodes" => nodes, "pageInfo" => page}}}}}
    end)

    assert {:error, {:linear_assignees_not_human_or_unavailable, _, _}} = Client.verify_project_assignees(contexts)
    assert_receive {:human_page, nil}
    assert_receive {:human_page, "next"}
  end

  test "overlapping scopes fail before dispatch and repeated page cursors terminate", %{contexts: [one, two]} do
    team = %{two | settings: %{two.settings | tracker: %{two.settings.tracker | project_slug: nil, team_key: "PRO"}}}

    SymphonyElixir.TestSupport.stub_linear_client(fn _payload, _headers ->
      item = Map.put(issue_node(one), "team", %{"key" => "PRO"})
      {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [item], "pageInfo" => %{"hasNextPage" => false}}}}}}
    end)

    assert {:error, :ambiguous_workspace_project_scope} = Client.fetch_project_candidates([one, team])
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn _payload, _headers ->
      send(parent, :page)
      {:ok, %{status: 200, body: %{"data" => %{"issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => true, "endCursor" => "same"}}}}}}
    end)

    assert {:error, :linear_invalid_page_cursor} = Client.fetch_project_candidates([one])
    assert_receive :page
    assert_receive :page
    refute_receive :page
  end

  test "old sessions and incompatible journals require handoff without changing data", %{root: root} do
    binding = %{"state_root" => root, "workspace_id" => "workspace"}
    old = Path.join(root, "codex/old-installation/sessions")
    File.mkdir_p!(old)
    session = Path.join(old, "retained.jsonl")
    File.write!(session, "retained")
    assert {:error, {:local_state_requires_handoff, _, message}} = LocalState.validate(binding)
    assert message =~ "Aktive Arbeit beenden"
    assert File.read!(session) == "retained"
    # Separate fresh state tests journal handling; the old fixture stays intact.
    journal_root = Path.join(root, "fresh")
    File.mkdir_p!(Path.join(journal_root, "comments"))
    journal = Path.join(journal_root, "comments/write.intent.json")

    records = [
      %{"installation_id" => "old", "workspace_id" => "workspace"},
      %{"installation_id" => "symphony", "workspace_id" => "other"}
    ]

    for record <- records do
      content = Jason.encode!(record)
      File.write!(journal, content)
      journal_binding = %{binding | "state_root" => journal_root}
      assert {:error, {:local_state_requires_handoff, ^journal, _}} = LocalState.validate(journal_binding)
      assert File.read!(journal) == content
    end

    File.write!(journal, Jason.encode!(%{"installation_id" => "symphony", "workspace_id" => "workspace"}))
    assert :ok = LocalState.validate(%{binding | "state_root" => journal_root})
  end

  defp issue_node(context) do
    %{
      "id" => context.name,
      "identifier" => "PRO-1",
      "project" => %{"slugId" => context.settings.tracker.project_slug},
      "state" => %{"name" => "In Arbeit (AI)"},
      "assignee" => %{"email" => "dev@example.com", "app" => false}
    }
  end
end
