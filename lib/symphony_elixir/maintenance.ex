defmodule SymphonyElixir.Maintenance do
  @moduledoc "Local service-wide drain control. The start arbiter owns its volatile state."
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.WriteContext
  alias SymphonyElixir.WorkerCapacity
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  @interruptible ["todo (ai)", "planung (ai)", "in arbeit (ai)", "prereview (ai)", "review (ai)", "test (ai)"]

  @spec interruptible?(String.t()) :: boolean()
  def interruptible?(phase), do: Schema.normalize_issue_state(phase) in @interruptible

  @spec interrupt_current?(String.t()) :: boolean()
  def interrupt_current?(generation) do
    control = status()
    context = WriteContext.current()

    with true <- control.enabled and control.generation == generation,
         true <- is_integer(control[:deadline_ms]) and control.deadline_ms <= System.monotonic_time(:millisecond),
         true <- is_binary(context["phase"]) and interruptible?(context["phase"]),
         {:ok, [issue]} <- SymphonyElixir.Tracker.fetch_issue_states_by_ids([context["issue_id"]], force_full: true),
         true <- issue.state == context["phase"] do
      current = status()

      current.enabled and current.generation == generation and
        is_integer(current[:deadline_ms]) and current.deadline_ms <= System.monotonic_time(:millisecond)
    else
      _ -> false
    end
  end

  @spec update(map()) :: {:ok, map()} | {:error, term()}
  def update(params) do
    with {:ok, request} <- validate(params), do: call({:maintenance, request})
  end

  @spec status() :: map()
  def status do
    case call(:maintenance) do
      %{} = result -> result
      _ -> %{enabled: true, generation: nil, requested_at: nil, reason: "Startarbiter nicht verfügbar", deadline_at: nil, drained: false}
    end
  end

  @spec enabled?() :: boolean()
  def enabled?, do: status().enabled

  @spec register() :: :ok | {:error, term()}
  def register, do: call({:maintenance_subscribe, self()})

  @spec project(map(), boolean()) :: map()
  def project(snapshot, persistence_ok?) do
    control = status()
    idle = control.enabled and control.drained and persistence_ok? and snapshot.running == [] and external_idle?()
    control |> Map.drop([:drained, :deadline_ms, :deadline_seconds]) |> Map.merge(%{idle: idle, draining: control.enabled and not idle})
  end

  @spec aggregate([map()], boolean()) :: map()
  def aggregate(snapshots, fresh?) do
    control = status()

    idle =
      control.enabled and control.drained and fresh? and snapshots != [] and
        Enum.all?(snapshots, fn s ->
          get_in(s, [:maintenance, :generation]) == control.generation and get_in(s, [:maintenance, :idle]) == true
        end)

    control |> Map.drop([:drained, :deadline_ms, :deadline_seconds]) |> Map.merge(%{idle: idle, draining: control.enabled and not idle})
  end

  defp call(message) do
    GenServer.call(WorkerCapacity, message)
  catch
    :exit, _ -> {:error, :maintenance_unavailable}
  end

  defp external_idle? do
    if SymphonyElixir.ProjectContext.current() do
      Journal.pending() == {:ok, []}
    else
      true
    end
  end

  defp validate(%{"enabled" => false} = params) when map_size(params) == 1, do: {:ok, %{enabled: false}}

  defp validate(%{"enabled" => true, "reason" => reason} = params) when is_binary(reason) do
    deadline = Map.get(params, "deadline_seconds")
    reason = String.trim(reason)

    if reason != "" and byte_size(reason) <= 2_000 and
         Enum.all?(Map.keys(params), &(&1 in ~w(enabled reason deadline_seconds))) and
         (is_nil(deadline) or (is_integer(deadline) and deadline > 0 and deadline <= 86_400)) do
      {:ok, %{enabled: true, reason: reason, deadline_seconds: deadline}}
    else
      {:error, :invalid_maintenance_request}
    end
  end

  defp validate(_), do: {:error, :invalid_maintenance_request}
end
