defmodule SymphonyElixir.TestRun.PoIncoming do
  @moduledoc "Bound proof of a mixed incoming PO group, with separate workspace receipts and cleanup."
  alias SymphonyElixir.{Config, PathSafety, ProjectContext, TestInstance}
  alias SymphonyElixir.Linear.{Client, DurableState}
  alias SymphonyElixir.Yolo.{Store, Workspace}

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

  defp probe_receipt({:ok, %{"attempt" => %{"session_id" => session, "completed" => completed, "sha" => sha, "workspace" => path}}}, issue, fixture) do
    labels = get_in(issue, ["labels", "nodes"]) || []
    names = Enum.map(labels, &String.downcase(&1["name"]))

    valid =
      Enum.all?([~s(skip "freigabe implementierung"), ~s(skip "freigabe review")], &(&1 in names)) and
        get_in(issue, ["assignee", "id"]) == fixture["assignee_id"] and is_binary(completed[fixture["id"]])

    if valid, do: {:ok, Map.put(fixture, "po_receipt", %{"session_id" => session, "sha" => sha, "workspace" => path})}, else: {:ok, fixture}
  end

  defp probe_receipt({:ok, _}, _issue, fixture), do: {:ok, fixture}
  defp probe_receipt(error, _issue, _fixture), do: error

  @spec cleanup(ProjectContext.t(), map()) :: :ok | {:error, term()}
  def cleanup(context, plan) do
    Path.wildcard(Path.join(directory(plan), "*.json"))
    |> Enum.reduce_while(:ok, fn path, _ ->
      case clean_receipt(path, context, plan) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp clean_receipt(path, context, plan) do
    with {:ok, receipt} <- DurableState.read(path) do
      if receipt["project"] == context.name and receipt["cleaned"] != true do
        remove_receipt(path, receipt, context, plan)
      else
        :ok
      end
    end
  end

  defp remove_receipt(path, receipt, context, plan) do
    with true <- receipt["source"] == plan["source"],
         workspace = %{path: receipt["path"], sha: receipt["sha"]},
         :ok <- safe_workspace(context, workspace),
         :ok <- remove(context, workspace) do
      DurableState.write(path, Map.put(receipt, "cleaned", true))
    else
      _ -> {:error, :test_po_workspace_cleanup_unconfirmed}
    end
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
