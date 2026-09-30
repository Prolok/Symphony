defmodule SymphonyElixir.WorkerCapacity do
  @moduledoc "Atomically starts workers within service-wide and SSH-host capacity limits."
  use GenServer
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.OpenClaw.Journal

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec configure([SymphonyElixir.ProjectContext.t()]) :: :ok
  def configure(contexts), do: GenServer.call(__MODULE__, {:configure, contexts})

  @spec count(String.t() | nil) :: non_neg_integer()
  def count(host), do: GenServer.call(__MODULE__, {:count, host})

  @spec count_state(String.t()) :: non_neg_integer()
  def count_state(issue_state), do: GenServer.call(__MODULE__, {:count_state, normalize_state(issue_state)})

  @spec update_state(pid(), String.t()) :: :ok
  def update_state(pid, issue_state), do: GenServer.call(__MODULE__, {:update_state, pid, normalize_state(issue_state)})

  @spec start_child(String.t() | nil, String.t(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def start_child(host, issue_state, fun) do
    GenServer.call(__MODULE__, {:start_child, host, normalize_state(issue_state), fun, project_id()})
  end

  @doc "Reattach an already accepted external run; its occupied slot must survive a service restart."
  @spec recover_child(String.t(), (-> term())) :: {:ok, pid()} | {:error, term()}
  def recover_child(issue_state, fun) do
    GenServer.call(__MODULE__, {:recover_child, normalize_state(issue_state), fun, project_id()})
  end

  defp project_id, do: if(ProjectContext.current(), do: ProjectContext.current().id)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      workers: %{},
      bindings: %{},
      subscribers: %{},
      maintenance: normal_maintenance(),
      deadline_timer: nil,
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyElixir.TaskSupervisor)
    }

    {:ok, configure_state(state, Keyword.get(opts, :contexts, []))}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {pid, _} -> Task.Supervisor.terminate_child(state.task_supervisor, pid) end)
  end

  @impl true
  def handle_call(:maintenance, _from, state) do
    drained = map_size(state.workers) == 0 and pending_bindings(state.contexts) == {:ok, MapSet.new()}
    {:reply, Map.put(state.maintenance, :drained, drained), state}
  end

  def handle_call({:maintenance_subscribe, pid}, _from, state) do
    subscribers = if Map.has_key?(state.subscribers, pid), do: state.subscribers, else: Map.put(state.subscribers, pid, Process.monitor(pid))
    if state.maintenance.enabled, do: send(pid, {:maintenance_changed, state.maintenance})
    if deadline_due?(state.maintenance), do: send(pid, {:maintenance_deadline, state.maintenance.generation})
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:maintenance, request}, _from, state) do
    if same_request?(state.maintenance, request) do
      {:reply, {:ok, public_maintenance(state.maintenance)}, state}
    else
      if state.deadline_timer, do: Process.cancel_timer(state.deadline_timer)
      control = new_maintenance(request)

      timer =
        if control[:deadline_ms],
          do: Process.send_after(self(), {:maintenance_deadline, control.generation}, request.deadline_seconds * 1_000)

      Enum.each(state.subscribers, fn {pid, _} -> send(pid, {:maintenance_changed, control}) end)
      SymphonyElixirWeb.ObservabilityPubSub.broadcast_update()
      {:reply, {:ok, public_maintenance(control)}, %{state | maintenance: control, deadline_timer: timer}}
    end
  end

  def handle_call({:recover_child, issue_state, fun, project}, {owner, _}, state) do
    case Task.Supervisor.start_child(state.task_supervisor, fun) do
      {:ok, pid} = result ->
        ref = Process.monitor(pid)
        owner_ref = Process.monitor(owner)
        workers = Map.put(state.workers, pid, {nil, issue_state, ref, owner_ref})
        {:reply, result, %{state | workers: workers, bindings: Map.put(state.bindings, pid, {project, issue_state})}}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:configure, contexts}, _from, state), do: {:reply, :ok, configure_state(state, contexts)}

  def handle_call({:count, host}, _from, state), do: {:reply, host_count(state, host), state}

  def handle_call({:count_state, issue_state}, _from, state), do: {:reply, state_count(state, issue_state), state}

  def handle_call({:update_state, pid, issue_state}, _from, state) do
    workers =
      case Map.fetch(state.workers, pid) do
        {:ok, {host, _, ref, owner_ref}} -> Map.put(state.workers, pid, {host, issue_state, ref, owner_ref})
        :error -> state.workers
      end

    {:reply, :ok, %{state | workers: workers}}
  end

  def handle_call({:start_child, host, issue_state, fun, project}, {owner, _}, state) do
    host_limit = Map.get(state.host_limits, host, :infinity)
    state_limit = Map.get(state.state_limits, issue_state, state.limit)

    if not state.maintenance.enabled and capacity_available?(state) and host_count(state, host) < host_limit and
         state_count(state, issue_state) < state_limit do
      case Task.Supervisor.start_child(state.task_supervisor, fun) do
        {:ok, pid} = result ->
          ref = Process.monitor(pid)
          owner_ref = Process.monitor(owner)
          workers = Map.put(state.workers, pid, {host, issue_state, ref, owner_ref})
          {:reply, result, %{state | workers: workers, bindings: Map.put(state.bindings, pid, {project, issue_state})}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, if(state.maintenance.enabled, do: :maintenance, else: :worker_capacity)}, state}
    end
  end

  @impl true
  def handle_info({:maintenance_deadline, generation}, %{maintenance: %{generation: generation, enabled: true}} = state) do
    Enum.each(state.subscribers, fn {pid, _} -> send(pid, {:maintenance_deadline, generation}) end)
    {:noreply, %{state | deadline_timer: nil}}
  end

  def handle_info({:maintenance_deadline, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    workers =
      Map.reject(state.workers, fn {pid, {_host, _issue_state, worker_ref, owner_ref}} ->
        cond do
          ref == worker_ref ->
            Process.demonitor(owner_ref, [:flush])
            true

          ref == owner_ref ->
            Task.Supervisor.terminate_child(state.task_supervisor, pid)
            Process.demonitor(worker_ref, [:flush])
            true

          true ->
            false
        end
      end)

    subscribers = Map.reject(state.subscribers, fn {_, monitor} -> monitor == ref end)
    {:noreply, %{state | workers: workers, bindings: Map.take(state.bindings, Map.keys(workers)), subscribers: subscribers}}
  end

  defp configure_state(state, contexts) do
    host_limits =
      Enum.reduce(contexts, %{}, fn context, limits ->
        worker = context.settings.worker
        limit = worker.max_concurrent_agents_per_host || :infinity
        Enum.reduce(worker.ssh_hosts, limits, fn host, acc -> Map.update(acc, host, limit, &min(&1, limit)) end)
      end)

    limit = contexts |> Enum.map(& &1.settings.agent.max_concurrent_agents) |> Enum.min(fn -> :infinity end)

    state_limits =
      Enum.reduce(contexts, %{}, fn context, limits ->
        Map.merge(limits, context.settings.agent.max_concurrent_agents_by_state, fn _, a, b -> min(a, b) end)
      end)

    Map.merge(state, %{limit: limit, host_limits: host_limits, state_limits: state_limits, contexts: contexts})
  end

  defp capacity_available?(state) do
    case pending_bindings(state.contexts) do
      {:ok, pending} ->
        attached = state.bindings |> Map.values() |> MapSet.new()
        orphaned = pending |> MapSet.difference(attached) |> MapSet.size()
        map_size(state.workers) + orphaned < state.limit

      {:error, _} ->
        false
    end
  end

  defp pending_bindings(contexts) do
    Enum.reduce_while(contexts, {:ok, MapSet.new()}, fn context, {:ok, acc} ->
      case ProjectContext.with_context(context, &Journal.pending/0) do
        {:ok, orders} -> {:cont, {:ok, Enum.reduce(orders, acc, &MapSet.put(&2, {context.id, "yolo " <> &1["group"]}))}}
        error -> {:halt, error}
      end
    end)
  end

  defp host_count(state, host), do: Enum.count(state.workers, fn {_pid, {worker_host, _, _, _}} -> worker_host == host end)
  defp state_count(state, name), do: Enum.count(state.workers, fn {_pid, {_, worker_state, _, _}} -> worker_state == name end)
  defp normalize_state(name), do: Schema.normalize_issue_state(name)

  defp normal_maintenance, do: %{enabled: false, generation: Ecto.UUID.generate(), requested_at: nil, reason: nil, deadline_at: nil, deadline_ms: nil, deadline_seconds: nil}
  defp new_maintenance(%{enabled: false}), do: normal_maintenance()

  defp new_maintenance(request) do
    now = DateTime.utc_now()
    seconds = request.deadline_seconds

    %{
      enabled: true,
      generation: Ecto.UUID.generate(),
      requested_at: DateTime.to_iso8601(now),
      reason: request.reason,
      deadline_seconds: seconds,
      deadline_at: if(seconds, do: DateTime.to_iso8601(DateTime.add(now, seconds))),
      deadline_ms: if(seconds, do: System.monotonic_time(:millisecond) + seconds * 1_000)
    }
  end

  defp same_request?(%{enabled: false}, %{enabled: false}), do: true
  defp same_request?(current, request), do: current.enabled == request.enabled and current.reason == request[:reason] and current.deadline_seconds == request[:deadline_seconds]
  defp deadline_due?(control), do: control.enabled and is_integer(control.deadline_ms) and control.deadline_ms <= System.monotonic_time(:millisecond)
  defp public_maintenance(control), do: Map.drop(control, [:deadline_ms, :deadline_seconds])
end
