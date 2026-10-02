defmodule SymphonyElixir.Yolo.Nonstart do
  @moduledoc "Conservative recovery of an interrupted, locally unstarted PO checkout under the group lock."
  require Logger
  alias SymphonyElixir.{Config, PathSafety}
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  alias SymphonyElixir.Yolo.{Operations, Store, Workspace}

  @spec reconcile(String.t()) :: :ok | {:error, term()}
  def reconcile(group) do
    with {:ok, record} <- Store.read(group) do
      reconcile_record(group, record, record["attempt"])
    end
  end

  defp reconcile_record(group, record, %{"cleanup_contract" => 1, "checkout_cleanup" => status} = attempt)
       when status in ~w(creating pending) do
    used? = is_binary(attempt["session_id"]) or attempt["session_end"] == true or not no_delivery?(record["deliveries"], attempt["id"])
    if used? or settled_external?(group, attempt), do: :ok, else: reconcile_attempt(group, record, attempt)
  end

  defp reconcile_record(_, _, _), do: :ok

  defp settled_external?(group, attempt) do
    case Journal.read(group) do
      {:ok, %{"local_nonstart" => proof}} when is_map(proof) -> false
      {:ok, order} -> resolved_order?(order, attempt)
      _ -> false
    end
  end

  @spec resolved_external_attempt?(String.t(), map()) :: boolean()
  def resolved_external_attempt?(group, attempt) do
    case Journal.read(group) do
      {:ok, order} -> resolved_order?(order, attempt)
      _ -> false
    end
  end

  defp resolved_order?(%{"id" => id, "state" => "retired", "writable" => false, "retirement" => %{"kind" => "fenced_interruption", "attempt" => proof}}, attempt),
    do: id == attempt["id"] and proof == attempt

  defp resolved_order?(%{"id" => id, "state" => "rejected", "writable" => false, "rejection" => proof}, attempt) when is_map(proof), do: id == attempt["id"]
  defp resolved_order?(_, _), do: false

  defp reconcile_attempt(group, record, %{"id" => id, "workspace" => path, "sha" => sha} = attempt) do
    workspace = %{path: path, sha: sha}
    proof = Map.take(attempt, ~w(id workspace sha))

    with true <- Workspace.owned?(group, workspace, id) and is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
         :ok <- inactive(record, id),
         :ok <- no_external_start(group, id),
         :ok <- no_unjournaled_artifacts(group, id),
         :ok <- remove(group, record, attempt, workspace, proof) do
      :ok
    else
      reason -> diagnose(group, attempt, reason)
    end
  end

  defp reconcile_attempt(group, _record, attempt), do: diagnose(group, attempt, :missing_checkout_binding)

  defp remove(group, record, attempt, workspace, proof) do
    id = attempt["id"]
    pending = Map.merge(attempt, %{"checkout_cleanup" => "pending", "cleanup_proof" => proof})

    with :ok <- removable(group, attempt, workspace, proof),
         :ok <- Store.write(group, Map.merge(record, %{"attempt" => pending, "checkout_cleanup_blocked" => true})),
         :ok <- remove_present(group, workspace, id) do
      Store.write(group, Map.merge(record, %{"attempt" => Map.put(pending, "checkout_cleanup", "removed"), "checkout_cleanup_blocked" => false}))
    end
  end

  defp removable(group, attempt, workspace, proof) do
    if attempt["checkout_cleanup"] == "pending" and attempt["cleanup_proof"] == proof and Workspace.checkout_present?(group, attempt["id"]) == {:ok, false},
      do: :ok,
      else: Workspace.remove(group, workspace, attempt["id"], false)
  end

  defp remove_present(group, workspace, id) do
    if Workspace.checkout_present?(group, id) == {:ok, false}, do: :ok, else: Workspace.remove(group, workspace, id)
  end

  @spec inactive(map(), String.t()) :: :ok | {:error, atom()}
  def inactive(record, id) do
    attempt = record["attempt"]

    if idle_attempt?(attempt, id) and is_nil(get_in(record, ["delivery_ends", id])) and no_delivery?(record["deliveries"], id) and
         is_list(attempt["members"]) and match?({:ok, []}, Operations.related(attempt["members"])) do
      :ok
    else
      {:error, :yolo_nonstart_activity_unconfirmed}
    end
  end

  defp idle_attempt?(attempt, id) do
    is_map(attempt) and attempt["id"] == id and is_nil(attempt["session_id"]) and
      is_nil(attempt["session_end"]) and (attempt["completed"] || %{}) == %{}
  end

  @spec no_delivery?(term(), String.t()) :: boolean()
  def no_delivery?(nil, _id), do: true

  def no_delivery?(deliveries, id) when is_map(deliveries) do
    Enum.all?(Map.values(deliveries), fn
      %{"run_id" => other} when is_binary(other) -> other != id
      _ -> false
    end)
  end

  def no_delivery?(_, _), do: false

  @spec no_external_start(String.t(), String.t()) :: :ok | {:error, atom()}
  def no_external_start(group, id) do
    with {:error, :enoent} <- Journal.history(group, id),
         {:ok, current} <- Journal.read(group),
         true <- safe_order?(current, id) do
      :ok
    else
      _ -> {:error, :yolo_review_delivery_uncertain}
    end
  end

  defp safe_order?(nil, _), do: true

  defp safe_order?(%{"id" => id, "state" => "rejected", "rejection" => proof} = order, id) when is_map(proof),
    do: order["acceptance_observed"] != true and order["execution_observed"] != true and is_nil(order["checkout_proof"])

  defp safe_order?(%{"id" => other} = order, id) when other != id, do: not Journal.pending?(order)
  defp safe_order?(_, _), do: false

  @spec artifacts_absent(String.t()) :: :ok | {:error, atom()}
  def artifacts_absent(id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root),
         path = Path.join([root, "yolo-runs", id]),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         {:error, :enoent} <- File.lstat(path) do
      :ok
    else
      _ -> {:error, :yolo_nonstart_artifacts_unconfirmed}
    end
  end

  defp no_unjournaled_artifacts(group, id) do
    case Journal.read(group) do
      {:ok, %{"id" => ^id, "state" => "rejected"}} -> :ok
      _ -> artifacts_absent(id)
    end
  end

  defp diagnose(group, attempt, reason) do
    members = Enum.map_join(attempt["members"] || [], " ", &"issue_id=#{&1} issue_identifier=unknown")

    Logger.warning(
      "YOLO interrupted checkout protected group=#{group} run_id=#{attempt["id"]} #{members} workspace=#{attempt["workspace"]} reason=#{inspect(reason)} action=checkout_binding_and_nonstart_evidence_required"
    )

    {:error, if(group == "review", do: :yolo_review_checkout_cleanup_unconfirmed, else: :yolo_checkout_cleanup_unconfirmed)}
  end
end
