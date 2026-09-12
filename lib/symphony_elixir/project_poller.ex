defmodule SymphonyElixir.ProjectPoller do
  @moduledoc "One periodic candidate fetch per workspace, shared by project loops and retries."
  use GenServer
  require Logger

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{ProjectContext, Projects}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec candidates(ProjectContext.t()) :: {:ok, list()} | {:error, term()}
  def candidates(context), do: GenServer.call(__MODULE__, {:candidates, context.id}, 120_000)

  @spec refresh() :: :ok
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @spec polling() :: map()
  def polling do
    GenServer.call(__MODULE__, :polling, 50)
  catch
    :exit, _ -> %{checking?: true, next_poll_in_ms: nil, poll_interval_ms: nil}
  end

  @impl true
  def init(opts) do
    contexts = Keyword.fetch!(opts, :contexts)
    interval = contexts |> Enum.map(& &1.settings.polling.interval_ms) |> Enum.min()

    state = %{
      contexts: contexts,
      interval: interval,
      result: {:error, :initial_poll_pending},
      timer: nil,
      timer_token: nil
    }

    case Client.verify_project_assignees(contexts) do
      :ok -> {:ok, state, {:continue, :poll}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, poll(state)}

  @impl true
  def handle_call(:polling, _from, state) do
    remaining = if state.timer, do: Process.read_timer(state.timer), else: false
    {:reply, %{checking?: false, next_poll_in_ms: remaining || 0, poll_interval_ms: state.interval}, state}
  end

  def handle_call({:candidates, id}, _from, state) do
    result =
      case state.result do
        {:ok, candidates} -> {:ok, Map.fetch!(candidates, id)}
        error -> error
      end

    {:reply, result, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, poll(state)}
  end

  @impl true
  def handle_info({:poll, token}, %{timer_token: token} = state), do: {:noreply, poll(state)}
  def handle_info({:poll, _stale_token}, state), do: {:noreply, state}

  defp poll(state) do
    result = Client.fetch_project_candidates(state.contexts)
    if match?({:error, _}, result), do: Logger.error("Gemeinsames Linear-Polling fehlgeschlagen: #{inspect(result)}")
    token = make_ref()
    timer = Process.send_after(self(), {:poll, token}, state.interval)

    for context <- state.contexts do
      if pid = GenServer.whereis(Projects.server(context)), do: send(pid, :tick)
    end

    %{state | result: result, timer: timer, timer_token: token}
  end
end
