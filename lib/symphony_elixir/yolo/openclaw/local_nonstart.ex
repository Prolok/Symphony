defmodule SymphonyElixir.Yolo.OpenClaw.LocalNonstart do
  @moduledoc "One legacy nonstart proof from Symphony's correlated start failure and a fresh absent-session check."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Yolo.{Nonstart, OpenClaw, Store}
  alias SymphonyElixir.Yolo.OpenClaw.{Gateway, Journal}
  @binding ~w(id group project_id agent linear_agent_id linear_workspace_id session_id payload_sha256 workspace sha members)
  @start_errors [":linear_app_request_unavailable", "{:linear_api_request, :linear_app_request_unavailable}"]

  @spec recover(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def recover(order, opts) do
    if OpenClaw.enabled_for?(order) and (candidate?(order) or is_map(order["local_nonstart"])),
      do: resolve(Map.take(order, @binding), true, opts),
      else: {:error, :openclaw_local_nonstart_unconfirmed}
  end

  @spec resolve(map(), boolean(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(binding, apply?, opts) do
    context = ProjectContext.current()

    with true <- Enum.sort(Map.keys(binding)) == Enum.sort(@binding),
         true <- binding["group"] in ~w(incoming planning in_progress blocker review) and binding["project_id"] == context.id,
         true <- Config.openclaw_yolo_agent() == binding["agent"] and Config.yolo_agent_id() in [nil, binding["linear_agent_id"]],
         true <- original_session?(binding, context.id) do
      callback = fn -> resolve_locked(binding, apply?, opts) end
      ProjectContext.with_context(%{context | yolo_agent_id: binding["linear_agent_id"]}, callback)
    else
      _ -> {:error, :openclaw_local_nonstart_unconfirmed}
    end
  end

  defp original_session?(binding, project) do
    binding["session_id"] == "agent:#{binding["agent"]}:symphony:#{OpenClaw.digest(project)}:#{binding["group"]}:#{binding["id"]}"
  end

  defp resolve_locked(binding, apply?, opts), do: Store.lock(binding["group"], fn -> transition(binding, apply?, opts) end)

  defp transition(binding, apply?, opts) do
    case Journal.transition(binding, &changes(&1, binding, opts), apply?) do
      {:error, :openclaw_generation_changed} -> archived(binding)
      result -> result
    end
  end

  defp archived(binding) do
    with {:ok, %{"state" => "rejected", "local_nonstart" => proof} = order} when is_map(proof) <- Journal.history(binding["group"], binding["id"]),
         true <- Map.take(order, @binding) == binding do
      {:ok, order}
    else
      _ -> {:error, :openclaw_generation_changed}
    end
  end

  defp changes(%{"state" => "rejected", "local_nonstart" => proof} = current, binding, _opts) when is_map(proof) do
    if Map.take(current, @binding) == binding, do: {:ok, %{}}, else: {:error, :openclaw_local_nonstart_unconfirmed}
  end

  defp changes(current, binding, opts) do
    with true <- Map.take(current, @binding) == binding and candidate?(current),
         {:ok, record} <- Store.read(current["group"]),
         %{"group" => group, "run_id" => id, "reason" => reason} = failure <- record["failure"],
         true <- group == current["group"] and id == current["id"] and reason in @start_errors,
         :ok <- Nonstart.inactive(record, id),
         true <- get_in(record, ["attempt", "workspace"]) == current["workspace"] and get_in(record, ["attempt", "sha"]) == current["sha"],
         {:ok, absent} <- Gateway.absent_session(current, opts) do
      proof = %{
        "kind" => "local_nonstart",
        "phase" => "before_delivery",
        "reason" => "linear_app_request_unavailable",
        "failure" => failure,
        "failure_sha256" => OpenClaw.digest(Jason.encode!(failure)),
        "session_check_sha256" => OpenClaw.digest(Jason.encode!(absent)),
        "checked_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      {:ok,
       %{
         "state" => "rejected",
         "writable" => false,
         "error" => "openclaw_local_nonstart",
         "rejection" => proof,
         "local_nonstart" => proof,
         "recovery" => proof,
         "before_recovery" => Map.take(current, ~w(state error cancel_requested abort_acknowledged abort_error))
       }}
    else
      _ -> {:error, :openclaw_local_nonstart_unconfirmed}
    end
  end

  defp candidate?(current) do
    # Before this contract, this exact Linear error could leave intent only in
    # before_delivery: submit results entered acceptance/await, not Linear reads.
    # Missing delivery flags alone are never enough to release an old order.
    current["state"] in ~w(intent unknown cancel_pending) and not Map.has_key?(current, "submit_started") and
      current["acceptance_observed"] != true and current["execution_observed"] != true and explicitly_unobserved?(current) and
      Enum.all?(~w(terminal checkout_proof rejection retirement), &is_nil(current[&1])) and current["abort_acknowledged"] != true
  end

  defp explicitly_unobserved?(current) do
    case get_in(current, ["linear_bridge", "snapshots"]) do
      nil ->
        current["acceptance_observed"] == false and current["execution_observed"] == false

      snapshots when is_list(snapshots) and snapshots != [] ->
        Enum.all?(snapshots, fn snapshot ->
          observation = get_in(snapshot, ["projection", "observation"])
          is_map(observation) and observation["acceptance_observed"] == false and observation["execution_observed"] == false
        end)

      _ ->
        false
    end
  end
end
