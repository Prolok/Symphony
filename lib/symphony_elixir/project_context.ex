defmodule SymphonyElixir.ProjectContext do
  @moduledoc """
  Immutable project configuration passed explicitly to each project runtime and worker.
  Binding a context changes only the calling process, never the OS environment or CWD.
  """

  alias SymphonyElixir.{Config, EnvFile, PathSafety, Workflow}
  require Logger

  defstruct [:id, :name, :root, :workflow_path, :workflow, :settings, env: %{}]
  @type t :: %__MODULE__{}
  @key {__MODULE__, :context}

  @spec current() :: t() | nil
  def current, do: Process.get(@key)

  @spec bind(t() | nil) :: :ok
  def bind(context) do
    Process.put(@key, context)
    :ok
  end

  @spec with_context(t() | nil, (-> result)) :: result when result: var
  def with_context(context, fun) do
    previous = current()
    bind(context)

    try do
      fun.()
    after
      bind(previous)
    end
  end

  @spec env(String.t()) :: String.t() | nil
  def env(name) do
    case current() do
      %__MODULE__{env: env} -> Map.get(env, name)
      nil -> System.get_env(name)
    end
  end

  @spec discover(String.t(), Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
  def discover(value, code_root) do
    with {:ok, roots} <- normalize_roots(value, code_root) do
      Enum.reduce_while(roots, {:ok, []}, &discover_root/2)
      |> canonical_projects()
    end
  end

  @spec load(Path.t(), Path.t(), map()) :: {:ok, t()} | {:error, term()}
  def load(root, workflow_path, root_env) do
    with {:ok, root} <- PathSafety.canonicalize(root),
         {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, public_env} <- EnvFile.read_public(EnvFile.config_dir(root), get_in(workflow.config, ["tracker", "app", "client_secret_env"])) do
      env =
        public_env
        |> Map.drop(EnvFile.root_config_names())
        |> Map.merge(root_env)
        |> Map.merge(%{
          "SYMPHONY_PROJECT_ROOT" => root,
          "SYMPHONY_SOURCE_REPO" => root,
          "SYMPHONY_LINEAR_ENV_DIR" => EnvFile.config_dir(root),
          "SYMPHONY_PROJECT_WORKTREES_ROOT" => root <> "-worktrees",
          "SYMPHONY_WORKFLOW_FILE" => workflow_path,
          "SYMPHONY_WORKFLOW_DIR" => SymphonyElixir.RuntimePaths.workflow_dir()
        })

      context = %__MODULE__{
        id: root,
        name: Path.basename(root),
        root: root,
        workflow_path: workflow_path,
        workflow: workflow,
        env: env
      }

      with_context(context, &resolve_context/0)
    end
  end

  @doc "Create a new configuration snapshot from the last accepted workflow; existing workers retain their snapshot."
  @spec refresh(t()) :: t()
  def refresh(context) do
    workflow =
      with_context(nil, fn ->
        if Workflow.workflow_file_path() == context.workflow_path,
          do: SymphonyElixir.WorkflowStore.current(),
          else: {:ok, context.workflow}
      end)

    case workflow do
      {:ok, workflow} when workflow == context.workflow ->
        context

      {:ok, workflow} ->
        candidate = %{context | workflow: workflow, settings: nil}

        accept_refreshed_context(with_context(candidate, &resolve_context/0), context)

      {:error, reason} ->
        keep_context(context, reason)
    end
  end

  defp accept_refreshed_context({:ok, updated}, context) do
    keys = [:auth_mode, :app, :assignee, :endpoint, :kind, :project_slug, :team_key]

    if Map.take(updated.settings.tracker, keys) == Map.take(context.settings.tracker, keys) and
         updated.settings.workspace.root == context.settings.workspace.root,
       do: updated,
       else: keep_context(context, :project_binding_change_requires_restart)
  end

  defp accept_refreshed_context({:error, reason}, context), do: keep_context(context, reason)

  defp keep_context(context, reason) do
    Logger.error("Workflow reload rejected project_root=#{context.root} reason=#{inspect(reason)}; keeping last known good project configuration")
    context
  end

  defp resolve_context do
    with {:ok, settings} <- Config.settings(),
         :ok <- Config.validate_startup_requirements() do
      {:ok, %{current() | settings: settings}}
    end
  end

  defp discover_root(root, {:ok, projects}) do
    case File.ls(root) do
      {:ok, names} ->
        found = names |> Enum.sort() |> Enum.map(&Path.join(root, &1)) |> Enum.filter(&File.dir?(Path.join(&1, ".symphony")))
        {:cont, {:ok, projects ++ found}}

      {:error, reason} ->
        {:halt, {:error, {:project_root_unavailable, root, reason}}}
    end
  end

  defp normalize_roots(value, code_root) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand(&1, code_root))
    |> canonical_projects()
  end

  defp canonical_projects({:error, _} = error), do: error
  defp canonical_projects({:ok, paths}), do: canonical_projects(paths)

  defp canonical_projects(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case PathSafety.canonicalize(path) do
        {:ok, canonical} -> {:cont, {:ok, acc ++ [canonical]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.uniq(paths)}
      error -> error
    end
  end
end
