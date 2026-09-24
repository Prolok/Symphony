defmodule SymphonyElixir.Codex.TestToolTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.{DynamicTool, MCPServer, TestTool}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.ProjectContext

  setup do
    root = Path.dirname(Workflow.workflow_file_path())
    workspace = Path.join(root, "PRO-756")
    File.mkdir_p!(workspace)
    settings = Config.settings!() |> put_in([Access.key(:workspace), Access.key(:root)], root)
    settings = put_in(settings.worker.test_executor_socket, Path.join(root, "executor.sock"))
    settings = put_in(settings.worker.test_executor, %{"scenarios" => ~w(bootstrap workflow failure-probe po_handoff po_followup)})
    issue = %Issue{id: "bound", identifier: "PRO-756", state: "In Arbeit (AI)", assigned_to_worker: true}
    %{context: %ProjectContext{id: root, root: root, name: "symphony-test", settings: settings}, issue: issue, workspace: workspace}
  end

  defp args do
    %{"operation" => "start", "run_id" => "run-1", "head_sha" => String.duplicate("a", 40), "source_sha256" => String.duplicate("b", 64), "scenario" => "bootstrap"}
  end

  test "both transports bind the active issue and workspace without accepting operator paths", %{context: context, issue: issue, workspace: workspace} do
    ProjectContext.with_context(context, fn ->
      WriteContext.with_context(%{issue_id: issue.id}, fn ->
        opts = [
          contexts: [context],
          poller_context: fn _ -> context end,
          fetch_issue: fn [id] ->
            assert id == issue.id
            {:ok, [issue]}
          end,
          test_request: fn socket, payload ->
            assert socket == context.settings.worker.test_executor_socket
            assert payload["checkout"] == workspace
            assert payload["issue_id"] == issue.id
            assert payload["identifier"] == issue.identifier
            assert payload["source_sha256"] == args()["source_sha256"]
            {:ok, %{"status" => "failed", "cleanup" => true}}
          end
        ]

        for name <- ["symphony_test", "symphony_linear.symphony_test"], scenario <- ~w(bootstrap workflow failure-probe po_handoff po_followup) do
          args = Map.put(args(), "scenario", scenario)
          assert DynamicTool.execute(name, args, opts)["success"]
          reply = MCPServer.handle_request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => name, "arguments" => args}}, opts)
          refute reply["result"]["isError"]
        end

        for bad <- [nil, %{}, Map.put(args(), "manifest", "/private"), Map.put(args(), "head_sha", nil), Map.put(args(), "run_id", "../escape"), Map.put(args(), "scenario", "shell")] do
          assert {:error, :invalid_test_request} = TestTool.invoke(bad, opts)
        end

        assert {:error, :offline} = TestTool.invoke(args(), Keyword.put(opts, :fetch_issue, fn _ -> {:error, :offline} end))
        assert TestTool.mcp_call(%{})["isError"]
        refute TestTool.execute(%{})["success"]
      end)
    end)
  end

  test "unprovisioned, remote, manual and escaped contexts never contact the executor", %{context: context, issue: issue} do
    ProjectContext.with_context(context, fn ->
      assert {:error, :test_worker_issue_missing} = TestTool.invoke(args())

      WriteContext.with_context(%{issue_id: issue.id}, fn ->
        opts = [
          contexts: [context],
          poller_context: fn _ -> context end,
          fetch_issue: fn _ -> {:ok, [issue]} end,
          test_request: fn _, _ -> flunk("unbound execution") end
        ]

        disabled = put_in(context.settings.worker.test_executor_socket, nil)

        ProjectContext.with_context(disabled, fn ->
          disabled_opts = opts |> Keyword.put(:contexts, [disabled]) |> Keyword.put(:poller_context, fn _ -> disabled end)
          assert {:error, :test_executor_not_configured} = TestTool.invoke(args(), disabled_opts)
        end)

        WriteContext.with_context(%{worker_host: "remote"}, fn ->
          assert {:error, :test_remote_worker_not_supported} = TestTool.invoke(args(), opts)
        end)

        for phase <- ["Merge (AI)", "Todo (Dialog-AI)", "Planung (AI)"] do
          assert {:error, _} = TestTool.invoke(args(), Keyword.put(opts, :fetch_issue, fn _ -> {:ok, [%{issue | state: phase}]} end))
        end

        assert {:error, :test_workspace_unverified} = TestTool.invoke(args(), Keyword.put(opts, :fetch_issue, fn _ -> {:ok, [%{issue | identifier: "../foreign"}]} end))
      end)
    end)

    assert {:error, _} = Schema.parse(%{"worker" => %{"test_executor_socket" => "relative/socket"}})
  end

  test "a tilor project worker uses the Prolok executor binding with named rejection causes", %{context: target, issue: issue} do
    %ProjectContext{} = target
    settings = %{target.settings | worker: %{target.settings.worker | test_executor: nil, test_executor_socket: nil}}
    caller = %{target | id: target.id <> "-tilor", root: target.root <> "-tilor", name: "tilor-project", settings: settings}

    opts = [
      contexts: [caller, target],
      poller_context: fn _ -> caller end,
      fetch_issue: fn _ -> {:ok, [issue]} end,
      test_request: fn socket, _ ->
        assert socket == target.settings.worker.test_executor_socket
        {:ok, %{"running" => true}}
      end
    ]

    ProjectContext.with_context(caller, fn ->
      WriteContext.with_context(%{issue_id: issue.id}, fn ->
        assert {:ok, %{"running" => true}} = TestTool.invoke(args(), opts)
        assert {:error, :test_poller_context_changed} = TestTool.invoke(args(), Keyword.put(opts, :poller_context, fn _ -> target end))
        assert {:error, :test_poller_context_changed} = TestTool.invoke(args(), Keyword.put(opts, :poller_context, fn _ -> nil end))
        assert {:error, :test_poller_context_unavailable} = TestTool.invoke(args(), Keyword.put(opts, :poller_context, fn _ -> exit(:offline) end))
        assert {:error, :test_project_not_bound} = TestTool.invoke(args(), Keyword.put(opts, :contexts, [target]))
        assert {:error, :test_executor_not_configured} = TestTool.invoke(args(), Keyword.put(opts, :contexts, [caller]))
        assert {:error, :test_assignee_not_bound} = TestTool.invoke(args(), Keyword.put(opts, :fetch_issue, fn _ -> {:ok, [%{issue | assigned_to_worker: false}]} end))
        assert {:error, :test_issue_lookup_incomplete} = TestTool.invoke(args(), Keyword.put(opts, :fetch_issue, fn _ -> {:ok, []} end))
        assert {:error, :test_phase_not_allowed} = TestTool.invoke(args(), Keyword.put(opts, :fetch_issue, fn _ -> {:ok, [%{issue | state: "Merge (AI)"}]} end))
      end)
    end)
  end

  test "Unix transport handles receipts, rejections and uncertain responses without retry" do
    for response <- [~s({"status":"running"}), ~s({"error":"source_mismatch"}), "not-json", "[]", :closed] do
      path = Path.join(File.cwd!(), "tmp/executor-#{System.unique_integer([:positive])}.sock")
      File.mkdir_p!(Path.dirname(path))
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}, packet: :line])
      parent = self()

      spawn_link(fn ->
        {:ok, peer} = :gen_tcp.accept(listener)
        {:ok, raw} = :gen_tcp.recv(peer, 0, 1_000)
        send(parent, {:request, Jason.decode!(raw)})
        if response != :closed, do: :gen_tcp.send(peer, response <> "\n")
        :gen_tcp.close(peer)
      end)

      result = TestTool.request(path, %{"run_id" => "same"})
      assert_receive {:request, %{"run_id" => "same"}}

      case response do
        ~s({"status":"running"}) -> assert result == {:ok, %{"status" => "running"}}
        ~s({"error":"source_mismatch"}) -> assert result == {:error, {:test_executor_rejected, "source_mismatch"}}
        _ -> assert result == {:error, :test_executor_response_uncertain_query_same_run}
      end

      :gen_tcp.close(listener)
      File.rm!(path)
    end

    assert {:error, :test_executor_unavailable} = TestTool.request("/missing/symphony.sock", %{})
  end
end
