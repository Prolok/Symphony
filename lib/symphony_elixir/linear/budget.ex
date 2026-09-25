defmodule SymphonyElixir.Linear.Budget do
  @moduledoc "Recent request budget and grouped counts for each Linear app binding."

  use GenServer
  require Logger

  @summary_ms 300_000
  @stale_ms 3_600_000
  @background_lookup_ms 120_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec record(map(), atom(), map(), keyword()) :: :ok
  def record(binding, kind, headers, opts \\ []) do
    now = Keyword.get(opts, :now, System.monotonic_time(:millisecond))
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:record, binding, kind, headers, now})
    :ok
  end

  @spec low?(map()) :: boolean()
  def low?(binding) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:low?, key(binding)}), else: false
  end

  @spec allow_background_lookup?(map(), String.t()) :: boolean()
  def allow_background_lookup?(binding, identifier) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:background_lookup, key(binding), identifier}),
      else: true
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:low?, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    entry = state[key]
    {:reply, low_entry?(entry, now), state}
  end

  @impl true
  def handle_call({:background_lookup, key, identifier}, _from, state) do
    now = System.monotonic_time(:millisecond)
    entry = state[key]

    if low_entry?(entry, now) do
      last = get_in(entry, [:lookups, identifier])

      if is_integer(last) and now - last < @background_lookup_ms do
        {:reply, false, state}
      else
        updated = Map.update(entry, :lookups, %{identifier => now}, &Map.put(&1, identifier, now))
        {:reply, true, Map.put(state, key, updated)}
      end
    else
      {:reply, true, state}
    end
  end

  @impl true
  def handle_cast({:record, binding, kind, headers, now}, state) do
    key = key(binding)
    previous = Map.get(state, key, %{limit: nil, remaining: nil, observed_at: now, summary_at: now, counts: %{}, lookups: %{}})
    limit = integer(headers["x-ratelimit-requests-limit"]) || previous.limit
    remaining = integer(headers["x-ratelimit-requests-remaining"]) || previous.remaining
    observed_at = if is_integer(integer(headers["x-ratelimit-requests-remaining"])), do: now, else: previous.observed_at
    counts = Map.update(previous.counts, kind, 1, &(&1 + 1))
    entry = %{previous | limit: limit, remaining: remaining, observed_at: observed_at, counts: counts}

    entry =
      if now - previous.summary_at >= @summary_ms do
        Logger.info(
          "Linear budget summary workspace_id=#{binding["workspace_id"]} client_id=#{binding["client_id"]} remaining=#{inspect(remaining)} limit=#{inspect(limit)} requests=#{inspect(counts)}"
        )

        %{entry | counts: %{}, summary_at: now}
      else
        entry
      end

    {:noreply, Map.put(state, key, entry)}
  end

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil

  defp low_entry?(entry, now) do
    is_map(entry) and is_integer(entry.limit) and is_integer(entry.remaining) and
      now - entry.observed_at < @stale_ms and entry.remaining * 5 < entry.limit
  end

  defp key(binding), do: {binding["workspace_id"], binding["client_id"]}
end
