defmodule SymphonyElixir.Yolo.Recovery do
  @moduledoc "Resume journalled PO mutations without redelivering an unchanged model assignment."
  require Logger
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.{Admission, Followup, Group, Operations, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Journal

  @spec resume(map(), [map()], keyword()) :: :ok
  def resume(state, issues, opts) do
    _ = resume_with_state(state, issues, opts)
    :ok
  end

  @spec resume_with_state(map(), [map()], keyword()) :: map()
  def resume_with_state(state, issues, opts) do
    busy = MapSet.union(state.claimed, MapSet.new(Map.keys(state.running)))

    issues
    |> Enum.filter(&(Admission.eligible?(&1) and SymphonyElixir.TestRun.start_allowed?(&1) and not MapSet.member?(busy, &1.id)))
    |> Enum.group_by(&Group.name/1)
    |> Map.delete(nil)
    |> Enum.reduce(state, &resume_available(&1, &2, opts))
  end

  defp resume_available({group, members}, state, opts) do
    with false <- Map.has_key?(state.yolo_runs, group),
         {:ok, [_ | _]} <- Operations.pending(Enum.map(members, & &1.id)) do
      resume_locked(group, members, state, opts)
    else
      _ -> state
    end
  end

  defp resume_locked(group, members, state, opts) do
    case Store.lock(group, fn -> resume_group(group, members, state, opts) end) do
      %{yolo_operation_retries: _} = updated -> updated
      _ -> state
    end
  end

  defp resume_group(group, members, state, opts) do
    with :ok <- Journal.available(group),
         {:ok, record} <- Store.read(group),
         {:ok, pending} <- Operations.pending(Enum.map(members, & &1.id)) do
      ids = MapSet.new(members, & &1.id)

      pending
      |> Enum.filter(fn intent ->
        origins = intent["request"]["origin_ids"] || []
        origins != [] and Enum.all?(origins, &MapSet.member?(ids, &1)) and not escalated?(intent, record)
      end)
      |> Enum.reduce(state, &resume_intent(&1, group, members, &2, opts))
    else
      _ -> state
    end
  end

  defp escalated?(intent, record) do
    Enum.any?(intent["request"]["origin_ids"], fn id ->
      intent["key"] in (get_in(record, ["escalated_operations", id]) || []) or
        (is_binary(get_in(record, ["attempt", "completed", id])) and
           intent["key"] in (get_in(record, ["attempt", "escalated_operations", id]) || []))
    end)
  end

  defp resume_intent(intent, group, members, state, opts) do
    sources = members |> Enum.filter(&(&1.id in intent["request"]["origin_ids"])) |> Enum.sort_by(& &1.id)
    signal = source_signal(sources)
    now = Keyword.get(opts, :recovery_now, fn -> System.system_time(:millisecond) end).()
    key = {group, intent["key"]}

    case Store.read(group) do
      {:ok, record} ->
        details = %{
          intent: intent,
          group: group,
          sources: sources,
          opts: opts,
          record: record,
          signal: signal,
          now: now,
          key: key
        }

        resume_intent_record(details, state)

      _ ->
        state
    end
  end

  defp source_signal(sources) do
    fields = [:id, :state, :title, :description, :updated_at, :last_comment_signal, :assignee_id, :delegate_id]
    Digest.digest(Enum.map(sources, &Map.take(&1, fields)))
  end

  defp resume_intent_record(details, state) do
    previous = get_in(details.record, ["operation_retries", details.intent["key"]])

    if retry_waiting?(previous, details.signal, details.now, state, details.key) do
      state
    else
      result = invoke_intent(details.intent, details.group, details.sources, details.opts)
      record_result(result, details, state)
    end
  end

  defp retry_waiting?(previous, signal, now, state, key) do
    MapSet.member?(state.yolo_operation_retries, key) and is_map(previous) and
      previous["signal"] == signal and is_integer(previous["retry_at"]) and previous["retry_at"] > now
  end

  defp invoke_intent(intent, group, sources, opts) do
    lease = Keyword.get(opts, :lease, &IssueLease.run/2)
    invoke = Keyword.get(opts, :invoke, &Followup.invoke/2)

    with_leases(sources, lease, fn ->
      Scope.with_scope(group, sources, "recovery:" <> intent["key"], fn -> invoke.(intent["request"], opts) end)
    end)
  end

  defp record_result({:ok, _}, details, state) do
    clear_retry(details.group, details.intent["key"])
    %{state | yolo_operation_retries: MapSet.delete(state.yolo_operation_retries, details.key)}
  end

  defp record_result({:error, reason}, details, state) do
    source = hd(details.sources)

    Logger.warning(
      "YOLO operation recovery deferred issue_id=#{source.id} issue_identifier=#{source.identifier} group=#{details.group} operation_key=#{details.intent["key"]} reason=#{inspect(reason)}"
    )

    case Store.read(details.group) do
      {:ok, current} -> persist_retry(current, details, reason, state)
      _ -> state
    end
  end

  defp persist_retry(current, details, reason, state) do
    previous = get_in(current, ["operation_retries", details.intent["key"]])
    count = retry_count(previous, details.signal, reason)
    entry = %{"signal" => details.signal, "reason" => inspect(reason), "count" => count, "retry_at" => details.now + retry_delay(reason, count)}
    retries = Map.put(current["operation_retries"] || %{}, details.intent["key"], entry)
    record = current |> Map.delete("operation_retry_at") |> Map.put("operation_retries", retries)

    case Store.write(details.group, record) do
      :ok -> %{state | yolo_operation_retries: MapSet.put(state.yolo_operation_retries, details.key)}
      _ -> state
    end
  end

  defp retry_count(previous, signal, reason) do
    if is_map(previous) and previous["signal"] == signal and previous["reason"] == inspect(reason) and is_integer(previous["count"]) do
      previous["count"] + 1
    else
      1
    end
  end

  defp clear_retry(group, key) do
    with {:ok, record} <- Store.read(group) do
      retries = Map.delete(record["operation_retries"] || %{}, key)
      Store.write(group, record |> Map.delete("operation_retry_at") |> Map.put("operation_retries", retries))
    end
  end

  defp retry_delay(reason, count) do
    if transient?(reason) or count == 1, do: 30_000, else: min(900_000, (count - 1) * 300_000)
  end

  defp transient?(reason) do
    text = reason |> inspect() |> String.downcase()
    Enum.any?(~w(transport timeout timed_out offline rate_limited ratelimited relay http budget unavailable connection lease lock), &String.contains?(text, &1))
  end

  defp with_leases([], _lease, callback), do: callback.()
  defp with_leases([issue | rest], lease, callback), do: lease.(issue, fn -> with_leases(rest, lease, callback) end)
end
