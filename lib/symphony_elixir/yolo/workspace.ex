defmodule SymphonyElixir.Yolo.Workspace do
  @moduledoc "Dedicated detached project checkout; no ticket hooks, branches or main checkout updates."
  require Logger
  alias SymphonyElixir.TestRun.PoIncoming, as: PoIncoming

  alias SymphonyElixir.{Config, PathSafety, ProjectContext}

  @spec create(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create(group, run_id) do
    context = ProjectContext.current()

    with true <- group in ~w(incoming planning in_progress blocker review),
         {:ok, _} <- Ecto.UUID.cast(run_id),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         path = Path.join([root, "yolo", group, run_id]),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         false <- File.exists?(path),
         {_, 0} <- git(context.root, ["fetch", "origin", "main"]),
         {sha, 0} <- git(context.root, ["rev-parse", "--verify", "origin/main^{commit}"]),
         sha = String.trim(sha),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {_, 0} <- git(context.root, ["worktree", "add", "--detach", path, sha]) do
      record_created(group, run_id, %{path: path, sha: sha})
    else
      _ -> {:error, :yolo_workspace_unavailable}
    end
  end

  defp record_created(group, run_id, workspace) do
    case PoIncoming.record(workspace, run_id) do
      :ok -> {:ok, workspace}
      error -> cleanup_receipt_failure(group, run_id, workspace, error)
    end
  end

  defp cleanup_receipt_failure("review", run_id, workspace, error) do
    cleanup = remove_review(workspace, run_id)
    Logger.warning("YOLO review checkout receipt failed group=review run_id=#{run_id} reason=#{inspect(error)} checkout_cleanup=#{inspect(cleanup)}")
    {:error, :yolo_workspace_unavailable}
  end

  defp cleanup_receipt_failure(_, _, _, _), do: {:error, :yolo_workspace_unavailable}

  @spec unchanged?(map()) :: boolean()
  def unchanged?(workspace) do
    with {head, 0} <- git(workspace.path, ["rev-parse", "HEAD"]),
         {status, 0} <- git(workspace.path, ["status", "--porcelain", "--untracked-files=all"]) do
      String.trim(head) == workspace.sha and status == ""
    else
      _ -> false
    end
  end

  @doc "Remove only the registered, clean review checkout owned by this run."
  @spec remove_review(map(), String.t()) :: :ok | {:error, atom()}
  def remove_review(workspace, run_id), do: remove_review(workspace, run_id, true)

  @spec remove_review(map(), String.t(), boolean()) :: :ok | {:error, atom()}
  def remove_review(%{path: path, sha: sha}, run_id, apply?) do
    context = ProjectContext.current()

    with {:ok, _} <- Ecto.UUID.cast(run_id),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         ^path <- Path.join([root, "yolo", "review", run_id]),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         true <- File.dir?(path),
         {top, 0} <- git(path, ["rev-parse", "--show-toplevel"]),
         {:ok, ^path} <- PathSafety.canonicalize(String.trim(top)),
         {common, 0} <- git(context.root, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {^common, 0} <- git(path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]),
         {listing, 0} <- git(context.root, ["worktree", "list", "--porcelain"]),
         true <- registered?(listing, path, sha),
         true <- unchanged?(%{path: path, sha: sha}),
         {"", 0} <- git(path, ["status", "--porcelain", "--ignored", "--untracked-files=all"]),
         {_, 0} <- if(apply?, do: git(context.root, ["worktree", "remove", path]), else: {"", 0}) do
      :ok
    else
      _ -> {:error, :yolo_review_checkout_unsafe}
    end
  end

  def remove_review(_, _, _), do: {:error, :yolo_review_checkout_unsafe}

  @spec owned_review?(map(), String.t()) :: boolean()
  def owned_review?(%{path: path}, run_id) do
    with {:ok, _} <- Ecto.UUID.cast(run_id),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root) do
      path == Path.join([root, "yolo", "review", run_id])
    else
      _ -> false
    end
  end

  def owned_review?(_, _), do: false

  @spec review_checkout_present?(String.t()) :: {:ok, boolean()} | {:error, atom()}
  def review_checkout_present?(run_id) do
    context = ProjectContext.current()

    with {:ok, _} <- Ecto.UUID.cast(run_id),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         path = Path.join([root, "yolo", "review", run_id]),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         {listing, 0} <- git(context.root, ["worktree", "list", "--porcelain"]) do
      registered? = String.contains?(listing, "worktree " <> path <> "\n")
      {:ok, File.exists?(path) or registered?}
    else
      _ -> {:error, :yolo_review_checkout_unknown}
    end
  end

  defp registered?(listing, path, sha) do
    Enum.any?(String.split(listing, "\n\n"), fn entry ->
      lines = String.split(entry, "\n")
      ("worktree " <> path) in lines and ("HEAD " <> sha) in lines and "detached" in lines
    end)
  end

  defp git(path, args), do: System.cmd("git", args, cd: path, stderr_to_stdout: true, env: Config.without_linear_secret([]))
end
