defmodule SymphonyElixir.Yolo.Coordinator do
  @moduledoc "PO scheduling inside the existing project orchestrator and shared capacity."
  require Logger
  alias SymphonyElixir.{Config, ProjectContext, Tracker, Workpad}
  alias SymphonyElixir.Linear.YoloAgent
  alias SymphonyElixir.Yolo.{Admission, BlockerBrake, Completion, Delivery, Dependencies}
  alias SymphonyElixir.Yolo.{AgentHop, Escalation, Group, Impulse, Observation, Operations}
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Gateway
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  alias SymphonyElixir.Yolo.{Recovery, RetryBackoff, ReviewReadiness, Runner, Store}

  @operator_warning_interval_ms 300_000
  @operator_report_interval_ms 300_000

  @spec tick(map(), [map()], keyword()) :: map()
  def tick(state, issues, opts \\ []) do
    {state, cache} =
      AgentHop.with_cache(Map.get(state.yolo_retries, :agent_hops, %{}), fn ->
        do_tick(state, issues, opts)
      end)

    put_in(state.yolo_retries[:agent_hops], cache)
  end

  defp do_tick(state, issues, opts) do
    SymphonyElixir.Yolo.OpenClaw.LinearBridge.Delivery.tick(opts)
    state = recover_external(state, opts)
    runs = state.yolo_runs |> reconcile(issues) |> refresh_external(issues, opts)
    previous_ids = Enum.flat_map(state.yolo_runs, fn {_, run} -> run.ids end) |> MapSet.new()
    current_ids = Enum.flat_map(runs, fn {_, run} -> run.ids end) |> MapSet.new()
    claimed = state.claimed |> MapSet.difference(previous_ids) |> MapSet.union(current_ids)
    state = %{state | yolo_runs: runs, claimed: claimed}

    if is_binary(Config.yolo_agent_id()) do
      issues = recover_origins(state, issues, opts)
      relay_signals = relay_signals(issues)
      retrying_groups = retrying_groups(relay_signals)
      opts = opts |> Keyword.put(:relay_signals, relay_signals) |> Keyword.put(:retrying_groups, retrying_groups)
      {retrying, regular} = Enum.split_with(issues, &Map.has_key?(retrying_groups, Group.name(&1)))
      retrying = Enum.map(retrying, &%{&1 | blocked_by: retrying_groups[Group.name(&1)][&1.id]})

      case Dependencies.refresh_background(regular, state.yolo_marker_cache, Keyword.put(opts, :relay_background, true)) do
        {:ok, refreshed, marker_cache} ->
          schedule_refreshed(%{state | yolo_marker_cache: marker_cache}, issues, refreshed ++ retrying, opts)

        {:error, reason} ->
          Logger.warning("YOLO dependencies unavailable project_root=#{ProjectContext.current().root} reason=#{inspect(reason)}")
          state

        {:error, reason, marker_cache} ->
          Logger.warning("YOLO dependencies unavailable project_root=#{ProjectContext.current().root} reason=#{inspect(reason)}")
          %{state | yolo_marker_cache: marker_cache}
      end
    else
      state
    end
  end

  defp retry_notifications(state, issues, opts) do
    case Journal.pending() do
      {:ok, orders} ->
        retry_unreserved_notifications(state, issues, orders, opts)

      {:error, reason} ->
        Logger.warning("YOLO notification reservation check failed reason=#{inspect(reason)}")
        state
    end
  end

  defp retry_unreserved_notifications(state, issues, orders, opts) do
    reserved = MapSet.new(for order <- orders, member <- order["members"], do: member["id"])

    entries =
      issues
      |> Enum.filter(fn issue ->
        notification_retry_eligible?(issue) and not MapSet.member?(reserved, issue.id) and
          not MapSet.member?(state.claimed, issue.id) and not Map.has_key?(state.running, issue.id)
      end)
      |> Enum.flat_map(&pending_notification_entries/1)

    keys = Enum.map(entries, fn {issue, id, _initial_reason} -> {issue.id, id} end)
    state = put_in(state.yolo_retries.notifications, Map.take(state.yolo_retries.notifications, keys))

    if entries == [] do
      state
    else
      agent = Config.openclaw_yolo_agent()
      route = Keyword.get(opts, :escalation_route, &Gateway.destination/2)
      route_result = if is_binary(agent), do: route.(agent, opts), else: {:error, :openclaw_yolo_agent_unavailable}
      now = Keyword.get(opts, :notification_now, fn -> System.system_time(:millisecond) end).()

      Enum.reduce(entries, state, fn {issue, id, initial_reason}, acc ->
        retry_notification_if_due(acc, issue, id, initial_reason, route_result, now, opts)
      end)
    end
  end

  defp pending_notification_entries(issue) do
    case Escalation.pending_routes(issue.id) do
      {:ok, routes} ->
        Enum.map(routes, fn {id, reason} -> {issue, id, reason} end)

      {:error, reason} ->
        Logger.warning("YOLO notification journal unavailable issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        []
    end
  end

  defp retry_notification_if_due(state, issue, id, initial_reason, route_result, now, opts) do
    key = {issue.id, id}
    previous = state.yolo_retries.notifications[key]
    signal = Observation.relay_signal(issue)
    route_reason = inspect(route_result)

    if is_map(previous) and previous["signal"] == signal and previous["route_reason"] == route_reason and previous["retry_at"] > now do
      state
    else
      result = retry_notification(issue, id, route_result, opts)
      record_notification_retry(state, issue, key, signal, route_reason, initial_reason, result, now)
    end
  end

  defp retry_notification(issue, id, route_result, opts) do
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids(&1, force_full: true))

    case fetch.([issue.id]) do
      {:ok, [fresh]} ->
        retry_fresh_notification(issue, fresh, id, route_result, opts)

      {:error, reason} ->
        {:error, {:notification_refresh_failed, reason}}

      _ ->
        {:error, :notification_refresh_incomplete}
    end
  end

  defp retry_fresh_notification(issue, fresh, id, route_result, opts) do
    if fresh.id == issue.id and notification_retry_eligible?(fresh) and fresh.assignee_id == issue.assignee_id do
      route = fn _, _ -> route_result end
      Escalation.retry_pending(fresh, Keyword.merge(opts, notification_id: id, escalation_route: route))
    else
      {:error, :notification_refresh_ineligible}
    end
  end

  defp record_notification_retry(state, _issue, key, _signal, _route_reason, _initial_reason, :ok, _now) do
    put_in(state.yolo_retries.notifications, Map.delete(state.yolo_retries.notifications, key))
  end

  defp record_notification_retry(state, issue, key, signal, route_reason, initial_reason, {:error, reason}, now) do
    previous = state.yolo_retries.notifications[key]
    count = if is_nil(previous) and initial_reason == inspect(reason), do: 2, else: RetryBackoff.count(previous, signal, reason)
    entry = %{"signal" => signal, "route_reason" => route_reason, "reason" => inspect(reason), "count" => count, "retry_at" => now + RetryBackoff.delay(reason, count)}
    state = put_in(state.yolo_retries.notifications, Map.put(state.yolo_retries.notifications, key, entry))
    log_notification_retry(state, issue, reason, now)
  end

  defp notification_retry_eligible?(issue) do
    context = ProjectContext.current()

    Admission.eligible?(issue) or
      (issue.state in ["Yolo Review", "BLOCKER"] and is_nil(issue.delegate_id) and
         issue.assignee_id == Config.human_handoff_id() and issue.in_project_scope and
         issue.project_context_id == context.id and issue.workspace_id == context.settings.tracker.app["workspace_id"] and
         (is_nil(Config.allowed_issue_ids()) or issue.id in Config.allowed_issue_ids()))
  end

  defp log_notification_retry(state, issue, reason, now) do
    key = {issue.id, inspect(reason)}
    last = state.yolo_retries.logs[key]

    if is_nil(last) or now - last >= @operator_warning_interval_ms do
      Logger.warning("YOLO notification waiting issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
      put_in(state.yolo_retries.logs, Map.put(state.yolo_retries.logs, key, now))
    else
      state
    end
  end

  defp schedule_refreshed(state, original, refreshed, opts) do
    case complete_refresh(original, refreshed) do
      {:ok, issues} ->
        available = Enum.reject(issues, &Dependencies.marker_error?/1)
        state = retry_notifications(state, available, opts)
        state = Recovery.resume_with_state(state, available, opts)
        {issues, state} = admit(issues, state, opts)
        schedule_groups(state, issues, opts)

      {:error, reason} ->
        Logger.warning("YOLO dependencies unavailable project_root=#{ProjectContext.current().root} reason=#{inspect(reason)}")
        state
    end
  end

  defp complete_refresh(issues, refreshed) do
    if Enum.sort(Enum.map(issues, & &1.id)) == Enum.sort(Enum.map(refreshed, & &1.id)) do
      by_id = Map.new(refreshed, &{&1.id, &1})
      {:ok, Enum.map(issues, &Map.fetch!(by_id, &1.id))}
    else
      {:error, :yolo_dependencies_incomplete}
    end
  end

  defp relay_signals(issues) do
    issues
    |> Enum.reject(&is_nil(Group.name(&1)))
    |> Enum.group_by(&Group.name/1)
    |> Map.new(fn {group, members} -> {group, Map.new(members, &{&1.id, Observation.relay_signal(&1)})} end)
  end

  defp retrying_groups(signals) do
    Map.new(signals, fn {group, current} ->
      snapshot =
        case Store.read(group) do
          {:ok, %{"retry_at" => retry_at, "relay_signals" => ^current, "dependency_snapshot" => dependencies}}
          when is_integer(retry_at) and is_map(dependencies) ->
            restore_dependency_snapshot(dependencies, current)

          _ ->
            nil
        end

      {group, snapshot}
    end)
    |> Map.reject(fn {_, snapshot} -> is_nil(snapshot) end)
  end

  defp restore_dependency_snapshot(snapshot, signals) do
    if Enum.sort(Map.keys(snapshot)) == Enum.sort(Map.keys(signals)) and
         Enum.all?(Map.values(snapshot), fn blockers -> is_list(blockers) and Enum.all?(blockers, &is_map/1) end) do
      Map.new(snapshot, fn {id, blockers} -> {id, Enum.map(blockers, &restore_blocker/1)} end)
    end
  end

  defp restore_blocker(blocker) do
    Enum.reduce([:id, :identifier, :state, :state_type, :marker], %{}, fn field, acc ->
      value = Map.get(blocker, Atom.to_string(field), Map.get(blocker, field))
      if is_nil(value), do: acc, else: Map.put(acc, field, value)
    end)
  end

  defp recover_external(state, opts) do
    case Journal.pending() do
      {:ok, orders} ->
        Enum.reduce(orders, state, &recover_order(&2, &1, opts))

      {:error, reason} ->
        Logger.error("OpenClaw reservations unavailable project_root=#{ProjectContext.current().root} reason=#{inspect(reason)}")
        # An unreadable reservation cannot prove any slot/member is free.
        %{state | max_concurrent_agents: 0}
    end
  end

  defp recover_order(state, order, opts) do
    group = order["group"]
    run = state.yolo_runs[group]

    if run && is_pid(run.pid) && Process.alive?(run.pid) do
      state
    else
      members = Enum.map(order["members"], fn member -> %{id: member["id"], identifier: member["identifier"], state: member["state"]} end)
      recovery_opts = Keyword.put_new(opts, :recipient, self())
      runner = fn _, _, _ -> OpenClaw.recover(order, recovery_opts) end

      event = %{
        external: OpenClaw.observation(Map.merge(order, %{"writable" => false, "resumed" => true, "cancel_requested" => true})),
        session_id: order["session_id"],
        workspace_path: order["workspace"]
      }

      start(state, group, members, [], Keyword.merge(opts, runner: runner, recovering: true, initial_event: event))
    end
  end

  defp refresh_external(runs, issues, opts) do
    ids = runs |> Enum.filter(fn {_, run} -> is_map(get_in(run, [:event, :external])) end) |> Enum.flat_map(fn {_, run} -> run.ids end) |> Enum.uniq()
    known = Map.new(issues, &{&1.id, &1})
    missing = Enum.reject(ids, &Map.has_key?(known, &1))
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    fresh =
      case if(missing == [], do: {:ok, []}, else: fetch.(missing)) do
        {:ok, extra} -> Map.merge(known, Map.new(extra, &{&1.id, &1}))
        _ -> known
      end

    Map.new(runs, fn {group, run} ->
      if is_map(get_in(run, [:event, :external])) do
        {group, Map.put(run, :current_issues, Map.take(fresh, run.ids))}
      else
        {group, run}
      end
    end)
  end

  defp recover_origins(state, issues, opts) do
    ids = Enum.map(issues, & &1.id)
    fetch = Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1)

    # A lost last close response can leave only the blocked target in the poll.
    # Rehydrate its journalled sources under the existing incoming run/leases;
    # never admit the target before its operation has actually finished.
    with false <- Map.has_key?(state.yolo_runs, "incoming"),
         {:ok, record} <- Store.read("incoming"),
         true <- is_nil(record["retry_at"]) or record["retry_at"] <= System.system_time(:millisecond),
         {:ok, pending} <- Operations.pending(ids),
         missing = recovery_ids(pending, ids),
         true <- missing != [],
         {:ok, recovered} <- fetch.(missing),
         true <- Enum.sort(Enum.map(recovered, & &1.id)) == missing do
      issues ++ Enum.filter(recovered, &Operations.recovering_origin?/1)
    else
      _ -> issues
    end
  end

  defp recovery_ids(pending, ids) do
    pending
    |> Enum.filter(&(&1["request"]["kind"] == "aggregate"))
    |> Enum.flat_map(&(&1["closing"] || []))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in ids))
    |> Enum.sort()
  end

  defp schedule_groups(state, issues, opts) do
    case ReviewReadiness.observe(issues) do
      {:ok, epoch} ->
        Enum.reduce(Enum.sort(Group.groups(issues)), state, fn {group, members}, acc ->
          dispatch(acc, group, members, issues, Keyword.put(opts, :review_epoch, epoch))
        end)

      {:error, reason} ->
        Logger.warning("YOLO review readiness unavailable reason=#{inspect(reason)}")
        state
    end
  end

  defp reconcile(runs, issues) do
    by_id = Map.new(issues, &{&1.id, &1})

    Map.filter(runs, fn {group, run} ->
      alive? = is_pid(run.pid) and Process.alive?(run.pid)

      withdrawn? =
        Enum.all?(run.ids, &withdrawn?(by_id[&1]))

      own_finish? = Completion.ready?(group, run.issues)
      withdrawn? = withdrawn? and not own_finish?

      external? =
        case Journal.read(group) do
          {:ok, order} -> Journal.pending?(order)
          _ -> true
        end

      if alive? and withdrawn?, do: stop_withdrawn(run.pid, external?)

      alive? and (external? or not withdrawn?)
    end)
  end

  defp stop_withdrawn(pid, true), do: send(pid, :openclaw_cancel)
  defp stop_withdrawn(pid, false), do: Process.exit(pid, :shutdown)

  defp withdrawn?(nil), do: true
  defp withdrawn?(issue), do: not YoloAgent.delegated?(issue) or not Admission.eligible?(issue)

  defp admit(issues, state, opts) do
    reserved = Enum.flat_map(state.yolo_runs, fn {_, run} -> run.ids end)
    prepare = Keyword.get(opts, :prepare, &Admission.prepare/1)

    issues =
      Enum.flat_map(issues, fn issue ->
        if not Map.has_key?(opts[:retrying_groups] || %{}, Group.name(issue)) and
             Admission.eligible?(issue) and Admission.needed?(issue) and
             Dependencies.dispatchable?(issue) and
             not Group.terminal?(issue) and issue.id not in reserved and not Map.has_key?(state.running, issue.id) do
          [prepare_issue(issue, prepare)]
        else
          [issue]
        end
      end)

    {issues, state}
  end

  defp prepare_issue(issue, prepare) do
    case prepare.(issue) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning("YOLO admission failed issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)}")
        issue
    end
  end

  defp dispatch(state, group, members, issues, opts) do
    used = map_size(state.running) + map_size(state.yolo_runs)
    limit = state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents
    busy? = Enum.any?(members, &(Map.has_key?(state.running, &1.id) or MapSet.member?(state.claimed, &1.id)))
    allowed? = Enum.all?(members, &SymphonyElixir.TestRun.start_allowed?/1)

    if used < limit and not busy? and allowed? and not Map.has_key?(state.yolo_runs, group) do
      case prepare_group(group, members, opts) do
        {:run, pending} -> start(state, group, pending, issues, opts)
        _ -> state
      end
    else
      state
    end
  end

  defp prepare_group(group, members, opts) do
    Store.lock(group, fn -> observe_group(group, members, opts) end)
  end

  defp observe_group(group, members, opts) do
    with :ok <- Journal.available(group),
         :ok <- Delivery.reconcile(group),
         {:ok, stored} <- Store.read(group),
         {:ok, record} <- Impulse.observe(members, stored, opts),
         {:ok, valid_observations, _fingerprint, operator_errors} <-
           capture_group(group, members, record, Keyword.put(opts, :impulse_generations, Impulse.generations(record))),
         {:ok, record, agent_held} <- AgentHop.gate_durable(record, valid_observations, opts),
         observations = retain_error_observations(valid_observations, record["observations"], operator_errors),
         record = Delivery.migrate(record, observations),
         record = record_operator_errors(group, members, record, operator_errors, opts),
         available = available_members(members, valid_observations, agent_held),
         signals = get_in(opts[:relay_signals] || %{}, [group]),
         record = reset_changed_retry(record, signals),
         :ok <- persist_observations(group, stored, record, observations, signals, members),
         {:ok, operations} <- Operations.pending(Enum.map(members, & &1.id)),
         effective = if(operations == [], do: record, else: Map.put(record, "processed", nil)),
         pending = pending_members(members, available, observations, effective),
         waiting =
           agent_waiting_reason(agent_held, pending, members, available, observations, effective, operator_errors),
         record = if(waiting == "delivery_end_unconfirmed", do: record, else: reset_changed_nonstart(record, pending, observations)),
         stored_observations = observations_for_pending(observations, record, pending, waiting),
         updated =
           record
           |> Map.put("observations", stored_observations)
           |> Map.put("deferred_observations", if(stored_observations == observations, do: nil, else: observations))
           |> Map.put("relay_signals", signals || %{})
           |> Map.put("dependency_snapshot", dependency_snapshot(members))
           |> Map.put("waiting_reason", waiting),
         :ok <- if(updated == record, do: :ok, else: Store.write(group, updated)),
         true <- record["checkout_cleanup_blocked"] != true,
         true <- is_nil(record["retry_at"]) or record["retry_at"] <= System.system_time(:millisecond) do
      prepare_pending(group, pending, opts)
    else
      {:error, reason} ->
        record_waiting(group, reason)
        Logger.warning("YOLO observation failed group=#{group} reason=#{inspect(reason)}")
        :unavailable

      _ ->
        :waiting
    end
  end

  defp available_members(members, observations, held), do: Enum.filter(members, &(Map.has_key?(observations, &1.id) and not MapSet.member?(held, &1.id)))

  defp agent_waiting_reason(held, pending, members, available, observations, record, errors) do
    if pending == [] and MapSet.size(held) > 0,
      do: "agent_hop_limit",
      else: pending_waiting_reason(pending, members, available, observations, record, errors)
  end

  defp capture_group(group, members, record, opts) do
    cached = record["deferred_observations"] || record["observations"] || %{}

    if Map.has_key?(opts[:retrying_groups] || %{}, group) and
         map_size(record["operator_errors"] || %{}) == 0 and
         Enum.all?(members, &is_map(cached[&1.id])) do
      observations = Map.take(cached, Enum.map(members, & &1.id))
      {:ok, observations, Observation.fingerprint(observations), %{}}
    else
      Observation.capture_isolated(members, cached, opts)
    end
  end

  defp retain_error_observations(current, previous, errors) do
    (previous || %{})
    |> Map.take(Map.keys(errors))
    |> Map.merge(current)
  end

  defp waiting_reason(members, available, observations, record, errors) do
    cond do
      Delivery.unresolved_delivery?(members, record) -> "delivery_end_unconfirmed"
      map_size(errors) > 0 -> "operator_handoff_incomplete"
      true -> Delivery.waiting_reason(available, observations, record)
    end
  end

  defp pending_members(members, available, observations, record) do
    if Delivery.unresolved_delivery?(members, record), do: [], else: Delivery.pending(available, observations, record)
  end

  defp pending_waiting_reason([], members, available, observations, record, errors),
    do: waiting_reason(members, available, observations, record, errors)

  defp pending_waiting_reason(_pending, _members, _available, _observations, _record, _errors), do: nil

  defp record_operator_errors(group, members, record, errors, opts) do
    now = Keyword.get(opts, :handoff_now, fn -> System.system_time(:millisecond) end).()
    reports = Map.take(record["operator_error_reports"] || %{}, Map.keys(errors))

    reports =
      Enum.reduce(errors, reports, fn {id, reason}, reported ->
        issue = Enum.find(members, &(&1.id == id))
        signal = Observation.relay_signal(issue)
        {result, entry} = attempt_operator_report(issue, reason, signal, now, reported[id], opts)
        warn_operator_error(group, issue, reason, result, now)
        Map.put(reported, id, entry)
      end)

    record
    |> Map.put("operator_errors", Map.new(errors, fn {id, reason} -> {id, Atom.to_string(reason)} end))
    |> Map.put("operator_error_reports", reports)
  end

  defp attempt_operator_report(issue, reason, signal, now, previous, opts) do
    if operator_report_due?(previous, Atom.to_string(reason), signal, now) do
      report = Keyword.get(opts, :handoff_report, fn issue, reason -> report_operator_error(issue, reason, opts) end)
      result = report.(issue, reason)
      {result, %{"reason" => Atom.to_string(reason), "signal" => signal, "checked_at" => now, "reported" => result == :ok}}
    else
      {if(previous["reported"], do: :ok, else: :deferred), previous}
    end
  end

  defp operator_report_due?(%{"reason" => reason, "signal" => signal, "checked_at" => checked_at, "reported" => reported?}, reason, signal, now)
       when is_integer(checked_at) and is_boolean(reported?) do
    not reported? and now - checked_at >= @operator_report_interval_ms
  end

  defp operator_report_due?(_, _, _, _), do: true

  defp warn_operator_error(group, issue, reason, result, now) do
    Store.lock("operator-handoff-warnings", fn ->
      case Store.read("operator-handoff-warnings") do
        {:ok, record} -> persist_operator_warning(group, issue, reason, result, now, record)
        _ -> :ok
      end
    end)
  end

  defp persist_operator_warning(group, issue, reason, result, now, record) do
    key = issue.id <> ":" <> Atom.to_string(reason)
    warnings = record["warnings"] || %{}
    last = warnings[key]

    if not is_integer(last) or now - last >= @operator_warning_interval_ms do
      updated = Map.put(record, "warnings", Map.put(warnings, key, now))

      if Store.write("operator-handoff-warnings", updated) == :ok do
        Logger.warning("YOLO operator handoff invalid group=#{group} issue_id=#{issue.id} issue_identifier=#{issue.identifier} reason=#{inspect(reason)} report=#{inspect(result)}")
      end
    end
  end

  defp report_operator_error(issue, :yolo_operator_handoff_incomplete, opts) do
    note = "Betreiberauftrag ungültig: mehrere oder nicht auswertbare Blöcke im aktuellen Workpad; Auftrag dort korrigieren. Dieses Ticket bleibt bis dahin für den YOLO-Lauf gesperrt."
    comments = Keyword.get(opts, :workpad_comments, &Tracker.fetch_issue_comments(&1, force_full: true))
    write = Keyword.get(opts, :workpad_write, &Workpad.update_tracker_workpad/2)

    with {:ok, found} <- comments.(issue.id) do
      case Workpad.find_comment(found) do
        {:ok, workpad} -> maybe_write_operator_note(issue.id, workpad.body, note, write)
        {:error, {:multiple_workpad_comments, _}} -> report_duplicate_workpads(found, note, opts)
        error -> error
      end
    end
  end

  defp report_duplicate_workpads(comments, note, opts) do
    workpad =
      comments
      |> Enum.filter(&reportable_workpad?/1)
      |> Enum.sort_by(&(Map.get(&1, :id) || Map.get(&1, "id")))
      |> List.first()

    if is_map(workpad) do
      id = Map.get(workpad, :id) || Map.get(workpad, "id")
      body = Map.get(workpad, :body) || Map.get(workpad, "body")
      direct_write = Keyword.get(opts, :handoff_comment_write, &Tracker.update_comment/2)
      write = fn comment_id, updated -> write_duplicate_workpad(comment_id, updated, direct_write) end
      maybe_write_operator_note(id, body, note, write)
    else
      {:error, :workpad_comment_missing_id}
    end
  end

  defp reportable_workpad?(comment) do
    is_binary(Map.get(comment, :id) || Map.get(comment, "id")) and
      Workpad.comment_matches?(Map.get(comment, :body) || Map.get(comment, "body"))
  end

  defp write_duplicate_workpad(id, body, write) do
    with :ok <- Workpad.validate_update_body(body), do: write.(id, body)
  end

  defp maybe_write_operator_note(issue_id, body, note, write) do
    if String.contains?(body, note) do
      :ok
    else
      stamp = NaiveDateTime.local_now() |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
      entry = "- #{stamp} - #{note}\n"
      write.(issue_id, insert_operator_note(body, entry))
    end
  end

  defp insert_operator_note(body, entry) do
    if String.contains?(body, "### Verlauf\n") do
      String.replace(body, "### Verlauf\n", "### Verlauf\n\n" <> entry, global: false)
    else
      body <> "\n### Verlauf\n\n" <> entry
    end
  end

  defp reset_changed_retry(%{"retry_at" => retry_at, "relay_signals" => previous} = record, current)
       when is_integer(retry_at) and is_map(current) and previous != current do
    Map.merge(record, %{"retry_at" => nil, "nonstart" => nil, "failure_count" => 0, "last_failure_reason" => nil, "error" => nil})
  end

  defp reset_changed_retry(record, _), do: record

  defp dependency_snapshot(members), do: Map.new(members, &{&1.id, &1.blocked_by})

  defp persist_observations(group, stored, record, observations, signals, members) do
    previous = record["observations"] || %{}

    updated =
      Map.merge(record, %{
        "observations" => previous,
        "deferred_observations" => if(previous == observations, do: nil, else: observations),
        "relay_signals" => signals || %{},
        "dependency_snapshot" => dependency_snapshot(members)
      })

    if updated == stored, do: :ok, else: Store.write(group, updated)
  end

  defp observations_for_pending(observations, record, _pending, "delivery_end_unconfirmed") do
    Map.merge(observations, Map.take(record["observations"] || %{}, Map.keys(observations)))
  end

  defp observations_for_pending(observations, record, pending, _waiting) do
    previous = record["observations"] || %{}
    pending_ids = Enum.map(pending, & &1.id)
    Map.merge(observations, Map.take(previous, pending_ids))
  end

  defp reset_changed_nonstart(%{"nonstart" => %{"fingerprint" => fingerprint, "members" => ids}} = record, pending, observations) do
    pending_ids = Enum.map(pending, & &1.id)

    if fingerprint == Observation.fingerprint(Map.take(observations, pending_ids)) and ids == pending_ids do
      record
    else
      Map.merge(record, %{"nonstart" => nil, "retry_at" => nil})
    end
  end

  defp reset_changed_nonstart(record, _, _), do: record

  defp prepare_pending(group, pending, opts) do
    result = if group == "blocker", do: BlockerBrake.check(pending, opts), else: {:ok, pending}

    case result do
      {:ok, []} ->
        :unchanged

      {:ok, pending} ->
        {:run, pending}

      {:error, reason} ->
        record_waiting(group, reason)
        Logger.warning("YOLO BLOCKER brake unavailable reason=#{inspect(reason)}")
        :unavailable
    end
  end

  defp record_waiting(group, reason) do
    with {:ok, record} <- Store.read(group) do
      waiting = inspect(reason)
      if record["waiting_reason"] == waiting, do: :ok, else: Store.write(group, Map.put(record, "waiting_reason", waiting))
    end
  end

  defp start(state, group, members, issues, opts) do
    context = ProjectContext.current()
    recipient = Keyword.get(opts, :recipient, self())
    runner = Keyword.get(opts, :runner, fn name, members, all -> Runner.run(name, members, all, recipient: recipient) end)
    callback = fn -> ProjectContext.with_context(context, fn -> runner.(group, members, issues) end) end

    start = Keyword.get(opts, :start, fn name, fun -> start_worker(state, name, fun, opts[:recovering] == true) end)
    start_group = Keyword.get(opts, :start_group, fn name, _members, fun, _opts -> start.(name, fun) end)
    prior_record = Store.read(group)

    case start_group.(group, members, callback, opts) do
      {:ok, pid} ->
        record_start(state, group, members, pid, Keyword.get(opts, :initial_event, %{}))

      {:error, reason} ->
        handle_start_failure(state, group, members, opts, prior_record, reason)
    end
  end

  @doc false
  @spec start_worker(map(), String.t(), (-> term()), boolean()) :: {:ok, pid()} | {:error, term()}
  def start_worker(state, name, callback, recovering?) do
    cond do
      state.external_poll and recovering? -> SymphonyElixir.WorkerCapacity.recover_child("YOLO #{name}", callback)
      state.external_poll -> SymphonyElixir.WorkerCapacity.start_child(nil, "YOLO #{name}", callback)
      true -> Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, callback)
    end
  end

  @doc false
  @spec record_start(map(), String.t(), [map()], pid(), map()) :: map()
  def record_start(state, group, members, pid, event) do
    %{
      state
      | yolo_runs: Map.put(state.yolo_runs, group, %{pid: pid, ids: Enum.map(members, & &1.id), issues: members, started_at: DateTime.utc_now(), event: event}),
        claimed: MapSet.union(state.claimed, MapSet.new(members, & &1.id)),
        last_activity_at_ms: System.monotonic_time(:millisecond)
    }
  end

  defp handle_start_failure(state, group, members, opts, prior_record, reason) do
    unless opts[:recovering] == true or reason in [:capacity, :worker_capacity] or
             start_effect_recorded?(group, prior_record) do
      Runner.record_start_failure(group, members, reason)
    end

    if opts[:recovering] do
      %{state | claimed: MapSet.union(state.claimed, MapSet.new(members, & &1.id)), max_concurrent_agents: 0}
    else
      state
    end
  end

  defp start_effect_recorded?(group, prior_record), do: Store.read(group) != prior_record

  @spec event(map(), String.t(), map()) :: map()
  def event(runs, group, message) do
    case runs[group] do
      nil -> runs
      %{pid: pid} when is_map_key(message, :worker_pid) and message.worker_pid != pid -> runs
      run -> Map.put(runs, group, %{run | event: Map.merge(run.event, message)})
    end
  end

  @spec entries(map()) :: [map()]
  def entries(runs) do
    Enum.flat_map(runs, fn {group, run} ->
      Enum.map(run.issues, fn issue ->
        entry = %{
          issue_id: issue.id,
          identifier: issue.identifier,
          state: "YOLO " <> group,
          worker_host: nil,
          workspace_path: run.event[:workspace_path],
          session_id: run.event[:session_id],
          codex_app_server_pid: run.event[:codex_app_server_pid],
          codex_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          turn_count: 1,
          started_at: run.started_at,
          last_codex_timestamp: nil,
          last_codex_message: run.event[:message],
          last_codex_event: run.event[:event],
          recent_codex_events: [],
          runtime_seconds: DateTime.diff(DateTime.utc_now(), run.started_at)
        }

        external_entry(entry, run, issue)
      end)
    end)
  end

  defp external_entry(entry, run, issue) do
    case run.event[:external] do
      nil ->
        entry

      external ->
        current = get_in(run, [:current_issues, issue.id])
        external = Map.merge(external, %{original_state: issue.state, current_state: current && current.state, current_state_known: not is_nil(current)})

        %{entry | state: (current && current.state) || "Unbekannt", turn_count: if(external.reserved, do: 0, else: entry.turn_count)}
        |> Map.put(:external, external)
    end
  end

  @spec stop(map()) :: :ok
  def stop(runs) do
    Enum.each(runs, fn {group, run} ->
      revoke_before_stop(group, run)
      Process.exit(run.pid, :shutdown)
    end)

    :ok
  end

  defp revoke_before_stop(group, run) do
    case Journal.read(group) do
      {:ok, nil} -> :ok
      {:ok, order} -> await_revocation(order, run)
      {:error, reason} -> retry_stop(group, run, reason, fn -> revoke_before_stop(group, run) end)
    end
  end

  defp await_revocation(order, run) do
    # Keep the original generation through retries. Acquiring its journal lock
    # drains authorized calls; a timeout or failed write never permits a kill.
    case Journal.update(order, %{"writable" => false, "cancel_requested" => true}) do
      {:ok, _} -> :ok
      {:error, :openclaw_generation_changed} -> :ok
      {:error, reason} -> retry_stop(order["group"], run, reason, fn -> await_revocation(order, run) end)
    end
  end

  defp retry_stop(group, run, reason, retry) do
    Enum.each(Map.get(run, :issues, [%{id: nil, identifier: nil}]), fn issue ->
      Logger.warning("OpenClaw shutdown waiting group=#{group} issue_id=#{issue.id} issue_identifier=#{issue.identifier} session_id=#{get_in(run, [:event, :session_id])} reason=#{inspect(reason)}")
    end)

    Process.sleep(1000)
    retry.()
  end
end
