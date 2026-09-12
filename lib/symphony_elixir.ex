defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application
  alias SymphonyElixir.{Config, EnvFile, ProjectContext}

  @spec startup_preflight() :: :ok | {:error, term()}
  def startup_preflight do
    case SymphonyElixir.Projects.configured() do
      [] ->
        case EnvFile.load_runtime(EnvFile.bound_config_dir()) do
          :ok -> Config.validate_startup_requirements()
          {:error, reason} -> {:error, reason}
        end

      contexts ->
        Enum.reduce_while(contexts, :ok, &validate_context/2)
    end
  end

  defp validate_context(context, :ok) do
    case ProjectContext.with_context(context, &Config.validate_startup_requirements/0) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @impl true
  def start(_type, _args) do
    with :ok <- maybe_run_startup_preflight(),
         :ok <- SymphonyElixir.LogFile.configure() do
      children = [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, task_supervisor_options()},
        SymphonyElixir.WorkflowStore,
        orchestrator_child(),
        SymphonyElixir.HttpServer,
        SymphonyElixir.StatusDashboard
      ]

      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )
    end
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  defp maybe_run_startup_preflight do
    (Application.get_env(:symphony_elixir, :run_startup_preflight_on_boot, true) &&
       startup_preflight()) || :ok
  end

  defp orchestrator_child do
    case SymphonyElixir.Projects.configured() do
      [] -> SymphonyElixir.Orchestrator
      contexts -> {SymphonyElixir.ProjectSupervisor, contexts: contexts}
    end
  end

  defp task_supervisor_options do
    case SymphonyElixir.Projects.configured() do
      [] -> [name: SymphonyElixir.TaskSupervisor]
      _ -> [name: SymphonyElixir.TaskSupervisor, max_children: Config.settings!().agent.max_concurrent_agents]
    end
  end
end
