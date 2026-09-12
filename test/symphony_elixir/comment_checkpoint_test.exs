defmodule SymphonyElixir.CommentCheckpointTest do
  use SymphonyElixir.TestSupport
  alias Absinthe.Language, as: L
  alias Absinthe.Phase.Parse
  alias SymphonyElixir.Codex.{CommentTool, DynamicTool, MCPServer, MergeTool}
  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, Workpad}
  alias SymphonyElixir.Linear.{Adapter, CommentActionGuard, CommentMutations, CommentVersion, WriteContext}

  setup do
    System.put_env("SYMPHONY_LINEAR_ENV_DIR", Path.join(Path.dirname(Workflow.workflow_file_path()), ".symphony"))
    Process.put(:comments, %{})
    Process.put(:phase, "In Arbeit (AI)")
    Process.put(:counter, 0)

    SymphonyElixir.TestSupport.stub_linear_client(&request/2)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    :ok = Adapter.create_comment("issue", "## Symphony Workpad\n\n### Plan\n\n- [ ] Kommentarhinweise prüfen\n")
    %{issue: %Issue{id: "issue", identifier: "PRO-1", state: "In Arbeit (AI)"}}
  end

  test "actual raw, dynamic, MCP and adapter state paths reject pending input and failed fresh scans", %{issue: issue} do
    mutation = "mutation { handoff: issueUpdate(id: \"issue\", input: {stateId: \"next\"}) { success } }"
    refute DynamicTool.execute("linear_graphql", %{"query" => mutation})["success"]
    refute_received :status_mutation
    assert {:ok, checkpoint} = CommentTool.invoke(%{"operation" => "checkpoint", "issue_id" => issue.id})
    [%{"key" => baseline}] = checkpoint["inputs"]
    assert {:ok, _} = CommentTool.invoke(%{"operation" => "acknowledge", "issue_id" => issue.id, "results" => [result(baseline)]})
    assert :ok = Adapter.update_issue_state(issue.id, "PreReview (AI)")
    assert_received :status_mutation

    human("human", "Neue Korrektur")
    assert {:error, _} = Adapter.update_issue_state(issue.id, "PreReview (AI)")
    refute_received :status_mutation
    response = MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => mutation}}})
    assert response["result"]["isError"]
    refute_received :status_mutation
    assert {:ok, %{"inputs" => [%{"key" => key}]}} = CommentCheckpoint.checkpoint(issue)
    assert {:ok, _} = CommentCheckpoint.acknowledge(issue, [result(key)])
    Process.put(:scan_failure, true)
    refute DynamicTool.execute("linear_graphql", %{"query" => mutation})["success"]
    refute_received :status_mutation
    assert {:error, _} = CommentCheckpoint.prompt(issue)
    Process.delete(:scan_failure)
    assert :ok = CommentCheckpoint.before_action(issue)
    assert DynamicTool.execute("linear_graphql", %{"query" => mutation})["success"]
    assert_received :status_mutation
  end

  test "workpad acknowledgement records source version, survives retries and never acknowledges the successor edit", %{issue: issue} do
    establish(issue)
    first = human("human", "erste Fassung")
    assert {:ok, %{"inputs" => [%{"key" => key}]}} = CommentCheckpoint.checkpoint(issue)
    human("human", "zweite Fassung")
    assert {:ok, %{"inputs" => [second]}} = CommentCheckpoint.acknowledge(issue, [result(key)])
    assert second["source"]["body"] == "zweite Fassung"
    assert workpad_body() =~ CommentVersion.key(first)
    body = workpad_body()
    assert {:ok, _} = CommentCheckpoint.acknowledge(issue, [result(key)])
    assert workpad_body() == body
    assert {:ok, prompt} = CommentCheckpoint.prompt(issue)
    assert prompt =~ second["key"]
    assert prompt =~ "Review-Subagenten"
    replaced = result(second["key"], "Rückfrage", "Fachlichen Umfang geklärt")
    assert {:ok, _} = CommentCheckpoint.acknowledge(issue, [replaced])
    assert workpad_body() =~ "Rückfrage"
    assert :ok = CommentCheckpoint.before_action(issue)
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.checkpoint(issue)
  end

  test "pending handoff errors contain identifiers while full source text stays in the checkpoint", %{issue: issue} do
    establish(issue)
    body = "VERTRAULICHER_KOMMENTARTEXT_677"
    source = human("private", body)
    assert {:error, reason} = Adapter.update_issue_state(issue.id, "PreReview (AI)")
    assert inspect(reason) =~ "comment_inputs_pending"
    assert inspect(reason) =~ CommentVersion.key(source)
    refute inspect(reason) =~ body
    assert {:ok, %{"inputs" => [%{"source" => %{"body" => ^body}}]}} = CommentCheckpoint.checkpoint(issue)
  end

  test "MCP/dynamic checkpoints share delivery and errors; invalid or foreign issue arguments fail closed", %{issue: issue} do
    args = %{"operation" => "checkpoint", "issue_id" => issue.id}
    assert DynamicTool.execute("symphony_comments", args)["success"]
    response = MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/call", "params" => %{"name" => "symphony_comments", "arguments" => args}})
    refute response["result"]["isError"]
    assert {:error, :invalid_comment_arguments} = CommentTool.invoke(nil)
    assert {:error, :invalid_comment_operation} = CommentTool.invoke(%{args | "operation" => "unknown"})
    refute DynamicTool.execute("symphony_comments", nil)["success"]
    assert CommentTool.mcp_call(nil)["isError"]
    refute CommentTool.execute(nil)["success"]
    assert {:error, :offline} = CommentCheckpoint.bound_issue(issue.id, fetch_issue: fn _ -> {:error, :offline} end)
    assert {:error, :comment_issue_outside_active_scope} = CommentCheckpoint.bound_issue("missing")

    WriteContext.with_context(%{issue_id: "different"}, fn ->
      assert {:error, :comment_issue_outside_active_scope} = CommentCheckpoint.bound_issue(issue.id)
    end)

    Process.put(:phase, "Freigabe Review")
    assert {:error, :comment_issue_outside_active_scope} = CommentTool.invoke(args)

    for state <- ["Freigabe Review", "Freigabe Implementierung", "In Arbeit", "Todo (Dialog-AI)", "Todo (AI)", "Abbruch (AI)"] do
      refute CommentCheckpoint.active?(%{issue | state: state})
      assert {:ok, ""} = CommentCheckpoint.prompt(%{issue | state: state})
    end
  end

  test "state mutation parsing handles variables, aliases, defaults, fragments and directives without text heuristics" do
    payload = %{
      "query" => """
      mutation Change($id: String! = "issue", $input: IssueUpdateInput!, $skip: Boolean! = false) {
        ...Fields
        ignored: issueUpdate(id: "other", input: {title: "stateId"}) { success }
      }
      fragment Fields on Mutation { moved: issueUpdate(id: $id, input: $input) @skip(if: $skip) { success } }
      """,
      "variables" => %{"input" => %{"stateId" => "next"}}
    }

    assert {:ok, [%{"id" => "issue", "state_id" => "next"}]} = CommentMutations.state_updates(payload)
    assert {:ok, []} = CommentMutations.state_updates(put_in(payload, ["variables", "skip"], true))
    assert {:ok, []} = CommentMutations.state_updates(%{"query" => "query { viewer { id } }"})

    for query <- ["mutation {", "query A { viewer { id } } query B { viewer { id } }"] do
      assert {:error, :invalid_graphql_document} = CommentMutations.state_updates(%{"query" => query})
    end

    for query <- ["mutation { ...F } fragment F on Mutation { ...F }", "mutation { ...Missing }", "mutation($id: String!) { issueUpdate(id: $id, input: {stateId: \"next\"}) { success } }"] do
      assert {:error, :invalid_state_mutation} = CommentMutations.state_updates(%{"query" => query})
    end
  end

  test "backward exits stay possible, whereas incomplete scope and labels are blocking", %{issue: issue} do
    mutation = fn state -> %{"query" => "mutation { issueUpdate(id: \"issue\", input: {stateId: \"#{state}\"}) { success } }"} end
    assert :ok = CommentActionGuard.check(mutation.("blocker"))
    assert :ok = CommentActionGuard.check(mutation.("current"))
    Process.put(:phase, "Freigabe Review")
    assert :ok = CommentActionGuard.check(mutation.("next"))
    assert {:error, :comment_action_scope_unverified} = CommentActionGuard.check(mutation.("unknown"))
    assert {:error, :offline} = CommentActionGuard.check(mutation.("next"), query: fn _, _ -> {:error, :offline} end)
    Process.put(:phase, issue.state)
    assert {:error, :comment_issue_outside_active_scope} = CommentActionGuard.check(mutation.("next"), fetch_issue: fn _ -> {:ok, [%{issue | assigned_to_worker: false}]} end)
  end

  test "the actual bound merge callback rejects pending input, scan errors and moved issues", %{issue: issue} do
    issue = %{issue | state: "Merge (AI)"}
    Process.put(:phase, issue.state)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(Workflow.workflow_file_path()))
    assert {:error, :merge_workspace_unverified} = MergeTool.invoke(%{"head_sha" => String.duplicate("a", 40), "issue_id" => issue.id})
    opts = [labels: fn _ -> {:ok, ["Requires Manual Review"]} end]
    labels = MergeTool.handle_checkpoint({:ok, %{"operation" => "labels"}}, issue, opts)
    assert labels == %{"ok" => true, "labels" => ["Requires Manual Review"]}
    refute MergeTool.handle_checkpoint({:ok, %{"operation" => "merge"}}, issue, opts)["ok"]
    establish(issue)
    assert MergeTool.handle_checkpoint({:ok, %{"operation" => "merge"}}, issue, opts)["ok"]
    Process.put(:scan_failure, true)
    refute MergeTool.handle_checkpoint({:ok, %{"operation" => "merge"}}, issue, opts)["ok"]
    Process.delete(:scan_failure)
    Process.put(:phase, "Review")
    refute MergeTool.handle_checkpoint({:ok, %{"operation" => "merge"}}, issue, opts)["ok"]
    refute MergeTool.handle_checkpoint(:invalid, issue, opts)["ok"]
    assert {:error, :invalid_bound_merge_context} = MergeTool.invoke(nil)
    refute MergeTool.execute(nil)["success"]
    assert MergeTool.mcp_call(nil)["isError"]
    assert {:error, :comment_issue_outside_active_scope} = MergeTool.invoke(%{"head_sha" => String.duplicate("a", 40), "issue_id" => "missing"})
    refute DynamicTool.execute("symphony_merge", %{"head_sha" => "invalid"})["success"]
    response = MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/call", "params" => %{"name" => "symphony_merge", "arguments" => %{}}})
    assert response["result"]["isError"]
  end

  @tag timeout: 60_000
  test "bound MCP merge runs the real land process and sends no merge command until a fresh checkpoint passes", %{issue: issue} do
    issue = %{issue | state: "Merge (AI)"}
    Process.put(:phase, issue.state)
    root = Path.dirname(Workflow.workflow_file_path())
    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(Path.join(workspace_root, issue.identifier))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    bin = Path.join(root, "commands")
    File.mkdir_p!(bin)
    fixture = Path.expand("../support/linear_app/merge_counter.py", __DIR__)

    for command <- ["git", "gh"] do
      target = Path.join(bin, command)
      File.cp!(fixture, target)
      File.chmod!(target, 0o755)
    end

    previous_path = System.fetch_env!("PATH")
    marker = Path.join(root, "merge-requests.jsonl")
    System.put_env("PATH", bin <> ":" <> previous_path)
    System.put_env("SYMPHONY_TEST_MERGE_COUNTER", marker)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      System.delete_env("SYMPHONY_TEST_MERGE_COUNTER")
      System.delete_env("SYMPHONY_TEST_MERGE_LIMIT_ONCE")
    end)

    bind_git_context(root)
    opts = [labels: fn _ -> {:ok, []} end]
    args = %{"issue_id" => issue.id, "head_sha" => String.duplicate("a", 40)}
    assert {:error, :bound_merge_timeout} = MergeTool.invoke(args, Keyword.put(opts, :timeout_ms, 0))
    refute File.exists?(marker)
    assert {:error, {:bound_merge_incomplete, 9, _}} = MergeTool.invoke(args, opts)
    refute File.exists?(marker)
    establish(issue)
    Process.put(:scan_failure, true)
    assert {:error, {:bound_merge_incomplete, 9, _}} = MergeTool.invoke(args, opts)
    refute File.exists?(marker)
    Process.delete(:scan_failure)
    System.put_env("SYMPHONY_TEST_MERGE_LIMIT_ONCE", Path.join(root, "rate-limit-once"))
    assert {:error, {:bound_merge_incomplete, _, _}} = MergeTool.invoke(args, opts)
    refute File.exists?(marker)
    human("during-backoff", "Frische Korrektur nach Rate-Limit")
    assert {:error, {:bound_merge_incomplete, 9, _}} = MergeTool.invoke(args, opts)
    refute File.exists?(marker)
    assert {:ok, %{"inputs" => [%{"key" => key}]}} = CommentCheckpoint.checkpoint(issue)
    assert {:ok, _} = CommentCheckpoint.acknowledge(issue, [result(key)])
    response = MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 10, "method" => "tools/call", "params" => %{"name" => "symphony_merge", "arguments" => args}}, opts)
    refute response["result"]["isError"]
    [request] = marker |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert request == ["pr", "merge", "1", "--merge", "--match-head-commit", String.duplicate("a", 40), "--subject", "PRO-1: "]
  end

  test "fresh merge labels paginate completely and reject missing pages or API errors", %{issue: issue} do
    Process.put(:phase, "Merge (AI)")
    page = fn names, more, cursor -> data(%{"issue" => %{"labels" => %{"nodes" => Enum.map(names, &%{"name" => &1}), "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}}}) end
    Process.put(:label_pages, %{nil => page.(["Requires Manual Review"], true, "next"), "next" => page.(["keep"], false, nil)})
    request = {:ok, %{"operation" => "labels"}}
    assert MergeTool.handle_checkpoint(request, issue, []) == %{"ok" => true, "labels" => ["Requires Manual Review", "keep"]}
    Process.put(:label_pages, %{nil => page.([], true, "cycle"), "cycle" => page.([], true, "cycle")})
    refute MergeTool.handle_checkpoint(request, issue, [])["ok"]
    Process.put(:label_pages, %{nil => {:error, :offline}})
    refute MergeTool.handle_checkpoint(request, issue, [])["ok"]
  end

  test "bound merge reports missing Python and refuses incomplete remote workspace context", %{issue: issue} do
    Process.put(:phase, "Merge (AI)")
    root = Path.join(Path.dirname(Workflow.workflow_file_path()), "workspaces")
    File.mkdir_p!(Path.join(root, issue.identifier))
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)
    args = %{"issue_id" => issue.id, "head_sha" => String.duplicate("a", 40)}

    for workspace <- [nil, "relative/" <> issue.identifier, "/remote/other", "/remote/\n" <> issue.identifier] do
      WriteContext.with_context(%{worker_host: "worker-01", workspace_path: workspace}, fn ->
        assert {:error, :merge_workspace_unverified} = MergeTool.invoke(args)
      end)
    end

    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", root)

    try do
      assert {:error, :python_not_found} = MergeTool.invoke(args)
    after
      System.put_env("PATH", old_path)
    end
  end

  @tag timeout: 60_000
  test "dynamic merge uses the bound SSH worker even when its workspace does not exist locally", %{issue: issue} do
    Process.put(:phase, "Merge (AI)")
    issue = %{issue | state: "Merge (AI)"}
    root = Path.dirname(Workflow.workflow_file_path())
    remote_root = "~/.symphony-remote-workspaces"
    remote_workspace = "/remote/home/.symphony-remote-workspaces/" <> issue.identifier
    worker_workspace = Path.join(root, "worker")
    File.mkdir_p!(worker_workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: remote_root)
    bin = Path.join(root, "commands")
    File.mkdir_p!(bin)
    fixture = Path.expand("../support/linear_app/merge_counter.py", __DIR__)

    for command <- ["git", "gh"] do
      target = Path.join(bin, command)
      File.cp!(fixture, target)
      File.chmod!(target, 0o755)
    end

    ssh = Path.join(bin, "ssh")

    File.write!(ssh, """
    #!/usr/bin/env python3
    import os, shlex, sys
    assert sys.argv[1:5] == ['-T', '-p', '2200', 'worker-01'], sys.argv
    command = shlex.split(sys.argv[-1])[2]
    assert #{inspect(remote_workspace)} in command
    command = command.replace(#{inspect(remote_workspace)}, #{inspect(worker_workspace)})
    os.execvp('bash', ['bash', '-c', command])
    """)

    File.chmod!(ssh, 0o755)
    previous_path = System.fetch_env!("PATH")
    marker = Path.join(root, "remote-merge.jsonl")
    System.put_env("PATH", bin <> ":" <> previous_path)
    System.put_env("SYMPHONY_TEST_MERGE_COUNTER", marker)

    on_exit(fn ->
      System.put_env("PATH", previous_path)
      System.delete_env("SYMPHONY_TEST_MERGE_COUNTER")
    end)

    bind_git_context(root)
    refute File.dir?(remote_workspace)
    establish(issue)
    args = %{"issue_id" => issue.id, "head_sha" => String.duplicate("a", 40)}
    context = %{worker_host: "worker-01:2200", workspace_path: remote_workspace}

    WriteContext.with_context(context, fn ->
      Process.put(:scan_failure, true)
      refute DynamicTool.execute("symphony_merge", args, labels: fn _ -> {:ok, []} end)["success"]
      refute File.exists?(marker)
      Process.delete(:scan_failure)
      assert DynamicTool.execute("symphony_merge", args, labels: fn _ -> {:ok, []} end)["success"]
    end)

    assert length(String.split(File.read!(marker), "\n", trim: true)) == 1
  end

  test "checkpoint recovers an unconfirmed runtime write and refuses corrupt input state", %{issue: issue} do
    binding = Config.settings!().tracker.app
    [confirmation] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.confirmed.json"]))
    File.rm!(confirmation)
    assert {:ok, _} = CommentCheckpoint.checkpoint(issue)
    assert File.exists?(confirmation)
    [input] = Path.wildcard(Path.join([binding["state_root"], "inputs", "*.json"]))
    File.write!(input, "broken")
    assert {:error, :runtime_state_corrupt} = CommentCheckpoint.checkpoint(issue)
  end

  test "status checks honor the adopted issue allow-scope" do
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "    client_id:", "    allowed_issue_ids: [00000000-0000-4000-8000-000000000001]\n    client_id:"))
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    mutation = %{"query" => "mutation { issueUpdate(id: \"issue\", input: {stateId: \"next\"}) { success } }"}
    assert {:error, :comment_issue_outside_active_scope} = CommentActionGuard.check(mutation)
    refute_received :status_mutation
  end

  test "recovered review runtime routes pending input to worker retry, and blocks a failed fresh scan", %{issue: issue} do
    Process.put(:phase, "Review (AI)")
    issue = %{issue | state: "Review (AI)"}
    wp = Process.get(:comments) |> Map.values() |> hd()
    :ok = Adapter.update_comment(wp["id"], "## Symphony Workpad\n\n### Review\n\n- [x] Review (AI) read-only Subagent: Keine Findings.\n")
    establish(issue)
    workspace = Path.join(Path.dirname(Workflow.workflow_file_path()), "clean-workspace")
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.dirname(workspace))
    File.mkdir_p!(workspace)

    for args <- [["init", "-q"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "fixture"]] do
      assert {_, 0} = System.cmd("git", ["-C", workspace | args])
    end

    token = make_ref()
    retry = %{attempt: 1, retry_token: token, workspace_path: workspace}
    retry = Map.merge(retry, %{identifier: issue.identifier, recovered_turn_context: "Keine Findings."})
    state = %Orchestrator.State{max_concurrent_agents: 0, poll_interval_ms: 30_000, retry_attempts: %{issue.id => retry}}
    human("pending", "Neue Eingabe nach technischem Review")
    assert {:noreply, resumed} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)
    assert resumed.retry_attempts[issue.id].error == "no available orchestrator slots"
    Process.cancel_timer(resumed.retry_attempts[issue.id].timer_ref)
    refute_received :status_mutation
    establish(issue)
    assert {:ready, :no_findings} = Workpad.review_handoff_status([workpad_body()])
    Process.put(:signal_failure, true)
    assert {:noreply, failed} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)
    assert failed.retry_attempts[issue.id].error =~ "review handoff state update failed"
    Process.cancel_timer(failed.retry_attempts[issue.id].timer_ref)
    refute_received :status_mutation
    Process.delete(:signal_failure)
    assert {:noreply, completed} = Orchestrator.handle_info({:retry_issue, issue.id, token}, state)
    assert completed.retry_attempts == %{}
    assert_received :status_mutation
  end

  defp bind_git_context(root) do
    expected = Path.join(root, "git-config")
    previous = ProjectContext.current()
    {:ok, workflow} = Workflow.current()

    context = %ProjectContext{
      root: root,
      workflow_path: Workflow.workflow_file_path(),
      workflow: workflow,
      settings: Config.settings!(),
      env: %{"GH_REPO" => "", "GH_CONFIG_DIR" => expected, "GIT_SSH_COMMAND" => "ssh -F " <> expected, "LINEAR_APP_SECRET" => "synthetic-secret"}
    }

    System.put_env("SYMPHONY_TEST_EXPECT_GIT_ENV", expected)
    ProjectContext.bind(context)

    on_exit(fn ->
      ProjectContext.bind(previous)
      System.delete_env("SYMPHONY_TEST_EXPECT_GIT_ENV")
    end)
  end

  defp establish(issue) do
    {:ok, %{"inputs" => inputs}} = CommentCheckpoint.checkpoint(issue)
    results = Enum.map(inputs, &result(&1["key"]))
    if results != [], do: assert({:ok, _} = CommentCheckpoint.acknowledge(issue, results))
  end

  defp result(key, outcome \\ "übernommen", reason \\ "Hinweis im Plan berücksichtigt"), do: %{"key" => key, "outcome" => outcome, "reason" => reason}
  defp workpad_body, do: Process.get(:comments) |> Map.values() |> Enum.find(&String.starts_with?(&1["body"], "## Symphony Workpad")) |> Map.fetch!("body")
  defp human(id, body), do: put_comment(id, body, %{"id" => "human", "app" => false})

  defp put_comment(id, body, user) do
    count = Process.get(:counter) + 1
    Process.put(:counter, count)
    raw = %{"id" => id, "body" => body, "user" => user, "issue" => %{"id" => "issue"}, "updatedAt" => "2026-09-12T12:00:#{String.pad_leading(to_string(count), 2, "0")}Z"}
    Process.put(:comments, Map.put(Process.get(:comments), id, raw))
    raw
  end

  defp request(%{"query" => "query($id: String!, $after: String)" <> _} = payload, _headers) do
    Process.get(:label_pages)[payload["variables"].after]
  end

  defp request(%{"query" => "query SymphonyLinearPoll" <> _}, _headers) do
    {:ok, response} = issue_response(%{ids: ["issue"]})
    {:ok, put_in(response, [:body, "data", "issues", "pageInfo"], %{"hasNextPage" => false, "endCursor" => nil})}
  end

  defp request(payload, _headers) do
    query = payload["query"]
    vars = Map.get(payload, "variables", %{})

    cond do
      query =~ "SymphonyCommentAction" ->
        data(%{"issue" => %{"id" => "issue", "team" => %{"states" => %{"nodes" => states(), "pageInfo" => %{"hasNextPage" => false}}}}})

      query =~ "SymphonyResolveStateId" ->
        data(%{"issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "next"}]}}}})

      query =~ "SymphonyLinearIssuesById" ->
        issue_response(vars)

      query =~ "SymphonyCommentScanSignal" ->
        signal_response()

      query =~ "SymphonyLinearIssueComments" ->
        comment_response()

      query =~ "SymphonyReceipt" ->
        data(%{"comment" => Process.get(:comments)[vars["id"]]})

      query =~ "mutation" ->
        mutation(payload)

      true ->
        flunk("Unexpected query: #{query}")
    end
  end

  defp signal_response do
    nodes = Process.get(:comments) |> Map.values() |> Enum.sort_by(& &1["updatedAt"], :desc) |> Enum.take(1)
    if Process.get(:signal_failure), do: {:error, :scan_signal_offline}, else: data(%{"issue" => %{"comments" => %{"nodes" => nodes}}})
  end

  defp issue_response(vars) do
    nodes =
      if vars.ids == ["issue"],
        do: [
          %{
            "id" => "issue",
            "identifier" => "PRO-1",
            "title" => "",
            "project" => %{"slugId" => Config.settings!().tracker.project_slug},
            "team" => %{"key" => Config.settings!().tracker.team_key},
            "state" => %{"name" => Process.get(:phase)},
            "assignee" => %{"id" => "human", "email" => "dev@example.com", "app" => false}
          }
        ],
        else: []

    data(%{"issues" => %{"nodes" => nodes}})
  end

  defp comment_response do
    if Process.get(:scan_failure),
      do: {:error, :controlled_scan_failure},
      else: data(%{"issue" => %{"comments" => %{"nodes" => Map.values(Process.get(:comments)), "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}})
  end

  defp states, do: [%{"id" => "next", "name" => "PreReview (AI)"}, %{"id" => "current", "name" => "In Arbeit (AI)"}, %{"id" => "blocker", "name" => "BLOCKER"}]
  defp data(data), do: {:ok, %{status: 200, body: %{"data" => data}}}

  defp mutation(payload) do
    {:ok, %{input: %{definitions: [operation]}}} = Parse.run(%L.Source{body: payload["query"]})
    [field] = operation.selection_set.selections
    values = Map.new(field.arguments, &{&1.name, value(&1.value, payload["variables"] || %{})})

    if field.name == "issueUpdate" do
      send(self(), :status_mutation)
      data(%{(field.alias || field.name) => %{"success" => true}})
    else
      input = values["input"]
      id = input["id"] || values["id"]
      raw = put_comment(id, input["body"], %{"id" => "synthetic-app", "app" => true})
      data(%{(field.alias || field.name) => %{"success" => true, "comment" => raw, "symphonyReceipt" => raw}})
    end
  end

  defp value(%L.Variable{name: name}, vars), do: vars[name] || vars[String.to_existing_atom(name)]
  defp value(%L.ObjectValue{fields: fields}, vars), do: Map.new(fields, &{&1.name, value(&1.value, vars)})
  defp value(%{value: value}, _vars), do: value
end
