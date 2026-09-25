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
        %{"state" => "route_pending"} -> send_message(key, id, issue, proposal, agent, record, opts)
        nil -> send_message(key, id, issue, proposal, agent, record, opts)
        _ -> {:error, :yolo_escalation_delivery_unconfirmed}
      end
    end
  end

  defp send_message(key, id, issue, proposal, agent, record, opts) do
    route = Keyword.get(opts, :escalation_route, &Gateway.destination/2)

    case route.(agent, opts) do
      {:ok, destination} ->
        send_to_destination(key, id, issue, proposal, agent, record, destination, opts)

      {:error, reason} = error ->
        pending = %{
          "state" => "route_pending",
          "proposal" => proposal,
          "id" => id,
          "initial_error" => get_in(record, ["messages", id, "initial_error"]) || inspect(reason),
          "last_error" => inspect(reason),
          "retry_reason" => "configured_normal_route_unavailable"
        }

        with :ok <- save(key, record, id, pending), do: error
    end
  end

  defp send_to_destination(key, id, issue, proposal, agent, record, destination, opts) do
    intent = %{"state" => "intent", "destination" => destination, "proposal" => proposal, "id" => id}
    send = Keyword.get(opts, :escalation_send, &Gateway.notify/3)

    with :ok <- save(key, record, id, intent) do
      # An uncertain transport outcome is never submitted a second time.
      case send.(Map.merge(destination, %{"idempotencyKey" => id, "agentId" => agent}), message(issue, id, proposal), opts) do
        {:ok, %{"messageId" => message_id} = evidence} when is_binary(message_id) and message_id != "" ->
          save(key, record, id, Map.merge(intent, %{"state" => "sent", "evidence" => Map.take(evidence, ~w(messageId channel))}))

        _ ->
          {:error, :yolo_escalation_delivery_unconfirmed}
      end
    end
  end

  @spec retry_pending(map(), keyword()) :: :ok | {:error, term()}
  def retry_pending(issue, opts \\ []) do
    key = "escalation:" <> issue.id

    with true <- is_binary(Config.openclaw_yolo_agent()),
         {:ok, record} <- Store.read(key),
         {:ok, messages} <- messages(record) do
      messages
      |> Map.values()
      |> Enum.filter(&(&1["state"] == "route_pending"))
      |> Enum.reduce_while(:ok, &retry_entry(&1, &2, issue, opts))
    else
      false -> {:error, :openclaw_yolo_agent_unavailable}
      error -> error
    end
  end

  defp retry_entry(entry, _, issue, opts) do
    case notify(issue, %{"escalation" => entry["proposal"]}, opts) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  @spec pending(String.t()) :: {:ok, boolean()} | {:error, term()}
  def pending(id) do
    with {:ok, record} <- Store.read("escalation:" <> id),
         {:ok, messages} <- messages(record) do
      {:ok, Enum.any?(Map.values(messages), &(&1["state"] == "route_pending"))}
    end
  end

  defp messages(record) do
    messages = record["messages"] || %{}

    if is_map(messages) and Enum.all?(messages, &valid_message?/1),
      do: {:ok, messages},
      else: {:error, :yolo_escalation_journal_corrupt}
  end

  defp valid_message?({id, entry}), do: is_binary(id) and is_map(entry) and is_binary(entry["state"])

  defp save(key, record, id, receipt), do: Store.write(key, Map.put(record, "messages", Map.put(record["messages"] || %{}, id, receipt)))

  defp message(issue, id, proposal) do
    "#{issue.identifier}: #{issue.url}\nUrsache: #{proposal["cause"]}\nVersuche: #{proposal["attempts"]}\nVorschlag: #{proposal["proposal"]}\nEntscheidung: #{proposal["decision"]}\nVorschlags-ID: #{id}\nEin OK gilt ausschließlich für diesen Vorschlag; bestehende Zugangs- und Deploymentfreigaben bleiben erforderlich."
  end
end
