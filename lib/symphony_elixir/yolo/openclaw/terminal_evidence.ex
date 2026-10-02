defmodule SymphonyElixir.Yolo.OpenClaw.TerminalEvidence do
  @moduledoc "Shared original transcript checks and strictly bound operator terminal imports."
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
         :ok <- operator_inactive(reply, info),
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

  defp complete(reply, messages, snapshot? \\ false) do
    with false <- reply["hasMore"],
         nil <- reply["nextOffset"],
         true <- reply["truncated"] in [nil, false],
         [_ | _] <- messages,
         true <- Enum.all?(messages, &untruncated?/1),
         true <-
           (reply["offset"] == 0 and reply["totalMessages"] == length(messages)) or
             (snapshot? and reply["completeSnapshot"] == true and reply["offset"] in [nil, 0]),
         do: :ok,
         else: (_ -> {:error, :openclaw_terminal_history_incomplete})
  end

  defp untruncated?(message),
    do: is_map(message) and is_map(message["__openclaw"] || %{}) and get_in(message, ["__openclaw", "truncated"]) in [nil, false]

  defp operator_inactive(reply, info) do
    idle? = inactive?(reply, info) and match?(%{"items" => [], "total" => 0}, reply["pendingInputs"])
    if idle?, do: :ok, else: {:error, :openclaw_terminal_activity_conflict}
  end

  @spec inactive?(map(), map()) :: boolean()
  def inactive?(reply, info) do
    # In 2026.9.4 inFlightRun and hasActiveSubagentRun are deliberately omitted
    # when absent. hasActiveRun and the complete activeRunIds set are required.
    info["hasActiveRun"] == false and info["activeRunIds"] == [] and is_nil(info["lifecycleRunId"]) and
      info["hasActiveSubagentRun"] in [nil, false] and info["subagentRunState"] in [nil, "historical"] and is_nil(reply["inFlightRun"]) and
      Enum.all?([reply, info], &(&1["yielded"] in [nil, false] and &1["pendingError"] in [nil, false]))
  end

  @spec ended?(map()) :: boolean()
  def ended?(info) do
    is_binary(info["lastRunId"]) and info["lastRunId"] != "" and is_map_key(@states, info["status"]) and
      (info["abortedLastRun"] != true or info["status"] == "killed") and plausible_times?(info["startedAt"], info["endedAt"])
  end

  defp lifecycle(info, order) do
    if ended?(info) do
      {:ok, Map.merge(Map.take(info, ~w(status startedAt endedAt)), %{"runId" => order["id"], "state" => @states[info["status"]]})}
    else
      {:error, :openclaw_terminal_end_missing}
    end
  end

  defp terminal_record(messages, order, proof) do
    with {:ok, %{"__openclaw" => %{"id" => id, "mirrorOrigin" => "codex-app-server", "runId" => run_id} = meta} = record} <- terminal_message(messages, order["id"]),
         true <- run_id == order["id"] and id == proof["message_id"] and record == List.last(messages),
         true <- Enum.count(messages, &(get_in(&1, ["__openclaw", "id"]) == id)) == 1 do
      {:ok,
       Map.merge(Map.take(meta, ~w(mirrorIdentity mirrorSourceFingerprint)), %{
         "source" => "operator_terminal_original",
         "messageId" => id,
         "physicalSessionId" => proof["physical_session_id"],
         "message_sha256" => OpenClaw.digest(Jason.encode!(record))
       })}
    else
      _ -> {:error, :openclaw_terminal_record_invalid}
    end
  end

  @doc "Return only a unique original answer's timestamp from complete history, not a run result."
  @spec original_end(map(), String.t()) :: pos_integer() | nil
  def original_end(%{"messages" => messages} = history, run_id) when is_list(messages) do
    with :ok <- complete(history, messages, true),
         {:ok, %{"timestamp" => timestamp}} <- terminal_message(messages, run_id),
         true <- plausible_times?(timestamp, timestamp) do
      timestamp
    else
      _ -> nil
    end
  end

  def original_end(_, _), do: nil

  defp terminal_message(messages, run_id) do
    candidates =
      Enum.filter(messages, fn message ->
        meta = message["__openclaw"] || %{}
        (meta["runId"] == run_id and meta["runTerminal"] == true) or meta["idempotencyKey"] == "cli-assistant:" <> run_id
      end)

    with [%{"role" => "assistant", "__openclaw" => meta} = message] <- candidates,
         true <- Enum.all?([message, meta], &(&1["yielded"] in [nil, false] and &1["pendingError"] in [nil, false])),
         true <- is_nil(message["openclawStreamFallback"]) or (is_map(message["openclawStreamFallback"]) and message["openclawStreamFallback"]["source"] != "segment"),
         true <- terminal_marker?(message, meta, run_id) do
      {:ok, message}
    else
      _ -> {:error, :openclaw_terminal_record_invalid}
    end
  end

  defp terminal_marker?(_message, %{"runId" => run_id} = meta, run_id),
    do: meta["runTerminal"] == true and meta["mirrorOrigin"] == "codex-app-server" and identifier?(meta["mirrorIdentity"]) and fingerprint?(meta["mirrorSourceFingerprint"])

  defp terminal_marker?(message, meta, run_id), do: meta["idempotencyKey"] == "cli-assistant:" <> run_id and message["stopReason"] in ~w(stop aborted) and is_nil(meta["runId"])

  @spec plausible_times?(term(), term()) :: boolean()
  def plausible_times?(started, ended), do: is_integer(started) and is_integer(ended) and started > 0 and ended >= started and ended <= System.system_time(:millisecond)

  defp identifier?(value), do: is_binary(value) and Regex.match?(~r/^[\p{L}\p{N}_.@:-]{1,256}$/u, value)
  defp fingerprint?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{32}$/, value)
end
