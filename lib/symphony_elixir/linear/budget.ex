defmodule SymphonyElixir.Linear.Budget do
  @moduledoc "Recent request budget and grouped counts for each Linear app binding."

  use GenServer
  require Logger

  @summary_ms 300_000
  @stale_ms 3_600_000

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

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:low?, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    entry = state[key]

    low =
      is_map(entry) and is_integer(entry.limit) and is_integer(entry.remaining) and
        now - entry.observed_at < @stale_ms and entry.remaining * 5 < entry.limit

    {:reply, low, state}
  end

  @impl true
  def handle_cast({:record, binding, kind, headers, now}, state) do
    key = key(binding)
    previous = Map.get(state, key, %{limit: nil, remaining: nil, observed_at: now, summary_at: now, counts: %{}})
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
  defp key(binding), do: {binding["workspace_id"], binding["client_id"]}
end
