defmodule SymphonyElixir.Yolo.OpenClaw.LinearBridge.Projection do
  @moduledoc "Allowlisted projection of original journal evidence; no host fields or authority inferred from prompts."
  alias SymphonyElixir.Yolo.OpenClaw
  @flags ~w(writable acceptance_observed execution_observed cancel_requested abort_acknowledged)

  @spec payload(map(), map(), pos_integer()) :: {:ok, map()} | {:error, atom()}
  def payload(order, config, sequence) do
    ids = Enum.map(order["members"], & &1["id"])

    binding = %{
      "order_id" => order["id"],
      "group" => order["group"],
      "project_id" => order["project_id"],
      "linear_workspace_id" => order["linear_workspace_id"],
      "linear_agent_id" => order["linear_agent_id"],
      "openclaw_agent_id" => order["agent"],
      "workspace" => order["workspace"],
      "source_sha" => order["sha"],
      "payload_sha256" => order["payload_sha256"],
      "issue_ids" => Enum.sort(ids),
      "native" => %{"runId" => order["id"], "sessionKey" => order["session_id"]}
    }

    if valid_binding?(binding) and length(ids) == length(Enum.uniq(ids)) do
      observation = Map.new(@flags, &{&1, order[&1] == true})
      observation = Map.merge(observation, %{"state" => order["state"], "terminal" => terminal(order), "rejection" => rejection(order), "retirement" => retirement(order)})

      {:ok,
       %{"version" => 1, "producer_id" => config["producer_id"], "consumer_account_id" => config["consumer_account_id"], "sequence" => sequence, "binding" => binding, "observation" => observation}}
    else
      {:error, :openclaw_bridge_binding_invalid}
    end
  end

  defp valid_binding?(binding) do
    uuids = [binding["order_id"], binding["linear_workspace_id"], binding["linear_agent_id"] | binding["issue_ids"]]
    session = "agent:#{binding["openclaw_agent_id"]}:symphony:#{OpenClaw.digest(binding["project_id"])}:#{binding["group"]}:#{binding["order_id"]}"

    binding["issue_ids"] != [] and Enum.all?(uuids, &uuid?/1) and
      Enum.all?(~w(project_id workspace), &(is_binary(binding[&1]) and Path.type(binding[&1]) == :absolute)) and
      binding["group"] in ~w(incoming planning in_progress blocker review) and
      hex?(binding["source_sha"], [40, 64]) and hex?(binding["payload_sha256"], [64]) and binding["native"]["sessionKey"] == session
  end

  defp uuid?(value), do: match?({:ok, ^value}, Ecto.UUID.cast(value))

  defp hex?(value, sizes), do: is_binary(value) and byte_size(value) in sizes and Regex.match?(~r/\A[0-9a-f]+\z/, value)

  defp terminal(%{"terminal" => proof, "recovery" => %{"kind" => "terminal_original"} = recovery}) when is_map(proof) do
    proof
    |> Map.take(~w(runId status state startedAt endedAt))
    |> Map.merge(Map.take(recovery, ~w(evidence_sha256 source_sha256 execution_source_sha256)))
    |> Map.put("kind", "operator_terminal_original")
  end

  defp terminal(%{"terminal" => proof}) when is_map(proof),
    do: proof |> Map.take(~w(runId status startedAt endedAt stopReason)) |> Map.reject(fn {_, value} -> is_nil(value) end) |> Map.put("kind", "gateway")

  defp terminal(_), do: nil

  defp rejection(%{"rejection" => proof, "recovery" => recovery}) when is_map(proof) and is_map(recovery) do
    recovery |> Map.take(~w(code reason request_id source_sha256 execution_source_sha256 evidence_sha256)) |> Map.put("kind", "operator_pre_acceptance")
  end

  defp rejection(%{"rejection" => proof}) when is_map(proof), do: proof |> Map.take(~w(method phase code reason request_sha256 id session_id agent payload_sha256)) |> Map.put("kind", "gateway")
  defp rejection(_), do: nil

  defp retirement(%{"retirement" => proof}) when is_map(proof), do: Map.take(proof, ~w(kind stop_basis retired_at history_sha256 physical_session_id last_run_id session_end))
  defp retirement(_), do: nil
end
