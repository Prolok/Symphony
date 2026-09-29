defmodule SymphonyElixir.Linear.TrustedAgents do
  @moduledoc "Verified Linear app actors with the same decision authority as the configured human."

  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{Client, CommentVersion}

  @spec ids() :: [String.t()]
  def ids do
    case ProjectContext.current() do
      %{trusted_binding: binding, settings: %{tracker: tracker}} when is_binary(binding) ->
        if binding == binding_key(tracker), do: tracker.trusted_agent_ids, else: []

      _ ->
        []
    end
  end

  @spec verified?(ProjectContext.t() | nil) :: boolean()
  def verified?(nil), do: false
  def verified?(context), do: context.settings.tracker.trusted_agent_ids == [] or context.trusted_binding == binding_key(context.settings.tracker)

  @spec resolve({:ok, ProjectContext.t()} | {:error, term()}) :: {:ok, ProjectContext.t()} | {:error, term()}
  def resolve({:ok, context}) do
    with :ok <- ProjectContext.with_context(context, &verify/0) do
      {:ok, %{context | trusted_binding: binding_key(context.settings.tracker)}}
    end
  end

  def resolve(error), do: error

  @spec verify() :: :ok | {:error, term()}
  def verify do
    tracker = Config.settings!().tracker

    if verified?(ProjectContext.current()),
      do: :ok,
      else: verify(tracker.trusted_agent_ids, tracker.app["workspace_id"], tracker.app["user_id"])
  end

  @spec consistent?([ProjectContext.t()]) :: boolean()
  def consistent?([]), do: true

  def consistent?(contexts) do
    contexts
    |> Enum.map(& &1.settings.tracker.trusted_agent_ids)
    |> Enum.uniq()
    |> length() == 1
  end

  @spec trusted?(map(), [String.t()]) :: boolean()
  def trusted?(source, ids) do
    actor = source["user"] || source["actor"]

    is_map(actor) and actor["app"] == true and is_binary(actor["id"]) and actor["id"] in ids and
      is_nil(source["botActor"]) and is_nil(source["externalUser"]) and is_nil(source["onBehalfOf"])
  end

  @spec human_or_trusted?(map(), [String.t()]) :: boolean()
  def human_or_trusted?(source, ids) do
    actor = source["user"] || source["actor"]

    trusted?(source, ids) or
      (is_map(actor) and actor["app"] == false and is_binary(actor["id"]) and
         is_nil(source["botActor"]) and is_nil(source["externalUser"]) and is_nil(source["onBehalfOf"]))
  end

  defp binding_key(tracker), do: CommentVersion.digest([tracker.app, tracker.trusted_agent_ids])

  defp verify([], _workspace, _own), do: :ok

  defp verify(ids, workspace, own) do
    query = """
    query SymphonyTrustedAgents($filter: UserFilter!) {
      users(filter: $filter, first: 100) {
        nodes { id app active name organization { id } }
        pageInfo { hasNextPage }
      }
    }
    """

    with false <- own in ids,
         {:ok, %{"data" => %{"users" => %{"nodes" => users, "pageInfo" => %{"hasNextPage" => false}}}} = response} <-
           Client.graphql(query, %{filter: %{"id" => %{"in" => ids}}}),
         true <- response["errors"] in [nil, []] and is_list(users),
         true <- Enum.sort(Enum.map(users, & &1["id"])) == Enum.sort(ids),
         true <- Enum.all?(users, &(&1["app"] == true and &1["active"] == true and get_in(&1, ["organization", "id"]) == workspace)) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :linear_trusted_agents_invalid}
    end
  end
end
