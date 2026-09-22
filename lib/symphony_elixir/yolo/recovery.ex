defmodule SymphonyElixir.Yolo.Recovery do
  @moduledoc "Resume journalled PO mutations without redelivering an unchanged model assignment."
  require Logger
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Yolo.{Admission, Followup, Group, Operations, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Journal

  @spec resume(map(), [map()], keyword()) :: :ok
  def resume(state, issues, opts) do
    busy = MapSet.union(state.claimed, MapSet.new(Map.keys(state.running)))

    issues
    |> Enum.filter(&(Admission.eligible?(&1) and SymphonyElixir.TestRun.start_allowed?(&1) and not MapSet.member?(busy, &1.id)))
    |> Enum.group_by(&Group.name/1)
    |> Map.delete(nil)
    |> Enum.each(&resume_available(&1, state, opts))

    :ok
  end

  defp resume_available({group, members}, state, opts) do
    with false <- Map.has_key?(state.yolo_runs, group),
         {:ok, [_ | _]} <- Operations.pending(Enum.map(members, & &1.id)) do
      Store.lock(group, fn -> resume_group(group, members, opts) end)
    end
  end

  defp resume_group(group, members, opts) do
    with :ok <- Journal.available(group),
         {:ok, record} <- Store.read(group),
         true <- is_nil(record["operation_retry_at"]) or record["operation_retry_at"] <= System.system_time(:millisecond),
         {:ok, pending} <- Operations.pending(Enum.map(members, & &1.id)) do
      ids = MapSet.new(members, & &1.id)

      pending
      |> Enum.filter(fn intent ->
        origins = intent["request"]["origin_ids"] || []
        origins != [] and Enum.all?(origins, &MapSet.member?(ids, &1)) and not escalated?(intent, record)
      end)
      |> Enum.each(&resume_intent(&1, group, members, opts))
    end
  end

  defp escalated?(intent, record) do
    Enum.any?(intent["request"]["origin_ids"], fn id ->
      intent["key"] in (get_in(record, ["escalated_operations", id]) || []) or
        (is_binary(get_in(record, ["attempt", "completed", id])) and
           intent["key"] in (get_in(record, ["attempt", "escalated_operations", id]) || []))
    end)
  end

  defp resume_intent(intent, group, members, opts) do
    sources = members |> Enum.filter(&(&1.id in intent["request"]["origin_ids"])) |> Enum.sort_by(& &1.id)
    lease = Keyword.get(opts, :lease, &IssueLease.run/2)

    result =
      with_leases(sources, lease, fn ->
        Scope.with_scope(group, sources, "recovery:" <> intent["key"], fn -> Followup.invoke(intent["request"], opts) end)
      end)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        source = hd(sources)
        Logger.warning("YOLO operation recovery deferred issue_id=#{source.id} issue_identifier=#{source.identifier} group=#{group} operation_key=#{intent["key"]} reason=#{inspect(reason)}")

        with {:ok, record} <- Store.read(group) do
          Store.write(group, Map.put(record, "operation_retry_at", System.system_time(:millisecond) + 30_000))
        end
    end
  end

  defp with_leases([], _lease, callback), do: callback.()
  defp with_leases([issue | rest], lease, callback), do: lease.(issue, fn -> with_leases(rest, lease, callback) end)
end
