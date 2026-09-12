defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with a repo-managed WORKFLOW.md.
  """

  alias SymphonyElixir.{EnvFile, LogFile, Workflow}

  # Keep the legacy acknowledgement flag accepted so older scripts still parse.
  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer, yolo: :boolean]

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          optional(:set_yolo_mode) => (boolean() -> :ok | {:error, term()}),
          default_workflow_path: (-> String.t()),
          env_files_dir: (-> String.t()),
          file_regular?: (String.t() -> boolean()),
          load_env_files: (String.t() -> :ok | {:error, term()}),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          validate_startup_requirements: (-> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    result = with :ok <- SymphonyElixir.ServiceMutex.acquire(), do: evaluate(args)

    case result do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps),
             :ok <- maybe_set_yolo_mode(opts, deps) do
          run(deps.default_workflow_path.(), deps.env_files_dir.(), deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, env_files_dir, deps) do
    expanded_path = Path.expand(workflow_path)

    expanded_env_files_dir =
      env_files_dir
      |> Path.expand()
      |> EnvFile.config_dir()

    case deps.file_regular?.(expanded_path) do
      true -> load_and_start(expanded_path, expanded_env_files_dir, deps)
      false -> {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec default_workflow_path() :: String.t()
  def default_workflow_path do
    case System.get_env("SYMPHONY_WORKFLOW_FILE") do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> Workflow.default_workflow_file_path()
          path -> path
        end

      _empty_or_missing ->
        Workflow.default_workflow_file_path()
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--logs-root <path>] [--port <port>] [--yolo]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      default_workflow_path: &default_workflow_path/0,
      env_files_dir: &File.cwd!/0,
      file_regular?: &File.regular?/1,
      load_env_files: &load_project_env_files/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      validate_startup_requirements: &SymphonyElixir.Application.startup_preflight/0,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      set_yolo_mode: &set_yolo_mode/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp load_project_env_files(_env_files_dir) do
    workflow = Workflow.workflow_file_path()
    root = System.get_env("SYMPHONY_ROOT_DIR") || SymphonyElixir.RuntimePaths.workflow_dir()
    SymphonyElixir.Projects.prepare(root, workflow)
  end

  defp format_env_file_error({:invalid_env_file, path, line_number, reason}) do
    "#{path}:#{line_number}: #{inspect(reason)}"
  end

  defp format_env_file_error({:env_file_read_failed, path, reason}) do
    "#{path}: #{inspect(reason)}"
  end

  defp format_env_file_error(reason), do: inspect(reason)

  defp load_and_start(workflow_path, env_files_dir, deps) do
    with :ok <- deps.set_workflow_file_path.(workflow_path),
         :ok <- deps.load_env_files.(env_files_dir),
         :ok <- deps.validate_startup_requirements.() do
      start_application(workflow_path, deps)
    else
      {:error, reason} ->
        {:error, format_run_error(workflow_path, reason)}
    end
  end

  defp start_application(workflow_path, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony with workflow #{workflow_path}: #{inspect(reason)}"}
    end
  end

  defp format_run_error(workflow_path, :missing_linear_assignee_env) do
    "Failed to start Symphony with workflow #{workflow_path}: LINEAR_ASSIGNEE must be set in the environment, .symphony/.env, or .symphony/.env.local"
  end

  defp format_run_error(workflow_path, :missing_linear_assignee) do
    "Failed to start Symphony with workflow #{workflow_path}: tracker.assignee must resolve to a non-empty value"
  end

  defp format_run_error(workflow_path, {:invalid_workflow_config, message}) do
    "Failed to start Symphony with workflow #{workflow_path}: #{message}"
  end

  defp format_run_error(workflow_path, :missing_linear_api_token) do
    "Failed to start Symphony with workflow #{workflow_path}: missing linear api token"
  end

  defp format_run_error(workflow_path, :missing_linear_scope) do
    "Failed to start Symphony with workflow #{workflow_path}: configure exactly one Linear scope using tracker.project_slug/tracker.team_key or LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY"
  end

  defp format_run_error(workflow_path, :multiple_linear_scopes) do
    "Failed to start Symphony with workflow #{workflow_path}: project and team scopes are mutually exclusive; check tracker.project_slug/tracker.team_key and LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY"
  end

  defp format_run_error(workflow_path, reason) do
    "Failed to load environment for workflow #{workflow_path}: #{format_env_file_error(reason)}"
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp maybe_set_yolo_mode(opts, deps) do
    set_yolo_mode = Map.get(deps, :set_yolo_mode, &set_yolo_mode/1)
    set_yolo_mode.(Keyword.get(opts, :yolo, false))
  end

  defp set_yolo_mode(enabled?) when is_boolean(enabled?) do
    Application.put_env(:symphony_elixir, :yolo, enabled?)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
