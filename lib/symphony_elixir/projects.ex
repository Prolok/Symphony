defmodule SymphonyElixir.Projects do
  @moduledoc "Discovery and aggregate observability for one service serving all projects."
  use GenServer

  alias SymphonyElixir.{EnvFile, Orchestrator, ProjectContext}
  alias SymphonyElixir.Linear.Client

  @spec configured() :: [ProjectContext.t()]
  def configured, do: Application.get_env(:symphony_elixir, :project_contexts, [])

  @spec prepare(Path.t(), Path.t()) :: :ok | {:error, term()}
  def prepare(code_root, workflow) do
    with {:ok, values} <- EnvFile.read_root(code_root),
         root_env <- Map.merge(Map.take(values, EnvFile.root_config_names()), Map.take(System.get_env(), EnvFile.root_config_names())),
         {:ok, roots} <- ProjectContext.discover(Map.get(root_env, "SYM_PROJECT_ROOT", "~/QuantHub"), code_root),
         false <- roots == [],
         {:ok, contexts} <- load_contexts(roots, workflow, root_env),
         :ok <- validate_workspace_roots(contexts),
         :ok <- Client.validate_workspace_bindings(contexts) do
      Application.put_env(:symphony_elixir, :project_contexts, contexts)
      Application.put_env(:symphony_elixir, :service_settings, hd(contexts).settings)
      :ok
    else
      true -> {:error, :no_symphony_projects_found}
      error -> error
    end
  end

  @spec validate_workspace_roots([ProjectContext.t()]) :: :ok | {:error, term()}
  def validate_workspace_roots(contexts) do
    Enum.reduce_while(contexts, {:ok, []}, &check_workspace_root/2)
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp check_workspace_root(context, {:ok, seen}) do
    case SymphonyElixir.PathSafety.canonicalize(context.settings.workspace.root) do
      {:ok, root} -> record_workspace_root(context, root, seen)
      error -> {:halt, error}
    end
  end

  defp record_workspace_root(context, root, seen) do
    case Enum.find(seen, fn {_, previous} -> roots_overlap?(root, previous) end) do
      nil -> {:cont, {:ok, [{context.root, root} | seen]}}
      {project, previous} -> {:halt, {:error, {:overlapping_project_worktree_roots, project, context.root, previous, root}}}
    end
  end

  defp roots_overlap?(a, b) do
    a == b or String.starts_with?(a, String.trim_trailing(b, "/") <> "/") or
      String.starts_with?(b, String.trim_trailing(a, "/") <> "/")
  end

  @spec server(ProjectContext.t()) :: GenServer.server()
  def server(context), do: {:via, Registry, {SymphonyElixir.ProjectRegistry, context.id}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Orchestrator)

  @impl true
  def init(opts) do
    Process.send_after(self(), :check_idle, 1_000)
    {:ok, Keyword.fetch!(opts, :contexts)}
  end

  @impl true
  def handle_info(:check_idle, contexts) do
    snapshots = Enum.map(contexts, &Orchestrator.snapshot(server(&1), 1_000))

    if globally_idle?(snapshots) do
      Task.start(fn -> Application.stop(:symphony_elixir) end)
    else
      Process.send_after(self(), :check_idle, 1_000)
    end

    {:noreply, contexts}
  end

  defp globally_idle?(snapshots) do
    Enum.all?(snapshots, &(is_map(&1) and &1.running == [] and &1.retrying == [] and &1.idle_shutdown_ms > 0)) and
      System.monotonic_time(:millisecond) - Enum.max(Enum.map(snapshots, & &1.last_activity_at_ms)) >=
        Enum.max(Enum.map(snapshots, & &1.idle_shutdown_ms))
  end

  @impl true
  def handle_call(:snapshot, _from, contexts) do
    snapshots = Enum.map(contexts, fn context -> {context, Orchestrator.snapshot(server(context), 10_000)} end)

    if Enum.all?(snapshots, fn {_, snapshot} -> is_map(snapshot) end) do
      result = %{
        projects: Enum.map(contexts, & &1.name),
        running: entries(snapshots, :running),
        retrying: entries(snapshots, :retrying),
        codex_totals: totals(snapshots),
        rate_limits: snapshots |> Enum.map(fn {_, s} -> s.rate_limits end) |> Enum.find(&(not is_nil(&1))),
        polling: SymphonyElixir.ProjectPoller.polling()
      }

      {:reply, result, contexts}
    else
      {:reply, :unavailable, contexts}
    end
  end

  def handle_call(:request_refresh, _from, contexts) do
    SymphonyElixir.ProjectPoller.refresh()
    result = %{queued: true, coalesced: false, requested_at: DateTime.utc_now(), operations: ["poll", "reconcile"]}
    {:reply, result, contexts}
  end

  defp load_contexts(roots, workflow, env) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, contexts} ->
      case ProjectContext.load(root, workflow, env) do
        {:ok, context} -> {:cont, {:ok, contexts ++ [context]}}
        {:error, reason} -> {:halt, {:error, {:invalid_project, root, reason}}}
      end
    end)
  end

  defp entries(snapshots, key) do
    Enum.flat_map(snapshots, fn {context, snapshot} ->
      Enum.map(
        Map.fetch!(snapshot, key),
        fn entry ->
          Map.merge(entry, %{
            project: context.name,
            project_qualifier: qualifier(context, snapshots),
            project_root: context.root,
            workspace_id: context.settings.tracker.app["workspace_id"],
            workspace_path: entry[:workspace_path] || Path.join(context.settings.workspace.root, entry.identifier)
          })
        end
      )
    end)
  end

  defp qualifier(context, snapshots) do
    if Enum.count(snapshots, fn {project, _} -> project.name == context.name end) > 1, do: context.root, else: context.name
  end

  defp totals(snapshots) do
    Enum.reduce(snapshots, %{}, fn {_, snapshot}, acc -> Map.merge(acc, snapshot.codex_totals, fn _, a, b -> a + b end) end)
  end
end
