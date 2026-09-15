defmodule SymphonyElixir.ProjectContext do
  @moduledoc """
  Immutable project configuration passed explicitly to each project runtime and worker.
  Binding a context changes only the calling process, never the OS environment or CWD.
  """

  alias SymphonyElixir.{Config, EnvFile, PathSafety, Workflow}
  require Logger

  defstruct [:id, :name, :root, :workflow_path, :workflow, :settings, :code_root, root_env: %{}, env: %{}]
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

  @spec load(Path.t(), Path.t(), map(), Path.t() | nil) :: {:ok, t()} | {:error, term()}
  def load(root, workflow_path, root_env, code_root \\ nil) do
    with {:ok, root} <- PathSafety.canonicalize(root),
         {:ok, workflow} <- Workflow.load(workflow_path),
         {:ok, public_env} <- EnvFile.read_public(EnvFile.config_dir(root), get_in(workflow.config, ["tracker", "app", "client_secret_env"]), get_in(workflow.config, ["tracker", "relay", "key_env"])) do
      env =
        public_env
        |> Map.drop(EnvFile.root_config_names() ++ SymphonyElixir.RuntimePaths.runtime_env_names())
        |> Map.merge(root_env)
        |> Map.merge(%{
          "SYMPHONY_ROOT_DIR" => code_root || SymphonyElixir.RuntimePaths.workflow_dir(),
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
        code_root: code_root,
        root_env: root_env,
        env: env
      }

      with_context(context, &resolve_context/0)
    end
  end

  @doc "Reload the original workflow and env files; existing workers retain their accepted context."
  @spec refresh(t()) :: t()
  def refresh(context) do
    candidate =
      with {:ok, root_env} <- refreshed_root_env(context) do
        load(context.root, context.workflow_path, root_env, context.code_root)
      end

    accept_refreshed_context(candidate, context)
  end

  defp refreshed_root_env(%{code_root: nil, root_env: env}), do: {:ok, env}

  defp refreshed_root_env(context) do
    with {:ok, values} <- EnvFile.read_root(context.code_root) do
      {:ok, Map.merge(values, Map.take(System.get_env(), EnvFile.root_config_names()))}
    end
  end

  @doc "Carry the accepted public configuration into worker subprocesses without copying files."
  @spec runtime_env() :: map()
  def runtime_env do
    case current() do
      nil ->
        %{}

      context ->
        payload = Map.take(context, [:root, :workflow_path, :workflow, :env])
        encoded = payload |> Jason.encode!() |> :zlib.compress() |> Base.url_encode64()
        %{"SYMPHONY_PROJECT_CONTEXT" => encoded}
    end
  end

  @spec restore(String.t(), Path.t()) :: :ok | {:error, term()}
  def restore(encoded, config_dir) do
    with {:ok, compressed} <- Base.url_decode64(encoded),
         {:ok, payload} <- Jason.decode(:zlib.uncompress(compressed)),
         %{"root" => root, "workflow_path" => path, "workflow" => workflow, "env" => env} <- payload,
         true <- EnvFile.config_dir(root) == Path.expand(config_dir),
         true <- path == System.get_env("SYMPHONY_WORKFLOW_FILE"),
         true <- is_map(env) and Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end),
         %{"config" => config, "prompt" => prompt, "prompt_template" => template} <- workflow do
      context = %__MODULE__{
        id: root,
        name: Path.basename(root),
        root: root,
        workflow_path: path,
        workflow: %{config: config, prompt: prompt, prompt_template: template},
        env: env
      }

      case with_context(context, &resolve_context/0) do
        {:ok, resolved} -> bind(resolved)
        _ -> {:error, :invalid_project_context}
      end
    else
      _ -> {:error, :invalid_project_context}
    end
  rescue
    _ -> {:error, :invalid_project_context}
  end

  defp accept_refreshed_context({:ok, %{workflow: workflow, env: env}}, %{workflow: workflow, env: env} = context), do: context

  defp accept_refreshed_context({:ok, updated}, context) do
    keys = [:auth_mode, :app, :relay, :assignee, :endpoint, :kind, :project_slug, :team_key]

    if Map.take(updated.settings.tracker, keys) == Map.take(context.settings.tracker, keys) and
         updated.settings.workspace.root == context.settings.workspace.root,
       do: updated,
       else: keep_context(context, :project_binding_change_requires_restart)
  end

  defp accept_refreshed_context({:error, reason}, context), do: keep_context(context, reason)

  defp keep_context(context, reason) do
    Logger.error("Configuration reload rejected project_root=#{context.root} reason=#{inspect(reason)}; keeping last known good project configuration")
    context
  end

  defp resolve_context do
    with {:ok, settings} <- Config.settings(),
         :ok <- Config.validate_startup_requirements(),
         :ok <- validate_review_budget() do
      {:ok, %{current() | settings: settings}}
    end
  end

  defp validate_review_budget do
    Config.maximum_review_iterations!(SymphonyElixir.RuntimePaths.workflow_dir())
    :ok
  rescue
    ArgumentError -> {:error, :invalid_review_budget}
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
