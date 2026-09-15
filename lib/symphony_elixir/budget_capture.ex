defmodule SymphonyElixir.BudgetCapture do
  @moduledoc "Operator-only recorder for existing transport telemetry; does not start or stop services."
  @events [[:symphony, :linear, :request], [:symphony, :relay, :request]]
  @phases ~w(cold_start idle active burst reconcile outage checkpoint)

  @spec start(Path.t(), map()) :: :ok
  def start(path, metadata) do
    {:ok, _} = Application.ensure_all_started(:telemetry)

    {:ok, pid} =
      Agent.start(
        fn ->
          {:ok, file} = File.open(path, [:write, :exclusive, :utf8])

          %{
            file: file,
            start: System.monotonic_time(:millisecond),
            phase: "setup",
            completed: [],
            failed: false,
            sequence: 0
          }
        end,
        name: __MODULE__
      )

    :ok = :telemetry.attach_many(__MODULE__, @events, &__MODULE__.record/4, pid)
    emit(%{event: "start", metadata: metadata})
    :ok
  end

  @spec record([atom()], map(), map(), pid()) :: :ok
  def record([:symphony, transport, :request], measurements, metadata, _pid) do
    # Transport metadata already excludes credentials, URLs and provider bodies.
    emit(%{
      event: "request",
      transport: transport,
      measurement: Map.take(measurements, [:requests, :duration_ms]),
      metadata: Map.take(metadata, [:workspace_id, :kind, :status, :headers])
    })
  end

  @spec phase(String.t(), number(), (-> term())) :: term()
  def phase(name, seconds, action \\ fn -> :ok end)
      when name in @phases and is_number(seconds) and seconds > 0 and seconds <= 3600 do
    duration = round(seconds * 1000)

    Agent.update(__MODULE__, fn state ->
      true = state.phase == "setup" and name not in state.completed
      write_record(%{state | phase: name}, %{event: "phase_start", duration_ms: duration})
    end)

    IO.puts("Budget phase=#{name} seconds=#{seconds} at=#{DateTime.to_iso8601(DateTime.utc_now())}")
    started = System.monotonic_time(:millisecond)
    # A slow/failed action invalidates the phase; it never becomes a shorter
    # successful window. No retry or cancellation of external work is implied.
    try do
      result = action.()
      elapsed = System.monotonic_time(:millisecond) - started
      if elapsed > duration, do: raise("phase action exceeded its time window")
      Process.sleep(max(duration - elapsed, 0))

      Agent.update(__MODULE__, fn state ->
        state = write_record(state, %{event: "phase_end", duration_ms: duration})
        %{state | phase: "setup", completed: state.completed ++ [name]}
      end)

      result
    after
      Agent.update(__MODULE__, fn state ->
        :ok = :file.sync(state.file)
        if state.phase == name, do: %{state | failed: true, phase: "setup"}, else: state
      end)
    end
  end

  @spec finish(map()) :: :ok
  def finish(attestation) do
    true = Agent.get(__MODULE__, &(&1.completed == @phases and not &1.failed))

    true =
      Enum.all?(@events, fn event ->
        Enum.any?(:telemetry.list_handlers(event), &(&1.id == __MODULE__))
      end)

    emit(%{event: "finish", attestation: attestation})
    :ok = :telemetry.detach(__MODULE__)

    Agent.get(__MODULE__, fn state ->
      :ok = :file.sync(state.file)
      :ok = File.close(state.file)
    end)

    Agent.stop(__MODULE__)
  end

  defp emit(record) do
    Agent.update(__MODULE__, &write_record(advance_state(&1), record), :infinity)
  end

  # Called before any project discovery/authentication by the normal CLI.
  # The plan is public data, never executable code or a private envfile.
  @spec start_run(Path.t() | nil) :: :ok | {:error, String.t()}
  def start_run(nil), do: :ok

  def start_run(path) do
    with {:ok, %{size: size}} when size <= 65_536 <- File.stat(path),
         {:ok, json} <- File.read(path),
         {:ok, %{"output" => output, "metadata" => metadata, "phases" => phases}} <- Jason.decode(json),
         true <- is_binary(output) and Path.type(output) == :absolute,
         true <- valid_plan?(metadata, phases) do
      :ok = start(output, Map.take(metadata, ~w(variant evidence revision source_sha256 instrumentation_sha256 workload_sha256 workspace_ids)))
      Agent.update(__MODULE__, &Map.merge(&1, %{runtime: true, remaining: phases}))
      :ok = advance()
      {:ok, timer} = :timer.apply_interval(50, __MODULE__, :advance, [])
      Agent.update(__MODULE__, &Map.put(&1, :timer, timer))
      :ok
    else
      _ -> {:error, "Budget capture: ungültiger öffentlicher Messplan oder Ausgabepfad"}
    end
  rescue
    _ -> {:error, "Budget capture: Messanschluss konnte nicht gestartet werden"}
  end

  @spec advance() :: :ok
  def advance do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &advance_state/1, :infinity)
    :ok
  end

  @spec close_run(atom()) :: :ok
  def close_run(reason) do
    if Process.whereis(__MODULE__) && Agent.get(__MODULE__, &Map.get(&1, :runtime, false)) do
      Agent.update(__MODULE__, &close_state(&1, reason))

      :telemetry.detach(__MODULE__)
      Agent.stop(__MODULE__)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp close_state(%{runtime: true} = state, reason) do
    :timer.cancel(state.timer)
    state = advance_state(state)
    state = write_record(state, %{event: "finish", attestation: %{}, shutdown: reason, recorder_intact: handlers_intact?()})
    :ok = :file.sync(state.file)
    :ok = File.close(state.file)
    %{state | runtime: false}
  end

  defp close_state(state, _reason), do: state

  defp handlers_intact? do
    Enum.all?(@events, fn event -> Enum.any?(:telemetry.list_handlers(event), &(&1.id == __MODULE__)) end)
  end

  defp valid_plan?(metadata, phases) when is_map(metadata) and is_list(phases) do
    metadata["variant"] in ~w(baseline feature) and metadata["evidence"] in ~w(live fixture) and
      valid_revision?(metadata["revision"]) and valid_hashes?(metadata) and
      valid_workspaces?(metadata["workspace_ids"]) and valid_phases?(phases)
  end

  defp valid_plan?(_, _), do: false

  defp valid_revision?("uncommitted"), do: true
  defp valid_revision?(value), do: matches?(value, ~r/\A[a-f0-9]{40}\z/)

  defp valid_hashes?(metadata) do
    Enum.all?(~w(source_sha256 instrumentation_sha256 workload_sha256), &matches?(metadata[&1], ~r/\A[a-f0-9]{64}\z/))
  end

  defp valid_workspaces?(ids) when is_list(ids) and ids != [] do
    ids == Enum.uniq(ids) and Enum.all?(ids, &matches?(&1, ~r/\A[a-zA-Z0-9-]{1,64}\z/))
  end

  defp valid_workspaces?(_), do: false

  defp valid_phases?(phases) do
    Enum.map(phases, & &1["name"]) == @phases and Enum.all?(phases, &valid_duration?(&1["duration_ms"]))
  end

  defp valid_duration?(duration), do: is_integer(duration) and duration > 0 and duration <= 3_600_000
  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp advance_state(%{runtime: true} = state) do
    cond do
      state.phase != "setup" and System.monotonic_time(:millisecond) >= state.deadline ->
        state = write_record(state, %{event: "phase_end", duration_ms: state.duration})
        advance_state(%{state | phase: "setup", completed: state.completed ++ [state.phase]})

      state.phase == "setup" and state.remaining != [] ->
        [phase | remaining] = state.remaining
        duration = phase["duration_ms"]
        state = Map.merge(state, %{phase: phase["name"], remaining: remaining, duration: duration, deadline: System.monotonic_time(:millisecond) + duration})
        state = write_record(state, %{event: "phase_start", duration_ms: duration})
        :ok = :file.sync(state.file)
        state

      true ->
        state
    end
  end

  defp advance_state(state), do: state

  defp write_record(state, record) do
    record =
      Map.merge(record, %{
        sequence: state.sequence,
        phase: state.phase,
        elapsed_ms: System.monotonic_time(:millisecond) - state.start,
        at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    :ok = IO.write(state.file, "Budget capture=" <> Jason.encode!(record) <> "\n")
    %{state | sequence: state.sequence + 1}
  end
end
