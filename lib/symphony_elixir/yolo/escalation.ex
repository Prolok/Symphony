defmodule SymphonyElixir.Yolo.Escalation do
  @moduledoc "Evidenced escalation to a verified project agent or the existing human channel."
  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.TrustedAgents
  alias SymphonyElixir.Yolo.{API, OpenClaw, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Gateway

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{"escalation" => details}) when is_map(details) do
    if Enum.all?(~w(cause attempts proposal decision), &(is_binary(details[&1]) and String.trim(details[&1]) != "")),
      do: :ok,
      else: {:error, :yolo_escalation_incomplete}
  end

  def validate(_), do: {:error, :yolo_escalation_incomplete}

  @spec handover(map(), map(), keyword(), (map(), map(), keyword() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def handover(issue, %{"escalation" => details} = args, opts, update) do
    with :ok <- validate(args),
         {:ok, recipient} <- recipient(opts),
         {:ok, input} <- handover_input(recipient),
         :ok <- visible_note(issue, details, recipient, opts),
         :ok <- update.(issue, input, opts) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_escalation_handoff_unconfirmed}
    end
  end

  @spec recipient(keyword()) :: {:ok, map() | nil} | {:error, term()}
  def recipient(opts) do
    case trusted_target() do
      {:ok, nil} -> {:ok, nil}
      {:ok, id} -> resolve_recipient(id, opts)
      error -> error
    end
  end

  defp trusted_target do
    with {:ok, settings} <- Config.settings() do
      id = settings.tracker.escalation_trusted_agent_id

      cond do
        is_nil(id) -> {:ok, nil}
        id not in settings.tracker.trusted_agent_ids -> {:error, :linear_escalation_trusted_agent_not_trusted}
        id not in TrustedAgents.ids() -> {:error, :linear_escalation_trusted_agent_unverified}
        true -> {:ok, id}
      end
    end
  end

  defp resolve_recipient(id, opts) do
    document = "query YoloEscalationRecipient($filter: UserFilter!) { users(filter: $filter, first: 2) { nodes { id app active url isMentionable organization { id } } pageInfo { hasNextPage } } }"
    app = Config.settings!().tracker.app

    with {:ok, %{"users" => %{"nodes" => [user], "pageInfo" => %{"hasNextPage" => false}}}} <- API.query(document, %{filter: %{"id" => %{"eq" => id}}}, opts),
         true <- user["id"] == id and user["app"] == true and user["active"] == true and id != app["user_id"],
         true <- get_in(user, ["organization", "id"]) == app["workspace_id"],
         true <- is_boolean(user["isMentionable"]),
         true <- user["isMentionable"] == false or profile_url?(user["url"]) do
      {:ok, %{id: id, url: if(user["isMentionable"], do: user["url"])}}
    else
      {:error, _} = error -> error
      _ -> {:error, :linear_escalation_trusted_agent_unconfirmed}
    end
  end

  defp profile_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "linear.app", path: path, userinfo: nil} when is_binary(path) -> String.starts_with?(path, "/")
      _ -> false
    end
  end

  defp profile_url?(_), do: false

  @spec owner(keyword()) :: {:ok, String.t()} | {:error, term()}
  def owner(opts) do
    with {:ok, recipient} <- recipient(opts) do
      case {recipient, Config.human_handoff_id()} do
        {nil, human} when is_binary(human) -> {:ok, "Menschliche Zuständigkeit: @#{human}."}
        # Preserve the workpad's strict Markdown readback. Only the visible
        # decision comment emits a profile URL that Linear turns into a mention.
        {%{} = agent, _} -> {:ok, recipient_line(%{agent | url: nil})}
        _ -> {:error, :yolo_escalation_handoff_unconfirmed}
      end
    end
  end

  defp recipient_line(agent), do: "Eskalationsziel: Trusted Agent `#{agent.id}`" <> if(agent.url, do: " – #{agent.url}", else: "")

  defp handover_input(nil) do
    case Config.human_handoff_id() do
      human when is_binary(human) -> {:ok, %{assigneeId: human, delegateId: nil}}
      _ -> {:error, :yolo_escalation_handoff_unconfirmed}
    end
  end

  defp handover_input(%{}), do: {:ok, %{delegateId: nil}}

  defp visible_note(issue, details, recipient, opts) do
    proposal = String.trim(details["proposal"])
    decision = String.trim(details["decision"])
    prefix = "Entscheidung benötigt für #{issue.identifier}"
    suffix = "\n\nFrage: #{decision}\nEmpfehlung: #{proposal}"
    body = prefix <> if(recipient, do: "\n\n" <> recipient_line(recipient), else: "") <> suffix
    matches = note_matcher(body, prefix, suffix, recipient)
    fetch = Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1)
    create = Keyword.get(opts, :escalation_comment, &Tracker.create_comment/2)

    with {:ok, comments} <- fetch.(issue.id), do: ensure_note(comments, issue.id, body, matches, fetch, create)
  end

  defp note_matcher(body, _, _, nil), do: &(Map.get(&1, :body) == body)
  defp note_matcher(body, _, _, %{url: nil}), do: &(Map.get(&1, :body) == body)

  defp note_matcher(body, prefix, suffix, recipient) do
    # Confirm the rendered link's target as well as the stable recipient UUID.
    # An absent, foreign or additional mention must not acknowledge this note.
    start = prefix <> "\n\nEskalationsziel: Trusted Agent `#{recipient.id}` – "
    targets = Enum.map_join([recipient.url, "linear://userMention/#{recipient.id}"], "|", &Regex.escape/1)
    rendered = Regex.compile!("\\A#{Regex.escape(start)}\\[[^\\]\\r\\n]+\\]\\((?:#{targets})\\)#{Regex.escape(suffix)}\\z")

    fn comment ->
      actual = Map.get(comment, :body)
      is_binary(actual) and (actual == body or Regex.match?(rendered, actual))
    end
  end

  defp ensure_note(comments, id, body, matches, fetch, create) do
    if Enum.any?(comments, matches) do
      :ok
    else
      result = create.(id, body)
      verify_note(fetch.(id), matches, result)
    end
  end

  defp verify_note({:ok, comments}, matches, result) do
    cond do
      Enum.any?(comments, matches) -> :ok
      result == :ok -> {:error, :yolo_escalation_comment_unconfirmed}
      true -> result
    end
  end

  defp verify_note({:error, _} = error, _body, _result), do: error

  @spec notify(map(), map(), keyword()) :: :ok | {:error, term()}
  def notify(issue, args, opts) do
    case trusted_target() do
      {:ok, nil} ->
        case Config.openclaw_yolo_agent() do
          nil -> :ok
          agent -> notify_enabled(issue, args, agent, opts)
        end

      {:ok, _id} ->
        :ok

      error ->
        error
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
    case trusted_target() do
      {:ok, nil} -> retry_human_pending(issue, opts)
      {:ok, _id} -> :ok
      error -> error
    end
  end

  defp retry_human_pending(issue, opts) do
    key = "escalation:" <> issue.id

    with true <- is_binary(Config.openclaw_yolo_agent()),
         {:ok, record} <- Store.read(key),
         {:ok, messages} <- messages(record) do
      messages
      |> Map.values()
      |> Enum.filter(&(&1["state"] == "route_pending" and (is_nil(opts[:notification_id]) or &1["id"] == opts[:notification_id])))
      |> Enum.reduce_while(:ok, &retry_entry(&1, &2, issue, opts))
    else
      false -> {:error, :openclaw_yolo_agent_unavailable}
      error -> error
    end
  end

  @spec pending_routes(String.t()) :: {:ok, [{String.t(), String.t() | nil}]} | {:error, term()}
  def pending_routes(id) do
    case trusted_target() do
      {:ok, nil} -> human_pending_routes(id)
      {:ok, _id} -> {:ok, []}
      error -> error
    end
  end

  defp human_pending_routes(id) do
    with {:ok, record} <- Store.read("escalation:" <> id),
         {:ok, messages} <- messages(record) do
      {:ok, Enum.flat_map(messages, fn {key, entry} -> if entry["state"] == "route_pending", do: [{key, entry["last_error"]}], else: [] end)}
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
    case trusted_target() do
      {:ok, nil} -> human_pending(id)
      {:ok, _id} -> {:ok, false}
      error -> error
    end
  end

  defp human_pending(id) do
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
