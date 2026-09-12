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

  @spec execute(map(), map(), (map() -> term()), map(), keyword()) :: term()
  def execute(binding, payload, request, context \\ %{}, opts \\ []) do
    with {:ok, prepared, receipts} <- CommentMutations.prepare(payload) do
      execute_prepared(binding, prepared, receipts, request, context, opts)
    end
  end

  defp execute_prepared(_binding, prepared, [], request, _context, _opts), do: request.(prepared)

  defp execute_prepared(binding, prepared, receipts, request, context, opts) do
    IssueLease.with_journal_lock(
      binding["state_root"],
      fn -> execute_locked(binding, prepared, receipts, request, context, opts) end,
      Keyword.get(opts, :lock_timeout, 10_000)
    )
  end

  defp execute_locked(binding, prepared, receipts, request, context, opts) do
    binding = Map.put(binding, :state_writer, Keyword.get(opts, :state_writer, &DurableState.write/2))

    with {:ok, receipts} <- collect(receipts, &hydrate_receipt(binding, &1, request)),
         :ok <- recover_before_write(binding, receipts, request),
         :ok <- persist_intents(binding, receipts, context),
         {:ok, response} <- request.(prepared),
         :ok <- confirm_response(binding, receipts, response) do
      {:ok, response}
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
    IssueLease.with_journal_lock(binding["state_root"], fn ->
      with {:ok, records} <- intents(binding) do
        collect(records, &confirm_remote(binding, &1, request))
      end
    end)
  end

  @spec classify(map(), map()) :: :own | :pending | :foreign | {:error, term()}
  def classify(binding, comment) do
    with {:ok, records} <- intents(binding) do
      classify_records(records, binding, comment)
    end
  end

  defp classify_records(records, binding, comment) do
    matches = Enum.filter(records, &(&1["comment_id"] == comment["id"] and not rejected?(binding, &1)))

    cond do
      Enum.any?(matches, &matches?(&1, comment, binding)) -> :own
      matches != [] or get_in(comment, ["user", "id"]) == binding["user_id"] -> :pending
      true -> :foreign
    end
  end

  defp recover_before_write(binding, receipts, request) do
    with {:ok, records} <- intents(binding),
         {:ok, recovered} <- collect(Enum.reject(records, &(confirmed?(binding, &1) or rejected?(binding, &1))), &confirm_remote(binding, &1, request)) do
      # Another issue or a restarted runtime may have completed reconciliation.
      # The original run/tool context is evidence, not a retry identity.
      prior = Enum.filter(records, &recovered?(binding, &1))
      check_recovery(records, recovered, receipts, prior)
    end
  end

  defp check_recovery(records, recovered, receipts, prior) do
    unresolved = Enum.filter(recovered, &(&1["state"] != "confirmed"))
    repeated = Enum.filter(records, &repeated_creation?(&1, recovered ++ prior, receipts))

    cond do
      unresolved != [] -> {:error, {:comment_write_unresolved, unresolved}}
      repeated != [] -> {:error, {:comment_write_recovered, Enum.map(repeated, & &1["comment_id"])}}
      true -> :ok
    end
  end

  defp repeated_creation?(record, recovered, receipts) do
    record["operation"] == "commentCreate" and
      Enum.any?(recovered, &(&1["comment_id"] == record["comment_id"])) and
      Enum.any?(receipts, &(&1["operation"] == "commentCreate" and comparable_input(&1) == comparable_input(record)))
  end

  defp comparable_input(record), do: Map.delete(record["input"], "id")

  defp recovered?(binding, record) do
    match?({:ok, %{"recovered" => true}}, DurableState.read(path(binding, record, "confirmed")))
  end

  defp rejected?(binding, record) do
    match?({:ok, %{"state" => "rejected"}}, DurableState.read(path(binding, record, "rejected")))
  end

  defp confirmed?(binding, record) do
    case DurableState.read(path(binding, record, "confirmed")) do
      {:ok, %{"comment" => comment}} -> matches?(record, comment, binding)
      _ -> false
    end
  end

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

  defp lookup_remote(binding, record, request) do
    case request.(%{"query" => @lookup, "variables" => %{"id" => record["comment_id"]}}) do
      {:ok, %{status: 200, body: %{"data" => %{"comment" => comment}} = body}} when is_map(comment) ->
        reconcile_comment(binding, record, comment, Map.get(body, "errors", []))

      _ ->
        {:ok, result(record, "pending")}
    end
  end

  defp reconcile_comment(binding, record, comment, errors) do
    if errors in [nil, []] and matches?(record, comment, binding) do
      with :ok <- persist(binding, path(binding, record, "confirmed"), %{"comment" => comment, "recovered" => true}) do
        {:ok, result(record, "confirmed")}
      end
    else
      {:ok, result(record, "conflict")}
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

  defp intents(binding) do
    case File.ls(directory(binding)) do
      {:ok, files} ->
        files |> Enum.filter(&String.ends_with?(&1, ".intent.json")) |> collect(&read_intent(binding, &1))

      {:error, :enoent} ->
        {:ok, []}

      _ ->
        {:error, :comment_journal_unavailable}
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
