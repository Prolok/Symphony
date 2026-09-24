defmodule SymphonyElixir.Yolo.OpenClaw do
  @moduledoc "Durable external PO execution; uncertain acceptance never authorizes another submission."
  require Logger
  alias SymphonyElixir.{Config, PathSafety, ProjectContext}
  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal, OwnerTransport, Recovery, ToolBridge}
  alias SymphonyElixir.Yolo.Scope

  @spec run(map(), String.t(), [map()], String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issues, run_id, opts) do
    adapter = Keyword.get(opts, :openclaw_adapter, Gateway)
    agent = Config.openclaw_yolo_agent()
    group = Scope.current()["group"]
    order = order(group, agent, workspace, issues, run_id, opts)
    result = OwnerTransport.within(fn -> start(order, prompt, adapter, opts) end)
    log_failure(result, order, opts)
    result
  end

  defp start(order, prompt, adapter, opts) do
    with true <- is_binary(Config.yolo_agent_id()),
         :ok <- Journal.available(order["group"]),
         :ok <- adapter.preflight(order["agent"], opts),
         {:ok, directory} <- artifacts(order["id"]),
         {:ok, bridge} <- ToolBridge.start(order, directory, Keyword.get(opts, :tool_opts, [])) do
      try do
        submit(order, bridge, prompt, adapter, opts)
      after
        ToolBridge.stop(bridge)
      end
    else
      false -> {:error, :openclaw_requires_verified_linear_yolo_agent}
      {:error, _} = error -> error
    end
  end

  defp log_failure({:error, reason}, order, opts) do
    code = if is_atom(reason), do: Atom.to_string(reason), else: "openclaw_local_error"
    id = order["id"]

    current =
      case Journal.read(order["group"]) do
        {:ok, %{"id" => ^id} = current} -> current
        _ -> Map.put(order, "state", "local_error")
      end

    event(Map.put(current, "error", code), :failed, opts)
  end

  defp log_failure(_, _, _), do: :ok

  defp artifacts(run_id) do
    with {:ok, _} <- Ecto.UUID.cast(run_id),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         path = Path.join([root, "yolo-runs", run_id]),
         {:ok, ^path} <- PathSafety.canonicalize(path) do
      {:ok, path}
    else
      _ -> {:error, :openclaw_artifact_path_invalid}
    end
  end

  defp order(group, agent, workspace, issues, run_id, opts) do
    project = ProjectContext.current()
    project_key = digest(project.id)
    timeout = Keyword.get(opts, :openclaw_timeout_seconds, 3600)

    %{
      "id" => run_id,
      "group" => group,
      "agent" => agent,
      "session_id" => "agent:#{agent}:symphony:#{project_key}:#{group}:#{run_id}",
      "project_id" => project.id,
      "linear_agent_id" => Config.yolo_agent_id(),
      "linear_workspace_id" => Config.settings!().tracker.app["workspace_id"],
      "workspace" => workspace.path,
      "sha" => workspace.sha,
      "members" => Enum.map(issues, &%{"id" => &1.id, "identifier" => &1.identifier, "state" => &1.state}),
      "state" => "intent",
      "writable" => true,
      "execution" => "openclaw",
      "interruption_contract" => 1,
      "timeout_seconds" => timeout,
      "deadline" => System.system_time(:millisecond) + timeout * 1000
    }
  end

  defp submit(order, bridge, prompt, adapter, opts) do
    payload = prompt <> tool_instructions(bridge, order)
    order = Map.put(order, "payload_sha256", digest(payload))

    with :ok <- File.write(Path.join(Path.dirname(bridge.descriptor), "request.md"), payload),
         :ok <- Journal.write(order),
         :ok <- Keyword.get(opts, :before_delivery, fn -> :ok end).() do
      event(order, :submitted, opts)
      # The intent is durable BEFORE invoking any external submission. Even a
      # transport failure leaves this exact run reserved until terminal proof.
      changes = acceptance(adapter.submit(order, payload, opts), order)

      if changes["state"] == "rejected", do: Keyword.get(opts, :delivery_rejected, fn -> :ok end).()

      with {:ok, order} <- Journal.update(order, changes) do
        event(order, :acceptance, opts)
        await(order, adapter, opts)
      end
    end
  end

  defp acceptance({:ok, %{"runId" => id, "status" => "accepted"}}, %{"id" => id}), do: %{"state" => "accepted", "acceptance_observed" => true}

  defp acceptance({:rejected, %{"method" => "agent", "phase" => "pre_acceptance", "code" => "INVALID_REQUEST", "reason" => reason} = proof}, order)
       when reason in ~w(cwd_reserved cwd_not_absolute) do
    proof = Map.take(proof, ~w(method phase code reason request_sha256))
    proof = Map.merge(proof, Map.take(order, ~w(id session_id agent payload_sha256)))
    %{"state" => "rejected", "writable" => false, "error" => "openclaw_pre_acceptance_rejected", "rejection" => proof}
  end

  defp acceptance(_, _), do: %{"state" => "unknown", "writable" => false, "error" => "openclaw_acceptance_unconfirmed"}

  defp tool_instructions(bridge, order) do
    """


    ## OpenClaw-Auftrag #{order["id"]}

    Nutze deinen vorhandenen Agentenkontext und freigegebene Wissensquellen.
    Dieser Workflow und der gebundene versionierte Projekt-Skill bestimmen Ablauf und Prüfmaßstab.
    Memory ersetzt weder sym-yolo-review noch Prüfbelege. Verwende für Review die
    Übergabe mit review.binding, Prüfungen, Findings/Lernentscheidungen und Einschränkungen.
    Bei widersprechenden Agentenanweisungen
    keine konkurrierende Steuerung starten; den Widerspruch als Fehler melden.
    LinearBridge-Mentions sind Beratung, keine Freigabe oder zweite Ausführung.
    Der Produktprüfstand bleibt #{order["workspace"]} (SHA #{order["sha"]});
    halte ihn unverändert und führe gebundene Tools ausschließlich dort aus.
    Dein Wissensworkspace ist kein Prüfstand. Keine weiteren Agents starten.
    Übernimm erforderliche Betreiberprüfungen selbst, soweit dein vorhandener
    Agentenauftrag die Testumgebung und bestehenden Zugänge bereits freigibt.
    Dazu darfst du außerhalb des Prüfcheckouts isolierte Testbereitstellung und
    deren bestehende Betreiberwerkzeuge nutzen; Quellstand, Testprojekt, eigene
    Fixtures und Rückfallbestand vorher bestätigen. Keine fremde Arbeit ändern.
    Fehlende lokale Bereitstellung oder ein eingeschränktes Workerwerkzeug ist
    allein kein menschlicher Blocker. Prüfe und nutze den autorisierten Betreiberweg
    vollständig, dokumentiere Belege und setze den gebundenen Ticketlauf fort.
    Erst strategische Produktentscheidungen oder danach nicht autonom behebbare
    Hindernisse (etwa wirklich fehlende Zugangsdaten) an den Menschen eskalieren.
    Keine Rechte erweitern, keine produktiven Dienste ungefragt umstellen und
    keine laufgebundene Zugriffssperre durch einen anderen Zugang umgehen.

    Die vorhandenen Symphony-MCP-Werkzeuge sind über diesen laufgebundenen Helfer
    tatsächlich erreichbar. Nutze dein lokales exec-Werkzeug mit Arbeitsverzeichnis
    #{shell_quote(order["workspace"])} oder führe exakt aus:
    cd -- #{shell_quote(order["workspace"])} && python3 #{shell_quote(bridge.helper)} #{shell_quote(bridge.descriptor)}
    Der Helfer misst sein reales Arbeitsverzeichnis, Git-Root, SHA und sauberen
    Stand bei jedem Aufruf; Symphony prüft diese vor dem Werkzeugzugriff erneut.
    Referenzierte Prüfanweisungen mit absoluten Pfaden aus diesem Checkout lesen.
    Übergib jeweils genau eine JSON-RPC-Anfrage über stdin, zuerst
    {"jsonrpc":"2.0","id":1,"method":"tools/list"}.
    Aufrufe: {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"TOOL","arguments":{}}}.
    Keine Ersatzbindung, keine direkten Linear-Zugänge. Bei verweigerter Bindung
    sofort stoppen. Keine Credentials oder den Inhalt der Bindungsdatei ausgeben.
    Nutze symphony_yolo_complete für jede tatsächlich abgeschlossene Entscheidung, außer nach erfolgreichem handoff/wait/escalate: diese bestätigen das Mitglied bereits intern; kein zweiter Abschlussaufruf.
    Der Abschlussbericht nennt Lauf-ID, betroffene Tickets, Entscheidungen,
    tatsächlich ausgeführte Aktionen und Prüfbelege; offene Arbeit bleibt offen.
    """
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  @spec recover(map(), keyword()) :: term()
  def recover(order, opts \\ []) do
    # A recovered run cannot inherit write authority from an earlier BEAM or
    # bridge. Keep group/member leases until a confirmed external terminal.
    lock = Keyword.get(opts, :recovery_lock, &IssueLease.with_lock/3)

    lock.("symphony-openclaw", Journal.path(order["group"]), fn -> recover_locked(order, opts) end)
  end

  defp recover_locked(order, opts) do
    hold_members(order["members"], order, opts, fn ->
      with {:ok, current} <- Journal.update(order, %{"writable" => false, "cancel_requested" => true, "resumed" => true}) do
        event(current, :recovered, opts)
        await(current, Keyword.get(opts, :openclaw_adapter, Gateway), opts)
      end
    end)
  end

  @doc "One terminal reconciliation for an already fenced order; no abort, submission or polling loop."
  @spec reconcile_terminal(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_terminal(order, opts \\ []) do
    IssueLease.with_lock("symphony-openclaw", Journal.path(order["group"]), fn ->
      hold_members(order["members"], order, opts, fn ->
        reconcile_terminal_locked(order, opts)
      end)
    end)
  end

  defp reconcile_terminal_locked(order, opts) do
    adapter = Keyword.get(opts, :openclaw_adapter, Gateway)

    with {:ok, %{"id" => id, "writable" => false, "cancel_requested" => true} = current} <- Journal.read(order["group"]),
         true <- id == order["id"] and current["project_id"] == ProjectContext.current().id and enabled_for?(current),
         true <- current["interruption_contract"] == 1 and Journal.pending?(current),
         response = adapter.status(current, opts),
         {:ok, finished} <- Recovery.retire(current, response, adapter, opts) do
      event(finished, :ended, opts)
      {:ok, finished}
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_interruption_unresolved}
    end
  end

  defp hold_members([], _order, _opts, callback), do: callback.()

  defp hold_members([member | rest], order, opts, callback) do
    lock = Keyword.get(opts, :recovery_lock, &IssueLease.with_lock/3)
    lock.(order["linear_workspace_id"], member["id"], fn -> hold_members(rest, order, opts, callback) end)
  end

  defp await(order, adapter, opts) do
    with {:ok, %{"id" => id} = current} <- Journal.read(order["group"]),
         true <- id == order["id"] do
      if Journal.pending?(current) do
        await_pending(current, adapter, opts)
      else
        event(current, :ended, opts)
        run_result(current, current["state"])
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :openclaw_generation_changed}
    end
  end

  defp await_pending(order, adapter, opts) do
    order = maybe_cancel(order, adapter, opts)
    response = if enabled_for?(order), do: adapter.status(order, opts), else: {:error, :openclaw_disabled_with_pending_order}

    case terminal(response, order) do
      {:terminal, state, evidence} ->
        finish(order, response, {state, evidence}, adapter, opts)

      :pending ->
        order = observe_failure(order, response, opts)
        await_interruption(order, response, adapter, opts)
    end
  end

  defp finish(order, response, {state, evidence}, adapter, opts) do
    case Journal.transition(order, &terminal_changes(&1, state, evidence)) do
      {:ok, finished} ->
        event(finished, :ended, opts)
        run_result(finished, finished["state"])

      {:error, {:openclaw_fenced_terminal, current}} ->
        current = cancel(current, adapter, opts)
        await_interruption(current, response, adapter, opts)

      error ->
        error
    end
  end

  defp terminal_changes(%{"interruption_contract" => 1, "writable" => false} = current, _state, _evidence) do
    # Transport loss or concurrent revocation can fence the order during a poll.
    # Check under the journal lock before committing a normal terminal result.
    if Journal.pending?(current), do: {:error, {:openclaw_fenced_terminal, current}}, else: {:ok, %{}}
  end

  defp terminal_changes(_current, state, evidence), do: {:ok, %{"state" => state, "writable" => false, "terminal" => evidence}}

  defp await_interruption(order, response, adapter, opts) do
    case Recovery.retire(order, response, adapter, opts) do
      {:ok, finished} ->
        event(finished, :ended, opts)
        run_result(finished, finished["state"])

      {:error, _} ->
        wait = Keyword.get(opts, :openclaw_wait, &Process.sleep/1)
        wait.(1000)
        await(order, adapter, opts)
    end
  end

  defp observe_failure(order, {:error, reason}, opts) do
    reason = if is_atom(reason), do: Atom.to_string(reason), else: "openclaw_transport_failed"

    if order["error"] == reason do
      order
    else
      case Journal.update(order, %{"state" => "unknown", "writable" => false, "error" => reason}) do
        {:ok, updated} ->
          event(updated, :uncertain, opts)
          updated

        _ ->
          order
      end
    end
  end

  defp observe_failure(%{"id" => id} = order, {:ok, %{"runId" => id} = reply}, opts) do
    if is_number(reply["startedAt"]) or reply["status"] in ~w(accepted running) do
      # Observed execution rules out non-start recovery, but does not change
      # existing authority or overwrite a concurrent cancellation/transport loss.
      changes = %{"acceptance_observed" => true, "execution_observed" => is_number(reply["startedAt"]) or reply["status"] == "running"}

      case Journal.update(order, changes) do
        {:ok, updated} ->
          observation_event(order, updated, :observation_updated, opts)
          updated

        _ ->
          order
      end
    else
      order
    end
  end

  defp observe_failure(order, _response, _opts), do: order

  defp maybe_cancel(order, adapter, opts) do
    requested =
      receive do
        :openclaw_cancel -> true
      after
        0 -> order["cancel_requested"] == true or System.system_time(:millisecond) >= order["deadline"]
      end

    if requested, do: cancel(order, adapter, opts), else: order
  end

  defp cancel(order, adapter, opts) do
    case Journal.update(order, %{"cancel_requested" => true, "writable" => false, "state" => "cancel_pending"}) do
      {:ok, updated} ->
        observation_event(order, updated, :cancel_requested, opts)
        abort_external(updated, adapter, opts)

      _ ->
        %{order | "writable" => false}
    end
  end

  defp abort_external(order, adapter, opts) do
    if Journal.pending?(order) and enabled_for?(order) and order["abort_acknowledged"] != true and
         get_in(order, ["abort_error", "retryable"]) != false do
      persist_abort_result(order, adapter.cancel(order, opts), opts)
    else
      order
    end
  end

  defp persist_abort_result(order, :ok, opts), do: update_abort(order, %{"abort_acknowledged" => true}, opts)

  defp persist_abort_result(order, {:error, {:openclaw_abort_failed, proof}}, opts) do
    update_abort(order, %{"abort_error" => proof}, opts)
  end

  defp persist_abort_result(order, {:error, reason}, opts) do
    reason = if is_atom(reason), do: Atom.to_string(reason), else: "openclaw_transport_failed"
    update_abort(order, %{"abort_error" => %{"reason" => reason, "retryable" => true}}, opts)
  end

  defp persist_abort_result(order, _, opts), do: persist_abort_result(order, {:error, :openclaw_abort_unconfirmed}, opts)

  defp update_abort(order, changes, opts) do
    case Journal.update(order, changes) do
      {:ok, updated} ->
        observation_event(order, updated, :abort_updated, opts)
        updated

      _ ->
        order
    end
  end

  defp run_result(_order, "rejected"), do: {:error, :openclaw_request_rejected_before_acceptance}
  defp run_result(_order, "retired"), do: {:error, :openclaw_interrupted_order_retired}

  defp run_result(order, state) do
    if state == "completed" and order["cancel_requested"] != true do
      {:ok, %{session_id: order["session_id"]}}
    else
      {:error, :openclaw_run_failed_or_cancelled}
    end
  end

  @spec enabled_for?(map()) :: boolean()
  def enabled_for?(order), do: Config.openclaw_yolo_agent() == order["agent"] and Config.yolo_agent_id() == order["linear_agent_id"]

  @spec terminal(term(), map()) :: {:terminal, String.t(), map()} | :pending
  def terminal({:ok, %{"runId" => id, "status" => status, "endedAt" => ended} = response}, %{"id" => id})
      when status in ["ok", "error", "timeout"] and is_number(ended) do
    if response["yielded"] == true or response["pendingError"] == true do
      :pending
    else
      {:terminal, if(status == "ok", do: "completed", else: "failed"), Map.take(response, ~w(runId status startedAt endedAt stopReason))}
    end
  end

  def terminal(_, _), do: :pending

  defp observation_event(previous, current, event, opts) do
    if observation(previous) != observation(current), do: event(current, event, opts)
  end

  defp event(order, event, opts) do
    Enum.each(order["members"], fn member ->
      Logger.info(
        "OpenClaw PO event=#{event} project_root=#{order["project_id"]} issue_id=#{member["id"]} issue_identifier=#{member["identifier"]} run_id=#{order["id"]} session_id=#{order["session_id"]} state=#{order["state"]} reason=#{order["error"]} action=#{operator_action(order)}"
      )
    end)

    if recipient = opts[:recipient] do
      message = %{
        event: event,
        worker_pid: self(),
        session_id: order["session_id"],
        workspace_path: order["workspace"],
        message: operator_action(order),
        external: observation(order)
      }

      send(recipient, {:yolo_event, order["group"], message})
    end
  end

  @spec observation(map()) :: map()
  def observation(order) do
    reserved = Journal.pending?(order) and order["writable"] == false

    %{
      run_id: order["id"],
      original_group: order["group"],
      execution_state: order["state"],
      reserved: reserved,
      resumed: order["resumed"] == true,
      missing_evidence: if(reserved, do: missing_evidence(order)),
      abort_error: order["abort_error"],
      error: order["error"]
    }
  end

  defp missing_evidence(%{"interruption_contract" => 1, "cancel_requested" => true}), do: "inactive_session_or_input_resolution_required"

  defp missing_evidence(order) do
    if order["acceptance_observed"] == true or order["execution_observed"] == true,
      do: "terminal_original_required",
      else: "terminal_or_pre_acceptance_original_required"
  end

  defp operator_action(%{"state" => "rejected", "rejection" => %{"code" => "INVALID_REQUEST", "reason" => reason}})
       when reason in ~w(cwd_reserved cwd_not_absolute),
       do: "Vor Annahme abgelehnt (INVALID_REQUEST/#{reason}); Reservierung freigegeben, regulärer Retry möglich."

  defp operator_action(%{"state" => "rejected"}), do: "Vor Annahme abgelehnt; Reservierung freigegeben."

  defp operator_action(%{"state" => "retired"}), do: "Unterbrochenen Auftrag technisch aufgegeben; offene Arbeit wird frisch geplant, keine fachliche Erfolgsbestätigung."

  defp operator_action(%{"abort_acknowledged" => true} = order), do: interruption_action(order)

  defp operator_action(%{"abort_error" => %{"retryable" => false}}),
    do: "OpenClaw-Abbruch abgewiesen; Fehlerbeleg erhalten, kein automatischer Abbruchretry. Reservierung bis frischem End-/Inaktivitätsbeleg erhalten."

  defp operator_action(%{"interruption_contract" => 1, "cancel_requested" => true, "writable" => false} = order), do: interruption_action(order)

  defp operator_action(%{"state" => "local_error"}), do: "OpenClaw-Aufruf fehlgeschlagen; Gateway und Auftragsjournal prüfen."

  defp operator_action(%{"writable" => false} = order) do
    if Journal.pending?(order),
      do: "OpenClaw ungeklärt; reserviert. Betreiber: Endbeleg prüfen oder beleggebundene Recovery gemäß docs/openclaw-yolo.md.",
      else: "OpenClaw beendet; Reservierung freigegeben."
  end

  defp operator_action(_), do: "OpenClaw-Auftrag läuft."

  defp interruption_action(order) do
    if Journal.pending?(order),
      do: "OpenClaw unterbrochen; reserviert. Frische Inaktivität und Eingaben werden geprüft; ungeklärte Eingaben benötigen Betreiberklärung gemäß docs/openclaw-yolo.md.",
      else: "OpenClaw beendet; Reservierung freigegeben."
  end

  @spec digest(binary()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
