defmodule SymphonyElixir.ProjectContextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Config, ProjectContext, RuntimePaths}
  alias SymphonyElixir.Linear.{Assignees, Client}

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-project-context-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "discovery visits one level across roots and deduplicates canonical paths", %{root: root} do
    first = Path.join(root, "QuantHub")
    second = Path.join(root, "ProjectHub")

    for path <- ["QuantHub/One/.symphony", "QuantHub/Two/.symphony", "ProjectHub/Three/.symphony", "QuantHub/One-worktrees/PRO-1/.symphony"] do
      File.mkdir_p!(Path.join(root, path))
    end

    File.ln_s!(first, Path.join(root, "alias"))
    assert {:ok, projects} = ProjectContext.discover(" #{first},#{second},#{root}/alias ", root)
    assert projects == [Path.join(first, "One"), Path.join(first, "Two"), Path.join(second, "Three")]
  end

  test "concurrent contexts bind scope, paths and state without changing environment or cwd", %{root: root} do
    workflow = Path.join(root, "WORKFLOW.md")

    File.write!(workflow, """
    ---
    tracker:
      kind: linear
      auth_mode: app
      app:
        client_id: $LINEAR_APP_CLIENT_ID
        workspace_id: $LINEAR_APP_WORKSPACE_ID
        user_id: $LINEAR_APP_USER_ID
        client_secret_env: LINEAR_APP_SECRET
        installation_id: symphony
      project_slug: $LINEAR_PROJECT_SLUG
      assignee: $LINEAR_ASSIGNEE
    workspace:
      root: $SYMPHONY_PROJECT_WORKTREES_ROOT
    ---
    A fixture workflow.
    """)

    contexts =
      for name <- ["one", "two", "three"] do
        project = Path.join(root, name)
        File.mkdir_p!(Path.join(project, ".symphony"))

        File.write!(Path.join(project, ".symphony/.env"), """
        LINEAR_PROJECT_SLUG=#{name}
        LINEAR_APP_CLIENT_ID=client
        LINEAR_APP_WORKSPACE_ID=workspace
        LINEAR_APP_USER_ID=app-user
        LINEAR_ASSIGNEE=first@example.com, second@example.com
        LINEAR_APP_SECRET=fixture-secret
        """)

        assert {:ok, context} = ProjectContext.load(project, workflow, %{})
        refute Map.has_key?(context.env, "LINEAR_APP_SECRET")
        context
      end

    cwd = File.cwd!()
    env = System.get_env()

    for context <- contexts do
      Task.async(fn ->
        ProjectContext.with_context(context, fn ->
          assert Config.settings!().tracker.project_slug == context.name
          assert RuntimePaths.project_root() == context.root
          assert Config.settings!().workspace.root == context.root <> "-worktrees"
          assert Config.settings!().tracker.app["state_root"] == Path.join(context.root, ".symphony/state")
          assert RuntimePaths.builtin_env()["SYMPHONY_LINEAR_ENV_DIR"] == Path.join(context.root, ".symphony")
        end)

        assert ProjectContext.current() == nil
      end)
    end
    |> Task.await_many()

    assert File.cwd!() == cwd
    assert System.get_env() == env
    assert :ok = Client.validate_workspace_bindings(contexts)
    [first | rest] = contexts
    changed = put_in(first.settings.tracker.app["client_id"], "another-client")
    assert {:error, {:conflicting_workspace_app_binding, "workspace"}} = Client.validate_workspace_bindings([changed | rest])
  end

  test "assignee lists match either human and exclude another assignee" do
    uuid = "b47fc057-4771-4e8e-8f9c-1633e4463068"
    list = " First@Example.com, #{uuid},first@example.com "
    assert Assignees.parse(list) == ["first@example.com", uuid]
    assert Assignees.human?(list, "app-user")
    refute Assignees.human?("me,first@example.com", "app-user")
    refute Assignees.human?(uuid, uuid)

    for assignee <- [%{"email" => "FIRST@example.com"}, %{"id" => uuid}] do
      assert Client.normalize_issue_for_test(%{"assignee" => assignee}, list).assigned_to_worker
    end

    refute Client.normalize_issue_for_test(%{"assignee" => %{"email" => "other@example.com"}}, list).assigned_to_worker
  end
end
