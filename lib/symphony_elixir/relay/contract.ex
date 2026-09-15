defmodule SymphonyElixir.Relay.Contract do
  @moduledoc "Validation of the pinned LinearRelay v1 response envelopes."
  alias SymphonyElixir.Relay.Config
  @maximum 9_007_199_254_740_991

  @spec consumer(map(), String.t(), map()) :: :ok | {:error, atom()}
  def consumer(view, id, subscription) do
    valid =
      view["version"] == 1 and view["consumerId"] == id and view["subscription"] == subscription and
        Config.id?(view["generation"]) and Config.id?(view["snapshotToken"]) and
        integer?(view["cursor"]) and integer?(view["snapshotExpiresAt"]) and
        positive?(view["retentionMs"]) and view["status"] in ["ready", "snapshot_required"]

    result(valid)
  end

  @spec page(map(), String.t(), String.t(), non_neg_integer()) :: :ok | {:error, atom()}
  def page(page, workspace, generation, cursor) do
    events = page["events"]

    valid =
      page["version"] == 1 and page["generation"] == generation and
        page_positions?(page, cursor) and positive?(page["retentionMs"]) and
        receipt?(page, cursor) and is_list(events) and length(events) <= 100

    with :ok <- result(valid),
         :ok <- result(Enum.all?(events, &event?(&1, workspace, cursor, page["scannedThrough"]))) do
      positions = Enum.map(events, & &1["position"])
      result(positions == Enum.sort(Enum.uniq(positions)))
    end
  end

  defp receipt?(page, cursor) do
    if page["scannedThrough"] == cursor,
      do: page["receipt"] == nil and page["events"] == [],
      else: Config.id?(page["receipt"])
  end

  defp page_positions?(page, cursor) do
    integer?(page["scannedThrough"]) and integer?(page["head"]) and
      page["scannedThrough"] >= cursor and page["scannedThrough"] <= page["head"] and
      page["scannedThrough"] - cursor <= 100
  end

  defp event?(event, workspace, cursor, through) when is_map(event) do
    event["version"] == 1 and event["workspaceId"] == workspace and Config.id?(event["eventId"]) and
      integer?(event["position"]) and event["position"] > cursor and event["position"] <= through and
      event_metadata?(event) and
      understood?(event)
  end

  defp event?(_, _, _, _), do: false

  defp event_metadata?(event) do
    is_boolean(event["broadcast"]) and integer?(event["acceptedAt"]) and integer?(event["publishedAt"]) and
      is_list(event["assigneeIds"]) and Enum.all?(event["assigneeIds"], &Config.id?/1)
  end

  # A resync signal is the versioned interpretation of an unknown upstream type.
  # Unknown events without that signal remain unacknowledged.
  defp understood?(%{"signal" => "resync_required"}), do: true

  defp understood?(%{"signal" => nil, "type" => type, "action" => action, "issueId" => issue} = event) do
    type in ["Issue", "Comment"] and action in ["create", "update", "remove"] and Config.id?(issue) and
      (type != "Comment" or Config.id?(event["commentId"]))
  end

  defp understood?(_), do: false

  @spec ack(map(), non_neg_integer()) :: :ok | {:error, atom()}
  def ack(response, through), do: result(response["version"] == 1 and response["cursor"] == through)

  defp integer?(n), do: is_integer(n) and n >= 0 and n <= @maximum
  defp positive?(n), do: integer?(n) and n > 0
  defp result(true), do: :ok
  defp result(false), do: {:error, :invalid_relay_response}
end
