defmodule SymphonyElixir.Yolo.OpenClaw.Recovery do
  @moduledoc "Operator-only import of correlated rejection or terminal originals; never a timeout-based release."
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.{OpenClaw, Operations, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, TerminalEvidence}
  @binding ~w(id group project_id agent linear_agent_id linear_workspace_id session_id payload_sha256 workspace sha members)

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
