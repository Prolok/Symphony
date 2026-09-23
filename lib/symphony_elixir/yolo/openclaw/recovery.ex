defmodule SymphonyElixir.Yolo.OpenClaw.Recovery do
  @moduledoc "Fenced interruption recovery and operator import of original evidence; never a timeout-based release."
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.{OpenClaw, Operations, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, TerminalEvidence}
  @binding ~w(id group project_id agent linear_agent_id linear_workspace_id session_id payload_sha256 workspace sha members)

  @doc "Give up a new, fenced order after a fresh idle-session check; preserve the missing original outcome."
  @spec retire(map(), term(), module(), keyword()) :: {:ok, map()} | {:error, term()}
  def retire(order, response, adapter, opts) do
    if retirement_candidate?(order) and retirement_response?(response, order) and OpenClaw.enabled_for?(order) do
      Journal.transition(order, fn current -> retirement_changes(current, response, adapter, opts) end)
    else
      {:error, :openclaw_interruption_unresolved}
    end
  end

  defp retirement_response?(response, order), do: lost_result?(response, order) or match?({:terminal, _, _}, OpenClaw.terminal(response, order))

  defp retirement_candidate?(order) do
    order["interruption_contract"] == 1 and order["writable"] == false and
      order["cancel_requested"] == true and
      order["state"] in ~w(accepted unknown cancel_pending) and is_nil(order["terminal"])
  end

  defp lost_result?({:ok, %{"status" => "timeout"} = reply}, order) do
    reply["runId"] in [nil, order["id"]] and is_nil(reply["startedAt"]) and is_nil(reply["endedAt"]) and
      reply["yielded"] != true and reply["pendingError"] != true
  end

  defp lost_result?(_, _), do: false

  defp retirement_changes(%{"state" => state}, _response, _adapter, _opts) when state in ~w(completed failed cancelled rejected retired), do: {:ok, %{}}

  defp retirement_changes(current, response, adapter, opts) do
    read = Keyword.get(opts, :interruption_history, &adapter.history(&1, opts))

    with true <- retirement_candidate?(current),
         true <- current["project_id"] == ProjectContext.current().id and OpenClaw.enabled_for?(current),
         {:ok, history} <- read.(current),
         :ok <- idle_session(history, current),
         {:ok, stop_basis} <- stop_basis(current, response, history),
         {:ok, inputs} <- retained_inputs(history["pendingInputs"], current),
         {:ok, record} <- Store.read(current["group"]),
         %{"id" => id} = attempt <- record["attempt"],
         true <- id == current["id"] do
      proof = %{
        "kind" => "fenced_interruption",
        "stop_basis" => stop_basis,
        "retired_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "physical_session_id" => history["sessionId"],
        "last_run_id" => history["sessionInfo"]["lastRunId"],
        "history_sha256" => OpenClaw.digest(Jason.encode!(history)),
        "before_retirement" => Map.take(current, ~w(state error resumed cancel_requested abort_acknowledged)),
        "retained_inputs" => inputs,
        "attempt" => attempt,
        "deliveries" => Map.filter(record["deliveries"] || %{}, fn {_, receipt} -> receipt["run_id"] == id end)
      }

      changes = %{"state" => "retired", "writable" => false, "retirement" => proof, "error" => "openclaw_interrupted_order_retired"}

      case OpenClaw.terminal(response, current) do
        {:terminal, _, evidence} -> {:ok, Map.put(changes, "terminal", evidence)}
        :pending -> {:ok, changes}
      end
    else
      _ -> {:error, :openclaw_interruption_unresolved}
    end
  end

  defp stop_basis(%{"abort_acknowledged" => true}, _response, _history), do: {:ok, "abort_acknowledged"}

  defp stop_basis(order, response, history) do
    # A denied abort is never an acknowledgement. A naturally ended original
    # can still be retired, but only while that same run is freshly proven idle.
    case OpenClaw.terminal(response, order) do
      {:terminal, _, evidence} ->
        info = history["sessionInfo"]

        if info["lastRunId"] == order["id"] and info["endedAt"] == evidence["endedAt"] and
             (is_nil(evidence["startedAt"]) or info["startedAt"] == evidence["startedAt"]),
           do: {:ok, "terminal_original"},
           else: {:error, :openclaw_interruption_unresolved}

      :pending ->
        {:error, :openclaw_interruption_unresolved}
    end
  end

  defp idle_session(%{"sessionInfo" => info} = history, order) when is_map(info) do
    if session_identity?(history, info, order) and inactive?(history, info) and ended?(info),
      do: :ok,
      else: {:error, :openclaw_interruption_unresolved}
  end

  defp idle_session(_, _), do: {:error, :openclaw_interruption_unresolved}

  defp session_identity?(history, info, order) do
    physical = history["sessionId"]
    session = "agent:#{order["agent"]}:symphony:#{OpenClaw.digest(order["project_id"])}:#{order["group"]}:#{order["id"]}"

    history["sessionKey"] == session and order["session_id"] == session and info["key"] == session and
      is_binary(physical) and physical != "" and info["sessionId"] == physical
  end

  defp inactive?(history, info) do
    info["hasActiveRun"] == false and info["activeRunIds"] == [] and
      info["hasActiveSubagentRun"] in [nil, false] and info["subagentRunState"] in [nil, "historical"] and
      is_nil(history["inFlightRun"]) and
      Enum.all?([history, info], &(&1["yielded"] != true and &1["pendingError"] != true))
  end

  defp ended?(info) do
    started = info["startedAt"]
    ended = info["endedAt"]

    is_binary(info["lastRunId"]) and info["lastRunId"] != "" and info["status"] in ~w(done failed timeout killed) and
      is_integer(started) and is_integer(ended) and started > 0 and ended >= started and
      ended <= System.system_time(:millisecond)
  end

  defp retained_inputs(%{"items" => items, "total" => total} = page, order) when is_list(items) and is_integer(total) do
    # Only an exact copy of our original payload can be accounted for without
    # introducing a second inbox. Keep it on the host and retain its receipt.
    # Filtered/truncated pages, queued work and additional input require review.
    if total == length(items) and total <= 1 and is_nil(page["nextBefore"]) and Enum.all?(items, &original_input?(&1, order)) do
      {:ok, Enum.map(items, &(Map.take(&1, ~w(id runId state acceptedAt)) |> Map.put("payload_sha256", order["payload_sha256"])))}
    else
      {:error, :openclaw_interruption_input_unresolved}
    end
  end

  defp retained_inputs(_, _), do: {:error, :openclaw_interruption_input_unresolved}

  defp original_input?(%{"message" => %{"role" => "user", "content" => content}} = input, order) do
    text = input_text(content)

    is_binary(input["id"]) and input["id"] != "" and input["runId"] == order["id"] and input["state"] == "interrupted" and
      is_integer(input["acceptedAt"]) and input["acceptedAt"] > 0 and input["acceptedAt"] <= System.system_time(:millisecond) and
      is_binary(text) and OpenClaw.digest(text) == order["payload_sha256"]
  end

  defp original_input?(_, _), do: false
  defp input_text(text) when is_binary(text), do: text
  defp input_text([%{"type" => "text", "text" => text}]) when is_binary(text), do: text
  defp input_text(_), do: nil

  @spec resolve(map(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(evidence, apply? \\ false, opts \\ []) do
    with %{"binding" => %{"id" => id, "group" => group} = binding} <- evidence,
         true <- group in ~w(incoming planning in_progress blocker review),
         true <- binding["project_id"] == ProjectContext.current().id,
         {:ok, proof} <- proof(evidence, opts) do
      case Journal.transition(binding, &changes(&1, binding, proof, opts), apply?) do
        {:error, :openclaw_generation_changed} -> archived(group, id, proof)
        result -> result
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_recovery_evidence_invalid}
    end
  end

  defp archived(group, id, proof) do
    case Journal.history(group, id) do
      {:ok, %{"state" => state, "recovery" => ^proof} = previous} when state in ~w(rejected completed failed cancelled) -> {:ok, previous}
      _ -> {:error, :openclaw_generation_changed}
    end
  end

  defp changes(%{"state" => state, "recovery" => proof}, _binding, proof, _opts) when state in ~w(rejected completed failed cancelled), do: {:ok, %{}}

  defp changes(current, binding, %{"kind" => "terminal_original"} = proof, opts) do
    with true <- Map.take(current, @binding) == binding and Enum.sort(Map.keys(binding)) == Enum.sort(@binding),
         true <- current["state"] in ~w(unknown cancel_pending) and current["writable"] == false,
         true <- current["acceptance_observed"] == true and current["execution_observed"] == true,
         true <- is_nil(current["terminal"]),
         true <- fresh?(proof["checked_at"]),
         :ok <- no_active_run(current, opts),
         :ok <- TerminalEvidence.confirm(current, proof, opts),
         true <- fresh?(proof["checked_at"]) do
      {:ok,
       %{
         "state" => proof["terminal"]["state"],
         "terminal" => proof["terminal"],
         "writable" => false,
         "cancel_requested" => true,
         "error" => nil,
         "recovery" => proof,
         "before_recovery" => Map.take(current, ~w(state error cancel_requested abort_acknowledged))
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_recovery_conflict}
    end
  end

  defp changes(current, binding, proof, opts) do
    with true <- Map.take(current, @binding) == binding and Enum.sort(Map.keys(binding)) == Enum.sort(@binding),
         true <- current["state"] in ~w(unknown cancel_pending),
         true <- current["writable"] == false,
         true <- current["acceptance_observed"] != true and current["execution_observed"] != true,
         true <- is_nil(current["terminal"]) and is_nil(current["checkout_proof"]),
         :ok <- no_actions(current),
         :ok <- no_active_run(current, opts),
         true <- fresh?(proof["checked_at"]) do
      {:ok,
       %{
         "state" => "rejected",
         "writable" => false,
         "error" => "openclaw_pre_acceptance_rejected",
         "rejection" => Map.take(proof, ~w(code reason request_id source_sha256)),
         "recovery" => proof,
         "before_recovery" => Map.take(current, ~w(state error cancel_requested abort_acknowledged))
       }}
    else
      _ -> {:error, :openclaw_recovery_conflict}
    end
  end

  defp no_active_run(order, opts) do
    status = Keyword.get(opts, :status, &gateway_status/1)

    case status.(order) do
      {:ok, %{"status" => "timeout"} = reply} ->
        if reply["runId"] in [nil, order["id"]] and is_nil(reply["startedAt"]) and is_nil(reply["endedAt"]) and
             reply["yielded"] != true and reply["pendingError"] != true,
           do: :ok,
           else: {:error, :openclaw_recovery_active_or_foreign_run}

      _ ->
        {:error, :openclaw_recovery_active_or_foreign_run}
    end
  end

  defp gateway_status(order) do
    with :ok <- Gateway.preflight(order["agent"], []), do: Gateway.status(order, [])
  end

  defp no_actions(order) do
    # Use the original Linear agent's journal even after a configuration change.
    context = %{ProjectContext.current() | yolo_agent_id: order["linear_agent_id"]}

    ProjectContext.with_context(context, fn ->
      with {:ok, record} <- Store.read(order["group"]),
           true <- empty_attempt?(record["attempt"], order["id"]),
           {:ok, []} <- Operations.related(Enum.map(order["members"], & &1["id"])) do
        :ok
      else
        _ -> {:error, :openclaw_recovery_action_conflict}
      end
    end)
  end

  defp empty_attempt?(%{"id" => id} = attempt, id), do: (attempt["completed"] || %{}) == %{} and is_nil(attempt["session_id"])
  defp empty_attempt?(_, _), do: false

  defp proof(%{"version" => 2} = evidence, opts), do: TerminalEvidence.proof(evidence, opts)

  defp proof(%{"version" => 1} = evidence, _opts) do
    binding = evidence["binding"]

    with %{"request_id" => request_id, "method" => "agent", "run_id" => run_id, "session_id" => session} <- evidence["request"],
         true <- is_binary(request_id) and Regex.match?(~r/^[a-zA-Z0-9_:-]{8,128}$/, request_id),
         true <- run_id == binding["id"] and session == binding["session_id"] and evidence["request"]["agent"] == binding["agent"],
         true <- evidence["request"]["payload_sha256"] == binding["payload_sha256"] and evidence["request"]["cwd"] == binding["workspace"],
         %{"request_id" => ^request_id, "phase" => "pre_acceptance", "code" => "INVALID_REQUEST", "reason" => "cwd_reserved"} <- evidence["response"],
         "2026.9.4" <- evidence["gateway_version"],
         %{"run_id" => ^run_id, "session_id" => ^session, "no_active_or_foreign_execution" => true, "basis" => "correlated_original_rejection", "checked_at" => checked} <- evidence["execution_check"],
         true <- digest?(evidence["source_sha256"]) and digest?(evidence["execution_source_sha256"]),
         reviewer when is_binary(reviewer) <- evidence["reviewer"],
         true <- Regex.match?(~r/^[\p{L}\p{N}_.@-]{1,128}$/u, reviewer) do
      {:ok,
       %{
         "evidence_sha256" => OpenClaw.digest(Jason.encode!(evidence)),
         "source_sha256" => evidence["source_sha256"],
         "execution_source_sha256" => evidence["execution_source_sha256"],
         "request_id" => request_id,
         "code" => "INVALID_REQUEST",
         "reason" => "cwd_reserved",
         "gateway_version" => "2026.9.4",
         "checked_at" => checked,
         "reviewer" => reviewer
       }}
    else
      _ -> {:error, :openclaw_recovery_evidence_invalid}
    end
  end

  defp proof(_, _), do: {:error, :openclaw_recovery_evidence_invalid}

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp fresh?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.diff(DateTime.utc_now(), time) in 0..300
      _ -> false
    end
  end

  defp fresh?(_), do: false
end
