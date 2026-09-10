defmodule SymphonyElixir.Linear.WorkpadTransfer do
  @moduledoc """
  Explicit, restartable workpad handover between separately authenticated writers.
  The caller holds the workspace/issue lease and has stopped legacy workers at a
  turn boundary. Each invocation receives one writer only; no credential fallback.
  """

  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Workpad

  @historical "## Symphony Workpad (historisch, inaktiv)"
  @type api :: (atom(), map() -> term())

  @spec begin(map(), String.t(), String.t(), map(), api()) :: {:ok, map()} | {:error, term()}
  def begin(binding, issue_id, target_user, backup, api) do
    case read(binding, issue_id) do
      {:error, :enoent} -> prepare(binding, issue_id, target_user, backup, api)
      {:ok, %{"phase" => "active"}} -> prepare(binding, issue_id, target_user, backup, api)
      {:ok, record} -> {:ok, record}
      error -> error
    end
  end

  defp prepare(binding, issue_id, target_user, backup, api) do
    with true <- backup["turns_stopped"] == true and is_map(backup["files"]),
         {:ok, identity} <- api.(:identity, %{}),
         true <- identity["workspace_id"] == binding["workspace_id"] and identity["user_id"] != target_user,
         {:ok, comments} <- api.(:list, %{"issue_id" => issue_id}),
         {:ok, source} <- single(comments),
         true <- author(source) == identity["user_id"] do
      record = %{
        "workspace_id" => binding["workspace_id"],
        "issue_id" => issue_id,
        "phase" => "prepared",
        "source" => source,
        "target_id" => Ecto.UUID.generate(),
        "source_user" => identity["user_id"],
        "target_user" => target_user,
        "backup" => backup,
        "transfer_id" => Ecto.UUID.generate()
      }

      persist(binding, record)
    else
      false -> {:error, :workpad_transfer_precondition_failed}
      error -> error
    end
  end

  @spec retire(map(), String.t(), api()) :: {:ok, map()} | {:error, term()}
  def retire(binding, issue_id, api) do
    with {:ok, record} <- read(binding, issue_id),
         :ok <- identity(api, binding, record["source_user"]),
         true <- record["phase"] in ["prepared", "retired"],
         {:ok, comments} <- api.(:list, %{"issue_id" => issue_id}),
         :ok <- check_source(record, comments),
         :ok <- api.(:update, %{"id" => record["source"]["id"], "body" => retired_body(record)}),
         {:ok, verified} <- api.(:list, %{"issue_id" => issue_id}),
         true <- retired?(record, verified) do
      persist(binding, %{record | "phase" => "retired"})
    else
      false -> {:error, :workpad_transfer_verification_failed}
      error -> error
    end
  end

  @spec activate(map(), String.t(), api()) :: {:ok, map()} | {:error, term()}
  def activate(binding, issue_id, api) do
    case read(binding, issue_id) do
      {:ok, %{"phase" => "active"} = record} ->
        with :ok <- identity(api, binding, record["target_user"]),
             {:ok, comments} <- api.(:list, %{"issue_id" => issue_id}),
             :ok <- check_current(record, Map.put(binding, "user_id", record["target_user"]), comments) do
          {:ok, record}
        end

      {:ok, _} ->
        complete_activation(binding, issue_id, api)

      error ->
        error
    end
  end

  defp complete_activation(binding, issue_id, api) do
    with {:ok, record} <- read(binding, issue_id),
         :ok <- identity(api, binding, record["target_user"]),
         true <- record["phase"] in ["retired", "active"],
         {:ok, comments} <- api.(:list, %{"issue_id" => issue_id}),
         true <- retired?(record, comments),
         :ok <- ensure_target(record, comments, api),
         :ok <- api.(:update, %{"id" => record["target_id"], "body" => target_body(record)}),
         {:ok, verified} <- api.(:list, %{"issue_id" => issue_id}),
         :ok <- check_active(record, verified) do
      persist(binding, Map.merge(record, %{"phase" => "active", "active_id" => record["target_id"]}))
    else
      false -> {:error, :workpad_transfer_verification_failed}
      error -> error
    end
  end

  @spec ready(map(), String.t(), [map()]) :: :ok | {:error, term()}
  def ready(binding, issue_id, comments) do
    case read(binding, issue_id) do
      {:ok, %{"phase" => "active"} = record} -> check_current(record, binding, comments)
      {:error, :enoent} -> check_initial(binding, issue_id, comments)
      {:ok, _} -> {:error, :workpad_transfer_incomplete}
      error -> error
    end
  end

  defp check_initial(binding, issue_id, comments) do
    with {:ok, comment} <- single(comments),
         true <- author(comment) == binding["user_id"],
         {:ok, _record} <-
           persist(binding, %{
             "workspace_id" => binding["workspace_id"],
             "issue_id" => issue_id,
             "phase" => "active",
             "active_id" => comment["id"],
             "target_user" => binding["user_id"],
             "transfer_id" => Ecto.UUID.generate()
           }) do
      :ok
    else
      false -> {:error, :workpad_migration_required}
      error -> error
    end
  end

  defp check_current(record, binding, comments) do
    with {:ok, comment} <- single(comments),
         true <- comment["id"] == record["active_id"] and author(comment) == binding["user_id"] do
      :ok
    else
      false -> {:error, :workpad_active_identity_changed}
      error -> error
    end
  end

  @spec read(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(binding, issue_id), do: DurableState.read(path(binding, issue_id))

  defp persist(binding, record) do
    # Retain every completed transfer before a later reverse handover begins.
    archive = Path.join([binding["state_root"], "transfers", "history", record["transfer_id"] <> ".json"])

    with :ok <- DurableState.write(path(binding, record["issue_id"]), record),
         :ok <- DurableState.write(archive, record) do
      {:ok, record}
    end
  end

  defp path(binding, issue_id) do
    key = :crypto.hash(:sha256, binding["workspace_id"] <> ":" <> issue_id) |> Base.encode16(case: :lower)
    Path.join([binding["state_root"], "transfers", key <> ".json"])
  end

  defp identity(api, binding, expected) do
    with {:ok, identity} <- api.(:identity, %{}),
         true <- identity["workspace_id"] == binding["workspace_id"] and identity["user_id"] == expected do
      :ok
    else
      false -> {:error, :workpad_wrong_writer}
      error -> error
    end
  end

  defp single(comments) do
    case Enum.filter(comments, &Workpad.comment_matches?(&1["body"])) do
      [comment] -> {:ok, comment}
      [] -> {:error, :workpad_comment_not_found}
      many -> {:error, {:multiple_workpad_comments, length(many)}}
    end
  end

  defp check_source(record, comments) do
    source = Enum.find(comments, &(&1["id"] == record["source"]["id"]))

    if (source && author(source) == record["source_user"]) and
         source["body"] in [record["source"]["body"], retired_body(record)], do: :ok, else: {:error, :workpad_source_changed}
  end

  defp retired?(record, comments) do
    Enum.any?(
      comments,
      &(&1["id"] == record["source"]["id"] and
          author(&1) == record["source_user"] and &1["body"] == retired_body(record))
    )
  end

  defp ensure_target(record, comments, api) do
    case Enum.find(comments, &(&1["id"] == record["target_id"])) do
      nil ->
        if Enum.any?(comments, &Workpad.comment_matches?(&1["body"])),
          do: {:error, :workpad_active_collision},
          else: api.(:create, %{"id" => record["target_id"], "issueId" => record["issue_id"], "body" => target_body(record)})

      target ->
        if author(target) == record["target_user"] and target["body"] == target_body(record) do
          :ok
        else
          {:error, :workpad_target_changed}
        end
    end
  end

  defp check_active(record, comments) do
    with {:ok, target} <- single(comments),
         true <-
           target["id"] == record["target_id"] and author(target) == record["target_user"] and
             target["body"] == target_body(record) and retired?(record, comments) do
      :ok
    else
      false -> {:error, :workpad_transfer_verification_failed}
      error -> error
    end
  end

  defp retired_body(record) do
    String.replace(record["source"]["body"], Workpad.marker(), @historical, global: false) <>
      "\n\nNachfolger: " <> record["target_id"] <> " (Übergabe " <> record["transfer_id"] <> ")\n"
  end

  defp target_body(record) do
    record["source"]["body"] <>
      "\n\nVorgänger: " <>
      record["source"]["id"] <>
      " (Übergabe " <> record["transfer_id"] <> ")\n"
  end

  defp author(comment), do: get_in(comment, ["user", "id"])
end
