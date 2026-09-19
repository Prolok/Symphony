defmodule SymphonyElixir.Yolo.Workspace do
  @moduledoc "Dedicated detached project checkout; no ticket hooks, branches or main checkout updates."
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
         {_, 0} <- git(context.root, ["worktree", "add", "--detach", path, sha]),
         workspace = %{path: path, sha: sha},
         :ok <- PoIncoming.record(workspace, run_id) do
      {:ok, workspace}
    else
      _ -> {:error, :yolo_workspace_unavailable}
    end
  end

  @spec unchanged?(map()) :: boolean()
  def unchanged?(workspace) do
    with {head, 0} <- git(workspace.path, ["rev-parse", "HEAD"]),
         {status, 0} <- git(workspace.path, ["status", "--porcelain"]) do
      String.trim(head) == workspace.sha and status == ""
    else
      _ -> false
    end
  end

  defp git(path, args), do: System.cmd("git", args, cd: path, stderr_to_stdout: true, env: Config.without_linear_secret([]))
end
