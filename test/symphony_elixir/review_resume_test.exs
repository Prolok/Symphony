defmodule SymphonyElixir.ReviewResumeTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureLog
  alias SymphonyElixir.Codex.ReviewState
  alias SymphonyElixir.Linear.DurableState

  test "foreign, stale and unbound terminal events cannot finish the parent turn" do
    root = Path.join([File.cwd!(), "_build", "review-resume-#{System.unique_integer([:positive])}"])
    workspace = Path.join(root, "workspaces/PRO-704")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    executable = Path.join(root, "codex")

    foreign =
      for method <- ["turn/completed", "turn/failed", "turn/cancelled"],
          params <- [
            %{"threadId" => "child", "turn" => %{"id" => "child-turn"}},
            %{"threadId" => "parent", "turn" => %{"id" => "old-turn"}},
            %{}
          ] do
        "printf '%s\\n' '#{Jason.encode!(%{method: method, params: params})}'"
      end

    File.write!(executable, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"parent"}}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"active"}}}'
          #{Enum.join(foreign, "\n")}
          sleep 1
          printf '%s\\n' '{"method":"item/completed","params":{"threadId":"parent","turnId":"active","item":{"type":"agentMessage","id":"final","text":"Parent finished","phase":"final_answer"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"parent","turn":{"id":"active","status":"completed","items":[]}}}'
          exit 0 ;;
      esac
    done
    """)

    File.chmod!(executable, 0o755)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_command: executable)
    owner = self()
    issue = %Issue{id: "review-resume", identifier: "PRO-704", state: "Review (AI)"}
    assert {:ok, %{turn_id: "active"}} = AppServer.run(workspace, "Protocol proof", issue, on_message: &send(owner, {:event, &1}))
    assert_received {:event, %{payload: %{"method" => "item/completed", "params" => %{"item" => %{"text" => "Parent finished"}}}}}
    assert_received {:event, %{event: :turn_completed, payload: %{"params" => %{"threadId" => "parent", "turn" => %{"id" => "active"}}}}}
    refute_received {:event, %{event: :turn_failed}}
    refute_received {:event, %{event: :turn_cancelled}}
    refute_received {:event, %{event: :turn_completed}}
  end

  test "native child results survive interruption and resume once in the same parent thread" do
    root = Path.join([File.cwd!(), "_build", "native-review-#{System.unique_integer([:positive])}"])
    workspace = Path.join(root, "workspaces/PRO-704")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)
    script = Path.join(root, "server.py")
    trace = Path.join(root, "trace.jsonl")
    state_root = Path.join(root, "state")

    # Wire fields follow codex-cli 0.154.0's generated experimental v2 types.
    File.write!(script, """
    import json,sys
    trace,workspace=sys.argv[1:]
    def emit(value):
      print(json.dumps(value),flush=True)
    def item(value):
      emit({'method':'item/completed','params':{'threadId':'parent','turnId':'parent-turn','item':value}})
    spawn={'type':'subAgentActivity','id':'round-1','kind':'started','agentThreadId':'child','agentPath':'/root/reviewer'}
    activity={'type':'subAgentActivity','id':'activity-1','kind':'completed','agentThreadId':'child','agentPath':'/root/reviewer'}
    resumed=False
    for line in sys.stdin:
      request=json.loads(line)
      with open(trace,'a') as f: f.write(json.dumps(request)+'\\n')
      method=request.get('method'); rid=request.get('id'); params=request.get('params',{})
      if method=='initialize': emit({'id':rid,'result':{}})
      elif method in ('thread/start','thread/resume'):
        resumed=method=='thread/resume'
        emit({'id':rid,'result':{'thread':{'id':'parent'}}})
      elif method=='thread/read':
        tid=params['threadId']
        emit({'id':rid,'result':{'thread':{'id':tid,'parentThreadId':None if tid=='parent' else 'parent','cwd':workspace}}})
      elif method=='thread/turns/list':
        if params['threadId']=='parent':
          turns=[{'id':'parent-turn','status':'interrupted','itemsView':'full','items':[spawn,activity]}] if resumed else []
        else:
          turns=[{'id':'child-turn','status':'completed','itemsView':'full','items':[{'type':'agentMessage','phase':'final_answer','id':'finding','text':'Findings: P1 keep the pending retry.'}]},
                 {'id':'child-turn-2','status':'completed','itemsView':'full','items':[{'type':'agentMessage','phase':'final_answer','id':'clean','text':'Keine Findings.'}]}]
        cursor=None
        if params['threadId']=='child':
          if params.get('cursor')=='second': turns=turns[1:]
          else: turns=turns[:1];cursor='second'
        emit({'id':rid,'result':{'data':turns,'nextCursor':cursor}})
      elif method=='turn/start':
        emit({'id':rid,'result':{'turn':{'id':'resumed-turn' if resumed else 'parent-turn'}}})
        if not resumed:
          item(spawn)
          emit({'method':'turn/completed','params':{'threadId':'child','turn':{'id':'child-turn','status':'completed'}}})
          item({'type':'collabAgentToolCall','id':'wait-1','tool':'wait','senderThreadId':'parent','receiverThreadIds':[],'agentsStates':{}})
          item(activity)
          emit({'id':9,'method':'item/tool/call','params':{'tool':'linear_graphql','arguments':{'query':'mutation { synthetic }'}}})
        emit({'method':'turn/completed','params':{'threadId':'parent','turn':{'id':'resumed-turn' if resumed else 'parent-turn','status':'completed' if resumed else 'interrupted'}}})
    """)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_command: "python3 #{script} #{trace} #{workspace}", codex_read_timeout_ms: 1_000)
    issue = %Issue{id: "native-review", identifier: "PRO-704", state: "Review (AI)"}
    opts = [issue: issue, review_state_root: state_root]
    {:ok, context} = ReviewState.open(issue, workspace, nil, opts)

    {:ok, session} = AppServer.start_session(workspace, opts)

    try do
      handoff = fn "linear_graphql", _ ->
        assert map_size(ReviewState.read(context)["results"]) == 2
        assert ReviewState.read(context)["calls"] == %{"round-1" => "parent-turn"}
        %{"success" => false, "output" => "RATELIMITED; retry-after: 3600"}
      end

      assert {:error, {:turn_cancelled, _}} = AppServer.run_turn(session, "First review", issue, tool_executor: handoff)
    after
      AppServer.stop_session(session)
    end

    before_retry = ReviewState.read(context)
    assert map_size(before_retry["results"]) == 2
    assert before_retry["calls"] == %{"round-1" => "parent-turn"}
    assert before_retry["agents"] == %{"child" => "parent-turn"}
    assert Enum.all?(before_retry["results"], fn {_, result} -> is_nil(result["delivered_in_turn"]) end)

    for _ <- 1..2 do
      {:ok, session} = AppServer.start_session(workspace, opts)

      try do
        assert {:ok, _} = AppServer.run_turn(session, "Continue", issue)
      after
        AppServer.stop_session(session)
      end
    end

    requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "thread/start")) == 1
    assert Enum.count(requests, &(&1["method"] == "thread/resume")) == 2
    prompts = for request <- requests, request["method"] == "turn/start", do: Jason.encode!(request["params"]["input"])
    assert [first, recovered, later] = prompts
    refute first =~ "P1 keep"
    assert recovered =~ "P1 keep"
    assert recovered =~ "Keine Findings."
    assert recovered =~ "parent/child/child-turn/finding"
    assert recovered =~ "1 bereits gestartete Reviewaufrufe; Budget unverändert"
    refute later =~ "P1 keep"
    after_retry = ReviewState.read(context)
    assert Map.keys(after_retry["results"]) == Map.keys(before_retry["results"])
    assert after_retry["calls"] == before_retry["calls"]
    assert Enum.all?(after_retry["results"], fn {_, result} -> result["delivered_in_turn"] == "resumed-turn" end)
  end

  test "a review abandoned before its first turn replaces a missing persisted thread and runs" do
    root = Path.join([File.cwd!(), "_build", "missing-review-rollout-#{System.unique_integer([:positive])}"])
    workspace = Path.join(root, "workspaces/PRO-922")
    state_root = Path.join(root, "state")
    script = Path.join(root, "server.py")
    trace = Path.join(root, "trace.jsonl")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(script, """
    import json,sys
    trace=sys.argv[1]
    def emit(value): print(json.dumps(value),flush=True)
    for line in sys.stdin:
      request=json.loads(line)
      with open(trace,'a') as f: f.write(json.dumps(request)+'\\n')
      method=request.get('method'); rid=request.get('id')
      if method=='initialize': emit({'id':rid,'result':{}})
      elif method=='thread/start':
        with open(trace) as f: starts=sum(json.loads(line).get('method')=='thread/start' for line in f)
        emit({'id':rid,'result':{'thread':{'id':'orphan' if starts==1 else 'replacement'}}})
      elif method=='thread/resume':
        emit({'id':rid,'error':{'code':-32600,'message':'no rollout found for thread id orphan'}})
      elif method=='turn/start':
        emit({'id':rid,'result':{'turn':{'id':'review-turn'}}})
        emit({'method':'turn/completed','params':{'threadId':'replacement','turn':{'id':'review-turn','status':'completed'}}})
    """)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: Path.join(root, "workspaces"), codex_command: "python3 #{script} #{trace}")
    File.write!(Path.join(workspace, "README.md"), "before review\n")
    assert {_, 0} = System.cmd("git", ["-C", workspace, "init", "-b", "main"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", workspace, "add", "README.md"], stderr_to_stdout: true)
    assert {_, 0} = System.cmd("git", ["-C", workspace, "commit", "-m", "initial"], stderr_to_stdout: true)
    File.write!(Path.join(workspace, "review.txt"), "pending\n")

    assert {:ok, :committed} =
             SymphonyElixir.Workspace.prepare_review_autocommit(workspace, "PRO-922 Review (AI) Autocommit\n\nTest snapshot")

    {autocommit_head, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])

    {marker_path, 0} =
      System.cmd("git", ["-C", workspace, "rev-parse", "--path-format=absolute", "--git-path", "symphony.review-ai-autocommit.done"])

    marker_path = String.trim(marker_path)
    assert File.exists?(marker_path)
    issue = %Issue{id: "missing-review-rollout", identifier: "PRO-922", title: "Missing review rollout", state: "Review (AI)"}
    opts = [issue: issue, review_state_root: state_root]
    {:ok, context} = ReviewState.open(issue, workspace, nil, opts)

    # The first process exits after state creation, before turn/start (e.g. comment_journal_busy).
    {:ok, first_session} = AppServer.start_session(workspace, opts)
    assert first_session.thread_id == "orphan"
    AppServer.stop_session(first_session)
    assert %{"thread_id" => "orphan", "calls" => %{}, "results" => %{}} = ReviewState.read(context)

    log =
      capture_log(fn ->
        assert {:ok, %{thread_id: "replacement", turn_id: "review-turn"}} = AppServer.run(workspace, "Review now", issue, opts)
      end)

    assert log =~ "PRO-922"
    assert log =~ "orphan"
    assert log =~ "no rollout found"
    assert log =~ "[warning]"
    assert ReviewState.read(context)["thread_id"] == "replacement"
    assert {^autocommit_head, 0} = System.cmd("git", ["-C", workspace, "rev-parse", "HEAD"])
    assert File.exists?(marker_path)
    assert {:ok, :already_recorded} = SymphonyElixir.Workspace.prepare_review_autocommit(workspace, "should not commit again")
    requests = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.map(requests, & &1["method"]) |> Enum.filter(&(&1 in ["thread/start", "thread/resume", "turn/start"])) ==
             ["thread/start", "thread/resume", "thread/start", "turn/start"]
  end

  test "missing-thread recovery refuses review history, other errors and dialog sessions" do
    root = Path.join([File.cwd!(), "_build", "protected-review-rollout-#{System.unique_integer([:positive])}"])
    workspace = Path.join(root, "workspaces/PRO-922")
    state_root = Path.join(root, "state")
    script = Path.join(root, "server.py")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(script, """
    import json,sys
    trace,config_path=sys.argv[1:]
    with open(config_path) as f: config=json.load(f)
    for line in sys.stdin:
      request=json.loads(line)
      with open(trace,'a') as f: f.write(json.dumps(request)+'\\n')
      method=request.get('method'); rid=request.get('id')
      if method=='initialize': print(json.dumps({'id':rid,'result':{}}),flush=True)
      elif method=='thread/resume': print(json.dumps({'id':rid,'error':config}),flush=True)
      elif method=='thread/start': print(json.dumps({'id':rid,'result':{'thread':{'id':'unexpected'}}}),flush=True)
    """)

    missing = %{"code" => -32_600, "message" => "no rollout found for thread id orphan"}

    for {case_name, error} <- [
          {"calls", missing},
          {"results", missing},
          {"agents", missing},
          {"other-error", %{"code" => -32_600, "message" => "backend busy"}},
          {"other-code", %{"code" => -32_000, "message" => missing["message"]}},
          {"other-thread", %{"code" => -32_600, "message" => "no rollout found for thread id other"}},
          {"thread-id-prefix", %{"code" => -32_600, "message" => "no rollout found for thread id orphan-extra"}},
          {"dialog", missing}
        ] do
      trace = Path.join(root, "#{case_name}.jsonl")
      config = Path.join(root, "#{case_name}.json")
      File.write!(config, Jason.encode!(error))

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: Path.join(root, "workspaces"),
        codex_command: "python3 #{script} #{trace} #{config}"
      )

      issue = %Issue{
        id: "protected-review-#{case_name}",
        identifier: "PRO-922",
        state: if(case_name == "dialog", do: "Todo (Dialog-AI)", else: "Review (AI)")
      }

      opts = [issue: issue, review_state_root: state_root]

      before =
        if case_name == "dialog" do
          nil
        else
          {:ok, context} = ReviewState.open(issue, workspace, nil, opts)
          :ok = ReviewState.bind_thread(context, "orphan")
          record = ReviewState.read(context)

          updated =
            case case_name do
              "calls" ->
                Map.put(record, "calls", %{"review-call" => "turn-1"})

              "agents" ->
                Map.put(record, "agents", %{"child" => "turn-1"})

              "results" ->
                result = %{"parent_thread_id" => "orphan", "child_thread_id" => "child", "turn_id" => "child-turn", "item_id" => "final", "text" => "Finding", "delivered_in_turn" => nil}

                record
                |> Map.put("agents", %{"child" => "turn-1"})
                |> Map.put("results", %{"orphan/child/child-turn/final" => result})

              _ ->
                record
            end

          :ok = DurableState.write(context.path, updated)
          {context, updated}
        end

      opts = if case_name == "dialog", do: Keyword.put(opts, :thread_id, "orphan"), else: opts
      assert {:error, {:thread_resume_failed, "orphan", {:response_error, ^error}}} = AppServer.start_session(workspace, opts)
      if before, do: assert(ReviewState.read(elem(before, 0)) == elem(before, 1))

      methods = trace |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!(&1)["method"])
      assert "thread/resume" in methods
      refute "thread/start" in methods
      refute "turn/start" in methods
    end
  end
end
