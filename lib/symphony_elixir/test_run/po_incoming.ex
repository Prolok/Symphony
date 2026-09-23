defmodule SymphonyElixir.TestRun.PoIncoming do
  @moduledoc "Bound proof of a mixed incoming PO group, with separate workspace receipts and cleanup."
  alias SymphonyElixir.{Config, PathSafety, ProjectContext, TestInstance}
  alias SymphonyElixir.Linear.{Client, DurableState}
  alias SymphonyElixir.Yolo.{OpenClaw, Store, Workspace}
  alias SymphonyElixir.Yolo.OpenClaw.Journal, as: OpenClawJournal

  @spec record(map(), String.t()) :: :ok | {:error, term()}
  def record(workspace, run_id) do
    if Config.test_run_stage() == "run" do
      with {:ok, plan} <- DurableState.read(Config.test_run_plan()) do
        context = ProjectContext.current()
        receipt = %{"path" => workspace.path, "sha" => workspace.sha, "source" => plan["source"], "project" => context.name, "cleaned" => false}
        DurableState.write(Path.join(directory(plan), run_id <> ".json"), receipt)
      end
    else
      :ok
    end
  end

  @spec probe(map(), map()) :: {:ok, map()} | {:error, term()}
  def probe(issue, %{"po_incoming" => true} = fixture) do
    with {:ok, [context]} <- Client.resolve_relay_contexts([ProjectContext.current()]) do
      ProjectContext.with_context(context, fn ->
        probe_receipt(Store.read("incoming"), issue, fixture)
      end)
    end
  end

  def probe(_, fixture), do: {:ok, fixture}

  @spec decision_confirmed?(map(), map(), map()) :: boolean()
  def decision_confirmed?(issue, fixture, completed) do
    labels = get_in(issue, ["labels", "nodes"]) || []
    names = Enum.map(labels, &String.downcase(&1["name"]))

    Enum.all?([~s(skip "freigabe implementierung"), ~s(skip "freigabe review")], &(&1 in names)) and
      get_in(issue, ["assignee", "id"]) == fixture["assignee_id"] and is_binary(completed[fixture["id"]])
  end

  defp probe_receipt({:ok, %{"attempt" => %{"session_id" => session, "completed" => completed, "sha" => sha, "workspace" => path}}}, issue, fixture) do
    receipt = %{"session_id" => session, "sha" => sha, "workspace" => path, "openclaw" => OpenClawJournal.receipt("incoming", session)}
    if decision_confirmed?(issue, fixture, completed), do: {:ok, Map.put(fixture, "po_receipt", receipt)}, else: {:ok, fixture}
  end

  defp probe_receipt({:ok, _}, _issue, fixture), do: {:ok, fixture}
  defp probe_receipt(error, _issue, _fixture), do: error

  @spec cleanup(ProjectContext.t(), map(), keyword()) :: :ok | {:error, term()}
  def cleanup(context, plan, opts \\ []) do
    Path.wildcard(Path.join(directory(plan), "*.json"))
    |> Enum.reduce_while(:ok, fn path, _ ->
      case clean_receipt(path, context, plan, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp clean_receipt(path, context, plan, opts) do
    with {:ok, receipt} <- DurableState.read(path) do
      if receipt["project"] == context.name and receipt["cleaned"] != true do
        remove_receipt(path, receipt, context, plan, opts)
      else
        :ok
      end
    end
  end

  defp remove_receipt(path, receipt, context, plan, opts) do
    with true <- receipt["source"] == plan["source"],
         workspace = %{path: receipt["path"], sha: receipt["sha"]},
         :ok <- safe_workspace(context, workspace),
         :ok <- external_finished(context, receipt, Path.basename(path, ".json"), opts),
         :ok <- remove(context, workspace) do
      DurableState.write(path, Map.put(receipt, "cleaned", true))
    else
      _ -> {:error, :test_po_workspace_cleanup_unconfirmed}
    end
  end

  defp external_finished(context, receipt, run_id, opts) do
    ProjectContext.with_context(context, fn ->
      with {:ok, orders} <- OpenClawJournal.pending(),
           :ok <- reconcile_owned(Enum.filter(orders, &(&1["workspace"] == receipt["path"])), context, receipt, run_id, opts),
           {:ok, remaining} <- OpenClawJournal.pending() do
        cleanup_allowed(remaining, receipt["path"])
      end
    end)
  end

  defp reconcile_owned([], _context, _receipt, _run_id, _opts), do: :ok

  defp reconcile_owned([%{"id" => id} = order], context, receipt, id, opts) do
    with true <- order["project_id"] == context.id and order["sha"] == receipt["sha"],
         {:ok, [verified]} <- Client.resolve_relay_contexts([context]),
         {:ok, _} <- ProjectContext.with_context(verified, fn -> OpenClaw.reconcile_terminal(order, opts) end) do
      :ok
    else
      _ -> {:error, :openclaw_cleanup_pending}
    end
  end

  defp reconcile_owned(_, _, _, _, _), do: {:error, :openclaw_cleanup_pending}

  defp cleanup_allowed(orders, path) do
    if Enum.any?(orders, &(&1["workspace"] == path)), do: {:error, :openclaw_cleanup_pending}, else: :ok
  end

  defp safe_workspace(context, workspace) do
    with {:ok, root} <- PathSafety.canonicalize(context.settings.workspace.root),
         {:ok, path} <- PathSafety.canonicalize(workspace.path),
         true <- path == workspace.path and String.starts_with?(path, Path.join(root, "yolo") <> "/"),
         {common, 0} <- git(context.root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
      verify_existing_workspace(path, common, workspace)
    end
  end

  defp verify_existing_workspace(path, common, workspace) do
    if File.exists?(path) do
      with {^common, 0} <- git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]), true <- Workspace.unchanged?(workspace), do: :ok
    else
      :ok
    end
  end

  defp remove(context, workspace) do
    if File.exists?(workspace.path) do
      case git(context.root, ["worktree", "remove", workspace.path]) do
        {_, 0} -> :ok
        _ -> {:error, :test_po_workspace_remove_failed}
      end
    else
      :ok
    end
  end

  defp directory(plan), do: Path.join([TestInstance.state_root(), "runs", plan["run_id"], "yolo-workspaces"])
  defp git(path, args), do: System.cmd("git", args, cd: path, stderr_to_stdout: true, env: Config.without_linear_secret([]))
end
