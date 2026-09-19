defmodule SymphonyElixir.Yolo.Store do
  @moduledoc "Durable observations and receipts for a project/agent/status group."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Store, as: Digest

  @spec key(String.t()) :: String.t()
  def key(group) do
    context = ProjectContext.current()
    Digest.digest({context.id, context.settings.tracker.app["workspace_id"], Config.yolo_agent_id(), group})
  end

  @spec path(String.t()) :: Path.t()
  def path(group), do: Path.join([Config.settings!().tracker.app["state_root"], "yolo", key(group) <> ".json"])

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(group) do
    identity = key(group)

    case DurableState.read(path(group)) do
      {:error, :enoent} -> {:ok, %{"identity" => identity, "observations" => %{}, "processed" => nil, "attempt" => nil}}
      {:ok, %{"identity" => ^identity, "observations" => observations} = record} when is_map(observations) -> {:ok, record}
      _ -> {:error, :yolo_state_corrupt}
    end
  end

  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(group, record), do: DurableState.write(path(group), record)

  @spec lock(String.t(), (-> result)) :: result | {:error, term()} when result: term()
  def lock(group, callback), do: IssueLease.with_lock("symphony-yolo", key(group), callback)
end
