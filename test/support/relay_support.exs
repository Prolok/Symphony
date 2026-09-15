defmodule SymphonyElixir.RelayFixture do
  @moduledoc false
  # Local implementation of the pinned transport envelopes. Deliberately has no
  # Linear credentials; it proves client behavior, not a deployed relay service.
  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{consumers: %{}, events: %{}, calls: [], faults: %{}} end)
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def request(server, workspace, consumer, operation, body) do
    Agent.get_and_update(server, fn state ->
      key = {workspace, consumer}
      state = %{state | calls: state.calls ++ [{workspace, consumer, operation, body}]}

      case Map.get(state.faults, {key, operation}, []) do
        [error | rest] -> {error, put_in(state.faults[{key, operation}], rest)}
        [] -> execute(state, key, operation, body)
      end
    end)
  end

  def fault(server, workspace, consumer, operation, error), do: Agent.update(server, &put_in(&1.faults[{{workspace, consumer}, operation}], [error]))
  def calls(server), do: Agent.get(server, & &1.calls)
  def consumer(server, workspace, consumer), do: Agent.get(server, & &1.consumers[{workspace, consumer}])
  def forget(server, workspace, consumer), do: Agent.update(server, &%{&1 | consumers: Map.delete(&1.consumers, {workspace, consumer})})

  def publish(server, workspace, attrs \\ %{}) do
    Agent.get_and_update(server, fn state ->
      events = Map.get(state.events, workspace, [])
      position = length(events) + 1

      event =
        Map.merge(
          %{
            "version" => 1,
            "eventId" => "event-#{position}",
            "workspaceId" => workspace,
            "position" => position,
            "type" => "Issue",
            "action" => "update",
            "sourceTime" => nil,
            "acceptedAt" => 1,
            "publishedAt" => 1,
            "issueId" => "issue",
            "commentId" => nil,
            "agentSessionId" => nil,
            "assigneeIds" => ["human"],
            "broadcast" => false,
            "signal" => nil,
            "payload" => %{}
          },
          attrs
        )

      {event, put_in(state.events[workspace], events ++ [event])}
    end)
  end

  def http(conn, server, keys) do
    [authorization] = Plug.Conn.get_req_header(conn, "authorization")
    workspace = Map.get(keys, String.replace_prefix(authorization, "Bearer ", ""))

    if workspace do
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      segments = String.split(conn.request_path, "/", trim: true)
      ["v1", "consumers", consumer | suffix] = segments

      op =
        case {conn.method, suffix} do
          {"PUT", []} -> :register
          {"GET", ["events"]} -> :poll
          {"POST", ["ack"]} -> :ack
          {"POST", ["resync"]} -> :resync
        end

      body = if bytes == "", do: nil, else: Jason.decode!(bytes)

      case request(server, workspace, consumer, op, body) do
        {:ok, body} -> Req.Test.json(conn, body)
        {:error, {:relay_http, status, error}} -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"version" => 1, "error" => error})
      end
    else
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"version" => 1, "error" => "unauthorized"})
    end
  end

  defp execute(state, {workspace, id} = key, :register, subscription) do
    old = state.consumers[key]
    consumer = if old && old.subscription == subscription, do: old, else: fresh(state, workspace, subscription)
    {{:ok, view(consumer, id)}, put_in(state.consumers[key], consumer)}
  end

  defp execute(state, key, operation, body) do
    case state.consumers[key] do
      nil -> {{:error, {:relay_http, 404, "not_found"}}, state}
      consumer -> operate(state, key, consumer, operation, body)
    end
  end

  defp operate(state, {workspace, id} = key, c, :resync, %{"phase" => "begin"}) do
    c = if c.ready, do: fresh(state, workspace, c.subscription), else: c
    {{:ok, view(c, id)}, put_in(state.consumers[key], c)}
  end

  defp operate(state, {_, id} = key, c, :resync, %{"phase" => "complete", "token" => token}) do
    if token == c.token do
      c = %{c | ready: true}
      {{:ok, view(c, id)}, put_in(state.consumers[key], c)}
    else
      {{:error, {:relay_http, 409, "invalid_generation"}}, state}
    end
  end

  defp operate(state, _key, %{ready: false}, _op, _body), do: {{:error, {:relay_http, 409, "snapshot_required"}}, state}

  defp operate(state, {workspace, _} = key, c, :poll, _) do
    events = Map.get(state.events, workspace, [])
    head = length(events)
    page = c.pending || begin_page(events, c, head)
    pending = if page["receipt"], do: page, else: nil
    {{:ok, page}, put_in(state.consumers[key], %{c | pending: pending})}
  end

  defp operate(state, key, c, :ack, %{"receipt" => receipt}) do
    cond do
      receipt in c.acks ->
        {{:ok, %{"version" => 1, "cursor" => c.cursor}}, state}

      c.pending && c.pending["receipt"] == receipt ->
        c = %{c | cursor: c.pending["scannedThrough"], pending: nil, acks: [receipt | c.acks]}
        {{:ok, %{"version" => 1, "cursor" => c.cursor}}, put_in(state.consumers[key], c)}

      true ->
        {{:error, {:relay_http, 409, "invalid_receipt"}}, state}
    end
  end

  defp begin_page(events, c, head) do
    through = min(c.cursor + 100, head)

    relevant =
      Enum.filter(events, fn e ->
        e["position"] > c.cursor and e["position"] <= through and
          (e["broadcast"] or c.subscription["assigneeIds"] == [] or Enum.any?(e["assigneeIds"], &(&1 in c.subscription["assigneeIds"])))
      end)

    %{
      "version" => 1,
      "generation" => c.generation,
      "events" => relevant,
      "receipt" => if(through > c.cursor, do: Ecto.UUID.generate(), else: nil),
      "scannedThrough" => through,
      "head" => head,
      "retentionMs" => 604_800_000
    }
  end

  defp fresh(state, workspace, subscription),
    do: %{subscription: subscription, generation: Ecto.UUID.generate(), token: Ecto.UUID.generate(), cursor: length(Map.get(state.events, workspace, [])), ready: false, pending: nil, acks: []}

  defp view(c, id),
    do: %{
      "version" => 1,
      "consumerId" => id,
      "subscription" => c.subscription,
      "generation" => c.generation,
      "cursor" => c.cursor,
      "status" => if(c.ready, do: "ready", else: "snapshot_required"),
      "snapshotToken" => c.token,
      "snapshotExpiresAt" => 86_400_000,
      "retentionMs" => 604_800_000
    }
end
