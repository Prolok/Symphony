defmodule SymphonyElixir.ReviewResumeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ReviewState

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
end
