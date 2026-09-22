defmodule SymphonyElixir.Yolo.Escalation do
  @moduledoc "Once-per-proposal notification on the configured agent's existing human channel."
  alias SymphonyElixir.Config
  alias SymphonyElixir.Yolo.{OpenClaw, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Gateway

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{"escalation" => details}) when is_map(details) do
    if Enum.all?(~w(cause attempts proposal decision), &(is_binary(details[&1]) and String.trim(details[&1]) != "")),
      do: :ok,
      else: {:error, :yolo_escalation_incomplete}
  end

  def validate(_), do: {:error, :yolo_escalation_incomplete}

  @spec notify(map(), map(), keyword()) :: :ok | {:error, term()}
  def notify(issue, args, opts) do
    case Config.openclaw_yolo_agent() do
      nil -> :ok
      agent -> notify_enabled(issue, args, agent, opts)
    end
  end

  defp notify_enabled(issue, %{"escalation" => details}, agent, opts) when is_map(details) do
    if validate(%{"escalation" => details}) == :ok and is_binary(issue.url) do
      proposal = Map.take(details, ~w(cause attempts proposal decision))
      id = OpenClaw.digest(:erlang.term_to_binary({agent, issue.id, Enum.sort(proposal)}))
      key = "escalation:" <> issue.id
      Store.lock(key, fn -> dispatch(key, id, issue, proposal, agent, opts) end)
    else
      {:error, :yolo_escalation_incomplete}
    end
  end

  defp notify_enabled(_, _, _, _), do: {:error, :yolo_escalation_incomplete}

  defp dispatch(key, id, issue, proposal, agent, opts) do
    with {:ok, record} <- Store.read(key) do
      case get_in(record, ["messages", id]) do
        %{"state" => "sent"} -> :ok
        nil -> send_message(key, id, issue, proposal, agent, record, opts)
        _ -> {:error, :yolo_escalation_delivery_unconfirmed}
      end
    end
  end

  defp send_message(key, id, issue, proposal, agent, record, opts) do
    route = Keyword.get(opts, :escalation_route, &Gateway.destination/2)
    send = Keyword.get(opts, :escalation_send, &Gateway.notify/3)

    with {:ok, destination} <- route.(agent, opts),
         message = message(issue, id, proposal),
         intent = %{"state" => "intent", "destination" => destination, "proposal" => proposal, "id" => id},
         :ok <- save(key, record, id, intent) do
      # An uncertain transport outcome is never submitted a second time, even
      # if the external gateway's deduplication cache has expired.
      case send.(Map.merge(destination, %{"idempotencyKey" => id, "agentId" => agent}), message, opts) do
        {:ok, %{"messageId" => message_id} = evidence} when is_binary(message_id) and message_id != "" ->
          save(key, record, id, Map.merge(intent, %{"state" => "sent", "evidence" => Map.take(evidence, ~w(messageId channel))}))

        _ ->
          {:error, :yolo_escalation_delivery_unconfirmed}
      end
    end
  end

  defp save(key, record, id, receipt), do: Store.write(key, Map.put(record, "messages", Map.put(record["messages"] || %{}, id, receipt)))

  defp message(issue, id, proposal) do
    "#{issue.identifier}: #{issue.url}\nUrsache: #{proposal["cause"]}\nVersuche: #{proposal["attempts"]}\nVorschlag: #{proposal["proposal"]}\nEntscheidung: #{proposal["decision"]}\nVorschlags-ID: #{id}\nEin OK gilt ausschließlich für diesen Vorschlag; bestehende Zugangs- und Deploymentfreigaben bleiben erforderlich."
  end
end
