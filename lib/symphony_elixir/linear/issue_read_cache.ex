defmodule SymphonyElixir.Linear.IssueReadCache do
  @moduledoc "Relay-backed issue reads with a bounded Linear safety verification."

  use GenServer

  alias SymphonyElixir.{CommentCheckpoint, ProjectContext, ProjectPoller}
  alias SymphonyElixir.Linear.{Adapter, Budget, CommentVersion, Issue, WriteContext}
  alias SymphonyElixir.Tracker

  @safety_ms 900_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))

  @spec fetch([String.t()], keyword()) :: {:ok, [SymphonyElixir.Linear.Issue.t()]} | {:error, term()}
  def fetch(ids, opts \\ []) when is_list(ids) do
    case fetch_issues(ids, opts) do
      {:ok, issues} -> {:ok, Enum.map(issues, &Issue.normalize_dependencies/1)}
      error -> error
    end
  end

  defp fetch_issues(ids, opts) do
    ids = Enum.uniq(ids)
    fetch_linear = Keyword.get(opts, :fetch_linear, fn ids -> Tracker.adapter().fetch_issue_states_by_ids(ids) end)
    context = Keyword.get(opts, :context, ProjectContext.current())
    relay = Keyword.get(opts, :relay, &ProjectPoller.read_issues/2)
    now = Keyword.get_lazy(opts, :now, &clock/0)

    cond do
      ids == [] -> {:ok, []}
      opts[:force_full] == true -> fetch_linear.(ids)
      not match?(%ProjectContext{}, context) or is_nil(context.settings.tracker.relay) -> fetch_linear.(ids)
      true -> serialized({context.id, Enum.sort(ids)}, fn -> relay_fetch(ids, context, relay, fetch_linear, now, Keyword.get(opts, :critical, false)) end)
    end
  end

  @spec comments(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def comments(id, opts \\ []) do
    context = ProjectContext.current()

    case opts[:force_full] != true && ProjectPoller.read_issues(context, [id]) do
      {:ok, [{_epoch, issue}]} ->
        with {:ok, inbox} <- CommentCheckpoint.background_scan(issue, opts |> Keyword.put_new(:background_now, &comment_clock/0) |> Keyword.put(:include_own_outputs, true)) do
          {:ok, current_comments(inbox)}
        end

      _ ->
        Adapter.fetch_issue_comments(id)
    end
  end

  defp current_comments(inbox) do
    Enum.map(inbox["current"] || %{}, fn {_id, key} ->
      {:ok, normalized} = CommentVersion.normalize(inbox["versions"][key]["source"])
      normalized
    end)
  end

  @spec verify_binding(term(), (-> :ok | {:error, term()})) :: :ok | {:error, term()}
  def verify_binding(binding, verify) do
    serialized({:binding, binding}, fn -> verify_binding_serialized(binding, verify) end)
  end

  defp verify_binding_serialized(binding, verify) do
    context = ProjectContext.current()
    id = WriteContext.current()["issue_id"]

    case context do
      %ProjectContext{settings: %{tracker: %{relay: relay}}} when not is_nil(relay) ->
        case ProjectPoller.comment_epoch(context, id) do
          {:ok, {generation, _, _}} -> verify_ready_binding(context, id, generation, binding, verify)
          _ -> verify.()
        end

      _ ->
        verify.()
    end
  end

  defp verify_ready_binding(context, id, generation, binding, verify) do
    keys = [{{context.id, context.settings.tracker.app["workspace_id"], {:binding, binding}}, generation}]
    now = clock()

    case verification(keys, now) do
      {true, _} ->
        :ok

      {false, cache_generation} ->
        verify_and_mark(context, id, generation, verify, {keys, now, cache_generation})
    end
  end

  defp verify_and_mark(context, id, generation, verify, {keys, now, cache_generation}) do
    with :ok <- verify.() do
      unchanged? = match?({:ok, {^generation, _, _}}, ProjectPoller.comment_epoch(context, id))
      if unchanged?, do: mark(keys, now, cache_generation)
      :ok
    end
  end

  defp serialized(key, callback), do: :global.trans({{__MODULE__, key}, self()}, callback, [node()])

  defp clock, do: Application.get_env(:symphony_elixir, :linear_read_now_fun, fn -> System.monotonic_time(:millisecond) end).()
  defp comment_clock, do: Application.get_env(:symphony_elixir, :linear_read_now_fun, fn -> System.system_time(:millisecond) end).()

  @spec invalidate([String.t()] | :all) :: :ok
  def invalidate(ids) when is_list(ids) or ids == :all do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:invalidate, ids})
    :ok
  end

  defp relay_fetch(ids, context, relay, fetch_linear, now, critical?) do
    case relay.(context, ids) do
      {:ok, entries} when length(entries) == length(ids) ->
        use_relay_entries(ids, entries, context, relay, fetch_linear, now, critical?)

      _ ->
        budgeted_linear(context, fetch_linear, ids, critical?)
    end
  end

  defp use_relay_entries(ids, entries, context, relay, fetch_linear, now, critical?) do
    binding = CommentVersion.digest([context.id, context.settings.tracker.app, context.settings.tracker.project_slug, context.settings.tracker.team_key, context.assignee_ids])
    keys = Enum.zip_with(ids, entries, fn id, {epoch, _issue} -> {{binding, context.settings.tracker.app["workspace_id"], id}, epoch} end)

    case verification(keys, now) do
      {true, _generation} ->
        {:ok, Enum.map(entries, &elem(&1, 1))}

      {false, generation} ->
        verification = %{now: now, critical?: critical?, generation: generation}
        verify_linear(ids, entries, keys, context, relay, fetch_linear, verification)
    end
  end

  defp verify_linear(ids, entries, keys, context, relay, fetch_linear, verification) do
    %{now: now, critical?: critical?, generation: generation} = verification

    with {:ok, issues} <- budgeted_linear(context, fetch_linear, ids, critical?) do
      same_fields =
        Enum.zip_with(issues, entries, fn linear, {_, snapshot} ->
          Issue.normalize_dependencies(linear) ==
            Issue.normalize_dependencies(without_relay_metadata(snapshot))
        end)
        |> Enum.all?(& &1)

      matches = Enum.map(issues, & &1.id) == ids and same_fields

      # A relay update during the HTTP call must be verified on the next read.
      if matches and relay_epochs_unchanged?(relay, context, ids, entries), do: mark(keys, now, generation)
      {:ok, issues}
    end
  end

  defp without_relay_metadata(issue) do
    signal = Map.get(issue, :last_comment_signal)
    signal = if is_map(signal), do: Map.delete(signal, :relay_epoch), else: signal
    signal = if signal == %{}, do: nil, else: signal
    %{issue | last_comment_signal: signal, relay_event: nil}
  end

  defp budgeted_linear(context, fetch_linear, ids, critical?) do
    if critical? or Budget.pressure(context.settings.tracker.app) != :critical,
      do: fetch_linear.(ids),
      else: {:error, :linear_budget_reserved}
  end

  defp relay_epochs_unchanged?(relay, context, ids, entries) do
    case relay.(context, ids) do
      {:ok, latest} -> Enum.map(latest, &elem(&1, 0)) == Enum.map(entries, &elem(&1, 0))
      _ -> false
    end
  end

  defp verification(keys, now) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:verified, keys, now}),
      else: {false, nil}
  end

  defp mark(keys, now, generation) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:mark, keys, now, generation})
  end

  @impl true
  def init(_), do: {:ok, %{entries: %{}, generation: 0}}

  @impl true
  def handle_call({:verified, keys, now}, _from, state) do
    valid =
      Enum.all?(keys, fn {key, epoch} ->
        case state.entries[key] do
          {^epoch, at} when is_integer(at) -> now >= at and now - at < @safety_ms
          _ -> false
        end
      end)

    {:reply, {valid, state.generation}, state}
  end

  @impl true
  def handle_call({:invalidate, :all}, _from, state), do: {:reply, :ok, %{state | entries: %{}, generation: state.generation + 1}}

  def handle_call({:invalidate, ids}, _from, state) do
    ids = MapSet.new(ids)
    entries = Map.reject(state.entries, fn {{_, _, id}, _} -> MapSet.member?(ids, id) end)
    {:reply, :ok, %{state | entries: entries, generation: state.generation + 1}}
  end

  @impl true
  def handle_cast({:mark, keys, now, generation}, %{generation: generation} = state) do
    entries = Enum.reduce(keys, state.entries, fn {key, epoch}, acc -> Map.put(acc, key, {epoch, now}) end)
    {:noreply, %{state | entries: entries}}
  end

  def handle_cast({:mark, _, _, _}, state), do: {:noreply, state}
end
