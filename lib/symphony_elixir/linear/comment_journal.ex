defmodule SymphonyElixir.Linear.CommentJournal do
  @moduledoc """
  Durable app comment receipts, protected by a separate host-local journal transaction lock.
  Intent precedes HTTP. Pending writes are reconciled before subsequent writes;
  unknown outcomes remain visible and cannot cause a blind duplicate creation.
  """

  alias SymphonyElixir.Linear.{CommentMutations, DurableState, IssueLease}
  alias SymphonyElixir.Workpad

  @lookup "query SymphonyReceipt($id: String!) { comment(id: $id) { id body bodyData updatedAt user { id } issue { id } } }"

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

    with :ok <- recover_before_write(binding, receipts, request, context),
         {:ok, receipts} <- collect(receipts, &hydrate_receipt(binding, &1, request)),
         :ok <- persist_intents(binding, receipts, context),
         {:ok, response} <- request.(prepared),
         :ok <- confirm_response(binding, receipts, response) do
      {:ok, response}
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
    matches = Enum.filter(records, &(&1["comment_id"] == comment["id"]))

    cond do
      Enum.any?(matches, &matches?(&1, comment, binding)) -> :own
      matches != [] or get_in(comment, ["user", "id"]) == binding["user_id"] -> :pending
      true -> :foreign
    end
  end

  defp recover_before_write(binding, receipts, request, context) do
    with {:ok, records} <- intents(binding),
         {:ok, recovered} <- collect(Enum.reject(records, &confirmed?(binding, &1)), &confirm_remote(binding, &1, request)) do
      prior = Enum.filter(records, &(recovered?(binding, &1) and &1["context"] == context))
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
    reduce_ok(receipts, fn receipt ->
      comment = get_in(response, [:body, "data", receipt["field"], "symphonyReceipt"])
      confirm_comment(binding, receipt, comment)
    end)
  end

  defp confirm_comment(binding, receipt, comment) when is_map(comment) do
    if matches?(receipt, comment, binding),
      do: persist(binding, path(binding, receipt, "confirmed"), %{"comment" => comment}),
      else: :ok
  end

  defp confirm_comment(_binding, _receipt, _comment), do: :ok

  defp confirm_remote(binding, record, request) do
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
    comment["id"] == record["comment_id"] and get_in(comment, ["user", "id"]) == binding["user_id"] and
      (is_nil(record["issue_id"]) or get_in(comment, ["issue", "id"]) == record["issue_id"]) and
      Enum.all?(Map.take(record["input"], ["body", "bodyData"]), fn {key, value} -> comment[key] == value end)
  end

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
         true <- record["workspace_id"] == binding["workspace_id"] do
      {:ok, record}
    else
      _ -> {:error, :comment_journal_corrupt}
    end
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
