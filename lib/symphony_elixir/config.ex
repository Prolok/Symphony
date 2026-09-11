defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Linear.AppAuth
  alias SymphonyElixir.Linear.WriteContext

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.{EnvFile, Workflow}

  @type linear_scope :: {:project, String.t()} | {:team, String.t()}

  @default_prompt_template """
  Du arbeitest an einem Linear-Ticket.

  Identifier: {{ issue.identifier }}
  Titel: {{ issue.title }}

  Beschreibung:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  Keine Beschreibung vorhanden.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        with {:ok, settings} <- Schema.parse(config),
             :ok <- validate_bound_identity(settings.tracker) do
          {:ok, settings}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Reads only the referenced process secret; it never becomes part of settings."
  @spec linear_client_secret(map()) :: {:ok, String.t()} | {:error, atom()}
  def linear_client_secret(binding) do
    SymphonyElixir.EnvFile.linear_secret(binding["client_secret_env"])
  end

  @doc "Non-secret environment names excluded from non-authentication children."
  @spec linear_secret_env_names() :: [String.t()]
  def linear_secret_env_names do
    configured =
      case linear_secret_reference() do
        "$" <> name -> System.get_env(name)
        name -> name
      end

    ["LINEAR_APP_SECRET", configured, System.get_env("SYMPHONY_LINEAR_CLIENT_SECRET_ENV")]
    |> Enum.filter(&(is_binary(&1) and Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, &1)))
    |> Enum.uniq()
  end

  @doc "Return the public secret reference so loaders can exclude project-selected names before exporting values."
  @spec linear_secret_reference() :: String.t() | nil
  def linear_secret_reference do
    case Workflow.current() do
      {:ok, %{config: %{"tracker" => %{"auth_mode" => "app", "app" => app}}}} -> app["client_secret_env"]
      _ -> nil
    end
  end

  @spec without_linear_secret(map() | list()) :: [{String.t(), String.t() | nil}]
  def without_linear_secret(env) do
    Enum.reduce(linear_secret_env_names(), Map.new(env), &Map.put(&2, &1, nil))
    |> Map.put("SYMPHONY_LINEAR_SECRET_ACCESS", "denied")
    |> Enum.to_list()
  end

  @spec linear_runtime_env() :: map()
  def linear_runtime_env do
    tracker = settings!().tracker

    if tracker.auth_mode == "app" do
      %{
        "SYMPHONY_LINEAR_AUTH_MODE" => tracker.auth_mode,
        "SYMPHONY_LINEAR_CLIENT_SECRET_ENV" => tracker.app["client_secret_env"],
        "SYMPHONY_CODEX_STATE_ROOT" => Path.join([tracker.app["state_root"], "codex", tracker.app["installation_id"]]),
        "SYMPHONY_LINEAR_BINDING_HASH" => binding_hash(tracker),
        "SYMPHONY_RUN_ID" => WriteContext.current()["run_id"] || "",
        "SYMPHONY_PHASE" => WriteContext.current()["phase"] || ""
      }
    else
      %{}
    end
  end

  defp validate_bound_identity(tracker) do
    case {System.get_env("SYMPHONY_LINEAR_AUTH_MODE"), System.get_env("SYMPHONY_LINEAR_BINDING_HASH")} do
      {"app", value} when is_binary(value) and value != "" ->
        if value == binding_hash(tracker), do: :ok, else: {:error, :linear_runtime_binding_changed}

      {"app", _} ->
        {:error, :linear_runtime_binding_missing}

      _ ->
        :ok
    end
  end

  defp binding_hash(tracker) do
    {tracker.auth_mode, tracker.app, tracker.endpoint, tracker.project_slug, tracker.team_key, tracker.assignee}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec local_codex_command() :: String.t()
  def local_codex_command do
    case System.get_env("SYMPHONY_CODEX_COMMAND") do
      command when is_binary(command) ->
        case String.trim(command) do
          "" -> configured_local_codex_command()
          trimmed_command -> trimmed_command
        end

      _ ->
        configured_local_codex_command()
    end
  end

  @doc "Resolves the review budget from the environment and the active Symphony checkout."
  @spec maximum_review_iterations!(Path.t()) :: pos_integer()
  def maximum_review_iterations!(symphony_root) do
    value =
      case System.fetch_env("SYM_MAXIMUM_REVIEW_ITERATIONS") do
        {:ok, value} ->
          value

        :error ->
          case EnvFile.read(symphony_root) do
            {:ok, values} -> Map.get(values, "SYM_MAXIMUM_REVIEW_ITERATIONS", "3")
            {:error, reason} -> raise ArgumentError, "Invalid SYM_MAXIMUM_REVIEW_ITERATIONS config: #{inspect(reason)}"
          end
      end

    case Integer.parse(String.trim(value)) do
      {limit, ""} when limit > 0 -> limit
      _ -> raise ArgumentError, "Invalid SYM_MAXIMUM_REVIEW_ITERATIONS: expected a positive integer"
    end
  end

  defp configured_local_codex_command do
    settings = settings!()
    command = settings.codex.command
    release = local_helper_root()
    app? = settings.tracker.auth_mode == "app"
    bundled? = command == "sym-codex --observer" or (app? and command == "codex app-server")

    if is_binary(release) and release != "" and bundled? do
      helper = shell_quote(Path.join(release, "sym-codex")) <> " --observer"

      if app? do
        # Restore the validated local toolchain after AppServer's login shell.
        python = System.get_env("SYMPHONY_PYTHON") || System.find_executable("python3") || "python3"
        env = ["PATH=" <> System.fetch_env!("PATH"), "SYMPHONY_PYTHON=" <> python]
        "/usr/bin/env " <> Enum.map_join(env, " ", &shell_quote/1) <> " " <> helper
      else
        helper
      end
    else
      command
    end
  end

  defp local_helper_root do
    case System.get_env("SYMPHONY_RELEASE_ROOT") do
      release when is_binary(release) and release != "" ->
        release

      _ ->
        root = Path.dirname(Workflow.default_workflow_file_path())
        if File.regular?(Path.join(root, "sym-codex")), do: root
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec yolo?() :: boolean()
  def yolo? do
    Application.get_env(:symphony_elixir, :yolo, false) == true
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec validate_startup_requirements() :: :ok | {:error, term()}
  def validate_startup_requirements do
    case settings() do
      {:ok, settings} -> validate_startup_requirements(settings)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec linear_scope() :: {:ok, linear_scope()} | {:error, term()}
  def linear_scope do
    with {:ok, settings} <- settings() do
      linear_scope(settings.tracker)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    regular_codex_runtime_settings(workspace, opts)
  end

  defp regular_codex_runtime_settings(workspace, opts) do
    with {:ok, settings} <- settings(),
         {:ok, turn_sandbox_policy} <-
           Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
      {:ok,
       %{
         approval_policy: settings.codex.approval_policy,
         thread_sandbox: settings.codex.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp validate_startup_requirements(settings) do
    case validate_required_environment(settings) do
      :ok -> validate_semantics(settings)
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_semantics(settings) do
    case settings.tracker.kind do
      nil ->
        {:error, :missing_tracker_kind}

      "linear" ->
        validate_linear_tracker(settings)

      "memory" ->
        :ok

      kind ->
        {:error, {:unsupported_tracker_kind, kind}}
    end
  end

  defp validate_linear_tracker(%{tracker: %{auth_mode: "app"} = tracker}) do
    with :ok <- AppAuth.validate(tracker),
         {:ok, _scope} <- linear_scope(tracker) do
      :ok
    end
  end

  defp validate_linear_tracker(settings) do
    if is_binary(settings.tracker.api_key) do
      case linear_scope(settings.tracker) do
        {:ok, _scope} -> validate_linear_assignee(settings.tracker.assignee)
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_linear_api_token}
    end
  end

  defp validate_linear_assignee(assignee) do
    if yolo?() or is_binary(assignee), do: :ok, else: {:error, :missing_linear_assignee}
  end

  @spec linear_scope(Schema.Tracker.t()) :: {:ok, linear_scope()} | {:error, term()}
  def linear_scope(%Schema.Tracker{project_slug: project_slug, team_key: team_key}) do
    case {project_slug, team_key} do
      {project_slug, nil} when is_binary(project_slug) -> {:ok, {:project, project_slug}}
      {nil, team_key} when is_binary(team_key) -> {:ok, {:team, team_key}}
      {nil, nil} -> {:error, :missing_linear_scope}
      {_project_slug, _team_key} -> {:error, :multiple_linear_scopes}
    end
  end

  defp validate_required_environment(%{tracker: %{kind: "linear"}}) do
    if yolo?() do
      :ok
    else
      validate_required_assignee_environment()
    end
  end

  defp validate_required_environment(_settings), do: :ok

  defp validate_required_assignee_environment do
    case System.get_env("LINEAR_ASSIGNEE") do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, :missing_linear_assignee_env}, else: :ok

      _ ->
        {:error, :missing_linear_assignee_env}
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      other ->
        format_simple_config_error(other)
    end
  end

  defp format_simple_config_error(:workflow_front_matter_not_a_map) do
    "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"
  end

  defp format_simple_config_error(:missing_linear_api_token) do
    "Invalid WORKFLOW.md config: missing linear api token"
  end

  defp format_simple_config_error(:missing_linear_scope) do
    "Invalid Linear scope config: configure exactly one Linear scope using tracker.project_slug/tracker.team_key or LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY"
  end

  defp format_simple_config_error(:multiple_linear_scopes) do
    "Invalid Linear scope config: project and team scopes are mutually exclusive; check tracker.project_slug/tracker.team_key and LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY"
  end

  defp format_simple_config_error(:missing_linear_assignee) do
    "Invalid WORKFLOW.md config: tracker.assignee must resolve to a non-empty value"
  end

  defp format_simple_config_error(:missing_linear_assignee_env) do
    "Invalid WORKFLOW.md config: LINEAR_ASSIGNEE must be set in the environment, .symphony/.env, or .symphony/.env.local"
  end

  defp format_simple_config_error(other) do
    "Invalid WORKFLOW.md config: #{inspect(other)}"
  end
end
