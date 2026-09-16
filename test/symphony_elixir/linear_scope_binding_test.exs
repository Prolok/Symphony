defmodule SymphonyElixir.LinearScopeBindingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.ScopeBinding
  alias SymphonyElixir.ProjectContext

  setup do
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "Project")
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    teams = %{"nodes" => [%{"id" => "pro-id", "key" => "PRO"}], "pageInfo" => %{"hasNextPage" => false}}
    viewer = %{"organization" => %{"id" => context.settings.tracker.app["workspace_id"]}}
    project = %{"id" => "project-id", "slugId" => context.settings.tracker.project_slug, "teams" => teams}
    data = %{"viewer" => viewer, "projects" => %{"nodes" => [project], "pageInfo" => %{"hasNextPage" => false}}}
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    {:ok, context: context, teams: teams, project: project, data: data}
  end

  test "fresh project and team scopes resolve in their own bound context", %{context: context, teams: teams, data: data} do
    parent = self()

    SymphonyElixir.TestSupport.stub_linear_client(fn request, _ ->
      send(parent, {:query, request})
      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    assert {:ok, %{kind: :project, project_id: "project-id", teams: verified}} = ScopeBinding.resolve(context)
    assert verified == teams["nodes"]
    assert_received {:query, %{"query" => query}}
    assert query =~ "includeArchived: true"
    assert query =~ "hasNextPage"
    context = put_in(context.settings.tracker.project_slug, nil)
    context = put_in(context.settings.tracker.team_key, "PRO")
    reply(%{"viewer" => data["viewer"], "teams" => teams})
    assert {:ok, %{kind: :team, scope: "PRO", teams: ^verified}} = ScopeBinding.resolve(context)
  end

  test "partial, missing, ambiguous and foreign bindings never authorize a reservation", %{context: context, teams: teams, project: project, data: data} do
    for rejected <- [
          %{},
          put_in(data["viewer"]["organization"]["id"], "foreign"),
          put_in(data["projects"]["nodes"], []),
          put_in(data["projects"]["nodes"], [project, project]),
          put_in(data["projects"]["pageInfo"]["hasNextPage"], true),
          put_in(data["projects"]["nodes"], [%{project | "slugId" => "foreign"}]),
          put_in(data["projects"]["nodes"], [%{project | "teams" => nil}])
        ] do
      reply(rejected)
      assert {:error, _} = ScopeBinding.resolve(context)
    end

    for invalid <- [
          nil,
          %{},
          %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false}},
          put_in(teams["pageInfo"]["hasNextPage"], true),
          %{teams | "nodes" => [nil]},
          %{teams | "nodes" => [%{"id" => "", "key" => "PRO"}]},
          %{teams | "nodes" => [%{"id" => "id", "key" => " PRO "}]},
          %{teams | "nodes" => teams["nodes"] ++ teams["nodes"]}
        ] do
      assert {:error, :invalid_project_teams} = ScopeBinding.complete_teams(invalid)
    end

    context = put_in(context.settings.tracker.project_slug, nil)
    context = put_in(context.settings.tracker.team_key, "QAI")

    for invalid <- [teams, %{teams | "nodes" => teams["nodes"] ++ [%{"id" => "qai-id", "key" => "QAI"}]}] do
      reply(%{"viewer" => data["viewer"], "teams" => invalid})
      assert {:error, :invalid_team_binding} = ScopeBinding.resolve(context)
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
      {:ok, %{status: 200, body: %{"data" => data, "errors" => [%{"message" => "partial"}]}}}
    end)

    assert {:error, _} = ScopeBinding.resolve(context)
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:error, :offline} end)
    assert {:error, _} = ScopeBinding.resolve(context)
  end

  test "changed membership between test validation and reservation is rejected", %{context: context, teams: teams, data: data} do
    expected = %{"project_id" => "project-id", "teams" => teams["nodes"]}
    context = %{context | test_instance: %{"manifest" => %{"projects" => %{context.name => expected}}}}
    reply(data)
    assert {:ok, _} = ScopeBinding.resolve(context)

    changed =
      put_in(data["projects"]["nodes"], [
        %{
          "id" => "project-id",
          "slugId" => context.settings.tracker.project_slug,
          "teams" => %{"nodes" => [%{"id" => "qai-id", "key" => "QAI"}], "pageInfo" => %{"hasNextPage" => false}}
        }
      ])

    reply(changed)
    assert {:error, _} = ScopeBinding.resolve(context)
    context = put_in(context.settings.tracker.project_slug, nil)
    context = put_in(context.settings.tracker.team_key, "PRO")
    reply(%{"viewer" => data["viewer"], "teams" => teams})
    assert {:error, _} = ScopeBinding.resolve(context)
  end

  defp reply(data) do
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:ok, %{status: 200, body: %{"data" => data}}} end)
  end
end
