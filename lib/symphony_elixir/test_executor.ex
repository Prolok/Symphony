defmodule SymphonyElixir.TestExecutor do
  @moduledoc "Service-owned lifecycle and verified project binding for the existing test executor."
  use GenServer
  require Logger

  alias SymphonyElixir.{BuildInfo, Config, PathSafety, ProjectContext, Projects, RuntimePaths}
  alias SymphonyElixir.Linear.{Client, ScopeBinding}

  @required ~w(workspace_id project_id slug_id teams scenarios timeout result_root)
  @scenarios ~w(bootstrap workflow failure-probe po_handoff po_followup)

  @spec valid_config?(term()) :: boolean()
  def valid_config?(value) when is_map(value) do
    Enum.sort(Map.keys(value)) == Enum.sort(@required) and valid_identity?(value) and valid_limits?(value)
  end

  def valid_config?(_), do: false

  defp valid_identity?(value) do
    Enum.all?(~w(workspace_id project_id), &uuid?(value[&1])) and
      is_binary(value["slug_id"]) and value["slug_id"] != "" and valid_teams?(value["teams"])
  end

  defp valid_teams?(teams) do
    match?({:ok, _}, ScopeBinding.complete_teams(%{"nodes" => teams, "pageInfo" => %{"hasNextPage" => false}}))
  end

  defp valid_limits?(value) do
    nonempty_list?(value["scenarios"], &(&1 in @scenarios)) and
      is_integer(value["timeout"]) and value["timeout"] in 1..3600 and
      is_binary(value["result_root"]) and Path.type(value["result_root"]) == :absolute
  end

  defp uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))
  defp nonempty_list?(value, predicate), do: is_list(value) and value != [] and Enum.all?(value, predicate)

  @spec validate_contexts([ProjectContext.t()]) :: :ok | {:error, term()}
  def validate_contexts(contexts) do
    case configured_targets(contexts) do
      [] ->
        if Enum.all?(contexts, &is_nil(&1.settings.worker.test_executor)), do: :ok, else: {:error, :routine_test_setup_invalid}

      [{target, config}] ->
        with true <- valid_config?(config),
             true <- Enum.all?(contexts, &(is_nil(&1.test_instance) and &1.settings.worker.test_executor in [nil, config])),
             :ok <- verify_target(target, config) do
          :ok
        else
          {:error, _} = error -> error
          _ -> {:error, :routine_test_setup_invalid}
        end

      _ ->
        {:error, :routine_test_setup_invalid}
    end
  end

  @spec verify_target(ProjectContext.t(), map()) :: :ok | {:error, term()}
  def verify_target(context, config) do
    ProjectContext.with_context(context, fn ->
      tracker = context.settings.tracker

      with true <- context.name == "symphony-test" and tracker.kind == "linear" and tracker.auth_mode == "app",
           true <- tracker.app["workspace_id"] == config["workspace_id"],
           true <- Config.linear_scope(tracker) == {:ok, {:project, config["slug_id"]}},
           true <- context.settings.worker.ssh_hosts == [],
           {:ok, %{"data" => data} = response} <- Client.graphql(binding_query(), %{id: config["project_id"]}),
           true <- response["errors"] in [nil, []],
           %{"project" => project, "viewer" => %{"organization" => workspace}} <- data,
           true <- project["id"] == config["project_id"] and project["slugId"] == config["slug_id"] and project["name"] == "symphony-test",
           {:ok, teams} <- ScopeBinding.complete_teams(project["teams"]),
           true <- Enum.sort(teams) == Enum.sort(config["teams"]),
           true <- workspace["id"] == config["workspace_id"] and String.downcase(workspace["urlKey"]) == "prolok" do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :routine_test_project_binding_rejected}
      end
    end)
  end

  defp binding_query do
    "query SymphonyRoutineBinding($id: String!) { project(id: $id) { id name slugId teams(first: 100, includeArchived: true) { nodes { id key } pageInfo { hasNextPage } } } viewer { organization { id urlKey } } }"
  end

  defp configured_targets(contexts), do: for(context <- contexts, context.name == "symphony-test", config = context.settings.worker.test_executor, is_map(config), do: {context, config})

  defp settings(contexts) do
    case List.first(configured_targets(contexts)) do
      {_, config} -> config
      nil -> nil
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 90_000}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    contexts = Keyword.get(opts, :contexts, Projects.configured())
    config = settings(contexts)
    state = %{port: nil, contexts: contexts, config: config, tasks: %{}, runner: Keyword.get(opts, :runner, &SymphonyElixir.RoutineTest.run/5)}

    if config do
      with false <- System.get_env("SYMPHONY_LINEAR_SECRET_ACCESS") == "denied",
           {:ok, port} <- open_executor(contexts, config, opts) do
        :ets.new(__MODULE__, [:named_table, :protected])
        {:ok, %{state | port: port}}
      else
        error -> {:stop, error}
      end
    else
      {:ok, state}
    end
  end

  defp open_executor(contexts, config, opts) do
    target = Enum.find(contexts, &(&1.name == "symphony-test"))
    socket = target.settings.worker.test_executor_socket
    root = config["result_root"]

    with false <- System.get_env("SYMPHONY_LINEAR_SECRET_ACCESS") == "denied",
         {:ok, ^root} <- PathSafety.canonicalize(root),
         true <- Enum.all?(contexts, &(&1.settings.worker.test_executor_socket in [nil, socket])),
         {:ok, ^socket} <- PathSafety.canonicalize(socket),
         true <- byte_size(socket) < 104 do
      command = Keyword.get(opts, :command, [System.find_executable("python3"), Path.join(RuntimePaths.workflow_dir(), "scripts/test-executor.py"), "--managed"])
      [executable | args] = command
      port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, {:line, 1_048_576}, args: args])
      sources = Enum.map(contexts, &%{root: &1.root, workspace_root: &1.settings.workspace.root})
      binding = %{target: target.root, workspace_root: target.settings.workspace.root, app: Map.take(target.settings.tracker.app, ~w(workspace_id client_id user_id)), config: config}
      payload = %{socket: socket, result_root: root, manifest: Path.join(root, "binding.json"), sources: sources, timeout: config["timeout"], scenarios: config["scenarios"], runtime_binding: binding}
      Port.command(port, Jason.encode!(payload) <> "\n")

      receive do
        {^port, {:data, {:eol, line}}} ->
          if Jason.decode(line) == {:ok, %{"event" => "ready"}}, do: {:ok, port}, else: close_failed(port)

        {^port, {:exit_status, _}} ->
          {:error, :test_executor_start_failed}
      after
        5_000 -> close_failed(port)
      end
    else
      _ -> {:error, :test_executor_setup_rejected}
    end
  end

  defp close_failed(port) do
    if Port.info(port), do: Port.close(port)
    {:error, :test_executor_not_ready}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"event" => "run"} = job} ->
        :ets.insert(__MODULE__, {job["directory"], true})
        task = Task.async(fn -> state.runner.(job, state.contexts, state.config, BuildInfo.source(), self()) end)
        {:noreply, put_in(state.tasks[task.ref], {task, job})}

      _ ->
        {:stop, :invalid_executor_event, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{_task, job}, tasks} ->
        :ets.delete(__MODULE__, job["directory"])
        complete(state.port, job, result)
        {:noreply, %{state | tasks: tasks}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {{_task, job}, tasks} ->
        :ets.delete(__MODULE__, job["directory"])
        complete(state.port, job, SymphonyElixir.RoutineTest.failed(job, "runtime_task_failed"))
        {:noreply, %{state | tasks: tasks}}
    end
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state), do: {:stop, :test_executor_exited, state}
  def handle_info({:EXIT, port, _}, %{port: port} = state), do: {:stop, :test_executor_exited, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @spec active?(Path.t()) :: boolean()
  def active?(directory) do
    :ets.lookup(__MODULE__, directory) == [{directory, true}]
  rescue
    ArgumentError -> false
  end

  defp complete(port, job, result) do
    Port.command(port, Jason.encode!(%{key: job["key"], cleanup: job["cleanup"], result: result}) <> "\n")
  end

  defp finish_task(task, job, port) do
    case Task.yield(task, 75_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> if port && Port.info(port), do: complete(port, job, result)
      _ -> :ok
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, {task, _job}} -> send(task.pid, :cancel_test) end)

    Enum.each(state.tasks, fn {_ref, {task, job}} -> finish_task(task, job, state.port) end)

    if state.port && Port.info(state.port), do: Port.close(state.port)
    :ok
  end
end
