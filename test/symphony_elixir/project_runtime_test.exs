defmodule SymphonyElixir.ProjectRuntimeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{ProjectContext, ProjectPoller, Projects, ProjectSupervisor}

  test "three real project runtimes share workspace pages and isolate hooks, workers and state" do
    root = Path.join(System.tmp_dir!(), "symphony-multi-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = Path.expand("../..", __DIR__)
    old_request = Application.get_env(:symphony_elixir, :linear_client_request_fun)
    old_req = Req.default_options()
    parent = self()
    Supervisor.terminate_child(SymphonyElixir.Supervisor, Orchestrator)

    on_exit(fn ->
      if old_request do
        Application.put_env(:symphony_elixir, :linear_client_request_fun, old_request)
      else
        Application.delete_env(:symphony_elixir, :linear_client_request_fun)
      end

      Req.default_options(old_req)
      Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator)
      File.rm_rf!(root)
    end)

    contexts =
      for {base, name, workspace, assignee} <- [
            {"QuantHub", "One", "workspace-a", "first@example.com"},
            {"QuantHub", "Two", "workspace-a", "second@example.com"},
            {"ProjectHub", "Three", "workspace-b", "first@example.com,second@example.com"}
          ] do
        project = Path.join([root, base, name])
        File.mkdir_p!(Path.join(project, ".symphony"))

        File.write!(Path.join(project, ".symphony/.env"), """
        LINEAR_APP_CLIENT_ID=client-#{workspace}
        LINEAR_APP_WORKSPACE_ID=#{workspace}
        LINEAR_APP_USER_ID=app-#{workspace}
        LINEAR_APP_INSTALLATION_ID=symphony
        LINEAR_APP_SECRET=synthetic-#{workspace}
        LINEAR_PROJECT_SLUG=#{name}
        LINEAR_ASSIGNEE=#{assignee}
        """)

        write_hooks(project)
        {:ok, context} = ProjectContext.load(project, Path.join(repo, "WORKFLOW.md"), %{})
        worker = Path.join(project, "worker.py")
        write_worker(worker)
        settings = context.settings

        settings = %{
          settings
          | polling: %{settings.polling | interval_ms: 60_000},
            agent: %{settings.agent | max_turns: 1},
            codex: %{settings.codex | command: "python3 #{worker}", turn_timeout_ms: 5_000},
            hooks: %{
              settings.hooks
              | after_create: ~s(python3 "$SYMPHONY_PROJECT_ROOT/.symphony/on_create_worktree.py" "$SYMPHONY_PROJECT_ROOT" "$PWD"),
                before_remove: ~s(python3 "$SYMPHONY_PROJECT_ROOT/.symphony/on_remove_worktree.py" "$SYMPHONY_PROJECT_ROOT" "$PWD")
            }
        }

        %{context | settings: settings}
      end

    [one, two, three] = contexts
    nodes = [node(one, "A-1", "first@example.com"), node(two, "A-2", "second@example.com"), node(three, "A-1", "second@example.com")]
    by_id = Map.new(nodes, &{&1["id"], &1})

    Req.default_options(
      plug: fn conn ->
        assert conn.request_path == "/oauth/token"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)
        workspace = String.replace_prefix(form["client_id"], "client-", "")
        assert form["client_secret"] == "synthetic-#{workspace}"
        Req.Test.json(conn, %{"access_token" => workspace, "token_type" => "Bearer", "expires_in" => 3600, "scope" => "read,write"})
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
      context = ProjectContext.current()
      workspace = context.settings.tracker.app["workspace_id"]
      assert {"Authorization", "Bearer #{workspace}"} in headers
      query = payload["query"] || payload[:query]
      vars = payload["variables"] || payload[:variables]

      data =
        cond do
          String.contains?(query, "SymphonyAppIdentity") ->
            %{"viewer" => %{"id" => "app-#{workspace}", "app" => true, "organization" => %{"id" => workspace}}}

          String.contains?(query, "SymphonyHumanAssignees") ->
            users = for email <- ["first@example.com", "second@example.com"], do: %{"id" => email, "email" => email, "app" => false}
            %{"users" => %{"nodes" => users, "pageInfo" => %{"hasNextPage" => false}}}

          String.contains?(query, "SymphonyWorkspacePoll") ->
            send(parent, {:page, workspace, vars.after, vars.filter})

            case {workspace, vars.after} do
              {"workspace-a", nil} -> page([hd(nodes), node(one, "A-9", "other@example.com")], true, "next")
              {"workspace-a", "next"} -> page([Enum.at(nodes, 1)], false, nil)
              {"workspace-b", nil} -> page([Enum.at(nodes, 2)], false, nil)
            end

          String.contains?(query, "SymphonyLinearIssuesById") ->
            %{"issues" => %{"nodes" => Enum.map(vars.ids, &Map.fetch!(by_id, &1))}}

          String.contains?(query, "SymphonyLinearIssueComments") ->
            %{"issue" => %{"comments" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}}

          String.contains?(query, "SymphonyIssueUpdateInputFields") ->
            %{"__type" => %{"inputFields" => []}}

          true ->
            flunk("unexpected query: #{query}")
        end

      {:ok, %{status: 200, body: %{"data" => data}}}
    end)

    start_supervised!({ProjectSupervisor, contexts: contexts})
    assert {:ok, _} = :sys.get_state(ProjectPoller).result
    assert_receive {:page, "workspace-a", nil, filter}, 3_000
    assert length(filter["or"]) == 2
    branches = Enum.map(filter["or"], fn branch -> Enum.reduce(branch["and"], %{}, &Map.merge/2) end)
    assert Enum.map(branches, & &1["project"]["slugId"]["eq"]) |> Enum.sort() == ["One", "Two"]

    for branch <- branches do
      project = branch["project"]["slugId"]["eq"]
      email = if project == "One", do: "first@example.com", else: "second@example.com"
      assert branch["assignee"] == %{"or" => [%{"email" => %{"eqIgnoreCase" => email}}], "app" => %{"eq" => false}}
      assert "In Arbeit (AI)" in branch["state"]["name"]["in"]
    end

    assert_receive {:page, "workspace-a", "next", _}, 3_000
    assert_receive {:page, "workspace-b", nil, _}, 3_000

    for context <- contexts do
      assert {:ok, [_]} = ProjectPoller.candidates(context)
    end

    for {context, issue} <- Enum.zip(contexts, nodes) do
      result = Path.join([context.settings.workspace.root, issue["identifier"], "result.json"])
      receipt = await_file(result)
      assert receipt["project"] == context.root
      assert receipt["cwd"] == Path.dirname(result)
      assert receipt["state_root"] == Path.join(context.root, ".symphony/state/codex/symphony")
      assert receipt["secret_visible"] == false
    end

    refute_receive {:page, _, _, _}, 100
    snapshot = Orchestrator.snapshot()
    assert snapshot.projects == ["One", "Two", "Three"]
    assert snapshot.polling.next_poll_in_ms > 0
    assert snapshot.polling.poll_interval_ms == 60_000
    assert {:error, :ambiguous_issue_identifier} = SymphonyElixirWeb.Presenter.issue_payload("A-1", Orchestrator, 1_000)
    assert {:ok, %{issue_id: "One-A-1"}} = SymphonyElixirWeb.Presenter.issue_payload("One:A-1", Orchestrator, 1_000)
    payload = SymphonyElixirWeb.Presenter.state_payload(Orchestrator, 1_000)
    assert payload.projects == ["One", "Two", "Three"]

    # Stop fixture workers before explicitly exercising only our own cleanup paths.
    for context <- contexts do
      state = :sys.get_state(Projects.server(context))

      for {_id, entry} <- state.running do
        Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid)
      end
    end

    stop_supervised!(ProjectSupervisor)

    for {context, issue} <- Enum.zip(contexts, nodes) do
      ProjectContext.with_context(context, fn -> Workspace.remove(Path.join(context.settings.workspace.root, issue["identifier"])) end)
      assert File.read!(Path.join(context.root, "hooks.log")) |> String.split("\n", trim: true) == ["create:#{context.name}", "remove:#{context.name}"]
    end
  end

  defp node(context, identifier, assignee) do
    %{
      "id" => context.name <> "-" <> identifier,
      "identifier" => identifier,
      "title" => "Fixture",
      "state" => %{"name" => "In Arbeit (AI)"},
      "project" => %{"slugId" => context.name},
      "team" => %{"key" => "A"},
      "assignee" => %{"id" => assignee, "email" => assignee, "app" => false}
    }
  end

  defp page(nodes, more, cursor), do: %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}}

  defp await_file(path, attempts \\ 200)
  defp await_file(path, 0), do: flunk("missing worker result #{path}")

  defp await_file(path, attempts) do
    case File.read(path) do
      {:ok, body} ->
        Jason.decode!(body)

      _ ->
        Process.sleep(25)
        await_file(path, attempts - 1)
    end
  end

  defp write_worker(path) do
    File.write!(path, ~S"""
    import sys,json,os,pathlib
    for line in sys.stdin:
      m=json.loads(line)
      method=m.get('method')
      result={}
      if method=='thread/start': result={'thread':{'id':'thread-fixture'}}
      if method=='turn/start':
        result={'turn':{'id':'turn-fixture'}}
        pathlib.Path('result.json').write_text(json.dumps({'project':os.environ.get('SYMPHONY_PROJECT_ROOT'),'cwd':os.getcwd(),'state_root':os.environ.get('SYMPHONY_CODEX_STATE_ROOT'),'secret_visible':bool(os.environ.get('LINEAR_APP_SECRET') or os.environ.get('LINEAR_API_KEY'))}))
      if 'id' in m: print(json.dumps({'id':m['id'],'result':result}),flush=True)
      if method=='turn/start': print(json.dumps({'method':'turn/completed'}),flush=True)
    """)
  end

  defp write_hooks(project) do
    for {file, action} <- [{"on_create_worktree.py", "create"}, {"on_remove_worktree.py", "remove"}] do
      File.write!(Path.join([project, ".symphony", file]), """
      import pathlib,sys,subprocess
      project,workspace=map(pathlib.Path,sys.argv[1:])
      with (project/'hooks.log').open('a') as f: f.write('#{action}:'+project.name+'\\n')
      if '#{action}'=='create':
        for args in [['init','-b','main'],['config','user.name','Fixture'],['config','user.email','fixture@example.com'],['commit','--allow-empty','-m','fixture']]:
          subprocess.run(['git','-C',str(workspace),*args],check=True,capture_output=True)
      """)
    end
  end
end
