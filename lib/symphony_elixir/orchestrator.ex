defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    Dialog,
    PromptBuilder,
    RuntimeInstances,
    RuntimePaths,
    StatusDashboard,
    Tracker,
    Workpad,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @worker_exit_finalize_drain_ms 250
  @idle_shutdown_message "Symphony nach Inaktivität beendet"
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @dialog_safety_full_check_base_ms 30_000
  @codex_recent_events_limit 200
  @cancel_state_name "abbruch (ai)"
  @in_arbeit_ai_state_name "in arbeit (ai)"
  @manual_in_progress_state_name "in arbeit"
  @yolo_manual_state_names ["freigabe implementierung", "freigabe review"]
  @regular_run_mode :regular
  @dialog_run_mode :dialog
  @manual_in_progress_bootstrap_run_mode :manual_in_progress_bootstrap
  @review_handoff_state_name "Freigabe Review"
  @review_no_findings_handoff_state_name "Test (AI)"
  @canceled_terminal_state_name "Abgebrochen"
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :idle_shutdown_ms,
      :idle_shutdown_ms_override,
      :last_activity_at_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :active_instance_count_fun,
      :shutdown_fun,
      :output_fun,
      external_poll: false,
      shutdown_requested: false,
      running: %{},
      completed: MapSet.new(),
      completed_states: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      dialog_observations: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    :ok = SymphonyElixir.ProjectContext.bind(Keyword.get(opts, :context))
    if Keyword.get(opts, :external_poll, false), do: Process.flag(:trap_exit, true)
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    idle_shutdown_ms_override = Keyword.get(opts, :idle_shutdown_ms)

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      idle_shutdown_ms: idle_shutdown_ms_override || config.polling.idle_shutdown_ms,
      idle_shutdown_ms_override: idle_shutdown_ms_override,
      last_activity_at_ms: now_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      active_instance_count_fun: Keyword.get(opts, :active_instance_count_fun, &RuntimeInstances.active_count/0),
      shutdown_fun: Keyword.get(opts, :shutdown_fun, &default_shutdown/0),
      output_fun: Keyword.get(opts, :output_fun, &IO.puts/1),
      external_poll: Keyword.get(opts, :external_poll, false),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    maybe_run_terminal_workspace_cleanup()

    initial_poll_delay_ms =
      if Keyword.get(
           opts,
           :initial_poll?,
           Application.get_env(:symphony_elixir, :run_initial_orchestrator_poll_on_start, true)
         ) do
        0
      else
        state.poll_interval_ms
      end

    state =
      if state.external_poll do
        # The shared initial fetch may finish before this project is registered.
        # Consume its cache on startup as well as on subsequent poll notifications.
        send(self(), :tick)
        state
      else
        schedule_tick(state, initial_poll_delay_ms)
      end

    {:ok, state}
  end

  @impl true
  def terminate(_reason, %State{external_poll: true, running: running}) do
    Enum.each(running, fn {_id, entry} ->
      Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, entry.pid)
    end)
  end

  def terminate(_reason, _state), do: :ok

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    previous_state = state
    state = maybe_dispatch(state)
    state = maybe_touch_activity_for_state_change(previous_state, state)
    state = maybe_request_idle_shutdown(state)

    state =
      if state.shutdown_requested or state.external_poll do
        state
      else
        schedule_tick(state, next_poll_delay_ms(state))
      end

    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        state =
          case reason do
            :normal ->
              schedule_running_entry_finalization(state, issue_id, Map.get(running, issue_id), reason)

            _ ->
              {running_entry, state} = pop_running_entry(state, issue_id)
              state = record_session_completion_totals(state, running_entry)
              session_id = running_entry_session_id(running_entry)

              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              state =
                schedule_issue_retry(state, issue_id, next_attempt, %{
                  identifier: running_entry.identifier,
                  error: "agent exited: #{inspect(reason)}",
                  worker_host: Map.get(running_entry, :worker_host),
                  workspace_path: Map.get(running_entry, :workspace_path),
                  recovered_turn_context: recoverable_turn_context(running_entry, reason),
                  review_subagent_call_ids: review_subagent_call_ids_for_retry(running_entry),
                  review_subagent_ids: review_subagent_ids_for_retry(running_entry)
                })

              Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")
              state
          end
          |> touch_activity()

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)} |> touch_activity()}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        case maybe_integrate_retry_codex_update(state, issue_id, update) do
          {:updated, next_state} ->
            notify_dashboard()
            {:noreply, touch_activity(next_state)}

          :unchanged ->
            {:noreply, state}
        end

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)} |> touch_activity()}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info(
        {:agent_completion_contract, issue_id, contract},
        %{running: running} = state
      )
      when is_binary(issue_id) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        notify_dashboard()

        {:noreply,
         %{state | running: Map.put(running, issue_id, Map.put(running_entry, :completion_contract, contract))}
         |> touch_activity()}
    end
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} ->
          case handle_retry_issue(state, issue_id, attempt, metadata) do
            {:noreply, next_state} -> {:noreply, touch_activity(next_state)}
          end

        :missing ->
          {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info({:finalize_running_issue_exit, issue_id, finalize_token}, %{running: running} = state)
      when is_binary(issue_id) and is_reference(finalize_token) do
    case Map.get(running, issue_id) do
      %{exit_finalize_token: ^finalize_token} ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        exit_reason = Map.get(running_entry, :exit_reason, :normal)
        running_entry = clear_running_entry_finalize_state(running_entry)
        session_id = running_entry_session_id(running_entry)
        state = record_session_completion_totals(state, running_entry)

        state =
          case exit_reason do
            :normal ->
              handle_normal_issue_completion(state, issue_id, session_id, running_entry)

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(exit_reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: "agent exited: #{inspect(exit_reason)}",
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path),
                recovered_turn_context: recoverable_turn_context(running_entry, exit_reason),
                review_subagent_call_ids: review_subagent_call_ids_for_retry(running_entry),
                review_subagent_ids: review_subagent_ids_for_retry(running_entry)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(exit_reason)}")

        notify_dashboard()
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      state = retain_visible_completed_states(state, issues)
      state = retain_visible_dialog_observations(state, issues)

      if available_slots(state) > 0 do
        choose_issues(state, issues)
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_scope} ->
        Logger.error("Configure exactly one Linear scope using tracker.project_slug/tracker.team_key or LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY")

        state

      {:error, :multiple_linear_scopes} ->
        Logger.error("Project and team scopes are mutually exclusive; check tracker.project_slug/tracker.team_key and LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY")

        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set()) and
      dialog_full_check_needed_for_dispatch?(issue, state, 1, System.monotonic_time(:millisecond))
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  @doc false
  @spec select_worker_host_for_issue_for_test(Issue.t(), term(), String.t() | nil) ::
          String.t() | nil | :no_worker_capacity
  def select_worker_host_for_issue_for_test(%Issue{} = issue, %State{} = state, preferred_worker_host) do
    select_worker_host_for_issue(issue, state, preferred_worker_host)
  end

  @doc false
  @spec observe_dialog_full_check_for_test(Issue.t(), term(), integer()) :: term()
  def observe_dialog_full_check_for_test(%Issue{} = issue, %State{} = state, now_ms) when is_integer(now_ms) do
    observe_dialog_full_check(state, issue, now_ms)
  end

  @doc false
  @spec observe_dialog_failed_full_check_for_test(Issue.t(), term(), integer()) :: term()
  def observe_dialog_failed_full_check_for_test(%Issue{} = issue, %State{} = state, now_ms)
      when is_integer(now_ms) do
    observe_dialog_failed_full_check(state, issue, now_ms)
  end

  @doc false
  @spec observe_dialog_dispatch_result_for_test(Issue.t(), term(), term(), integer()) :: term()
  def observe_dialog_dispatch_result_for_test(
        %Issue{} = issue,
        %State{} = state_before_dispatch,
        %State{} = state_after_dispatch,
        now_ms
      )
      when is_integer(now_ms) do
    observe_dialog_dispatched_full_check(state_before_dispatch, state_after_dispatch, issue, now_ms)
  end

  @doc false
  @spec dialog_safety_full_check_interval_ms_for_test(term(), non_neg_integer()) :: pos_integer()
  def dialog_safety_full_check_interval_ms_for_test(%State{} = state, dialog_issue_count)
      when is_integer(dialog_issue_count) and dialog_issue_count >= 0 do
    dialog_safety_full_check_interval_ms(state, dialog_issue_count)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      cancel_issue_state?(issue.state) ->
        Logger.info("Issue moved to cancel state: #{issue_context(issue)} state=#{issue.state}; aborting workflow and cleaning workspace")

        cancel_issue_workflow(state, issue)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        reconcile_active_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp reconcile_active_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        if same_run_mode?(running_entry, issue) do
          refresh_running_issue_state(state, issue)
        else
          Logger.info("Issue changed active run mode: #{issue_context(issue)} state=#{issue.state}; restarting with matching runner")

          terminate_running_issue(state, issue.id, false)
        end

      _ ->
        state
    end
  end

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if manual_in_progress_bootstrap_running_entry?(running_entry) do
      state
    else
      restart_stalled_codex_issue(state, issue_id, running_entry, elapsed_ms, timeout_ms)
    end
  end

  defp restart_stalled_codex_issue(state, issue_id, running_entry, elapsed_ms, timeout_ms) do
    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning(
        "Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms} " <>
          "last_event=#{inspect(Map.get(running_entry, :last_codex_event))} " <>
          "last_event_at=#{inspect(log_timestamp(Map.get(running_entry, :last_codex_timestamp)))} " <>
          "last_tool_call=#{log_inspect(Map.get(running_entry, :last_tool_call))} " <>
          "last_session_event=#{log_inspect(Map.get(running_entry, :last_codex_message))}; restarting with backoff"
      )

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        recovered_turn_context: recoverable_turn_context(running_entry, :stalled),
        review_subagent_call_ids: review_subagent_call_ids_for_retry(running_entry),
        review_subagent_ids: review_subagent_ids_for_retry(running_entry)
      })
    else
      state
    end
  end

  defp same_run_mode?(running_entry, %Issue{} = issue) when is_map(running_entry) do
    running_entry_run_mode(running_entry) == issue_run_mode(issue)
  end

  defp running_entry_run_mode(%{run_mode: run_mode}) when is_atom(run_mode), do: run_mode

  defp running_entry_run_mode(%{issue: %Issue{} = issue}), do: issue_run_mode(issue)

  defp running_entry_run_mode(_running_entry), do: @regular_run_mode

  defp issue_run_mode(%Issue{state: state_name}) when is_binary(state_name) do
    cond do
      Dialog.state?(state_name) -> @dialog_run_mode
      manual_in_progress_issue_state?(state_name) -> @manual_in_progress_bootstrap_run_mode
      true -> @regular_run_mode
    end
  end

  defp issue_run_mode(_issue), do: @regular_run_mode

  defp manual_in_progress_bootstrap_running_entry?(running_entry) when is_map(running_entry) do
    running_entry_run_mode(running_entry) == @manual_in_progress_bootstrap_run_mode
  end

  defp manual_in_progress_bootstrap_running_entry?(_running_entry), do: false

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp log_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp log_timestamp(_timestamp), do: nil

  defp log_inspect(value) do
    inspect(value, limit: 20, printable_limit: 500)
  end

  defp terminate_task(pid) when is_pid(pid) do
    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      task_supervisor when is_pid(task_supervisor) ->
        case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
          :ok ->
            :ok

          {:error, :not_found} ->
            Process.exit(pid, :shutdown)
        end

      _ ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(state, issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    dialog_issue_count = dialog_issue_count(issues)

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      cond do
        cancel_issue_state?(issue.state) ->
          cancel_issue_workflow(state_acc, issue)

        should_dispatch_issue?(issue, state_acc, active_states, terminal_states) ->
          maybe_dispatch_candidate_issue(state_acc, issue, dialog_issue_count)

        true ->
          state_acc
      end
    end)
  end

  defp maybe_dispatch_candidate_issue(%State{} = state, %Issue{} = issue, dialog_issue_count) do
    if Dialog.state?(issue.state) do
      maybe_dispatch_dialog_issue(state, issue, dialog_issue_count)
    else
      dispatch_issue(state, issue)
    end
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{
           running: running,
           claimed: claimed,
           completed_states: completed_states,
           retry_attempts: retry_attempts
         } = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !blocked_issue_in_dispatch_state?(issue, terminal_states) and
      dispatchable_after_completion?(issue, completed_states) and
      !pending_retry?(retry_attempts, issue.id) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(issue, state, nil)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp pending_retry?(retry_attempts, issue_id) when is_map(retry_attempts) and is_binary(issue_id) do
    Map.has_key?(retry_attempts, issue_id)
  end

  defp pending_retry?(_retry_attempts, _issue_id), do: false

  defp dispatchable_after_completion?(%Issue{state: issue_state} = issue, completed_states)
       when is_binary(issue_state) do
    Dialog.state?(issue_state) or not completed_in_current_state?(issue, completed_states)
  end

  defp dispatchable_after_completion?(issue, completed_states) do
    not completed_in_current_state?(issue, completed_states)
  end

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      dispatch_state?(issue, active_states) and
      !cancel_issue_state?(state_name) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp dispatch_state?(%Issue{state: state_name} = issue, active_states)
       when is_binary(state_name) do
    active_issue_state?(state_name, active_states) or skip_manual_issue_state?(issue)
  end

  defp dispatch_state?(_issue, _active_states), do: false

  defp skip_manual_issue_state?(%Issue{state: state_name} = issue) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    normalized_state in @yolo_manual_state_names and
      (Config.yolo?() or manual_skip_label?(issue, normalized_state))
  end

  defp skip_manual_issue_state?(_issue), do: false

  defp manual_skip_label?(%Issue{} = issue, normalized_state) when is_binary(normalized_state) do
    issue
    |> Issue.label_names()
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.any?(fn label ->
      label == ~s(skip "#{normalized_state}") or label == "skip #{normalized_state}"
    end)
  end

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: Config.yolo?() or assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp blocked_issue_in_dispatch_state?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    blocked_by_respected_issue_state?(issue_state) and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp blocked_issue_in_dispatch_state?(_issue, _terminal_states), do: false

  defp todo_issue_state?(state_name) when is_binary(state_name) do
    String.starts_with?(normalize_issue_state(state_name), "todo")
  end

  defp blocked_by_respected_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    todo_issue_state?(normalized_state) or normalized_state == @in_arbeit_ai_state_name
  end

  defp cancel_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @cancel_state_name
  end

  defp cancel_issue_state?(_state_name), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.concat(extra_active_state_names())
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp extra_active_state_names do
    dialog_state_names = [Dialog.state_name()]

    if Config.yolo?() do
      [@manual_in_progress_state_name | @yolo_manual_state_names] ++ dialog_state_names
    else
      [@manual_in_progress_state_name | dialog_state_names]
    end
  end

  defp manual_in_progress_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @manual_in_progress_state_name
  end

  defp manual_in_progress_issue_state?(_state_name), do: false

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         run_opts \\ []
       ) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, run_opts)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, run_opts) do
    recipient = self()

    case select_worker_host_for_issue(issue, state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, run_opts)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, run_opts) do
    context = SymphonyElixir.ProjectContext.current()

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           :ok = SymphonyElixir.ProjectContext.bind(context)

           AgentRunner.run(
             issue,
             recipient,
             Keyword.merge(run_opts, attempt: attempt, worker_host: worker_host)
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            dispatch_issue: issue,
            issue: issue,
            run_mode: issue_run_mode(issue),
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            last_codex_message: nil,
            codex_event_sequence: 0,
            recent_codex_events: [],
            last_codex_timestamp: nil,
            last_codex_event: nil,
            last_tool_call: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            recovered_turn_context: nil,
            recovered_review_subagent_call_ids:
              run_opts
              |> Keyword.get(:recovered_review_subagent_call_ids)
              |> normalize_review_subagent_call_ids(),
            recovered_review_subagent_ids:
              run_opts
              |> Keyword.get(:recovered_review_subagent_ids)
              |> normalize_review_subagent_ids(),
            review_subagent_call_ids: MapSet.new(),
            review_subagent_ids: MapSet.new(),
            completion_contract: nil,
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp maybe_dispatch_dialog_issue(%State{} = state, %Issue{} = issue, dialog_issue_count) do
    now_ms = System.monotonic_time(:millisecond)

    if dialog_full_check_needed_for_dispatch?(issue, state, dialog_issue_count, now_ms) do
      run_dialog_full_check(state, issue, now_ms)
    else
      state
    end
  end

  defp run_dialog_full_check(%State{} = state, %Issue{} = issue, now_ms) when is_integer(now_ms) do
    workspace = RuntimePaths.project_root()

    with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id),
         {:ok, request} <- Dialog.next_request(issue, comments, workspace) do
      case request do
        :noop ->
          Logger.debug("Skipping idle dialog issue after comment refresh: #{issue_context(issue)}")
          observe_dialog_full_check(state, issue, now_ms)

        %{prompt: prompt} = request when is_binary(prompt) ->
          dispatched_state = dispatch_issue(state, issue, nil, nil, dialog_run_opts(request))
          observe_dialog_dispatched_full_check(state, dispatched_state, issue, now_ms)
      end
    else
      {:error, reason} ->
        Logger.warning("Skipping dialog issue after comment refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        observe_dialog_failed_full_check(state, issue, now_ms)
    end
  end

  defp dialog_run_opts(request) when is_map(request), do: [dialog_request: request]

  defp dialog_full_check_needed_for_dispatch?(%Issue{} = issue, %State{} = state, dialog_issue_count, now_ms)
       when is_integer(now_ms) do
    if Dialog.state?(issue.state) do
      dialog_full_check_needed?(issue, state, dialog_issue_count, now_ms)
    else
      true
    end
  end

  defp dialog_full_check_needed?(%Issue{id: issue_id} = issue, %State{} = state, dialog_issue_count, now_ms)
       when is_binary(issue_id) do
    current_key = dialog_comment_signal_key(issue.last_comment_signal)

    case Map.get(state.dialog_observations, issue_id) do
      nil ->
        true

      %{comment_key: observed_key} = observation ->
        observed_key != current_key or dialog_safety_full_check_due?(observation, state, dialog_issue_count, now_ms)

      _observation ->
        true
    end
  end

  defp dialog_full_check_needed?(_issue, _state, _dialog_issue_count, _now_ms), do: true

  defp dialog_safety_full_check_due?(observation, %State{} = state, dialog_issue_count, now_ms)
       when is_map(observation) and is_integer(now_ms) do
    case Map.get(observation, :last_full_check_at_ms) do
      checked_at_ms when is_integer(checked_at_ms) ->
        now_ms - checked_at_ms >= dialog_safety_full_check_interval_ms(state, dialog_issue_count)

      _ ->
        true
    end
  end

  defp dialog_safety_full_check_interval_ms(%State{} = state, dialog_issue_count) do
    @dialog_safety_full_check_base_ms * max(1, dialog_issue_count) * active_instance_count(state)
  end

  defp observe_dialog_full_check(%State{} = state, %Issue{id: issue_id} = issue, now_ms)
       when is_binary(issue_id) and is_integer(now_ms) do
    observation = %{
      comment_key: dialog_comment_signal_key(issue.last_comment_signal),
      last_full_check_at_ms: now_ms
    }

    %{state | dialog_observations: Map.put(state.dialog_observations, issue_id, observation)}
  end

  defp observe_dialog_full_check(%State{} = state, _issue, _now_ms), do: state

  defp observe_dialog_failed_full_check(%State{} = state, %Issue{id: issue_id} = issue, now_ms)
       when is_binary(issue_id) and is_integer(now_ms) do
    current_key = dialog_comment_signal_key(issue.last_comment_signal)

    case Map.get(state.dialog_observations, issue_id) do
      nil when current_key == :missing ->
        observe_dialog_full_check(state, issue, now_ms)

      %{comment_key: observed_key} = observation when observed_key == current_key ->
        updated_observation = Map.put(observation, :last_full_check_at_ms, now_ms)
        %{state | dialog_observations: Map.put(state.dialog_observations, issue_id, updated_observation)}

      _ ->
        state
    end
  end

  defp observe_dialog_failed_full_check(%State{} = state, _issue, _now_ms), do: state

  defp observe_dialog_dispatched_full_check(
         %State{} = state_before_dispatch,
         %State{} = state_after_dispatch,
         %Issue{id: issue_id} = issue,
         now_ms
       )
       when is_binary(issue_id) and is_integer(now_ms) do
    if dialog_dispatch_accepted?(state_before_dispatch, state_after_dispatch, issue_id) do
      observe_dialog_full_check(state_after_dispatch, issue, now_ms)
    else
      state_after_dispatch
    end
  end

  defp dialog_dispatch_accepted?(%State{} = state_before_dispatch, %State{} = state_after_dispatch, issue_id)
       when is_binary(issue_id) do
    new_running_entry? =
      not Map.has_key?(state_before_dispatch.running, issue_id) and
        Map.has_key?(state_after_dispatch.running, issue_id)

    new_retry_entry? =
      not Map.has_key?(state_before_dispatch.retry_attempts, issue_id) and
        Map.has_key?(state_after_dispatch.retry_attempts, issue_id)

    new_running_entry? or new_retry_entry?
  end

  defp dialog_comment_signal_key(%{id: id, created_at: created_at, updated_at: updated_at}) do
    {comment_signal_key_value(id), comment_signal_key_value(created_at), comment_signal_key_value(updated_at)}
  end

  defp dialog_comment_signal_key(_signal), do: :missing

  defp comment_signal_key_value(value) when is_binary(value), do: value
  defp comment_signal_key_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp comment_signal_key_value(_value), do: nil

  defp dialog_issue_count(issues) when is_list(issues) do
    issues
    |> Enum.count(fn
      %Issue{state: state_name} -> Dialog.state?(state_name)
      _ -> false
    end)
    |> max(1)
  end

  defp complete_issue(%State{} = state, issue_id, issue_state) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        completed_states: put_completed_state(state.completed_states, issue_id, issue_state),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    recovered_turn_context = pick_retry_recovered_turn_context(previous_retry, metadata)
    review_subagent_call_ids = pick_retry_review_subagent_call_ids(previous_retry, metadata)
    review_subagent_ids = pick_retry_review_subagent_ids(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            recovered_turn_context: recovered_turn_context,
            review_subagent_call_ids: review_subagent_call_ids,
            review_subagent_ids: review_subagent_ids
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          recovered_turn_context: Map.get(retry_entry, :recovered_turn_context),
          review_subagent_call_ids: Map.get(retry_entry, :review_subagent_call_ids),
          review_subagent_ids: Map.get(retry_entry, :review_subagent_ids)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      cancel_issue_state?(issue.state) ->
        Logger.info("Issue state is cancel requested: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; aborting workflow and cleaning workspace")

        {:noreply, cancel_issue_workflow(state, issue, metadata[:worker_host])}

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      clean_review_retry_handoff_ready?(issue, metadata) ->
        handle_clean_review_retry_handoff(state, issue_id, issue, attempt, metadata)

      completed_in_current_state?(issue, state.completed_states) ->
        Logger.info("Issue already completed in current state during retry; stopping continuation: #{issue_context(issue)}")
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp cancel_issue_workflow(%State{} = state, %Issue{} = issue, cleanup_worker_host \\ nil) do
    state =
      case Map.get(state.running, issue.id) do
        %{identifier: _identifier} ->
          state
          |> terminate_running_issue(issue.id, true)
          |> clear_issue_tracking(issue.id)

        _ ->
          cleanup_issue_workspace(issue.identifier, cleanup_worker_host)
          clear_issue_tracking(state, issue.id)
      end

    case Tracker.update_issue_state(issue.id, @canceled_terminal_state_name) do
      :ok ->
        Logger.info("Issue cancel cleanup completed: #{issue_context(issue)} next_state=#{@canceled_terminal_state_name}")

      {:error, reason} ->
        Logger.warning("Issue cancel cleanup completed but state transition failed: #{issue_context(issue)} next_state=#{@canceled_terminal_state_name} reason=#{inspect(reason)}")
    end

    state
  end

  defp clear_issue_tracking(%State{} = state, issue_id) when is_binary(issue_id) do
    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        completed: MapSet.delete(state.completed, issue_id),
        completed_states: Map.delete(state.completed_states, issue_id),
        dialog_observations: Map.delete(state.dialog_observations, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp maybe_run_terminal_workspace_cleanup do
    if Application.get_env(:symphony_elixir, :run_terminal_workspace_cleanup_on_start, true) do
      run_terminal_workspace_cleanup()
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(issue, state, metadata[:worker_host]) do
      {:noreply,
       dispatch_issue(
         state,
         issue,
         attempt,
         metadata[:worker_host],
         retry_run_opts(metadata)
       )}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp maybe_integrate_retry_codex_update(%State{} = state, issue_id, update)
       when is_binary(issue_id) and is_map(update) do
    case Map.get(state.retry_attempts, issue_id) do
      nil ->
        :unchanged

      retry_entry ->
        tracking_entry = %{
          recovered_turn_context: Map.get(retry_entry, :recovered_turn_context),
          recovered_review_subagent_call_ids: MapSet.new(),
          recovered_review_subagent_ids: MapSet.new(),
          review_subagent_call_ids:
            retry_entry
            |> Map.get(:review_subagent_call_ids)
            |> normalize_review_subagent_call_ids(),
          review_subagent_ids:
            retry_entry
            |> Map.get(:review_subagent_ids)
            |> normalize_review_subagent_ids()
        }

        {updated_tracking_entry, _token_delta} = integrate_codex_update(tracking_entry, update)

        updated_retry_entry =
          retry_entry
          |> Map.put(:recovered_turn_context, Map.get(updated_tracking_entry, :recovered_turn_context))
          |> Map.put(
            :review_subagent_call_ids,
            review_subagent_call_ids_for_retry(updated_tracking_entry)
          )
          |> Map.put(
            :review_subagent_ids,
            review_subagent_ids_for_retry(updated_tracking_entry)
          )

        if updated_retry_entry == retry_entry do
          :unchanged
        else
          {:updated, %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, updated_retry_entry)}}
        end
    end
  end

  defp handle_normal_issue_completion(%State{} = state, issue_id, session_id, running_entry)
       when is_binary(issue_id) and is_map(running_entry) do
    completed_issue = completed_issue_for_running_entry(running_entry)

    case Map.get(running_entry, :completion_contract) do
      {:incomplete_phase_max_turns, reason} ->
        handle_incomplete_phase_max_turns_completion(state, issue_id, session_id, running_entry, reason)

      _contract ->
        handle_completed_phase_completion(state, issue_id, session_id, running_entry, completed_issue)
    end
  end

  defp handle_completed_phase_completion(
         %State{} = state,
         issue_id,
         session_id,
         running_entry,
         completed_issue
       ) do
    if manual_in_progress_issue_state?(completed_issue.state) or Dialog.state?(completed_issue.state) do
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; manual in-progress bootstrap finished without continuation")

      state
      |> complete_issue(issue_id, completed_issue)
      |> release_issue_claim(issue_id)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")
      log_review_retry_context(running_entry, session_id)

      state
      |> complete_issue(issue_id, completed_issue)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        recovered_turn_context: Map.get(running_entry, :recovered_turn_context),
        review_subagent_call_ids: review_subagent_call_ids_for_retry(running_entry),
        review_subagent_ids: review_subagent_ids_for_retry(running_entry)
      })
    end
  end

  defp handle_incomplete_phase_max_turns_completion(
         %State{} = state,
         issue_id,
         session_id,
         running_entry,
         reason
       ) do
    Logger.warning(
      "Agent task reached agent.max_turns with incomplete phase completion contract for issue_id=#{issue_id} session_id=#{session_id}; scheduling guardrail continuation without recording normal completion reason=#{inspect(reason)}"
    )

    log_review_retry_context(running_entry, session_id)

    schedule_issue_retry(state, issue_id, 1, %{
      identifier: running_entry.identifier,
      delay_type: :continuation,
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      recovered_turn_context: Map.get(running_entry, :recovered_turn_context),
      review_subagent_call_ids: review_subagent_call_ids_for_retry(running_entry),
      review_subagent_ids: review_subagent_ids_for_retry(running_entry)
    })
  end

  defp completed_issue_for_running_entry(%{dispatch_issue: %Issue{} = issue}), do: issue
  defp completed_issue_for_running_entry(%{issue: %Issue{} = issue}), do: issue

  defp completed_in_current_state?(
         %Issue{id: issue_id, state: issue_state, updated_at: updated_at},
         completed_states
       )
       when is_binary(issue_id) and is_binary(issue_state) and is_map(completed_states) do
    completed_state_matches_issue?(Map.get(completed_states, issue_id), issue_state, updated_at)
  end

  defp completed_in_current_state?(_issue, _completed_states), do: false

  defp put_completed_state(completed_states, issue_id, %Issue{
         state: issue_state,
         updated_at: updated_at
       })
       when is_map(completed_states) and is_binary(issue_id) and is_binary(issue_state) do
    Map.put(completed_states, issue_id, completed_state_value(issue_state, updated_at))
  end

  defp put_completed_state(completed_states, issue_id, issue_state)
       when is_map(completed_states) and is_binary(issue_id) and is_binary(issue_state) do
    Map.put(completed_states, issue_id, completed_state_value(issue_state, nil))
  end

  defp put_completed_state(completed_states, _issue_id, _issue_state) when is_map(completed_states),
    do: completed_states

  defp completed_state_value(issue_state, updated_at) when is_binary(issue_state) do
    if Dialog.state?(issue_state) do
      {normalize_issue_state(issue_state), completed_timestamp(updated_at)}
    else
      normalize_issue_state(issue_state)
    end
  end

  defp completed_state_matches_issue?(
         {completed_state, completed_updated_at},
         issue_state,
         updated_at
       )
       when is_binary(completed_state) and is_binary(issue_state) do
    Dialog.state?(issue_state) and completed_state == normalize_issue_state(issue_state) and
      completed_updated_at == completed_timestamp(updated_at)
  end

  defp completed_state_matches_issue?(completed_state, issue_state, _updated_at)
       when is_binary(completed_state) and is_binary(issue_state) do
    completed_state == normalize_issue_state(issue_state)
  end

  defp completed_state_matches_issue?(_completed_state, _issue_state, _updated_at), do: false

  defp completed_timestamp(%DateTime{} = updated_at), do: DateTime.to_iso8601(updated_at)
  defp completed_timestamp(_updated_at), do: nil

  defp retain_visible_completed_states(%State{} = state, issues) when is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    completed_states =
      Enum.reduce(state.completed_states, %{}, fn {issue_id, normalized_state}, acc ->
        if MapSet.member?(visible_issue_ids, issue_id) do
          Map.put(acc, issue_id, normalized_state)
        else
          acc
        end
      end)

    completed =
      Enum.reduce(state.completed, MapSet.new(), fn issue_id, acc ->
        if MapSet.member?(visible_issue_ids, issue_id) do
          MapSet.put(acc, issue_id)
        else
          acc
        end
      end)

    %{state | completed_states: completed_states, completed: completed}
  end

  defp retain_visible_dialog_observations(%State{} = state, issues) when is_list(issues) do
    visible_dialog_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id, state: state_name} when is_binary(issue_id) ->
          if Dialog.state?(state_name), do: [issue_id], else: []

        _ ->
          []
      end)
      |> MapSet.new()

    dialog_observations =
      Enum.reduce(state.dialog_observations, %{}, fn {issue_id, observation}, acc ->
        if MapSet.member?(visible_dialog_issue_ids, issue_id) do
          Map.put(acc, issue_id, observation)
        else
          acc
        end
      end)

    %{state | dialog_observations: dialog_observations}
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp schedule_running_entry_finalization(%State{} = state, issue_id, running_entry, reason)
       when is_binary(issue_id) and is_map(running_entry) do
    finalize_token = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:finalize_running_issue_exit, issue_id, finalize_token},
        @worker_exit_finalize_drain_ms
      )

    updated_running_entry =
      running_entry
      |> cancel_running_entry_finalize_timer()
      |> Map.put(:exit_reason, reason)
      |> Map.put(:exit_finalize_token, finalize_token)
      |> Map.put(:exit_finalize_timer_ref, timer_ref)

    %{state | running: Map.put(state.running, issue_id, updated_running_entry)}
  end

  defp schedule_running_entry_finalization(%State{} = state, _issue_id, _running_entry, _reason),
    do: state

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_recovered_turn_context(previous_retry, metadata) do
    metadata[:recovered_turn_context] || Map.get(previous_retry, :recovered_turn_context)
  end

  defp pick_retry_review_subagent_call_ids(previous_retry, metadata) do
    (metadata[:review_subagent_call_ids] || Map.get(previous_retry, :review_subagent_call_ids))
    |> normalize_review_subagent_call_ids()
  end

  defp pick_retry_review_subagent_ids(previous_retry, metadata) do
    (metadata[:review_subagent_ids] || Map.get(previous_retry, :review_subagent_ids))
    |> normalize_review_subagent_ids()
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp retry_run_opts(metadata) when is_map(metadata) do
    []
    |> maybe_put_retry_run_opt(:recovered_turn_context, metadata[:recovered_turn_context])
    |> maybe_put_retry_run_opt(
      :recovered_review_subagent_call_ids,
      metadata[:review_subagent_call_ids]
    )
    |> maybe_put_retry_run_opt(:recovered_review_subagent_ids, metadata[:review_subagent_ids])
  end

  defp maybe_put_retry_run_opt(run_opts, _key, nil) when is_list(run_opts), do: run_opts

  defp maybe_put_retry_run_opt(run_opts, key, value) when is_list(run_opts) do
    Keyword.put(run_opts, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp select_worker_host_for_issue(%Issue{state: state_name}, %State{} = state, preferred_worker_host)
       when is_binary(state_name) do
    if Dialog.state?(state_name) do
      nil
    else
      select_worker_host(state, preferred_worker_host)
    end
  end

  defp select_worker_host_for_issue(_issue, %State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(issue, %State{} = state, preferred_worker_host) do
    select_worker_host_for_issue(issue, state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if GenServer.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if GenServer.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          recent_codex_events: Map.get(metadata, :recent_codex_events, []),
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       last_activity_at_ms: state.last_activity_at_ms,
       idle_shutdown_ms: state.idle_shutdown_ms,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    existing_session_id = Map.get(running_entry, :session_id)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)
    previous_review_subagent_call_ids = tracked_review_subagent_call_ids(running_entry)
    previous_review_subagent_ids = tracked_review_subagent_ids(running_entry)
    review_completion = extract_review_subagent_completion_text(running_entry, update)
    recovered_turn_context = review_completion || Map.get(running_entry, :recovered_turn_context)

    recovered_review_subagent_call_ids = recovered_review_subagent_call_ids_for_update(running_entry, review_completion)

    recovered_review_subagent_ids = recovered_review_subagent_ids_for_update(running_entry, review_completion)

    review_subagent_call_ids = review_subagent_call_ids_for_update(running_entry, existing_session_id, update)

    review_subagent_ids =
      review_subagent_ids_for_update(
        running_entry,
        existing_session_id,
        update,
        review_subagent_call_ids
      )

    maybe_log_review_completion_capture(
      running_entry,
      update,
      review_completion,
      review_subagent_call_ids,
      review_subagent_ids
    )

    maybe_log_review_subagent_tracking_update(
      running_entry,
      update,
      previous_review_subagent_call_ids,
      previous_review_subagent_ids,
      review_subagent_call_ids,
      review_subagent_ids
    )

    session_id = session_id_for_update(existing_session_id, update)
    next_event_sequence = Map.get(running_entry, :codex_event_sequence, 0) + 1
    summarized_update = summarize_codex_update(update, session_id, next_event_sequence)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarized_update,
        codex_event_sequence: next_event_sequence,
        recent_codex_events:
          update_recent_codex_events(
            Map.get(running_entry, :recent_codex_events, []),
            summarized_update
          ),
        session_id: session_id,
        last_codex_event: event,
        last_tool_call: last_tool_call_for_update(Map.get(running_entry, :last_tool_call), update),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, existing_session_id, update),
        recovered_review_subagent_call_ids: recovered_review_subagent_call_ids,
        recovered_review_subagent_ids: recovered_review_subagent_ids,
        review_subagent_call_ids: review_subagent_call_ids,
        review_subagent_ids: review_subagent_ids,
        recovered_turn_context: recovered_turn_context
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update, session_id, sequence) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      sequence: sequence,
      session_id: session_id,
      timestamp: update[:timestamp]
    }
    |> put_present(:codex_method, update[:codex_method])
    |> put_present(:item_type, update[:item_type])
    |> put_present(:tool_name, update[:tool_name])
    |> put_present(:call_id, update[:call_id])
    |> put_present(:jsonrpc_id, update[:jsonrpc_id])
    |> put_present(:tool_success, update[:tool_success])
  end

  defp last_tool_call_for_update(_existing, %{event: event} = update)
       when event in [
              :tool_call_started,
              :tool_call_completed,
              :tool_call_failed,
              :unsupported_tool_call
            ] do
    %{
      event: event,
      timestamp: update[:timestamp],
      session_id: update[:session_id]
    }
    |> put_present(:tool_name, update[:tool_name])
    |> put_present(:call_id, update[:call_id])
    |> put_present(:item_type, update[:item_type])
    |> put_present(:tool_success, update[:tool_success])
  end

  defp last_tool_call_for_update(existing, _update), do: existing

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp update_recent_codex_events(events, event) when is_list(events) and is_map(event) do
    events
    |> Kernel.++([event])
    |> Enum.take(-@codex_recent_events_limit)
  end

  defp update_recent_codex_events(_events, event) when is_map(event), do: [event]

  defp review_subagent_call_ids_for_update(running_entry, existing_session_id, update)
       when is_map(running_entry) and is_map(update) do
    running_entry
    |> review_subagent_call_ids_base(existing_session_id, update)
    |> MapSet.union(extract_review_subagent_call_ids(running_entry, update))
  end

  defp review_subagent_ids_for_update(
         running_entry,
         existing_session_id,
         update,
         review_subagent_call_ids
       )
       when is_map(running_entry) and is_map(update) do
    running_entry
    |> review_subagent_ids_base(existing_session_id, update)
    |> MapSet.union(extract_review_subagent_ids(update, review_subagent_call_ids))
  end

  defp recoverable_turn_context(running_entry, _reason) when is_map(running_entry) do
    Map.get(running_entry, :recovered_turn_context)
  end

  defp review_subagent_call_ids_for_retry(running_entry) when is_map(running_entry) do
    if is_binary(Map.get(running_entry, :recovered_turn_context)) do
      MapSet.new()
    else
      tracked_review_subagent_call_ids(running_entry)
    end
  end

  defp review_subagent_ids_for_retry(running_entry) when is_map(running_entry) do
    if is_binary(Map.get(running_entry, :recovered_turn_context)) do
      MapSet.new()
    else
      tracked_review_subagent_ids(running_entry)
    end
  end

  defp recovered_review_subagent_call_ids_for_update(running_entry, review_completion)
       when is_map(running_entry) do
    if is_binary(review_completion) do
      MapSet.new()
    else
      running_entry
      |> Map.get(:recovered_review_subagent_call_ids, MapSet.new())
      |> normalize_review_subagent_call_ids()
    end
  end

  defp recovered_review_subagent_ids_for_update(running_entry, review_completion)
       when is_map(running_entry) do
    if is_binary(review_completion) do
      MapSet.new()
    else
      running_entry
      |> Map.get(:recovered_review_subagent_ids, MapSet.new())
      |> normalize_review_subagent_ids()
    end
  end

  defp tracked_review_subagent_call_ids(running_entry) when is_map(running_entry) do
    running_entry
    |> Map.get(:recovered_review_subagent_call_ids, MapSet.new())
    |> normalize_review_subagent_call_ids()
    |> MapSet.union(
      running_entry
      |> Map.get(:review_subagent_call_ids, MapSet.new())
      |> normalize_review_subagent_call_ids()
    )
  end

  defp tracked_review_subagent_ids(running_entry) when is_map(running_entry) do
    running_entry
    |> Map.get(:recovered_review_subagent_ids, MapSet.new())
    |> normalize_review_subagent_ids()
    |> MapSet.union(
      running_entry
      |> Map.get(:review_subagent_ids, MapSet.new())
      |> normalize_review_subagent_ids()
    )
  end

  defp review_subagent_call_ids_base(running_entry, existing_session_id, update)
       when is_map(running_entry) and is_map(update) do
    if reset_review_subagent_tracking?(existing_session_id, update) do
      MapSet.new()
    else
      running_entry
      |> Map.get(:review_subagent_call_ids, MapSet.new())
      |> normalize_review_subagent_call_ids()
    end
  end

  defp review_subagent_ids_base(running_entry, existing_session_id, update)
       when is_map(running_entry) and is_map(update) do
    if reset_review_subagent_tracking?(existing_session_id, update) do
      MapSet.new()
    else
      running_entry
      |> Map.get(:review_subagent_ids, MapSet.new())
      |> normalize_review_subagent_ids()
    end
  end

  defp reset_review_subagent_tracking?(existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_binary(session_id) do
    session_id != existing_session_id
  end

  defp reset_review_subagent_tracking?(_existing_session_id, _update), do: false

  defp extract_review_subagent_completion_text(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    if review_codex_state_for_running_entry?(running_entry) do
      extract_subagent_completion_text(running_entry, update)
    end
  end

  defp extract_subagent_completion_text(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    extract_subagent_completion_from_tagged_notification_candidates(running_entry, update) ||
      extract_subagent_completion_from_wait_agent_update(running_entry, update)
  end

  defp extract_review_subagent_call_ids(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw")
    ]
    |> Enum.reduce(MapSet.new(), fn value, ids ->
      Enum.reduce(extract_review_subagent_call_ids_from_event(running_entry, value), ids, fn id, acc ->
        MapSet.put(acc, id)
      end)
    end)
  end

  defp extract_review_subagent_call_ids_from_event(running_entry, value)
       when is_map(running_entry) and is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_review_subagent_call_ids_from_event(running_entry, decoded)
      _ -> []
    end
  end

  defp extract_review_subagent_call_ids_from_event(running_entry, %{
         "method" => "item/tool/call",
         "params" => params
       })
       when is_map(running_entry) do
    extract_review_subagent_call_ids_from_tool_call_params(running_entry, params)
  end

  defp extract_review_subagent_call_ids_from_event(running_entry, %{method: "item/tool/call", params: params})
       when is_map(running_entry) do
    extract_review_subagent_call_ids_from_tool_call_params(running_entry, params)
  end

  defp extract_review_subagent_call_ids_from_event(
         running_entry,
         %{"method" => method, "params" => %{"item" => item}}
       )
       when is_map(running_entry) and method in ["item/started", "item/completed"] do
    extract_review_subagent_call_ids_from_item(running_entry, item)
  end

  defp extract_review_subagent_call_ids_from_event(
         running_entry,
         %{method: method, params: %{item: item}}
       )
       when is_map(running_entry) and method in ["item/started", "item/completed"] do
    extract_review_subagent_call_ids_from_item(running_entry, item)
  end

  defp extract_review_subagent_call_ids_from_event(_running_entry, _value), do: []

  defp extract_review_subagent_call_ids_from_tool_call_params(running_entry, params)
       when is_map(running_entry) and is_map(params) do
    tool_name = tool_call_tool_name(params)
    call_id = tool_call_call_id(params)
    arguments = tool_call_arguments(params)

    reviewed_spawn_agent_call_id(running_entry, tool_name, call_id, arguments)
  end

  defp extract_review_subagent_call_ids_from_tool_call_params(_running_entry, _params), do: []

  defp extract_review_subagent_call_ids_from_item(running_entry, item)
       when is_map(running_entry) and is_map(item) do
    if collab_spawn_agent_item?(item) and
         track_review_subagent_spawn_call?(running_entry, collab_spawn_agent_arguments(item)) do
      candidate_review_subagent_call_ids_from_item(item)
    else
      []
    end
  end

  defp extract_review_subagent_call_ids_from_item(_running_entry, _item), do: []

  defp reviewed_spawn_agent_call_id(running_entry, tool_name, call_id, arguments)
       when is_map(running_entry) and is_binary(call_id) do
    if spawn_agent_tool_name?(tool_name) and valid_review_subagent_call_id?(call_id) and
         track_review_subagent_spawn_call?(running_entry, arguments) do
      [String.trim(call_id)]
    else
      []
    end
  end

  defp reviewed_spawn_agent_call_id(_running_entry, _tool_name, _call_id, _arguments), do: []

  defp tool_call_tool_name(params) when is_map(params) do
    Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") ||
      Map.get(params, :name)
  end

  defp tool_call_call_id(params) when is_map(params) do
    Map.get(params, "callId") || Map.get(params, :callId)
  end

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments)
  end

  defp track_review_subagent_spawn_call?(running_entry, arguments) when is_map(running_entry) do
    review_ai_issue_state_for_running_entry?(running_entry) or review_subagent_request?(arguments)
  end

  defp extract_review_subagent_ids(update, review_subagent_call_ids) when is_map(update) do
    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw"),
      synthetic_tool_call_output_event(update)
    ]
    |> Enum.reduce(MapSet.new(), fn value, ids ->
      Enum.reduce(extract_review_subagent_ids_from_event(value, review_subagent_call_ids), ids, fn
        id, acc ->
          MapSet.put(acc, id)
      end)
    end)
  end

  defp extract_review_subagent_ids_from_event(value, review_subagent_call_ids) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_review_subagent_ids_from_event(decoded, review_subagent_call_ids)
      _ -> []
    end
  end

  defp extract_review_subagent_ids_from_event(
         %{"method" => "item/completed", "params" => %{"item" => item}},
         review_subagent_call_ids
       ) do
    extract_review_subagent_ids_from_item(item, review_subagent_call_ids)
  end

  defp extract_review_subagent_ids_from_event(
         %{method: "item/completed", params: %{item: item}},
         review_subagent_call_ids
       ) do
    extract_review_subagent_ids_from_item(item, review_subagent_call_ids)
  end

  defp extract_review_subagent_ids_from_event(_value, _review_subagent_call_ids), do: []

  defp extract_review_subagent_ids_from_item(item, review_subagent_call_ids) when is_map(item) do
    cond do
      function_call_spawn_output_item?(item) and
          trusted_review_subagent_spawn_output?(item, review_subagent_call_ids) ->
        item
        |> Map.get("output", Map.get(item, :output))
        |> extract_review_subagent_ids_from_spawn_output()

      collab_spawn_agent_item?(item) and trusted_review_subagent_spawn_output?(item, review_subagent_call_ids) ->
        extract_review_subagent_ids_from_collab_spawn_item(item)

      true ->
        []
    end
  end

  defp extract_review_subagent_ids_from_item(_item, _review_subagent_call_ids), do: []

  defp extract_review_subagent_ids_from_collab_spawn_item(item) when is_map(item) do
    receiver_thread_ids =
      item
      |> Map.get("receiverThreadIds", Map.get(item, :receiverThreadIds, []))
      |> List.wrap()

    agent_state_ids =
      item
      |> Map.get("agentsStates", Map.get(item, :agentsStates))
      |> case do
        %{} = states -> Map.keys(states)
        _ -> []
      end

    (receiver_thread_ids ++ agent_state_ids)
    |> Enum.filter(&valid_review_subagent_id?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp extract_review_subagent_ids_from_spawn_output(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> extract_review_subagent_ids_from_spawn_output(decoded)
      _ -> []
    end
  end

  defp extract_review_subagent_ids_from_spawn_output(value) when is_map(value) do
    value
    |> candidate_review_subagent_id()
    |> case do
      id when is_binary(id) -> [id]
      _ -> []
    end
  end

  defp candidate_review_subagent_id(value) when is_map(value) do
    [
      Map.get(value, "id"),
      Map.get(value, :id),
      Map.get(value, "agent_id"),
      Map.get(value, :agent_id),
      Map.get(value, "agent_path"),
      Map.get(value, :agent_path)
    ]
    |> Enum.find(&valid_review_subagent_id?/1)
  end

  defp valid_review_subagent_id?(value) when is_binary(value) do
    trimmed = String.trim(value)

    trimmed != "" and
      (String.contains?(trimmed, ["-", "_", "/"]) or String.match?(trimmed, ~r/\d/u))
  end

  defp valid_review_subagent_id?(_value), do: false

  defp valid_review_subagent_call_id?(value) when is_binary(value), do: String.trim(value) != ""
  defp valid_review_subagent_call_id?(_value), do: false

  defp normalize_review_subagent_call_ids(value) when is_struct(value, MapSet), do: value

  defp normalize_review_subagent_call_ids(value) when is_list(value) do
    value
    |> Enum.filter(&valid_review_subagent_call_id?/1)
    |> Enum.map(&String.trim/1)
    |> MapSet.new()
  end

  defp normalize_review_subagent_call_ids(_value), do: MapSet.new()

  defp normalize_review_subagent_ids(value) when is_struct(value, MapSet), do: value

  defp normalize_review_subagent_ids(value) when is_list(value) do
    value
    |> Enum.filter(&valid_review_subagent_id?/1)
    |> Enum.map(&String.trim/1)
    |> MapSet.new()
  end

  defp normalize_review_subagent_ids(_value), do: MapSet.new()

  defp review_subagent_request?(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> review_subagent_request?(decoded)
      _ -> false
    end
  end

  defp review_subagent_request?(value) when is_map(value) do
    fork_context = Map.get(value, "fork_context", Map.get(value, :fork_context))
    agent_type = Map.get(value, "agent_type") || Map.get(value, :agent_type)
    review_text = review_subagent_request_text(value)
    normalized_text = String.downcase(review_text)

    fork_context == false and
      review_subagent_agent_type?(agent_type) and
      review_subagent_request_shape?(normalized_text)
  end

  defp review_subagent_request?(_value), do: false

  defp review_subagent_agent_type?(nil), do: true
  defp review_subagent_agent_type?(""), do: true
  defp review_subagent_agent_type?(:default), do: true
  defp review_subagent_agent_type?("default"), do: true
  defp review_subagent_agent_type?(:explorer), do: true
  defp review_subagent_agent_type?("explorer"), do: true
  defp review_subagent_agent_type?(_value), do: false

  defp review_subagent_request_shape?(normalized_text) when is_binary(normalized_text) do
    review_subagent_request_review_scope?(normalized_text) and
      review_subagent_request_read_only?(normalized_text) and
      review_subagent_request_expected_output?(normalized_text)
  end

  defp review_subagent_request_review_scope?(normalized_text) when is_binary(normalized_text) do
    String.contains?(normalized_text, "review") and
      String.contains?(normalized_text, "origin/main") and
      review_subagent_request_scope_target?(normalized_text)
  end

  defp review_subagent_request_read_only?(normalized_text) when is_binary(normalized_text) do
    String.contains?(normalized_text, "read-only") or
      String.contains?(normalized_text, "read only")
  end

  defp review_subagent_request_expected_output?(normalized_text) when is_binary(normalized_text) do
    String.contains?(normalized_text, "findings") and
      review_subagent_request_zero_findings_clause?(normalized_text)
  end

  defp review_subagent_request_scope_target?(normalized_text) when is_binary(normalized_text) do
    Enum.any?(
      [
        "worktree",
        "repository",
        "repo",
        "diff",
        "changed files",
        "scoped files"
      ],
      &String.contains?(normalized_text, &1)
    )
  end

  defp review_subagent_request_zero_findings_clause?(normalized_text) when is_binary(normalized_text) do
    String.contains?(normalized_text, "keine findings") or
      String.contains?(normalized_text, "no findings") or
      String.contains?(normalized_text, "nichts findest") or
      String.contains?(normalized_text, "if you find nothing") or
      String.contains?(normalized_text, "if you have no findings") or
      String.contains?(normalized_text, "if there are no findings")
  end

  defp review_subagent_request_text(value) when is_map(value) do
    [Map.get(value, "message") || Map.get(value, :message) | review_subagent_request_item_texts(value)]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  defp review_subagent_request_item_texts(value) when is_map(value) do
    value
    |> Map.get("items", Map.get(value, :items, []))
    |> List.wrap()
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{type: "text", text: text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp trusted_review_subagent_spawn_output?(item, review_subagent_call_ids)
       when is_map(item) and is_struct(review_subagent_call_ids, MapSet) do
    MapSet.size(review_subagent_call_ids) > 0 and
      Enum.any?(candidate_review_subagent_call_ids_from_item(item), fn call_id ->
        MapSet.member?(review_subagent_call_ids, call_id)
      end)
  end

  defp trusted_review_subagent_spawn_output?(_item, _review_subagent_call_ids), do: false

  defp function_call_spawn_output_item?(item) when is_map(item) do
    item_type(item) == "function_call_output" and spawn_agent_tool_name?(item_tool_name(item))
  end

  defp collab_spawn_agent_item?(item) when is_map(item) do
    item_type(item) == "collabAgentToolCall" and spawn_agent_tool_name?(item_tool_name(item))
  end

  defp collab_wait_agent_item?(item) when is_map(item) do
    item_type(item) == "collabAgentToolCall" and wait_agent_tool_name?(item_tool_name(item))
  end

  defp item_type(item) when is_map(item), do: Map.get(item, "type") || Map.get(item, :type)
  defp item_type(_item), do: nil

  defp item_tool_name(item) when is_map(item) do
    Map.get(item, "tool") || Map.get(item, :tool) || Map.get(item, "name") || Map.get(item, :name)
  end

  defp item_tool_name(_item), do: nil

  defp collab_spawn_agent_arguments(item) when is_map(item) do
    %{
      "message" => Map.get(item, "prompt") || Map.get(item, :prompt),
      "agent_type" => nil,
      "fork_context" => false
    }
  end

  defp candidate_review_subagent_call_ids_from_item(item) when is_map(item) do
    [
      Map.get(item, "id"),
      Map.get(item, :id),
      Map.get(item, "callId"),
      Map.get(item, :callId),
      Map.get(item, "call_id"),
      Map.get(item, :call_id)
    ]
    |> Enum.filter(&valid_review_subagent_call_id?/1)
    |> Enum.map(&String.trim/1)
  end

  defp synthetic_tool_call_output_event(update) when is_map(update) do
    with %{} = payload <- tool_call_payload(update),
         "item/tool/call" <- tool_call_method(payload),
         %{} = params <- tool_call_params(payload),
         tool_name when is_binary(tool_name) <- tool_call_name_from_params(params),
         call_id when is_binary(call_id) <- tool_call_id_from_params(params),
         true <- valid_review_subagent_call_id?(call_id),
         output when is_binary(output) <- tool_call_result_output(update) do
      build_tool_call_output_event(String.trim(call_id), tool_name, output)
    else
      _ -> nil
    end
  end

  defp tool_call_payload(update) when is_map(update) do
    Map.get(update, :payload) || Map.get(update, "payload")
  end

  defp tool_call_method(payload) when is_map(payload) do
    Map.get(payload, "method") || Map.get(payload, :method)
  end

  defp tool_call_params(payload) when is_map(payload) do
    Map.get(payload, "params") || Map.get(payload, :params)
  end

  defp tool_call_name_from_params(params) when is_map(params) do
    Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") ||
      Map.get(params, :name)
  end

  defp tool_call_id_from_params(params) when is_map(params) do
    Map.get(params, "callId") || Map.get(params, :callId)
  end

  defp tool_call_result_output(update) when is_map(update) do
    update
    |> Map.get(:tool_result, Map.get(update, "tool_result"))
    |> case do
      %{} = tool_result -> Map.get(tool_result, "output") || Map.get(tool_result, :output)
      _ -> nil
    end
  end

  defp build_tool_call_output_event(call_id, tool_name, output)
       when is_binary(call_id) and is_binary(tool_name) and is_binary(output) do
    %{
      "method" => "item/completed",
      "params" => %{
        "item" => %{
          "id" => call_id,
          "callId" => call_id,
          "type" => "function_call_output",
          "tool" => tool_name,
          "name" => tool_name,
          "output" => output
        }
      }
    }
  end

  defp extract_subagent_completion_from_tagged_notification_candidates(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    review_subagent_ids = tracked_review_subagent_ids(running_entry)
    review_subagent_call_ids = tracked_review_subagent_call_ids(running_entry)

    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw")
    ]
    |> Enum.find_value(
      &extract_subagent_completion_from_tagged_notification_event(
        &1,
        review_subagent_ids,
        review_subagent_call_ids
      )
    )
  end

  defp extract_subagent_completion_from_tagged_notification_candidates(_running_entry, _update),
    do: nil

  defp extract_subagent_completion_from_tagged_notification_event(
         value,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        extract_subagent_completion_from_tagged_notification_event(
          decoded,
          review_subagent_ids,
          review_subagent_call_ids
        )

      _ ->
        nil
    end
  end

  defp extract_subagent_completion_from_tagged_notification_event(
         %{
           "method" => "codex/event/user_message",
           "params" => %{"msg" => msg}
         },
         review_subagent_ids,
         review_subagent_call_ids
       ) do
    extract_subagent_completion_from_user_message(
      msg,
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp extract_subagent_completion_from_tagged_notification_event(
         %{
           method: "codex/event/user_message",
           params: %{msg: msg}
         },
         review_subagent_ids,
         review_subagent_call_ids
       ) do
    extract_subagent_completion_from_user_message(
      msg,
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp extract_subagent_completion_from_tagged_notification_event(
         _value,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_user_message(
         msg,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(msg) do
    with content when is_list(content) <- user_message_content(msg),
         tagged_text when is_binary(tagged_text) <- find_tagged_subagent_notification_text(content),
         {:ok, payload} <- decode_tagged_payload(tagged_text, "subagent_notification"),
         completion when is_binary(completion) <-
           valid_subagent_completion_from_payload(
             payload,
             review_subagent_ids,
             review_subagent_call_ids
           ),
         trimmed when trimmed != "" <- String.trim(completion) do
      trimmed
    else
      _ -> nil
    end
  end

  defp extract_subagent_completion_from_user_message(
         _msg,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_wait_agent_update(running_entry, update)
       when is_map(running_entry) and is_map(update) do
    review_subagent_ids = tracked_review_subagent_ids(running_entry)
    review_subagent_call_ids = tracked_review_subagent_call_ids(running_entry)

    [
      Map.get(update, :payload),
      Map.get(update, "payload"),
      Map.get(update, :raw),
      Map.get(update, "raw"),
      synthetic_tool_call_output_event(update)
    ]
    |> Enum.find_value(
      &extract_subagent_completion_from_wait_agent_event(
        &1,
        review_subagent_ids,
        review_subagent_call_ids
      )
    )
  end

  defp extract_subagent_completion_from_wait_agent_update(_running_entry, _update), do: nil

  defp extract_subagent_completion_from_wait_agent_event(
         value,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        extract_subagent_completion_from_wait_agent_event(
          decoded,
          review_subagent_ids,
          review_subagent_call_ids
        )

      _ ->
        nil
    end
  end

  defp extract_subagent_completion_from_wait_agent_event(
         %{"method" => "item/completed", "params" => %{"item" => item}},
         review_subagent_ids,
         review_subagent_call_ids
       ) do
    extract_subagent_completion_from_wait_agent_item(
      item,
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp extract_subagent_completion_from_wait_agent_event(
         %{method: "item/completed", params: %{item: item}},
         review_subagent_ids,
         review_subagent_call_ids
       ) do
    extract_subagent_completion_from_wait_agent_item(
      item,
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp extract_subagent_completion_from_wait_agent_event(
         _value,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_wait_agent_item(
         item,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(item) do
    cond do
      item_type(item) == "function_call_output" and wait_agent_tool_name?(item_tool_name(item)) ->
        item
        |> Map.get("output", Map.get(item, :output))
        |> extract_subagent_completion_from_wait_agent_result(
          review_subagent_ids,
          review_subagent_call_ids
        )

      collab_wait_agent_item?(item) ->
        extract_subagent_completion_from_collab_wait_item(
          item,
          review_subagent_ids,
          review_subagent_call_ids
        )

      true ->
        nil
    end
  end

  defp extract_subagent_completion_from_wait_agent_item(
         _item,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_collab_wait_item(
         item,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(item) do
    item
    |> collab_wait_agent_status()
    |> extract_subagent_completion_from_wait_agent_status(
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp collab_wait_agent_status(item) when is_map(item) do
    item
    |> Map.get("agentsStates", Map.get(item, :agentsStates))
    |> case do
      %{} = agents_states ->
        Enum.reduce(agents_states, %{}, &put_collab_wait_agent_completion/2)

      _ ->
        %{}
    end
  end

  defp put_collab_wait_agent_completion({agent_id, entry}, acc) when is_map(acc) do
    case collab_wait_agent_completion_entry(agent_id, entry) do
      {normalized_agent_id, completion} ->
        Map.put(acc, normalized_agent_id, %{"completed" => completion})

      nil ->
        acc
    end
  end

  defp put_collab_wait_agent_completion(_entry, acc), do: acc

  defp collab_wait_agent_completion_entry(agent_id, entry)
       when is_binary(agent_id) and is_map(entry) do
    with true <- valid_review_subagent_id?(agent_id),
         completion when is_binary(completion) <- collab_wait_agent_completion_text(entry),
         trimmed_completion when is_binary(trimmed_completion) <- trimmed_non_empty_binary(completion) do
      {String.trim(agent_id), trimmed_completion}
    else
      _ -> nil
    end
  end

  defp collab_wait_agent_completion_entry(_agent_id, _entry), do: nil

  defp collab_wait_agent_completion_text(%{"status" => "completed", "message" => message})
       when is_binary(message),
       do: message

  defp collab_wait_agent_completion_text(%{status: "completed", message: message})
       when is_binary(message),
       do: message

  defp collab_wait_agent_completion_text(%{"completed" => completion})
       when is_binary(completion),
       do: completion

  defp collab_wait_agent_completion_text(%{completed: completion})
       when is_binary(completion),
       do: completion

  defp collab_wait_agent_completion_text(%{"status" => %{"completed" => completion}})
       when is_binary(completion),
       do: completion

  defp collab_wait_agent_completion_text(%{status: %{completed: completion}})
       when is_binary(completion),
       do: completion

  defp collab_wait_agent_completion_text(_entry), do: nil

  defp extract_subagent_completion_from_wait_agent_result(
         value,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} ->
        extract_subagent_completion_from_wait_agent_result(
          decoded,
          review_subagent_ids,
          review_subagent_call_ids
        )

      _ ->
        nil
    end
  end

  defp extract_subagent_completion_from_wait_agent_result(
         %{"timed_out" => true},
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_wait_agent_result(
         %{timed_out: true},
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_wait_agent_result(
         %{"status" => status},
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(status) do
    extract_subagent_completion_from_wait_agent_status(
      status,
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp extract_subagent_completion_from_wait_agent_result(
         %{status: status},
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(status) do
    extract_subagent_completion_from_wait_agent_status(
      status,
      review_subagent_ids,
      review_subagent_call_ids
    )
  end

  defp extract_subagent_completion_from_wait_agent_result(
         _value,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_wait_agent_status(
         status,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(status) and is_struct(review_subagent_ids, MapSet) and
              is_struct(review_subagent_call_ids, MapSet) do
    Enum.find_value(status, fn
      {agent_id, entry} ->
        extract_subagent_completion_from_wait_agent_status_entry(
          agent_id,
          entry,
          review_subagent_ids
        )

      _ ->
        nil
    end) ||
      unverified_review_subagent_completion_from_wait_agent_status(
        status,
        review_subagent_ids,
        review_subagent_call_ids
      )
  end

  defp extract_subagent_completion_from_wait_agent_status(
         _status,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp extract_subagent_completion_from_wait_agent_status_entry(
         agent_id,
         %{"completed" => completion},
         review_subagent_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) do
      valid_recovered_review_completion(completion)
    end
  end

  defp extract_subagent_completion_from_wait_agent_status_entry(
         agent_id,
         %{completed: completion},
         review_subagent_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) do
      valid_recovered_review_completion(completion)
    end
  end

  defp extract_subagent_completion_from_wait_agent_status_entry(
         _agent_id,
         _entry,
         _review_subagent_ids
       ),
       do: nil

  defp review_subagent_id_matches?(review_subagent_ids, agent_id)
       when is_struct(review_subagent_ids, MapSet) and is_binary(agent_id) do
    MapSet.size(review_subagent_ids) > 0 and MapSet.member?(review_subagent_ids, agent_id)
  end

  defp review_subagent_id_matches?(_review_subagent_ids, _agent_id), do: false

  defp unverified_review_subagent_completion_from_wait_agent_status(
         status,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(status) and is_struct(review_subagent_ids, MapSet) and
              is_struct(review_subagent_call_ids, MapSet) do
    if trusted_unverified_review_wait_agent_status?(
         status,
         review_subagent_ids,
         review_subagent_call_ids
       ) do
      status
      |> Enum.reduce([], &collect_unverified_review_wait_agent_completion/2)
      |> Enum.uniq()
      |> one_unverified_review_wait_agent_completion()
    end
  end

  defp unverified_review_subagent_completion_from_wait_agent_status(
         _status,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp trusted_unverified_review_wait_agent_status?(
         status,
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_map(status) and is_struct(review_subagent_ids, MapSet) and
              is_struct(review_subagent_call_ids, MapSet) do
    map_size(status) == 1 and MapSet.size(review_subagent_ids) == 0 and
      MapSet.size(review_subagent_call_ids) > 0
  end

  defp collect_unverified_review_wait_agent_completion(entry, acc) do
    case unverified_review_wait_agent_completion_candidate(entry) do
      nil -> acc
      candidate -> [candidate | acc]
    end
  end

  defp unverified_review_wait_agent_completion_candidate({agent_id, %{"completed" => completion}})
       when is_binary(agent_id) and is_binary(completion) do
    normalized_unverified_review_wait_agent_completion(agent_id, completion)
  end

  defp unverified_review_wait_agent_completion_candidate({agent_id, %{completed: completion}})
       when is_binary(agent_id) and is_binary(completion) do
    normalized_unverified_review_wait_agent_completion(agent_id, completion)
  end

  defp unverified_review_wait_agent_completion_candidate(_entry), do: nil

  defp normalized_unverified_review_wait_agent_completion(agent_id, completion)
       when is_binary(agent_id) and is_binary(completion) do
    case valid_recovered_review_completion(completion) do
      normalized when is_binary(normalized) -> {String.trim(agent_id), normalized}
      _ -> nil
    end
  end

  defp one_unverified_review_wait_agent_completion([{_agent_id, completion}]), do: completion
  defp one_unverified_review_wait_agent_completion(_candidates), do: nil

  defp valid_recovered_review_completion(value) when is_binary(value) do
    PromptBuilder.normalize_recovered_review_context(value) || trimmed_non_empty_binary(value)
  end

  defp trimmed_non_empty_binary(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp review_codex_state_for_running_entry?(%{issue: %{state: state_name}})
       when is_binary(state_name) do
    normalize_issue_state(state_name) == "review (ai)"
  end

  defp review_codex_state_for_running_entry?(running_entry) when is_map(running_entry) do
    MapSet.size(tracked_review_subagent_call_ids(running_entry)) > 0 or
      MapSet.size(tracked_review_subagent_ids(running_entry)) > 0 or
      is_binary(Map.get(running_entry, :recovered_turn_context))
  end

  defp review_ai_issue_state_for_running_entry?(%{issue: %{state: state_name}})
       when is_binary(state_name) do
    normalize_issue_state(state_name) == "review (ai)"
  end

  defp review_ai_issue_state_for_running_entry?(_running_entry), do: false

  defp spawn_agent_tool_name?(tool_name), do: normalize_subagent_tool_name(tool_name) == "spawn_agent"

  defp wait_agent_tool_name?(tool_name) do
    normalize_tool = normalize_subagent_tool_name(tool_name)
    normalize_tool == "wait_agent" or normalize_tool == "wait"
  end

  defp normalize_subagent_tool_name(tool_name) when is_binary(tool_name) do
    tool_name
    |> String.trim()
    |> String.replace("-", "_")
    |> Macro.underscore()
  end

  defp normalize_subagent_tool_name(_tool_name), do: nil

  defp maybe_log_review_completion_capture(
         %{issue: %Issue{} = issue} = running_entry,
         update,
         review_completion,
         review_subagent_call_ids,
         review_subagent_ids
       )
       when is_binary(review_completion) and is_map(update) and
              is_struct(review_subagent_call_ids, MapSet) and
              is_struct(review_subagent_ids, MapSet) do
    Logger.info(
      "Captured review subagent completion: #{issue_context(issue)} session_id=#{running_entry_session_id(running_entry)} event=#{inspect(update[:event])}#{review_update_source_suffix(update)} recovered_kind=#{review_recovered_context_kind(review_completion)} review_subagent_call_ids=#{MapSet.size(review_subagent_call_ids)} review_subagent_ids=#{MapSet.size(review_subagent_ids)}"
    )
  end

  defp maybe_log_review_completion_capture(
         _running_entry,
         _update,
         _review_completion,
         _review_subagent_call_ids,
         _review_subagent_ids
       ),
       do: :ok

  defp maybe_log_review_subagent_tracking_update(
         %{issue: %Issue{} = issue} = running_entry,
         update,
         previous_review_subagent_call_ids,
         previous_review_subagent_ids,
         review_subagent_call_ids,
         review_subagent_ids
       )
       when is_map(update) and is_struct(previous_review_subagent_call_ids, MapSet) and
              is_struct(previous_review_subagent_ids, MapSet) and
              is_struct(review_subagent_call_ids, MapSet) and
              is_struct(review_subagent_ids, MapSet) do
    added_review_subagent_call_ids =
      MapSet.difference(review_subagent_call_ids, previous_review_subagent_call_ids)

    added_review_subagent_ids =
      MapSet.difference(review_subagent_ids, previous_review_subagent_ids)

    if MapSet.size(added_review_subagent_call_ids) > 0 or MapSet.size(added_review_subagent_ids) > 0 do
      Logger.info(
        "Tracked review subagent handoff: #{issue_context(issue)} session_id=#{running_entry_session_id(running_entry)} event=#{inspect(update[:event])}#{review_update_source_suffix(update)} added_review_subagent_call_ids=#{format_review_subagent_log_values(added_review_subagent_call_ids)} added_review_subagent_ids=#{format_review_subagent_log_values(added_review_subagent_ids)} review_subagent_call_ids=#{MapSet.size(review_subagent_call_ids)} review_subagent_ids=#{MapSet.size(review_subagent_ids)}"
      )
    end
  end

  defp maybe_log_review_subagent_tracking_update(
         _running_entry,
         _update,
         _previous_review_subagent_call_ids,
         _previous_review_subagent_ids,
         _review_subagent_call_ids,
         _review_subagent_ids
       ),
       do: :ok

  defp log_review_retry_context(%{issue: %Issue{} = issue} = running_entry, session_id)
       when is_binary(session_id) do
    review_subagent_call_ids = review_subagent_call_ids_for_retry(running_entry)
    review_subagent_ids = review_subagent_ids_for_retry(running_entry)
    recovered_kind = review_recovered_context_kind(Map.get(running_entry, :recovered_turn_context))
    review_subagent_call_id_count = review_subagent_count(review_subagent_call_ids)
    review_subagent_id_count = review_subagent_count(review_subagent_ids)

    if normalize_issue_state(issue.state) == "review (ai)" or recovered_kind != :none or
         review_subagent_call_id_count > 0 or review_subagent_id_count > 0 do
      Logger.info(
        "Review continuation handoff prepared: #{issue_context(issue)} session_id=#{session_id} recovered_kind=#{recovered_kind} review_subagent_call_ids=#{review_subagent_call_id_count} review_subagent_ids=#{review_subagent_id_count}"
      )
    end
  end

  defp log_review_retry_context(_running_entry, _session_id), do: :ok

  defp clean_review_retry_handoff_ready?(%Issue{state: state} = issue, metadata)
       when is_binary(state) and is_map(metadata) do
    normalize_issue_state(state) == "review (ai)" and
      review_recovered_context_kind(metadata[:recovered_turn_context]) == :no_findings and
      review_retry_workpad_no_findings?(issue) and
      review_retry_workspace_clean?(issue, metadata)
  end

  defp clean_review_retry_handoff_ready?(_issue, _metadata), do: false

  defp handle_clean_review_retry_handoff(%State{} = state, issue_id, %Issue{} = issue, attempt, metadata)
       when is_binary(issue_id) and is_integer(attempt) and is_map(metadata) do
    next_state = review_handoff_target_state(issue, metadata)

    case Tracker.update_issue_state(issue.id, next_state) do
      :ok ->
        Logger.info("Completed clean review handoff from recovered subagent result without dispatch: #{issue_context(issue)} next_state=#{next_state}")

        {:noreply, state |> complete_issue(issue_id, issue.state) |> release_issue_claim(issue_id)}

      {:error, reason} ->
        Logger.warning("Failed clean review handoff from recovered subagent result; retrying without dispatch: #{issue_context(issue)} next_state=#{next_state} reason=#{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue.id,
           attempt + 1,
           Map.merge(metadata, %{
             identifier: issue.identifier,
             error: "review handoff state update failed: #{inspect(reason)}"
           })
         )}
    end
  end

  defp review_handoff_target_state(%Issue{} = issue, metadata) when is_map(metadata) do
    if review_retry_workpad_no_findings?(issue) and review_retry_workspace_clean?(issue, metadata) do
      @review_no_findings_handoff_state_name
    else
      @review_handoff_state_name
    end
  end

  defp review_retry_workpad_no_findings?(%Issue{id: issue_id} = issue) when is_binary(issue_id) do
    case Tracker.fetch_issue_comment_bodies(issue_id) do
      {:ok, comments} ->
        comments
        |> Workpad.review_handoff_status()
        |> case do
          {:ready, :no_findings} ->
            true

          status ->
            Logger.info("Recovered review no-findings handoff is not safe because workpad evidence is incomplete: #{issue_context(issue)} workpad_status=#{inspect(status)}")

            false
        end

      {:error, reason} ->
        Logger.warning("Failed to inspect workpad review checklist before recovered no-findings handoff; skipping direct no-findings handoff: #{issue_context(issue)} reason=#{inspect(reason)}")

        false
    end
  end

  defp review_retry_workpad_no_findings?(_issue), do: false

  defp review_retry_workspace_clean?(%Issue{} = issue, metadata) when is_map(metadata) do
    case Map.get(metadata, :workspace_path) do
      workspace when is_binary(workspace) ->
        case Workspace.git_status_snapshot(workspace, Map.get(metadata, :worker_host)) do
          {:ok, ""} ->
            true

          {:ok, _status} ->
            false

          {:error, reason} ->
            Logger.warning("Failed to inspect recovered review workspace status before no-findings handoff; using regular review handoff: #{issue_context(issue)} reason=#{inspect(reason)}")

            false
        end

      _ ->
        Logger.warning("Recovered review no-findings handoff has no workspace path; using regular review handoff: #{issue_context(issue)}")

        false
    end
  end

  defp review_recovered_context_kind(value) when is_binary(value) do
    case PromptBuilder.normalize_recovered_review_context(value) do
      "Keine Findings." <> _ -> :no_findings
      "Findings:" <> _ -> :findings
      _ -> :none
    end
  end

  defp review_recovered_context_kind(_value), do: :none

  defp format_review_subagent_log_values(values) when is_struct(values, MapSet) do
    values
    |> Enum.to_list()
    |> Enum.sort()
    |> Enum.join(",")
    |> case do
      "" -> "none"
      joined -> joined
    end
  end

  defp review_subagent_count(values) when is_struct(values, MapSet), do: Enum.count(values)

  defp review_update_source_suffix(update) when is_map(update) do
    payload = Map.get(update, :payload) || Map.get(update, "payload")
    method = payload_method(payload)
    item = payload_item(payload)
    item_type = item_type(item)
    tool_name = item_tool_name(item)

    source_fields =
      []
      |> append_source_field("source_method", method)
      |> append_source_field("source_item_type", item_type)
      |> append_source_field("source_tool", tool_name)

    case source_fields do
      [] -> ""
      fields -> " " <> Enum.join(fields, " ")
    end
  end

  defp payload_method(payload) when is_map(payload), do: Map.get(payload, "method") || Map.get(payload, :method)
  defp payload_method(_payload), do: nil

  defp payload_item(payload) when is_map(payload) do
    payload
    |> Map.get("params", Map.get(payload, :params))
    |> case do
      %{} = params -> Map.get(params, "item") || Map.get(params, :item)
      _ -> nil
    end
  end

  defp payload_item(_payload), do: nil

  defp append_source_field(fields, _key, value) when not is_binary(value), do: fields

  defp append_source_field(fields, key, value) when is_list(fields) and is_binary(key) do
    case String.trim(value) do
      "" -> fields
      trimmed -> fields ++ ["#{key}=#{trimmed}"]
    end
  end

  defp find_tagged_subagent_notification_text(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "input_text", "text" => text} when is_binary(text) ->
        find_tagged_text(text, "subagent_notification")

      %{type: "input_text", text: text} when is_binary(text) ->
        find_tagged_text(text, "subagent_notification")

      _ ->
        nil
    end)
  end

  defp find_tagged_subagent_notification_text(_content), do: nil

  defp find_tagged_text(value, tag) when is_binary(value) and is_binary(tag) do
    trimmed_value = String.trim(value)
    open_tag = "<#{tag}>"
    close_tag = "</#{tag}>"
    payload_length = byte_size(trimmed_value) - byte_size(open_tag) - byte_size(close_tag)

    with true <- String.starts_with?(trimmed_value, open_tag),
         true <- String.ends_with?(trimmed_value, close_tag),
         true <- payload_length >= 0 do
      open_count = String.split(trimmed_value, open_tag) |> length() |> Kernel.-(1)
      close_count = String.split(trimmed_value, close_tag) |> length() |> Kernel.-(1)

      if open_count == 1 and close_count == 1 do
        trimmed_value
      end
    else
      _ -> nil
    end
  end

  defp find_tagged_text(_value, _tag), do: nil

  defp user_message_content(%{"payload" => %{"content" => content}}) when is_list(content), do: content
  defp user_message_content(%{payload: %{content: content}}) when is_list(content), do: content
  defp user_message_content(%{"content" => content}) when is_list(content), do: content
  defp user_message_content(%{content: content}) when is_list(content), do: content
  defp user_message_content(_msg), do: nil

  defp decode_tagged_payload(text, tag) when is_binary(text) and is_binary(tag) do
    trimmed_text = String.trim(text)
    open_tag = "<#{tag}>"
    close_tag = "</#{tag}>"

    with true <- String.starts_with?(trimmed_text, open_tag),
         true <- String.ends_with?(trimmed_text, close_tag) do
      payload_length = byte_size(trimmed_text) - byte_size(open_tag) - byte_size(close_tag)

      trimmed_text
      |> String.slice(byte_size(open_tag), payload_length)
      |> String.trim()
      |> Jason.decode()
    else
      _ -> :error
    end
  end

  defp valid_subagent_completion_from_payload(
         %{"agent_path" => agent_path, "status" => %{"completed" => completion}},
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(agent_path) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_path) or
         trusted_unverified_review_subagent_notification?(
           review_subagent_ids,
           review_subagent_call_ids
         ) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         %{agent_path: agent_path, status: %{completed: completion}},
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(agent_path) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_path) or
         trusted_unverified_review_subagent_notification?(
           review_subagent_ids,
           review_subagent_call_ids
         ) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         %{"agent_id" => agent_id, "status" => %{"completed" => completion}},
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) or
         trusted_unverified_review_subagent_notification?(
           review_subagent_ids,
           review_subagent_call_ids
         ) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         %{agent_id: agent_id, status: %{completed: completion}},
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_binary(agent_id) and is_binary(completion) do
    if review_subagent_id_matches?(review_subagent_ids, agent_id) or
         trusted_unverified_review_subagent_notification?(
           review_subagent_ids,
           review_subagent_call_ids
         ) do
      valid_recovered_review_completion(completion)
    end
  end

  defp valid_subagent_completion_from_payload(
         _payload,
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: nil

  defp trusted_unverified_review_subagent_notification?(
         review_subagent_ids,
         review_subagent_call_ids
       )
       when is_struct(review_subagent_ids, MapSet) and
              is_struct(review_subagent_call_ids, MapSet) do
    MapSet.size(review_subagent_ids) == 0 and MapSet.size(review_subagent_call_ids) == 1
  end

  defp trusted_unverified_review_subagent_notification?(
         _review_subagent_ids,
         _review_subagent_call_ids
       ),
       do: false

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_delay_ms(%State{} = state) do
    state.poll_interval_ms * active_instance_count(state)
  end

  defp active_instance_count(%State{active_instance_count_fun: fun}) when is_function(fun, 0) do
    case fun.() do
      count when is_integer(count) and count > 0 -> count
      _invalid -> 1
    end
  rescue
    _reason -> 1
  catch
    _kind, _reason -> 1
  end

  defp active_instance_count(%State{}), do: 1

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp cancel_running_entry_finalize_timer(%{exit_finalize_timer_ref: timer_ref} = running_entry)
       when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    Map.delete(running_entry, :exit_finalize_timer_ref)
  end

  defp cancel_running_entry_finalize_timer(running_entry), do: running_entry

  defp clear_running_entry_finalize_state(running_entry) when is_map(running_entry) do
    running_entry
    |> cancel_running_entry_finalize_timer()
    |> Map.delete(:exit_reason)
    |> Map.delete(:exit_finalize_token)
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        idle_shutdown_ms: state.idle_shutdown_ms_override || config.polling.idle_shutdown_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp maybe_touch_activity_for_state_change(%State{} = previous_state, %State{} = next_state) do
    if activity_state_changed?(previous_state, next_state) do
      touch_activity(next_state)
    else
      next_state
    end
  end

  defp activity_state_changed?(%State{} = previous_state, %State{} = next_state) do
    previous_state.running != next_state.running or
      previous_state.retry_attempts != next_state.retry_attempts or
      previous_state.claimed != next_state.claimed or
      previous_state.completed != next_state.completed or
      previous_state.completed_states != next_state.completed_states
  end

  defp maybe_request_idle_shutdown(%State{external_poll: true} = state), do: state
  defp maybe_request_idle_shutdown(%State{shutdown_requested: true} = state), do: state

  defp maybe_request_idle_shutdown(%State{idle_shutdown_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms <= 0,
       do: state

  defp maybe_request_idle_shutdown(%State{} = state) do
    cond do
      map_size(state.running) > 0 ->
        state

      map_size(state.retry_attempts) > 0 ->
        state

      true ->
        elapsed_ms = System.monotonic_time(:millisecond) - state.last_activity_at_ms

        if elapsed_ms >= state.idle_shutdown_ms do
          request_idle_shutdown(state, elapsed_ms)
        else
          state
        end
    end
  end

  defp request_idle_shutdown(%State{} = state, elapsed_ms) when is_integer(elapsed_ms) do
    Logger.info("Symphony idle shutdown requested idle_ms=#{elapsed_ms}")
    state.output_fun.(@idle_shutdown_message)
    spawn(fn -> state.shutdown_fun.() end)
    %{state | shutdown_requested: true, next_poll_due_at_ms: nil}
  end

  defp touch_activity(%State{} = state) do
    %{state | last_activity_at_ms: System.monotonic_time(:millisecond)}
  end

  defp default_shutdown do
    Application.stop(:symphony_elixir)
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !blocked_issue_in_dispatch_state?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running = Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
