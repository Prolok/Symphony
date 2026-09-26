defmodule SymphonyElixir.Linear.CommentJournal do
  @moduledoc """
  Durable app comment receipts, protected by a separate host-local journal transaction lock.
  Intent precedes HTTP. Pending writes are reconciled before subsequent writes;
  unknown outcomes remain visible and cannot cause a blind duplicate creation.
  """

  alias SymphonyElixir.Linear.{CommentMutations, DurableState, IssueLease, LocalState}
  alias SymphonyElixir.Workpad

  @lookup "query SymphonyReceipt($id: String!) { comment(id: $id) { id body bodyData quotedText resolvingUser { id } resolvingComment { id } updatedAt user { id } issue { id identifier } } }"
  @issue_lookup "query SymphonyReceiptIssue($id: String!) { issue(id: $id) { id } }"
  @recovery_update "mutation SymphonyRecoverCommentUpdate($id: String!, $input: CommentUpdateInput!) { recovered: commentUpdate(id: $id, input: $input) { success symphonyReceipt: comment { id body bodyData quotedText resolvingUser { id } resolvingComment { id } updatedAt user { id } issue { id identifier } } } }"
  # Closed receipts older than 14 days leave the active scan path. A small batch
  # bounds each transaction; pending and unknown outcomes stay active forever.
  @retention_days 14
  @archive_batch 16
  @match_fields ~w(body bodyData quotedText resolvingUserId resolvingCommentId)
  @version_fields ~w(body bodyData quotedText resolvingUser resolvingComment)

  @spec execute(map(), map(), (map() -> term()), map(), keyword()) :: term()
  def execute(binding, payload, request, context \\ %{}, opts \\ []) do
    with {:ok, prepared, receipts} <- CommentMutations.prepare(payload) do
      execute_prepared(binding, prepared, receipts, request, context, opts)
    end
  end

  defp execute_prepared(_binding, prepared, [], request, _context, _opts), do: request.(prepared)

  defp execute_prepared(binding, prepared, receipts, request, context, opts) do
    binding = Map.put(binding, :state_writer, Keyword.get(opts, :state_writer, &DurableState.write/2))

    # Serialize new writers, including identity hydration, while HTTP runs.
    # The shared journal lock only covers local intent/confirmation transactions.
    IssueLease.with_journal_lock(
      binding["state_root"] <> ".writes",
      fn -> execute_serialized(binding, prepared, receipts, request, context, opts) end,
      Keyword.get(opts, :lock_timeout, 10_000),
      "write-serialization"
    )
  end

  defp execute_serialized(binding, prepared, receipts, request, context, opts) do
    with {:ok, receipts} <- collect(receipts, &hydrate_receipt(binding, &1, request)),
         {:ok, known_ids} <- recover_before_write(binding, receipts, request),
         :ok <-
           IssueLease.with_journal_lock(
             binding["state_root"],
             fn ->
               persist_new_intents(binding, receipts, context, known_ids)
             end,
             Keyword.get(opts, :lock_timeout, 10_000),
             "write-intent"
           ),
         {:ok, response} <- request.(prepared),
         :ok <-
           IssueLease.with_journal_lock(binding["state_root"], fn -> confirm_response(binding, receipts, response) end, Keyword.get(opts, :lock_timeout, 10_000), "write-confirm") do
      {:ok, response}
    end
  end

  defp persist_new_intents(binding, receipts, context, known_ids) do
    with {:ok, files} <- active_files(binding),
         true <-
           files
           |> Enum.filter(&String.ends_with?(&1, ".intent.json"))
           |> Enum.all?(fn file -> MapSet.member?(known_ids, String.replace_suffix(file, ".intent.json", "")) end),
         :ok <- persist_intents(binding, receipts, context) do
      :ok
    else
      false -> {:error, :comment_write_concurrent}
      error -> error
    end
  end

  defp hydrate_receipt(_binding, %{"operation" => "commentCreate", "issue_id" => issue} = receipt, request) when is_binary(issue) do
    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_]*-[0-9]+\z/, issue) do
      resolve_issue_identity(receipt, request)
    else
      {:ok, receipt}
    end
  end

  defp hydrate_receipt(binding, %{"operation" => "commentUpdate"} = receipt, request) do
    case request.(%{"query" => @lookup, "variables" => %{"id" => receipt["comment_id"]}}) do
      {:ok, %{status: 200, body: %{"data" => %{"comment" => comment}} = body}} when is_map(comment) ->
        if Map.get(body, "errors", []) in [nil, []] and get_in(comment, ["user", "id"]) == binding["user_id"] do
          {:ok, Map.merge(receipt, %{"issue_id" => get_in(comment, ["issue", "id"]), "previous_version" => comment["updatedAt"]})}
        else
          {:error, :comment_update_identity_unverified}
        end

      _ ->
        {:error, :comment_update_identity_unverified}
    end
  end

  defp hydrate_receipt(_binding, receipt, _request), do: {:ok, receipt}

  defp resolve_issue_identity(receipt, request) do
    case request.(%{"query" => @issue_lookup, "variables" => %{"id" => receipt["issue_id"]}}) do
      {:ok, %{status: 200, body: %{"data" => %{"issue" => %{"id" => id}}} = body}} when is_binary(id) ->
        if Map.get(body, "errors", []) in [nil, []], do: {:ok, %{receipt | "issue_id" => id}}, else: {:error, :comment_issue_identity_unverified}

      _ ->
        {:error, :comment_issue_identity_unverified}
    end
  end

  @spec reconcile(map(), (map() -> term())) :: {:ok, [map()]} | {:error, term()}
  def reconcile(binding, request) do
    with {:ok, entries} <- locked_entries(binding, 10_000, "reconcile-read") do
      collect(entries, &reconcile_record(binding, &1, request))
    end
  end

  defp locked_entries(binding, timeout, purpose) do
    IssueLease.with_journal_lock(binding["state_root"], fn -> read_entries(binding) end, timeout, purpose)
  end

  defp read_entries(binding) do
    with {:ok, records} <- intents(binding), do: read_many(records, &snapshot_entry(binding, &1))
  end

  defp reconcile_record(binding, %{record: record, rejected: rejected}, request) do
    cond do
      rejected ->
        {:ok, result(record, "rejected")}

      record["_archived"] == true ->
        {:ok, result(record, "confirmed")}

      true ->
        response = request.(%{"query" => @lookup, "variables" => %{"id" => record["comment_id"]}})
        confirm_prefetched(binding, record, response, 10_000, "reconcile-confirm")
    end
  end

  defp confirm_prefetched(binding, record, response, timeout, purpose) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn -> confirm_current_record(binding, record, response) end,
      timeout,
      purpose
    )
  end

  defp confirm_current_record(binding, record, response) do
    with {:ok, catalog} <- archive_catalog(binding) do
      confirm_from_catalog(binding, record, response, catalog[record["operation_id"]])
    end
  end

  defp confirm_from_catalog(binding, record, response, nil), do: confirm_remote(binding, record, fn _ -> response end)

  defp confirm_from_catalog(_binding, _record, _response, archived),
    do: {:ok, result(archived, if(archived["_rejected"], do: "rejected", else: "confirmed"))}

  @spec classify(map(), map()) :: :own | :pending | :foreign | {:error, term()}
  def classify(binding, comment) do
    with {:ok, view} <- snapshot(binding) do
      classify_snapshot(view, binding, comment)
    end
  end

  @doc "Read each active intent once while holding the journal lock. The returned view is immutable."
  @spec snapshot(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(binding, opts \\ []) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn ->
        with :ok <- finish_archive_moves(binding),
             {:ok, records} <- intents(binding, Keyword.get(opts, :journal_reader, &read_intent(binding, &1))),
             {:ok, entries} <- read_many(records, &snapshot_entry(binding, &1)),
             :ok <- archive_due(binding, entries) do
          {:ok, entries |> Enum.group_by(& &1.record["comment_id"]) |> Map.new()}
        end
      end,
      Keyword.get(opts, :scan_lock_timeout, 750),
      "scan-snapshot"
    )
  end

  @doc "Reconcile pending receipts from the same intent view used to classify a scan."
  @spec observation_snapshot(map(), (map() -> term()) | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def observation_snapshot(binding, request, opts \\ []) do
    with {:ok, view} <- snapshot(binding, opts) do
      reconcile_view(binding, view, request)
    end
  end

  defp reconcile_view(_binding, view, nil), do: {:ok, view}

  defp reconcile_view(binding, view, request) do
    Enum.reduce_while(view, {:ok, %{}}, fn {comment_id, entries}, {:ok, acc} ->
      case collect(entries, &reconcile_view_entry(binding, &1, request)) do
        {:ok, reconciled} -> {:cont, {:ok, Map.put(acc, comment_id, reconciled)}}
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile_view_entry(binding, entry, request) do
    if pending_entry?(entry, binding) do
      record = entry.record
      response = request.(%{"query" => @lookup, "variables" => %{"id" => record["comment_id"]}})

      case confirm_prefetched(binding, record, response, 750, "scan-reconcile-confirm") do
        {:ok, %{"state" => "confirmed"}} ->
          comment = observed_comment(response)
          {:ok, %{entry | confirmed: comment, recovered: true}}

        {:ok, _result} ->
          {:ok, entry}

        error ->
          error
      end
    else
      {:ok, entry}
    end
  end

  defp observed_comment({:ok, %{body: %{"data" => %{"comment" => comment}}}}), do: comment
  defp observed_comment(_response), do: nil

  @spec classify_snapshot(map(), map(), map()) :: :own | :pending | :foreign | {:error, term()}
  def classify_snapshot(view, binding, comment) do
    entries = Map.get(view, comment["id"], [])
    latest = entries |> Enum.reject(& &1.rejected) |> Enum.max_by(&{&1.record["written_at"], &1.record["operation_id"]}, fn -> nil end)
    classify_latest(latest, binding, comment)
  end

  defp classify_latest(nil, binding, comment) do
    if get_in(comment, ["user", "id"]) == binding["user_id"], do: :pending, else: :foreign
  end

  defp classify_latest(%{confirmed: nil}, _binding, _comment), do: :pending

  defp classify_latest(%{record: %{"_archived" => true} = record}, _binding, comment) do
    if archive_matches?(record, comment) and archive_version?(record, comment), do: :own, else: :pending
  end

  defp classify_latest(%{record: record, confirmed: confirmed}, binding, comment) do
    if matches?(record, comment, binding) and confirmed_version?(confirmed, comment), do: :own, else: :pending
  end

  defp snapshot_entry(_binding, %{"_archived" => true} = record) do
    {:ok,
     %{
       record: record,
       confirmed: if(record["_confirmed"], do: true),
       recovered: record["_recovered"] == true,
       rejected: record["_rejected"] == true
     }}
  end

  defp snapshot_entry(binding, record) do
    with {:ok, confirmation} <- optional_receipt(path(binding, record, "confirmed"), "comment"),
         {:ok, rejected} <- optional_receipt(path(binding, record, "rejected"), "state") do
      {:ok,
       %{
         record: record,
         confirmed: if(is_map(confirmation), do: confirmation["comment"]),
         recovered: is_map(confirmation) and confirmation["recovered"] == true,
         rejected: rejected == "rejected"
       }}
    end
  end

  defp optional_receipt(path, key) do
    case DurableState.read(path) do
      {:ok, receipt} when is_map(receipt) -> {:ok, if(key == "comment", do: receipt, else: receipt[key])}
      {:error, :enoent} -> {:ok, nil}
      _ -> {:error, :comment_journal_corrupt}
    end
  end

  defp archive_due(binding, entries) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@retention_days, :day) |> DateTime.to_iso8601()
    entries |> Enum.filter(&archive_due?(&1, cutoff, binding)) |> Enum.take(@archive_batch) |> write_archive_batch(binding)
  end

  defp archive_due?(%{record: record, confirmed: confirmed, rejected: rejected}, cutoff, binding) do
    closed? =
      (rejected and is_nil(confirmed)) or
        (not rejected and is_map(confirmed) and matches?(record, confirmed, binding))

    record["_archived"] != true and is_binary(record["written_at"]) and record["written_at"] < cutoff and
      closed?
  end

  defp write_archive_batch([], _binding), do: :ok

  defp write_archive_batch(due, binding) do
    with {:ok, catalog} <- archive_catalog(binding),
         updated = Enum.reduce(due, catalog, fn entry, acc -> Map.put(acc, entry.record["operation_id"], archive_summary(entry)) end),
         :ok <- DurableState.write(archive_index(binding), archive_index_data(binding, updated)),
         :ok <- move_archive_batch(binding, Enum.map(due, &archive_summary/1)) do
      :ok
    else
      _ -> {:error, :comment_journal_archive_failed}
    end
  end

  defp archive_index_data(binding, entries) do
    %{"workspace_id" => binding["workspace_id"], "installation_id" => binding["installation_id"], "entries" => entries, "digest" => fingerprint(entries)}
  end

  defp archive_summary(%{record: record, confirmed: confirmed, recovered: recovered, rejected: rejected}) do
    keys = record["input"] |> Map.take(@match_fields) |> Map.keys() |> Enum.sort()
    version_keys = if is_map(confirmed), do: confirmed |> Map.take(@version_fields) |> Map.keys() |> Enum.sort(), else: []

    %{
      "_archived" => true,
      "_confirmed" => is_map(confirmed),
      "_rejected" => rejected,
      "_recovered" => recovered,
      "operation_id" => record["operation_id"],
      "operation" => record["operation"],
      "comment_id" => record["comment_id"],
      "issue_id" => record["issue_id"],
      "author_id" => record["author_id"],
      "written_at" => record["written_at"],
      "parent_id" => get_in(record, ["input", "parentId"]),
      "input_hash" => fingerprint(comparable_input(record)),
      "match_keys" => keys,
      "match_hash" => fingerprint(expected_match(record["input"], keys)),
      "version_keys" => version_keys,
      "version_hash" => fingerprint(Map.take(confirmed || %{}, version_keys)),
      "updated_at" => if(is_map(confirmed), do: confirmed["updatedAt"])
    }
  end

  defp move_archived(binding, record) do
    receipt = if record["_confirmed"], do: "confirmed", else: "rejected"

    Enum.reduce_while([receipt, "intent"], :ok, fn suffix, :ok ->
      from = path(binding, record, suffix)
      to = Path.join(archive_directory(binding), Path.basename(from))

      case move_archived_file(from, to) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp move_archived_file(from, to) do
    case {File.read(from), File.read(to)} do
      {{:ok, source}, {:ok, destination}} when source != destination ->
        {:error, :comment_journal_archive_failed}

      {{:error, :enoent}, {:ok, _}} ->
        :ok

      {{:ok, _}, _} ->
        case File.rename(from, to) do
          :ok -> :ok
          _ -> {:error, :comment_journal_archive_failed}
        end

      _ ->
        {:error, :comment_journal_archive_failed}
    end
  end

  defp move_archive_batch(_binding, []), do: :ok

  defp move_archive_batch(binding, records) do
    with :ok <- reduce_ok(records, &move_archived(binding, &1)),
         :ok <- sync_archive_directory(directory(binding)),
         :ok <- sync_archive_directory(archive_directory(binding)) do
      :ok
    else
      _ -> {:error, :comment_journal_archive_failed}
    end
  end

  defp sync_archive_directory(path) do
    with {:ok, descriptor} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      result = :file.sync(descriptor)
      closed = :file.close(descriptor)
      if result == :ok, do: closed, else: result
    end
  end

  defp finish_archive_moves(binding) do
    with {:ok, files} <- active_files(binding),
         {:ok, catalog} <- archive_catalog(binding) do
      files
      |> Enum.filter(&String.match?(&1, ~r/\.(intent|confirmed|rejected)\.json\z/))
      |> Enum.map(&String.replace(&1, ~r/\.(intent|confirmed|rejected)\.json\z/, ""))
      |> Enum.uniq()
      |> Enum.flat_map(&List.wrap(catalog[&1]))
      |> Enum.take(@archive_batch)
      |> then(&move_archive_batch(binding, &1))
    end
  end

  defp archive_matches?(record, comment) do
    same_id? = comment["id"] == record["comment_id"]
    same_author? = get_in(comment, ["user", "id"]) == record["author_id"]
    same_issue? = is_nil(record["issue_id"]) or record["issue_id"] in [get_in(comment, ["issue", "id"]), get_in(comment, ["issue", "identifier"])]

    same_id? and same_author? and same_issue? and
      fingerprint(actual_match(comment, record["match_keys"])) == record["match_hash"] and
      record["_confirmed"] == true
  end

  defp archive_version?(record, comment),
    do: fingerprint(Map.take(comment, record["version_keys"])) == record["version_hash"]

  defp expected_match(input, keys) do
    Map.new(keys, fn key -> {key, if(key == "bodyData", do: normalize_json(input[key]), else: input[key])} end)
  end

  defp actual_match(comment, keys) do
    Map.new(keys, fn key ->
      value =
        case key do
          "resolvingUserId" -> get_in(comment, ["resolvingUser", "id"])
          "resolvingCommentId" -> get_in(comment, ["resolvingComment", "id"])
          _ -> Map.get(comment, key, :missing)
        end

      {key, if(key == "bodyData", do: normalize_json(value), else: value)}
    end)
  end

  defp fingerprint(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp archive_index(binding), do: Path.join(archive_directory(binding), "index.json")
  defp archive_directory(binding), do: Path.join(directory(binding), "archive")

  defp archive_catalog(binding) do
    case DurableState.read(archive_index(binding)) do
      {:ok, %{"workspace_id" => workspace, "installation_id" => installation, "entries" => entries, "digest" => digest}} when is_map(entries) ->
        cond do
          installation != binding["installation_id"] ->
            {:error, {:local_state_requires_handoff, archive_directory(binding), LocalState.handoff_message()}}

          workspace != binding["workspace_id"] ->
            {:error, :comment_journal_corrupt}

          digest != fingerprint(entries) ->
            {:error, :comment_journal_corrupt}

          true ->
            {:ok, entries}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      _ ->
        {:error, :comment_journal_corrupt}
    end
  end

  @spec confirmed_comment_id?(map(), String.t()) :: boolean()
  def confirmed_comment_id?(binding, id) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn ->
        case intents(binding) do
          {:ok, records} -> Enum.any?(records, &(&1["comment_id"] == id and confirmed?(binding, &1)))
          _ -> false
        end
      end,
      10_000,
      "confirmed-comment-lookup"
    ) == true
  end

  @spec confirmed_relay_event?(map(), map()) :: boolean()
  def confirmed_relay_event?(binding, %{"commentId" => id, "action" => action} = event)
      when is_binary(id) and action in ["create", "update"] do
    operation = if action == "create", do: "commentCreate", else: "commentUpdate"
    version = get_in(event, ["payload", "updatedAt"]) || event["sourceTime"]

    IssueLease.with_journal_lock(
      binding["state_root"],
      fn ->
        case intents(binding) do
          {:ok, records} -> Enum.any?(records, &confirmed_relay_record?(binding, &1, id, operation, action, version))
          _ -> false
        end
      end,
      10_000,
      "relay-echo-lookup"
    ) == true
  end

  def confirmed_relay_event?(_binding, _event), do: false

  defp confirmed_relay_record?(binding, record, id, operation, action, version) do
    record["comment_id"] == id and record["operation"] == operation and
      relay_receipt_matches?(binding, record, action, version)
  end

  defp relay_receipt_matches?(_binding, %{"_archived" => true} = record, action, version) do
    record["_confirmed"] == true and relay_version_matches?(action, version, record["updated_at"])
  end

  defp relay_receipt_matches?(binding, record, action, version) do
    case confirmed_receipt(binding, record) do
      {:ok, %{"comment" => comment}} ->
        matches?(record, comment, binding) and relay_version_matches?(action, version, comment["updatedAt"])

      _ ->
        false
    end
  end

  defp relay_version_matches?("create", _version, _confirmed), do: true
  defp relay_version_matches?(_action, version, confirmed), do: not is_nil(version) and same_timestamp?(version, confirmed)

  defp same_timestamp?(left, right) when is_binary(left) and is_binary(right) do
    left == right or
      case {DateTime.from_iso8601(left), DateTime.from_iso8601(right)} do
        {{:ok, a, _}, {:ok, b, _}} -> DateTime.compare(a, b) == :eq
        _ -> false
      end
  end

  defp same_timestamp?(_left, _right), do: false

  @spec confirmed_reply_after?(map(), String.t(), integer()) :: boolean()
  def confirmed_reply_after?(binding, parent_id, after_ms) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn -> confirmed_reply_records?(binding, parent_id, after_ms) end,
      10_000,
      "confirmed-reply-lookup"
    ) == true
  end

  defp confirmed_reply_records?(binding, parent_id, after_ms) do
    case intents(binding) do
      {:ok, records} ->
        Enum.any?(records, fn record ->
          parent_id(record) == parent_id and written_after?(record["written_at"], after_ms) and
            confirmed?(binding, record)
        end)

      _ ->
        false
    end
  end

  defp written_after?(value, after_ms) when is_binary(value) and is_integer(after_ms) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> DateTime.to_unix(datetime, :millisecond) >= after_ms
      _ -> false
    end
  end

  defp written_after?(_value, _after_ms), do: false

  @doc "Reconcile outstanding receipts, then run the callback without holding the journal lock."
  @spec observe(map(), (map() -> term()) | nil, (-> term())) :: term()
  def observe(binding, request, callback) do
    with :ok <- reconcile_observation(binding, request), do: callback.()
  end

  defp reconcile_observation(_binding, nil), do: :ok

  defp reconcile_observation(binding, request) do
    with {:ok, entries} <- locked_entries(binding, 750, "scan-reconcile-read"),
         pending = entries |> Enum.filter(&pending_entry?(&1, binding)) |> Enum.map(& &1.record),
         {:ok, _results} <- collect(pending, &reconcile_observation_record(binding, &1, request)) do
      :ok
    end
  end

  defp reconcile_observation_record(binding, record, request) do
    response = request.(%{"query" => @lookup, "variables" => %{"id" => record["comment_id"]}})
    confirm_prefetched(binding, record, response, 750, "scan-reconcile-confirm")
  end

  defp confirmed_version?(confirmed, comment) do
    # Linear also bumps a parent comment's updatedAt when a reply is added.
    # Compare the confirmed write content; that thread activity is no foreign edit.
    Enum.all?(Map.take(confirmed, ~w(body bodyData quotedText resolvingUser resolvingComment)), fn {key, value} ->
      Map.fetch(comment, key) == {:ok, value}
    end)
  end

  defp recover_before_write(binding, receipts, request) do
    with {:ok, {records, entries}} <- recovery_snapshot(binding),
         {:ok, recovered} <-
           collect(
             entries |> Enum.filter(&pending_entry?(&1, binding)) |> Enum.map(& &1.record),
             &recover_remote_before_write(binding, &1, request)
           ) do
      # Another issue or a restarted runtime may have completed reconciliation.
      # The original run/tool context is evidence, not a retry identity.
      prior = entries |> Enum.filter(& &1.recovered) |> Enum.map(& &1.record)

      case check_recovery(records, recovered, receipts, prior) do
        :ok -> {:ok, MapSet.new(records, & &1["operation_id"])}
        error -> error
      end
    end
  end

  defp recovery_snapshot(binding) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn ->
        with {:ok, records} <- intents(binding),
             {:ok, entries} <- read_many(records, &snapshot_entry(binding, &1)) do
          {:ok, {records, entries}}
        end
      end,
      10_000,
      "write-recovery-snapshot"
    )
  end

  defp pending_entry?(%{rejected: true}, _binding), do: false
  defp pending_entry?(%{record: %{"_archived" => true}, confirmed: true}, _binding), do: false

  defp pending_entry?(%{record: record, confirmed: confirmed}, binding) when is_map(confirmed),
    do: not matches?(record, confirmed, binding)

  defp pending_entry?(_entry, _binding), do: true

  defp check_recovery(records, recovered, receipts, prior) do
    unresolved = Enum.filter(recovered, &(&1["state"] != "confirmed"))
    recovered_updates = Enum.filter(recovered, &(&1["recovered_update"] == true))
    repeated = Enum.filter(records, &repeated_write?(&1, recovered ++ prior, receipts))

    cond do
      unresolved != [] ->
        {:error, {:comment_write_unresolved, unresolved}}

      recovered_updates != [] ->
        {:error, {:comment_write_recovered, Enum.map(recovered_updates, & &1["comment_id"])}}

      repeated != [] ->
        {:error, {:comment_write_recovered, Enum.map(repeated, & &1["comment_id"])}}

      true ->
        :ok
    end
  end

  defp repeated_write?(record, recovered, receipts) do
    record["operation"] in ["commentCreate", "commentUpdate"] and
      Enum.any?(recovered, &(&1["comment_id"] == record["comment_id"])) and
      Enum.any?(receipts, fn receipt ->
        receipt["operation"] == record["operation"] and
          (record["operation"] == "commentCreate" or
             receipt["comment_id"] == record["comment_id"]) and
          input_fingerprint(receipt) == input_fingerprint(record)
      end)
  end

  defp comparable_input(record), do: Map.delete(record["input"], "id")

  defp input_fingerprint(%{"_archived" => true} = record), do: record["input_hash"]
  defp input_fingerprint(record), do: fingerprint(comparable_input(record))

  defp parent_id(record) do
    if record["_archived"] == true,
      do: record["parent_id"],
      else: get_in(record, ["input", "parentId"])
  end

  defp rejected?(binding, record) do
    match?({:ok, %{"state" => "rejected"}}, DurableState.read(path(binding, record, "rejected")))
  end

  defp confirmed?(binding, record) do
    if record["_archived"] == true do
      record["_confirmed"] == true
    else
      case confirmed_receipt(binding, record) do
        {:ok, %{"comment" => comment}} -> matches?(record, comment, binding)
        _ -> false
      end
    end
  end

  defp confirmed_receipt(binding, record), do: DurableState.read(path(binding, record, "confirmed"))

  defp persist_intents(binding, receipts, context) do
    reduce_ok(receipts, &persist_intent(binding, &1, context))
  end

  defp persist_intent(binding, receipt, context) do
    record =
      Map.merge(receipt, %{
        "workspace_id" => binding["workspace_id"],
        "author_id" => binding["user_id"],
        "installation_id" => binding["installation_id"],
        "context" => context,
        "output_type" => output_type(receipt["input"]["body"], context),
        "written_at" => DateTime.to_iso8601(DateTime.utc_now())
      })

    persist(binding, path(binding, receipt, "intent"), record)
  end

  defp confirm_response(binding, receipts, response) do
    if definitively_rejected?(response) do
      reduce_ok(receipts, &persist(binding, path(binding, &1, "rejected"), %{"state" => "rejected", "http_status" => response.status}))
    else
      reduce_ok(receipts, fn receipt ->
        comment = response_comment(response, receipt["field"])
        confirm_comment(binding, receipt, comment)
      end)
    end
  end

  defp response_comment(%{body: %{"data" => data}}, field) when is_map(data), do: get_in(data, [field, "symphonyReceipt"])
  defp response_comment(_response, _field), do: nil

  defp definitively_rejected?(%{status: status, body: body}) when is_map(body) do
    is_nil(body["data"]) and (status in [401, 429] or pre_execution_errors?(body["errors"]))
  end

  defp definitively_rejected?(%{status: status}) when status in [401, 429], do: true
  defp definitively_rejected?(_response), do: false

  defp pre_execution_errors?(errors) when is_list(errors) and errors != [] do
    Enum.all?(errors, fn error ->
      is_map(error) and is_nil(error["path"]) and
        get_in(error, ["extensions", "code"]) in ["GRAPHQL_PARSE_FAILED", "GRAPHQL_VALIDATION_FAILED", "RATELIMITED"]
    end)
  end

  defp pre_execution_errors?(_errors), do: false

  defp confirm_comment(binding, receipt, comment) when is_map(comment) do
    if matches?(receipt, comment, binding),
      do: persist(binding, path(binding, receipt, "confirmed"), %{"comment" => comment}),
      else: :ok
  end

  defp confirm_comment(_binding, _receipt, _comment), do: :ok

  defp confirm_remote(binding, record, request) do
    if rejected?(binding, record), do: {:ok, result(record, "rejected")}, else: lookup_remote(binding, record, request)
  end

  defp recover_remote_before_write(binding, record, request) do
    if rejected?(binding, record),
      do: {:ok, result(record, "rejected")},
      else: lookup_remote(binding, record, request, true)
  end

  defp lookup_remote(binding, record, request, recover_update? \\ false) do
    case request.(%{"query" => @lookup, "variables" => %{"id" => record["comment_id"]}}) do
      {:ok, %{status: 200, body: %{"data" => %{"comment" => comment}} = body}} when is_map(comment) ->
        reconcile_comment(
          binding,
          record,
          comment,
          Map.get(body, "errors", []),
          request,
          recover_update?
        )

      _ ->
        {:ok, result(record, "pending")}
    end
  end

  defp reconcile_comment(binding, record, comment, errors, request, recover_update?) do
    cond do
      errors not in [nil, []] ->
        {:ok, result(record, "conflict")}

      matches?(record, comment, binding) ->
        confirm_recovered_comment(binding, record, comment, recover_update?)

      recover_update? and safely_unapplied_update?(binding, record, comment) ->
        replay_update(binding, record, request)

      true ->
        {:ok, result(record, "conflict")}
    end
  end

  defp confirm_recovered_comment(binding, record, comment, recover_update?) do
    with :ok <-
           persist_recovery(binding, record, "confirmed", %{"comment" => comment, "recovered" => true}, recover_update?) do
      {:ok, recovered_result(record, recover_update?)}
    end
  end

  defp persist_recovery(binding, record, suffix, value, true) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn -> persist(binding, path(binding, record, suffix), value) end,
      10_000,
      "write-recovery-#{suffix}"
    )
  end

  defp persist_recovery(binding, record, suffix, value, false), do: persist(binding, path(binding, record, suffix), value)

  defp recovered_result(%{"operation" => "commentUpdate"} = record, true) do
    Map.put(result(record, "confirmed"), "recovered_update", true)
  end

  defp recovered_result(record, _recover_update?), do: result(record, "confirmed")

  defp safely_unapplied_update?(binding, record, comment) do
    record["operation"] == "commentUpdate" and
      record["replay_attempted"] != true and
      nonempty?(record["previous_version"]) and
      nonempty?(record["author_id"]) and
      record["author_id"] == binding["user_id"] and
      comment["updatedAt"] == record["previous_version"] and
      same_comment_identity?(binding, record, comment)
  end

  defp same_comment_identity?(binding, record, comment) do
    author_id = Map.get(record, "author_id", binding["user_id"])

    comment["id"] == record["comment_id"] and
      get_in(comment, ["user", "id"]) == author_id and
      (is_nil(record["issue_id"]) or
         record["issue_id"] in [
           get_in(comment, ["issue", "id"]),
           get_in(comment, ["issue", "identifier"])
         ])
  end

  defp replay_update(binding, record, request) do
    payload = %{
      "query" => @recovery_update,
      "variables" => %{"id" => record["comment_id"], "input" => record["input"]}
    }

    with :ok <- persist_recovery(binding, record, "intent", Map.put(record, "replay_attempted", true), true) do
      case request.(payload) do
        {:ok, response} ->
          confirm_replayed_update(binding, record, response)

        _ ->
          {:ok, result(record, "pending")}
      end
    end
  end

  defp confirm_replayed_update(binding, record, response) do
    case response_comment(response, "recovered") do
      comment when is_map(comment) -> confirm_replayed_comment(binding, record, comment)
      _comment -> {:ok, result(record, "pending")}
    end
  end

  defp confirm_replayed_comment(binding, record, comment) do
    if matches?(record, comment, binding) do
      confirm_recovered_comment(binding, record, comment, true)
    else
      {:ok, result(record, "pending")}
    end
  end

  defp result(record, state), do: %{"comment_id" => record["comment_id"], "state" => state}

  defp matches?(record, comment, binding) do
    author_id = Map.get(record, "author_id", binding["user_id"])

    comment["id"] == record["comment_id"] and get_in(comment, ["user", "id"]) == author_id and
      (is_nil(record["issue_id"]) or record["issue_id"] in [get_in(comment, ["issue", "id"]), get_in(comment, ["issue", "identifier"])]) and
      Enum.all?(Map.take(record["input"], ~w(body bodyData quotedText resolvingUserId resolvingCommentId)), &field_matches?(&1, comment))
  end

  defp field_matches?({"bodyData", expected}, comment), do: normalize_json(comment["bodyData"]) == normalize_json(expected)
  defp field_matches?({"resolvingUserId", expected}, comment), do: get_in(comment, ["resolvingUser", "id"]) == expected
  defp field_matches?({"resolvingCommentId", expected}, comment), do: get_in(comment, ["resolvingComment", "id"]) == expected
  defp field_matches?({key, expected}, comment), do: Map.fetch(comment, key) == {:ok, expected}

  defp normalize_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp normalize_json(value), do: value

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp intents(binding), do: intents(binding, &read_intent(binding, &1))

  defp intents(binding, reader) do
    with {:ok, files} <- active_files(binding),
         {:ok, catalog} <- archive_catalog(binding),
         {:ok, active} <- files |> Enum.filter(&String.ends_with?(&1, ".intent.json")) |> read_many(reader) do
      # The catalog is made durable before any move. It wins during interrupted
      # moves, so a confirmation cannot temporarily become pending.
      records = active |> Map.new(&{&1["operation_id"], &1}) |> Map.merge(catalog)
      {:ok, Map.values(records)}
    end
  end

  defp active_files(binding) do
    case File.ls(directory(binding)) do
      {:ok, files} -> {:ok, files}
      {:error, :enoent} -> {:ok, []}
      _ -> {:error, :comment_journal_unavailable}
    end
  end

  defp read_intent(binding, file) do
    with {:ok, record} <- DurableState.read(Path.join(directory(binding), file)),
         true <- record["workspace_id"] == binding["workspace_id"],
         :ok <- matching_installation(record, binding) do
      {:ok, record}
    else
      {:error, {:local_state_requires_handoff, _, _}} = error -> error
      _ -> {:error, :comment_journal_corrupt}
    end
  end

  defp matching_installation(record, binding) do
    if record["installation_id"] == binding["installation_id"],
      do: :ok,
      else: {:error, {:local_state_requires_handoff, directory(binding), LocalState.handoff_message()}}
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp read_many(items, fun) do
    items
    |> Task.async_stream(fun, max_concurrency: 32, timeout: 30_000, ordered: false)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, value}}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:ok, error}, _acc -> {:halt, error}
      _, _acc -> {:halt, {:error, :comment_journal_unavailable}}
    end)
  end

  defp reduce_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp persist(binding, path, record) do
    writer = Map.get(binding, :state_writer, &DurableState.write/2)

    case writer.(path, record) do
      :ok -> :ok
      _ -> {:error, :comment_journal_persist_failed}
    end
  end

  defp path(binding, receipt, suffix), do: Path.join(directory(binding), receipt["operation_id"] <> "." <> suffix <> ".json")
  defp directory(binding), do: Path.join(binding["state_root"], "comments")

  defp output_type(body, context) when is_binary(body) do
    cond do
      Workpad.comment_matches?(body) -> "workpad"
      String.starts_with?(body, "### Antwort Symphony") or context["phase"] == "Todo (Dialog-AI)" -> "dialog"
      context["phase"] in ["Review (AI)", "PreReview (AI)"] -> "review"
      true -> "comment"
    end
  end

  defp output_type(_body, _context), do: "comment"
end
