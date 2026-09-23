defmodule SymphonyElixir.TestRun.OpenClawInterruption do
  @moduledoc "One owned live interruption in the existing isolated incoming proof."
  alias SymphonyElixir.{Config, ProjectContext, TestInstance}
  alias SymphonyElixir.Linear.{Client, DurableState, IssueLease}
  alias SymphonyElixir.TestRun.PoIncoming
  alias SymphonyElixir.Yolo.{OpenClaw, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal}

  @fields ~w(id group project_id agent session_id payload_sha256 workspace sha members state writable interruption_contract acceptance_observed checkout_proof terminal retirement abort_acknowledged abort_error)

  @spec execute([ProjectContext.t()], map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(contexts, plan, journal, opts \\ []) do
    with %{"source" => source} <- Config.test_instance(),
         true <- source == plan["source"] and plan["scenario"] == "po_incoming" and plan["openclaw_interruption"] == true,
         [%{name: "symphony-test"} = context] <- contexts,
         {:ok, [verified]} <- Client.resolve_relay_contexts([context]) do
      ProjectContext.with_context(verified, fn -> execute_verified(plan, journal, opts) end)
    else
      {:error, _} = error -> error
      _ -> {:error, :test_interruption_unbound}
    end
  end

  defp execute_verified(plan, journal, opts) do
    if is_binary(plan["openclaw_agent"]) and Config.openclaw_yolo_agent() == plan["openclaw_agent"] do
      IssueLease.with_journal_lock(path(plan), fn -> execute_bound(plan, journal, opts) end)
    else
      {:error, :test_interruption_agent_mismatch}
    end
  end

  defp execute_bound(plan, journal, opts) do
    case DurableState.read(path(plan)) do
      {:error, :enoent} -> prepare(plan, journal, opts)
      {:ok, receipt} -> resume(plan, receipt)
      error -> error
    end
  end

  defp prepare(plan, journal, opts) do
    fixtures = Enum.filter(journal["fixtures"], &(&1["po_interruption"] == true))
    first = Enum.find(fixtures, &(&1["initial_state"] == "Backlog"))

    with true <- length(fixtures) == 3 and first != nil,
         {:ok, order} <- Journal.read("incoming"),
         {:ok, record} <- Store.read("incoming") do
      if first["observed_state"] == "Verworfen" and is_map(order) and is_binary(get_in(record, ["attempt", "completed", first["id"]])) do
        prepare_order(plan, fixtures, first, order, opts)
      else
        {:ok, %{"interruption" => %{"state" => "waiting_for_first_decision"}}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :test_interruption_fixtures_unconfirmed}
    end
  end

  defp prepare_order(plan, fixtures, first, order, opts) do
    # Tool dispatch shares this lock. Snapshot the completed action and revoke
    # authority together; no in-flight authorized write can cross the fence.
    with {:ok, _} <- Journal.transition(order, fn current -> fence(plan, fixtures, first, current, opts) end),
         {:ok, receipt} <- DurableState.read(path(plan)) do
      resume(plan, receipt)
    end
  end

  defp fence(plan, fixtures, first, order, opts) do
    ids = Enum.sort(Enum.map(fixtures, & &1["id"]))
    history = Keyword.get(opts, :history, &Gateway.history(&1, []))

    with true <- order["project_id"] == ProjectContext.current().id and OpenClaw.enabled_for?(order),
         true <- order["interruption_contract"] == 1 and order["acceptance_observed"] == true and order["writable"] == true and Journal.pending?(order),
         true <- Enum.sort(Enum.map(order["members"], & &1["id"])) == ids,
         %{"id" => id, "clean" => true} <- order["checkout_proof"],
         true <- id == order["id"],
         {:ok, %{"attempt" => %{"id" => ^id, "completed" => completed} = attempt}} when is_map(completed) <- Store.read("incoming"),
         true <- Map.keys(completed) == [first["id"]],
         {:ok, active} <- history.(order),
         true <- active_original?(active, order),
         receipt = %{
           "source" => plan["source"],
           "run_id" => plan["run_id"],
           "first_id" => first["id"],
           "before" => Map.take(order, @fields),
           "attempt" => attempt,
           "active" => Map.take(active["sessionInfo"], ~w(key sessionId status lastRunId hasActiveRun activeRunIds observerDigest)),
           "active_checked_at" => DateTime.to_iso8601(DateTime.utc_now())
         },
         :ok <- DurableState.write(path(plan), receipt) do
      {:ok, %{"writable" => false, "cancel_requested" => true}}
    else
      {:error, _} = error -> error
      _ -> {:error, :test_interruption_original_not_active_or_bound}
    end
  end

  defp active_original?(%{"sessionInfo" => info} = history, order) when is_map(info) do
    history["sessionKey"] == order["session_id"] and info["key"] == order["session_id"] and
      is_binary(history["sessionId"]) and history["sessionId"] != "" and info["sessionId"] == history["sessionId"] and
      info["hasActiveRun"] == true and Map.get(info, "status", "running") == "running" and
      active_run_identity?(info, order["id"]) and
      optional_run_identity?(history["inFlightRun"], order["id"])
  end

  defp active_original?(_, _), do: false

  defp active_run_identity?(info, id) do
    # Embedded runs need not have a visible chat-abort controller. Their
    # current observer digest supplies identity, not an inferred empty run set.
    controller = info["lastRunId"] == id and info["activeRunIds"] == [id]
    embedded = info["status"] == "running" and run_identity(info["observerDigest"]) == id

    (controller or embedded) and Map.get(info, "lastRunId", id) == id and
      Map.get(info, "activeRunIds", [id]) == [id] and
      optional_run_identity?(info["observerDigest"], id)
  end

  defp optional_run_identity?(nil, _id), do: true
  defp optional_run_identity?(value, id), do: run_identity(value) == id
  defp run_identity(%{"runId" => id}), do: id
  defp run_identity(_), do: nil

  defp resume(plan, receipt) do
    with true <- receipt["source"] == plan["source"] and receipt["run_id"] == plan["run_id"],
         {:ok, current} when is_map(current) <- Journal.read("incoming"),
         {:ok, original} <- original(current, receipt["before"]),
         {:ok, generations} <- generations(receipt["before"], current),
         {:ok, record} <- Store.read("incoming") do
      # If interrupted between durable intent and revocation, retry ONLY this
      # generation. A later generation must never receive the test cancellation.
      with {:ok, original} <- revoke_original(current, original) do
        result = Map.merge(receipt, %{"original" => Map.take(original, @fields), "current" => Map.take(current, @fields), "current_attempt" => record["attempt"], "generation_ids" => generations})
        {:ok, %{"interruption" => result}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :test_interruption_receipt_mismatch}
    end
  end

  defp generations(before, current) do
    ids = Enum.map(before["members"], & &1["id"])

    Path.wildcard(Path.join(Journal.path("incoming") <> ".history", "*.json"))
    |> Enum.reduce_while({:ok, [current["id"]]}, fn path, {:ok, found} ->
      case DurableState.read(path) do
        {:ok, %{"id" => id, "members" => members}} when is_list(members) ->
          matches = Enum.any?(members, &(&1["id"] in ids))
          {:cont, {:ok, if(matches, do: [id | found], else: found)}}

        _ ->
          {:halt, {:error, :test_interruption_history_unconfirmed}}
      end
    end)
  end

  defp original(%{"id" => id} = current, %{"id" => id}), do: {:ok, current}
  defp original(_current, before), do: Journal.history("incoming", before["id"])

  defp revoke_original(%{"id" => id}, %{"id" => id} = original) do
    Journal.update(original, %{"writable" => false, "cancel_requested" => true})
  end

  defp revoke_original(_current, original), do: {:ok, original}

  @spec probe(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def probe(issue, %{"po_interruption" => true, "initial_state" => "Backlog"} = fixture, plan) do
    case DurableState.read(path(plan)) do
      {:ok, %{"source" => source, "first_id" => id} = receipt} ->
        if source == plan["source"] and id == fixture["id"] and receipt["run_id"] == plan["run_id"] do
          probe_decision(issue, fixture, receipt)
        else
          {:error, :test_interruption_receipt_mismatch}
        end

      {:error, :enoent} ->
        {:ok, fixture}

      _ ->
        {:error, :test_interruption_receipt_mismatch}
    end
  end

  def probe(_issue, fixture, _plan), do: {:ok, fixture}

  defp probe_decision(issue, fixture, receipt) do
    # The archive supplies only the original execution binding. Success
    # still requires fresh issue conditions, including after a prior pass.
    if PoIncoming.decision_confirmed?(issue, fixture, receipt["attempt"]["completed"] || %{}) do
      before = receipt["before"]
      proof = %{"session_id" => before["session_id"], "sha" => before["sha"], "workspace" => before["workspace"]}
      {:ok, Map.put(fixture, "po_receipt", proof)}
    else
      {:ok, Map.delete(fixture, "po_receipt")}
    end
  end

  defp path(plan), do: Path.join([TestInstance.state_root(), "runs", plan["run_id"], "openclaw-interruption.json"])
end
