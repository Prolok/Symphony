defmodule SymphonyElixir.Relay.Session do
  @moduledoc "Serialized receive → persist → ack → refresh state machine for one workspace consumer."
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Relay.{Contract, Store}

  defstruct path: nil,
            record: nil,
            contexts: [],
            config: nil,
            request: nil,
            snapshot: nil,
            fetch: nil,
            persist: nil,
            clock: nil,
            registered: false,
            status: :initializing,
            error: nil,
            retry_at: 0,
            failures: 0

  @type t :: %__MODULE__{}

  @spec open(map(), String.t(), String.t(), [String.t()], String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(config, workspace, consumer, assignees, binding, opts) do
    subscription = %{"kind" => "symphony", "assigneeIds" => Enum.sort(Enum.uniq(assignees))}
    path = Store.path(config, workspace, consumer)

    record = %{
      "version" => 1,
      "workspace" => workspace,
      "consumer" => consumer,
      "binding" => binding,
      "authority" => opts[:authority],
      "subscription" => subscription,
      "generation" => nil,
      "phase" => "register",
      "cursor" => 0,
      "issues" => %{},
      "known" => [],
      "dirty" => [],
      "epochs" => %{},
      "pending" => nil,
      "reconcile_at" => 0
    }

    with true <- length(assignees) in 1..20 or (assignees == [] and opts[:workspace_wide] == true),
         {:ok, record} <- load(path, record) do
      {:ok,
       %__MODULE__{
         path: path,
         record: record,
         contexts: Keyword.get(opts, :contexts, []),
         config: config,
         request: Keyword.fetch!(opts, :request),
         snapshot: Keyword.fetch!(opts, :snapshot),
         fetch: Keyword.fetch!(opts, :fetch),
         persist: Keyword.get(opts, :persist, &DurableState.write/2),
         clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end)
       }}
    else
      false -> {:error, :relay_requires_one_to_twenty_humans}
      error -> error
    end
  end

  defp load(path, fresh) do
    case DurableState.read(path) do
      {:error, :enoent} ->
        {:ok, fresh}

      {:ok, stored} ->
        same_identity = Map.take(stored, ~w(version workspace consumer)) == Map.take(fresh, ~w(version workspace consumer))

        cond do
          not same_identity or not valid_record?(stored) ->
            {:error, :relay_cache_corrupt}

          Map.has_key?(stored, "authority") and stored["authority"] != fresh["authority"] ->
            {:error, :relay_cache_binding_mismatch}

          true ->
            {:ok, resume_record(stored, fresh)}
        end

      _ ->
        {:error, :relay_cache_corrupt}
    end
  end

  defp resume_record(stored, fresh) do
    # v1 records predate the separate authority fingerprint. Registration with
    # the authenticated workspace key still confirms generation/cursor before
    # any cached candidate can become ready. Reconcile old scopes in place.
    changed = stored["binding"] != fresh["binding"] or not Map.has_key?(stored, "authority")
    record = Map.merge(stored, Map.take(fresh, ~w(binding authority)))
    record = if changed, do: Map.put(record, "reconcile_at", 0), else: record

    if stored["subscription"] == fresh["subscription"] do
      Map.delete(record, "next_subscription")
    else
      Map.put(record, "next_subscription", fresh["subscription"])
    end
  end

  defp valid_record?(record) do
    is_map(record["issues"]) and is_map(record["epochs"]) and is_list(record["known"]) and is_list(record["dirty"]) and
      is_integer(record["cursor"]) and record["cursor"] >= 0 and is_integer(record["reconcile_at"]) and
      record["phase"] in ~w(register snapshot complete replay ready resync) and valid_pending?(record)
  end

  defp valid_pending?(%{"pending" => nil}), do: true

  defp valid_pending?(record) do
    is_map(record["pending"]) and
      Contract.page(record["pending"], record["workspace"], record["generation"], record["cursor"]) == :ok
  end

  @spec tick(t()) :: t()
  def tick(session) do
    if session.clock.() < session.retry_at do
      session
    else
      case advance(session) do
        {:ok, next} -> %{next | error: nil, failures: 0, retry_at: 0}
        {:error, reason, next} -> failed(next, reason)
      end
    end
  end

  defp advance(%{registered: false} = session) do
    case session.request.(:register, session.record["subscription"]) do
      {:ok, view} -> register(session, view)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp advance(%{record: %{"next_subscription" => _, "pending" => nil}} = session), do: change_subscription(session)

  defp advance(session) do
    case session.record["phase"] do
      "register" -> advance(%{session | registered: false})
      "resync" -> begin_snapshot(session)
      "snapshot" -> snapshot(session)
      "complete" -> complete(session)
      _ -> receive_page(session)
    end
  end

  defp change_subscription(session) do
    record =
      session.record
      |> Map.put("subscription", session.record["next_subscription"])
      |> Map.delete("next_subscription")
      |> Map.put("phase", "register")

    continue_saved(%{session | registered: false, status: :resyncing}, record, &advance/1)
  end

  defp register(session, view) do
    r = session.record

    case Contract.consumer(view, r["consumer"], r["subscription"]) do
      :ok -> registered(session, view)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp registered(session, view) do
    r = session.record

    cond do
      view["status"] == "snapshot_required" -> start_snapshot(session, view)
      view["generation"] != r["generation"] or not cursor_matches?(r, view) -> begin_snapshot(%{session | registered: true})
      r["phase"] in ["register", "snapshot", "resync"] -> begin_snapshot(%{session | registered: true})
      true -> advance(%{session | registered: true})
    end
  end

  defp cursor_matches?(record, view) do
    view["cursor"] == record["cursor"] or
      (is_map(record["pending"]) and view["cursor"] == record["pending"]["scannedThrough"])
  end

  defp begin_snapshot(session) do
    case session.request.(:resync, %{"phase" => "begin"}) do
      {:ok, view} -> start_snapshot(session, view)
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp start_snapshot(session, view) do
    r = session.record

    with :ok <- Contract.consumer(view, r["consumer"], r["subscription"]),
         true <- view["status"] == "snapshot_required" do
      record =
        Map.merge(r, %{
          "phase" => "snapshot",
          "generation" => view["generation"],
          "cursor" => view["cursor"],
          "token" => view["snapshotToken"],
          "pending" => nil,
          "dirty" => [],
          "known" => Enum.uniq(r["known"] ++ r["dirty"])
        })

      continue_saved(%{session | registered: true, status: :resyncing}, record, &snapshot/1)
    else
      _ -> {:error, :invalid_relay_response, session}
    end
  end

  defp snapshot(session) do
    case session.snapshot.(session.record["known"]) do
      {:ok, issues} ->
        record = replace_issues(session.record, issues, Map.keys(session.record["issues"]) ++ Enum.map(issues, & &1["id"]))
        record = Map.merge(record, %{"phase" => "complete", "reconcile_at" => next_reconcile(session)})
        continue_saved(session, record, &complete/1)

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp complete(session) do
    case session.request.(:resync, %{"phase" => "complete", "token" => session.record["token"]}) do
      {:ok, view} ->
        r = session.record

        with :ok <- Contract.consumer(view, r["consumer"], r["subscription"]),
             true <- view["generation"] == r["generation"] and view["cursor"] == r["cursor"] and view["status"] == "ready" do
          continue_saved(%{session | status: :catching_up}, Map.put(r, "phase", "replay"), &receive_page/1)
        else
          _ -> {:error, :invalid_relay_response, session}
        end

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp receive_page(%{record: %{"pending" => page}} = session) when is_map(page), do: acknowledge(session)

  defp receive_page(session) do
    case session.request.(:poll, nil) do
      {:ok, page} ->
        r = session.record

        case Contract.page(page, r["workspace"], r["generation"], r["cursor"]) do
          :ok -> accept_page(session, page)
          {:error, reason} -> {:error, reason, session}
        end

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp accept_page(session, %{"receipt" => nil} = page), do: refresh(session, page)

  defp accept_page(session, page) do
    # The entire page/receipt is durable before the first ack attempt. Its dirty
    # set remains durable even when hydration fails or the process is killed.
    ids = page["events"] |> Enum.map(& &1["issueId"]) |> Enum.filter(&is_binary/1)
    ids = ids ++ dependent_issue_ids(session.record["issues"], ids)
    r = session.record |> Map.put("pending", page) |> Map.update!("dirty", &Enum.uniq(&1 ++ ids))
    continue_saved(session, r, &acknowledge/1)
  end

  defp dependent_issue_ids(issues, ids) do
    changed = MapSet.new(ids)

    for {id, issue} <- issues,
        Enum.any?(get_in(issue, ["inverseRelations", "nodes"]) || [], &changed_blocker?(&1, changed)),
        do: id
  end

  defp changed_blocker?(%{"type" => type, "issue" => %{"id" => id}}, changed) when is_binary(type) do
    String.downcase(String.trim(type)) == "blocks" and MapSet.member?(changed, id)
  end

  defp changed_blocker?(_, _), do: false

  defp acknowledge(session) do
    page = session.record["pending"]

    case session.request.(:ack, %{"receipt" => page["receipt"]}) do
      {:ok, response} ->
        case Contract.ack(response, page["scannedThrough"]) do
          :ok -> acknowledged(session, page)
          {:error, reason} -> {:error, reason, session}
        end

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp acknowledged(session, page) do
    resync = Enum.any?(page["events"], &(&1["signal"] == "resync_required"))
    phase = if resync, do: "resync", else: "replay"
    r = Map.merge(session.record, %{"pending" => nil, "cursor" => page["scannedThrough"], "phase" => phase})

    continuation =
      cond do
        r["next_subscription"] -> &change_subscription/1
        resync -> &begin_snapshot/1
        true -> &refresh(&1, page)
      end

    continue_saved(session, r, continuation)
  end

  defp refresh(session, page) do
    cond do
      session.clock.() >= session.record["reconcile_at"] -> reconcile(session, page)
      session.record["dirty"] != [] -> hydrate(session, page)
      true -> ready(session, page)
    end
  end

  defp reconcile(session, page) do
    case session.snapshot.(session.record["known"]) do
      {:ok, issues} ->
        r = replace_issues(session.record, issues, session.record["known"] ++ Enum.map(issues, & &1["id"]))
        r = Map.merge(r, %{"dirty" => [], "reconcile_at" => next_reconcile(session)})
        continue_saved(session, r, &ready(&1, page))

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp hydrate(session, page) do
    ids = session.record["dirty"]

    case session.fetch.(ids) do
      {:ok, issues} ->
        r = replace_issues(session.record, issues, ids) |> Map.put("dirty", [])
        continue_saved(session, r, &ready(&1, page))

      {:error, reason} ->
        {:error, reason, session}
    end
  end

  defp replace_issues(record, issues, ids) do
    fresh = Map.new(issues, &{&1["id"], &1})
    # Relay positions are not Linear revisions. Even a delayed provider response
    # cannot replace a newer known issue version with an older version.
    fresh = Map.new(fresh, fn {id, issue} -> {id, latest(record["issues"][id], issue)} end)
    previous = Map.drop(record["issues"], ids)
    epochs = Enum.reduce(Enum.uniq(ids), record["epochs"], &Map.update(&2, &1, 1, fn n -> n + 1 end))
    Map.merge(record, %{"issues" => Map.merge(previous, fresh), "epochs" => epochs, "known" => Enum.uniq(record["known"] ++ ids)})
  end

  defp latest(%{"updatedAt" => before} = old, %{"updatedAt" => after_time} = fresh) when is_binary(before) and is_binary(after_time) do
    with {:ok, a, _} <- DateTime.from_iso8601(before), {:ok, b, _} <- DateTime.from_iso8601(after_time) do
      if DateTime.compare(a, b) == :gt, do: old, else: fresh
    else
      _ -> fresh
    end
  end

  defp latest(_, fresh), do: fresh

  defp ready(%{record: %{"next_subscription" => _}} = session, _page), do: change_subscription(session)

  defp ready(session, page) do
    ready = page["scannedThrough"] == page["head"]
    phase = if ready, do: "ready", else: "replay"
    session = %{session | status: if(ready, do: :ready, else: :catching_up)}
    if session.record["phase"] == phase, do: {:ok, session}, else: save(session, Map.put(session.record, "phase", phase))
  end

  defp continue_saved(session, record, callback) do
    case save(session, record) do
      {:ok, saved} -> callback.(saved)
      error -> error
    end
  end

  defp save(session, record) do
    case session.persist.(session.path, record) do
      :ok -> {:ok, %{session | record: record}}
      {:error, reason} -> {:error, reason, session}
    end
  end

  defp failed(session, reason) do
    {status, phase, registered} = error_mode(reason, session)
    delay = min(30_000 * Integer.pow(2, min(session.failures, 5)), 900_000)
    jitter = :erlang.phash2({session.record["consumer"], session.failures}, div(delay, 4) + 1)
    %{session | status: status, error: reason, registered: registered, record: Map.put(session.record, "phase", phase), retry_at: session.clock.() + delay + jitter, failures: session.failures + 1}
  end

  defp error_mode({:relay_http, 404, _}, _), do: {:resyncing, "register", false}
  defp error_mode({:relay_http, status, _}, _) when status in [409, 410], do: {:resyncing, "resync", true}
  defp error_mode({:relay_http, status, _}, s) when status in [401, 403], do: {:access_error, s.record["phase"], s.registered}
  defp error_mode(reason, s) when reason in [:invalid_relay_response, :relay_upgrade_required], do: {:upgrade_required, s.record["phase"], s.registered}
  defp error_mode(_reason, s), do: {:degraded, s.record["phase"], s.registered}

  defp next_reconcile(session) do
    interval = session.config["reconcile_ms"]
    session.clock.() + interval + :erlang.phash2({session.record["workspace"], session.record["consumer"]}, div(interval, 4) + 1)
  end

  @spec watch(t(), [String.t()]) :: t()
  def watch(session, ids) do
    missing = ids -- session.record["known"]

    if missing == [] do
      session
    else
      r = session.record |> Map.update!("known", &Enum.uniq(&1 ++ missing)) |> Map.update!("dirty", &Enum.uniq(&1 ++ missing))

      case save(session, r) do
        {:ok, saved} -> %{saved | status: :catching_up}
        {:error, reason, previous} -> failed(previous, reason)
      end
    end
  end

  @spec reconfigure(t(), String.t()) :: t()
  def reconfigure(session, binding) do
    if session.record["binding"] == binding do
      session
    else
      record = Map.merge(session.record, %{"binding" => binding, "reconcile_at" => 0})

      case save(session, record) do
        {:ok, saved} -> %{saved | status: :resyncing}
        {:error, reason, previous} -> failed(previous, reason)
      end
    end
  end
end
