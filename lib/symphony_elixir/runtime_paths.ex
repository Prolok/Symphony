defmodule SymphonyElixir.RuntimePaths do
  @moduledoc false

  alias SymphonyElixir.Workflow

  @runtime_env_names [
    "SYMPHONY_WORKFLOW_FILE",
    "SYMPHONY_WORKFLOW_DIR",
    "SYMPHONY_WORKFLOW_DIALOG_FILE",
    "SYMPHONY_WORKFLOW_INTERACTIVE_FILE",
    "SYMPHONY_ACTIVE_REPO_ROOT",
    "SYMPHONY_SOURCE_REPO",
    "SYMPHONY_ISSUE_ID",
    "SYMPHONY_ISSUE_IDENTIFIER",
    "SYMPHONY_ISSUE_LABELS_JSON",
    "SYMPHONY_PROJECT_ROOT",
    "SYMPHONY_PROJECT_WORKTREES_ROOT",
    "SYMPHONY_RELEASE_ROOT",
    "SYMPHONY_ROOT_DIR",
    "SYMPHONY_LINEAR_ENV_DIR",
    "SYMPHONY_LINEAR_AUTH_MODE",
    "SYMPHONY_LINEAR_CLIENT_SECRET_ENV",
    "SYMPHONY_LINEAR_BINDING_HASH",
    "SYMPHONY_CODEX_STATE_ROOT",
    "SYMPHONY_RUN_ID",
    "SYMPHONY_PHASE"
  ]

  @spec runtime_env_names() :: [String.t()]
  def runtime_env_names, do: @runtime_env_names

  @spec project_root() :: Path.t()
  def project_root do
    case SymphonyElixir.ProjectContext.current() do
      %{root: root} -> root
      nil -> File.cwd!()
    end
  end

  @spec project_worktrees_root() :: Path.t()
  def project_worktrees_root do
    project_worktrees_base_root() <> "-worktrees"
  end

  @spec workflow_dir() :: Path.t()
  def workflow_dir do
    case Map.get(bound_runtime_env(), "SYMPHONY_RELEASE_ROOT") do
      root when is_binary(root) and root != "" -> root
      _ -> Workflow.default_workflow_file_path() |> Path.dirname()
    end
  end

  @spec workflow_file() :: Path.t()
  def workflow_file do
    Workflow.workflow_file_path()
  end

  @spec builtin_env() :: %{String.t() => String.t()}
  def builtin_env do
    %{
      "SYMPHONY_PROJECT_ROOT" => project_root(),
      "SYMPHONY_PROJECT_WORKTREES_ROOT" => project_worktrees_root(),
      "SYMPHONY_WORKFLOW_DIR" => workflow_dir(),
      "SYMPHONY_WORKFLOW_FILE" => workflow_file()
    }
    |> Map.merge(bound_runtime_env())
    |> Map.merge(project_context_env())
  end

  defp project_context_env do
    case SymphonyElixir.ProjectContext.current() do
      %{env: env} -> Map.take(env, @runtime_env_names)
      nil -> %{}
    end
  end

  defp bound_runtime_env do
    root = System.get_env("SYMPHONY_RELEASE_ROOT")

    if is_binary(root) and File.regular?(Path.join(root, ".symphony-release.json")) do
      names =
        if System.get_env("SYMPHONY_LINEAR_AUTH_MODE") == "app",
          do: ~w(SYMPHONY_RELEASE_ROOT SYMPHONY_LINEAR_AUTH_MODE SYMPHONY_LINEAR_BINDING_HASH),
          else: ~w(SYMPHONY_RELEASE_ROOT)

      Map.new(names, &{&1, System.get_env(&1) || ""})
      |> Map.merge(System.get_env() |> Map.take(["SYMPHONY_ROOT_DIR", "SYMPHONY_LINEAR_ENV_DIR"]))
    else
      %{}
    end
  end

  @spec cleaned_system_env(map()) :: [{String.t(), String.t() | nil}]
  def cleaned_system_env(overrides \\ %{}) when is_map(overrides) do
    normalized_overrides = stringify_env(overrides)

    @runtime_env_names
    |> Enum.reject(&Map.has_key?(normalized_overrides, &1))
    |> Enum.map(&{&1, nil})
    |> Kernel.++(Enum.to_list(normalized_overrides))
    |> SymphonyElixir.Config.without_linear_secret()
  end

  @spec cleaned_builtin_system_env(map()) :: [{String.t(), String.t() | nil}]
  def cleaned_builtin_system_env(overrides \\ %{}) when is_map(overrides) do
    builtin_env()
    |> Map.merge(stringify_env(overrides))
    |> cleaned_system_env()
  end

  @spec cleaned_builtin_port_env(map()) :: [{charlist(), charlist() | false}]
  def cleaned_builtin_port_env(overrides \\ %{}) when is_map(overrides) do
    secret_names = SymphonyElixir.Config.linear_secret_env_names()

    normalized_overrides =
      builtin_env()
      |> Map.merge(stringify_env(overrides))
      |> Map.drop(secret_names)

    clears =
      (@runtime_env_names ++ secret_names)
      |> Enum.reject(&Map.has_key?(normalized_overrides, &1))
      |> Enum.map(&{String.to_charlist(&1), false})

    values =
      Enum.map(normalized_overrides, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    clears ++ values
  end

  @spec resolve_builtin_env(String.t()) :: String.t() | nil
  def resolve_builtin_env(name) when is_binary(name) do
    Map.get(builtin_env(), name)
  end

  defp stringify_env(env) when is_map(env) do
    Map.new(env, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp project_worktrees_base_root do
    cwd = project_root()

    case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           cd: cwd,
           env: SymphonyElixir.Config.without_linear_secret([]),
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.trim()
        |> case do
          "" -> cwd
          common_dir -> Path.expand("..", common_dir)
        end

      {_output, _status} ->
        cwd
    end
  end
end
