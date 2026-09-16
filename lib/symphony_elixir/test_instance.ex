defmodule SymphonyElixir.TestInstance do
  @moduledoc "Explicit, restart-bound isolation for the two operator-provisioned dummy projects."

  alias SymphonyElixir.{Config, PathSafety, ProjectContext, RuntimePaths}
  alias SymphonyElixir.Linear.{Client, ScopeBinding}

  @spec name([String.t()]) :: {:ok, String.t() | nil} | {:error, String.t()}
  def name(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [test_instance: [:string, :keep]])
    values = Keyword.get_values(opts, :test_instance)

    cond do
      invalid_test_option?(invalid) -> {:error, "Ungültige Option --test-instance"}
      values == [] -> {:ok, nil}
      length(values) == 1 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/, hd(values)) -> {:ok, hd(values)}
      true -> {:error, "--test-instance verlangt genau einen gültigen Namen"}
    end
  end

  @spec configure([String.t()], map()) :: :ok | {:error, String.t()}
  def configure(args, deps \\ %{}) do
    {opts, _, invalid} = OptionParser.parse(args, strict: [test_instance: [:string, :keep], logs_root: :string, port: [:integer, :keep], yolo: :boolean, budget_capture: :string])

    case Keyword.get_values(opts, :test_instance) do
      [] ->
        if invalid_test_option?(invalid),
          do: {:error, "Ungültige Option --test-instance"},
          else: :ok

      [name] ->
        configure_name(name, opts, deps)

      _ ->
        {:error, "--test-instance darf nur einmal angegeben werden"}
    end
  end

  defp invalid_test_option?(invalid), do: Enum.any?(invalid, fn {key, _} -> String.starts_with?(key, "--test-instance") end)

  defp configure_name(name, opts, deps) do
    root = RuntimePaths.workflow_dir()
    preflight = Map.get(deps, :preflight, &read_preflight/2)
    compiled = Map.get(deps, :compiled_source, SymphonyElixir.BuildInfo.source())

    with true <- Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,47}\z/, name),
         false <- Keyword.has_key?(opts, :logs_root),
         [port] when port in 1..65_535 <- Keyword.get_values(opts, :port),
         {json, 0} <- preflight.(name, root),
         {:ok, instance} <- Jason.decode(json),
         true <- instance["source"] == compiled,
         :ok <- validate_paths(instance) do
      Application.put_env(:symphony_elixir, :test_instance, instance)
      Application.put_env(:symphony_elixir, :test_instance_owner, self())
      Application.put_env(:symphony_elixir, :log_file, Path.join([state_root(), "runs", name, "log/symphony.log"]))
      :ok
    else
      _ -> {:error, "Teststart abgewiesen: eigene Portangabe, öffentliche Testbindung und erwarteten Quellstand prüfen"}
    end
  end

  defp read_preflight(name, root) do
    python = System.find_executable("python3") || "python3"
    System.cmd(python, [Path.join(root, "scripts/test-instance.py"), "preflight", name, root], stderr_to_stdout: true)
  end

  @spec current() :: map() | nil
  def current do
    case ProjectContext.current() do
      %ProjectContext{test_instance: instance} -> instance
      nil -> Application.get_env(:symphony_elixir, :test_instance)
    end
  end

  @spec state_root() :: Path.t()
  def state_root, do: Application.get_env(:symphony_elixir, :test_instance_state_root, Path.join(System.user_home!(), ".local/state/symphony/test-environment"))

  @spec context_env(Path.t()) :: map()
  def context_env(root) do
    case current() do
      nil -> %{}
      instance -> %{"SYMPHONY_PROJECT_WORKTREES_ROOT" => Path.join(instance["manifest"]["workspace_root"], Path.basename(root))}
    end
  end

  @spec project_state_root(Path.t()) :: Path.t()
  def project_state_root(config_dir) do
    case current() do
      nil -> Path.join(config_dir, "state")
      _ -> Path.join([state_root(), "projects", config_dir |> Path.dirname() |> Path.basename()])
    end
  end

  @spec validate_contexts([ProjectContext.t()]) :: :ok | {:error, term()}
  def validate_contexts(contexts) do
    case current() do
      nil -> :ok
      instance -> validate_test_contexts(instance, contexts)
    end
  end

  defp validate_test_contexts(instance, contexts) do
    expected = instance["manifest"]["projects"]

    if Enum.sort(Enum.map(contexts, & &1.name)) == Enum.sort(Map.keys(expected)) do
      {:ok, _} = Application.ensure_all_started(:req)

      Enum.reduce_while(contexts, :ok, &validate_test_context(&1, &2, expected))
    else
      {:error, :unexpected_test_projects}
    end
  end

  defp validate_test_context(context, :ok, expected) do
    result = ProjectContext.with_context(context, fn -> validate_binding(context, expected[context.name]) end)
    if result == :ok, do: {:cont, :ok}, else: {:halt, result}
  end

  defp validate_binding(context, expected) do
    tracker = context.settings.tracker
    relay = tracker.relay

    with true <- tracker.auth_mode == "app" and tracker.kind == "linear",
         true <- tracker.app["workspace_id"] == expected["workspace_id"],
         true <- Config.linear_scope(tracker) == {:ok, {:project, expected["slug_id"]}},
         true <- is_map(relay) and relay["consumer_id"] == nil,
         true <- relay["state_root"] == Path.join(state_root(), "relay"),
         true <- context.settings.workspace.root == context.env["SYMPHONY_PROJECT_WORKTREES_ROOT"],
         true <- Enum.all?([relay["state_root"], tracker.app["state_root"], context.settings.workspace.root], &canonical?/1),
         true <- context.settings.worker.ssh_hosts == [],
         {:ok, %{"data" => data} = response} <- Client.graphql(binding_query(), %{id: expected["project_id"]}),
         true <- response["errors"] in [nil, []],
         %{"project" => project, "viewer" => %{"organization" => workspace}} <- data,
         true <- project["id"] == expected["project_id"] and project["slugId"] == expected["slug_id"] and project["name"] == context.name,
         {:ok, teams} <- ScopeBinding.complete_teams(project["teams"]),
         true <- is_list(expected["teams"]) and Enum.sort(teams) == Enum.sort(expected["teams"]),
         true <- workspace["id"] == expected["workspace_id"] and String.downcase(workspace["urlKey"]) == expected["workspace"] do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, {:test_project_binding_rejected, context.name}}
    end
  end

  @spec public_info() :: map()
  def public_info do
    %{
      pid: System.pid(),
      source: SymphonyElixir.BuildInfo.source(),
      test_instance: current() && current()["name"],
      bindings:
        Enum.map(SymphonyElixir.Projects.configured(), fn context ->
          tracker = context.settings.tracker
          binding = context.test_instance && context.test_instance["manifest"]["projects"][context.name]

          %{
            name: context.name,
            root: context.root,
            workspace_id: tracker.app["workspace_id"],
            project_id: binding && binding["project_id"],
            project_slug: tracker.project_slug,
            team_key: tracker.team_key,
            teams: binding && binding["teams"],
            workspace_root: context.settings.workspace.root,
            state_root: tracker.app["state_root"],
            relay_root: tracker.relay && tracker.relay["state_root"]
          }
        end)
    }
  end

  defp binding_query do
    "query SymphonyTestBinding($id: String!) { project(id: $id) { id name slugId teams(first: 100, includeArchived: true) { nodes { id key } pageInfo { hasNextPage } } } viewer { organization { id urlKey } } }"
  end

  defp validate_paths(instance) do
    manifest = instance["manifest"]
    root = manifest["project_root"]
    workspaces = manifest["workspace_root"]
    code = instance["source"]["checkout"]
    forbidden = [code, root, Path.join(root, "symphony-test"), Path.join(root, "symphony-test-tilor")]

    with true <- is_binary(workspaces) and Path.type(workspaces) == :absolute,
         {:ok, ^workspaces} <- PathSafety.canonicalize(workspaces),
         {:ok, state} <- PathSafety.canonicalize(state_root()),
         true <- state == state_root(),
         false <- Enum.any?(forbidden, &overlap?(workspaces, &1)),
         false <- Enum.any?([workspaces | forbidden], &overlap?(state, &1)),
         false <- Enum.any?(get_in(manifest, ["main_instance", "projects"]) || [], &(overlap?(state, &1["root"]) or overlap?(state, &1["workspace_root"]))) do
      :ok
    else
      _ -> {:error, :test_paths_overlap_or_alias}
    end
  end

  defp overlap?(a, b), do: a == b or String.starts_with?(a, b <> "/") or String.starts_with?(b, a <> "/")
  defp canonical?(path), do: PathSafety.canonicalize(path) == {:ok, path}
end
