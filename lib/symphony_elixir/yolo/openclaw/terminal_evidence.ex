defmodule SymphonyElixir.Yolo.OpenClaw.TerminalEvidence do
  @moduledoc "Operator-reviewed original history; public projections alone cannot establish an old physical session binding."
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Gateway
  @limit 1_048_576
  @states %{"done" => "completed", "failed" => "failed", "timeout" => "failed", "killed" => "cancelled"}

  @spec proof(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def proof(evidence, opts) do
    with %{"version" => 2, "kind" => "terminal_original", "gateway_version" => "2026.9.4", "binding" => binding} <- evidence,
         true <- identifier?(evidence["reviewer"]),
         true <- identifier?(evidence["physical_session_id"]) and identifier?(evidence["message_id"]),
         {:ok, original} <- source(evidence, opts, "source"),
         {:ok, check} <- source(evidence, opts, "execution_source"),
         {:ok, terminal} <- history(original, binding, evidence),
         {:ok, ^terminal} <- history(check, binding, evidence) do
      {:ok,
       evidence
       |> Map.take(~w(kind gateway_version physical_session_id message_id source_sha256 execution_source_sha256 reviewer checked_at))
       |> Map.merge(%{"evidence_sha256" => OpenClaw.digest(Jason.encode!(evidence)), "terminal" => terminal})}
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_terminal_evidence_invalid}
    end
  end

  defp source(evidence, opts, key) do
    with bytes when is_binary(bytes) and byte_size(bytes) <= @limit <- get_in(opts[:sources] || %{}, [key]),
         true <- OpenClaw.digest(bytes) == evidence[key <> "_sha256"],
         {:ok, value} when is_map(value) <- Jason.decode(bytes) do
      {:ok, value}
    else
      _ -> {:error, :openclaw_terminal_source_invalid}
    end
  end

  @spec confirm(map(), map(), keyword()) :: :ok | {:error, atom()}
  def confirm(order, proof, opts) do
    read = Keyword.get(opts, :history, &Gateway.history(&1, []))

    with {:ok, reply} <- read.(order),
         {:ok, terminal} <- history(reply, order, proof),
         true <- terminal == proof["terminal"] do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :openclaw_terminal_counterproof_conflict}
    end
  end

  defp history(%{"sessionInfo" => info, "messages" => messages} = reply, order, proof) when is_map(info) and is_list(messages) do
    with :ok <- identity(reply, info, order, proof),
         :ok <- complete(reply, messages),
         :ok <- inactive(reply, info),
         {:ok, terminal} <- lifecycle(info, order),
         {:ok, record} <- terminal_record(messages, order, proof) do
      {:ok, Map.merge(terminal, record)}
    end
  end

  defp history(_, _, _), do: {:error, :openclaw_terminal_history_missing}

  defp identity(reply, info, order, proof) do
    session = order["session_id"]

    if is_binary(session) and is_binary(order["agent"]) and String.starts_with?(session, "agent:#{order["agent"]}:") and
         reply["sessionKey"] == session and info["key"] == session and
         reply["sessionId"] == proof["physical_session_id"] and info["sessionId"] == reply["sessionId"] and
         info["lastRunId"] == order["id"],
       do: :ok,
       else: {:error, :openclaw_terminal_identity_mismatch}
  end

  defp complete(reply, messages) do
    if reply["offset"] == 0 and reply["hasMore"] == false and reply["totalMessages"] == length(messages) and messages != [],
      do: :ok,
      else: {:error, :openclaw_terminal_history_incomplete}
  end

  defp inactive(reply, info) do
    # In 2026.9.4 inFlightRun and hasActiveSubagentRun are deliberately omitted
    # when absent. hasActiveRun and the complete activeRunIds set are required.
    if info["hasActiveRun"] == false and info["activeRunIds"] == [] and
         info["hasActiveSubagentRun"] in [nil, false] and info["subagentRunState"] in [nil, "historical"] and
         is_nil(reply["inFlightRun"]) and
         match?(%{"items" => [], "total" => 0}, reply["pendingInputs"]) and
         Enum.all?([reply, info], &(&1["yielded"] != true and &1["pendingError"] != true)),
       do: :ok,
       else: {:error, :openclaw_terminal_activity_conflict}
  end

  defp lifecycle(info, order) do
    started = info["startedAt"]
    ended = info["endedAt"]

    if is_map_key(@states, info["status"]) and (info["abortedLastRun"] != true or info["status"] == "killed") and
         is_integer(started) and is_integer(ended) and
         started > 0 and ended >= started and ended <= System.system_time(:millisecond) do
      {:ok, %{"runId" => order["id"], "status" => info["status"], "state" => @states[info["status"]], "startedAt" => started, "endedAt" => ended}}
    else
      {:error, :openclaw_terminal_end_missing}
    end
  end

  defp terminal_record(messages, order, proof) do
    with %{"role" => "assistant", "__openclaw" => %{"id" => id} = meta} <- List.last(messages),
         true <- id == proof["message_id"],
         true <- meta["runId"] == order["id"] and meta["runTerminal"] == true and meta["mirrorOrigin"] == "codex-app-server",
         true <- identifier?(meta["mirrorIdentity"]) and fingerprint?(meta["mirrorSourceFingerprint"]),
         true <- meta["yielded"] != true and meta["pendingError"] != true,
         true <- Enum.count(messages, &(message_id(&1) == id)) == 1,
         true <- Enum.count(messages, &terminal_for?(&1, order["id"])) == 1 do
      {:ok,
       %{
         "source" => "operator_terminal_original",
         "messageId" => id,
         "physicalSessionId" => proof["physical_session_id"],
         "mirrorIdentity" => meta["mirrorIdentity"],
         "mirrorSourceFingerprint" => meta["mirrorSourceFingerprint"],
         "message_sha256" => OpenClaw.digest(Jason.encode!(List.last(messages)))
       }}
    else
      _ -> {:error, :openclaw_terminal_record_invalid}
    end
  end

  defp message_id(%{"__openclaw" => %{"id" => id}}), do: id
  defp message_id(_), do: nil

  defp terminal_for?(%{"__openclaw" => %{"runId" => id, "runTerminal" => true}}, id), do: true
  defp terminal_for?(_, _), do: false

  defp identifier?(value), do: is_binary(value) and Regex.match?(~r/^[\p{L}\p{N}_.@:-]{1,256}$/u, value)
  defp fingerprint?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{32}$/, value)
end
