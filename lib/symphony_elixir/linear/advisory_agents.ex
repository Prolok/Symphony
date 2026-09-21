defmodule SymphonyElixir.Linear.AdvisoryAgents do
  @moduledoc "Verify explicitly configured advisory app users through the bound workspace client."

  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{Client, CommentVersion}

  @spec verify() :: :ok | {:error, term()}
  def verify do
    tracker = Config.settings!().tracker
    if verified?(ProjectContext.current()), do: :ok, else: verify(tracker.advisory_agent_ids, tracker.app["workspace_id"], tracker.app["user_id"])
  end

  @spec verified?(ProjectContext.t() | nil) :: boolean()
  def verified?(nil), do: false
  def verified?(context), do: context.settings.tracker.advisory_agent_ids == [] or context.advisory_binding == binding_key(context.settings.tracker)

  @spec resolve({:ok, ProjectContext.t()} | {:error, term()}) :: {:ok, ProjectContext.t()} | {:error, term()}
  def resolve({:ok, context}) do
    with :ok <- ProjectContext.with_context(context, &verify/0) do
      {:ok, %{context | advisory_binding: binding_key(context.settings.tracker)}}
    end
  end

  def resolve(error), do: error

  defp binding_key(tracker), do: CommentVersion.digest([tracker.app, tracker.advisory_agent_ids])

  defp verify([], _workspace, _own), do: :ok

  defp verify(ids, workspace, own) do
    query = """
    query SymphonyAdvisoryAgents($filter: UserFilter!) {
      users(filter: $filter, first: 100) {
        nodes { id app active organization { id } }
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
      _ -> {:error, :linear_advisory_agents_invalid}
    end
  end
end
