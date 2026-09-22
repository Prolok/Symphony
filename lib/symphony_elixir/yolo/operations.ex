defmodule SymphonyElixir.Yolo.Operations do
  @moduledoc "Project-bound durable intents. IDs and payloads are saved before any remote creation."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Relay.Store, as: Digest

  @spec path(String.t()) :: Path.t()
  def path(key) do
    context = ProjectContext.current()
    identity = Digest.digest({context.id, context.settings.tracker.app["workspace_id"]})
    Path.join([Config.settings!().tracker.app["state_root"], "yolo-actions", identity, Digest.digest(key) <> ".json"])
  end

  @spec run(String.t(), map(), (map() -> term())) :: term()
  def run(key, request, callback) do
    IssueLease.with_journal_lock(path(key), fn ->
      with {:ok, intent} <- load(key, request), do: callback.(intent)
    end)
  end

  defp load(key, request) do
    case DurableState.read(path(key)) do
      {:error, :enoent} ->
        intent = %{"key" => key, "request" => request, "issue_id" => Ecto.UUID.generate(), "done" => false}
        with :ok <- save(intent), do: {:ok, intent}

      {:ok, %{"key" => ^key, "request" => ^request} = intent} ->
        {:ok, intent}

      _ ->
        {:error, :yolo_operation_changed_or_corrupt}
    end
  end

  @spec save(map()) :: :ok | {:error, term()}
  def save(intent), do: DurableState.write(path(intent["key"]), intent)

  @spec target_ready?(String.t()) :: boolean()
  def target_ready?(id) do
    if ProjectContext.current() do
      case related([id]) do
        {:ok, operations} -> Enum.all?(operations, &(&1["issue_id"] != id or &1["done"] == true))
        _ -> false
      end
    else
      true
    end
  end

  @spec pending([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def pending(ids) do
    with {:ok, operations} <- related(ids), do: {:ok, Enum.reject(operations, & &1["done"])}
  end

  @spec recovering_origin?(map()) :: boolean()
  def recovering_origin?(%{state: "Umsetzungsticket erstellt"} = issue) do
    source = Map.take(issue, [:title, :description, :project_id, :team_id, :assignee_id, :delegate_id]) |> Jason.encode!() |> Jason.decode!()

    case pending([issue.id]) do
      {:ok, operations} ->
        Enum.any?(operations, fn intent ->
          intent["request"]["kind"] == "aggregate" and issue.id in (intent["closing"] || []) and
            get_in(intent, ["sources", issue.id]) == source
        end)

      _ ->
        false
    end
  end

  def recovering_origin?(_), do: false

  @spec related([String.t()]) :: {:ok, [map()]} | {:error, term()}
  def related(ids) do
    Path.wildcard(Path.join(Path.dirname(path("")), "*.json"))
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case DurableState.read(file) do
        {:ok, %{"request" => request} = intent} ->
          match? = intent["issue_id"] in ids or Enum.any?(request["origin_ids"] || [], &(&1 in ids))
          {:cont, {:ok, if(match?, do: [intent | acc], else: acc)}}

        _ ->
          {:halt, {:error, :yolo_operation_changed_or_corrupt}}
      end
    end)
  end

  @doc "Expand an explicitly enabled isolated pipeline only through confirmed own acceptance fixes."
  @spec allowed_ids([String.t()] | nil) :: [String.t()] | nil
  def allowed_ids(ids) do
    if is_list(ids) and Config.settings!().tracker.app["allow_yolo_followup_ids"] == true and not is_nil(Config.test_instance()) do
      expand_allowed(ids)
    else
      ids
    end
  end

  defp expand_allowed(ids) do
    case related(ids) do
      {:ok, operations} ->
        children = operations |> Enum.filter(&owned_fix?(&1, ids)) |> Enum.map(& &1["issue_id"])

        expanded = Enum.sort(Enum.uniq(ids ++ children))
        if Enum.sort(ids) == expanded, do: expanded, else: expand_allowed(expanded)

      _ ->
        ids
    end
  end

  defp owned_fix?(intent, ids) do
    origins = intent["request"]["origin_ids"]

    intent["done"] == true and intent["request"]["kind"] == "followup" and intent["request"]["blocks_origins"] == true and
      is_list(origins) and origins != [] and Enum.all?(origins, &(&1 in ids)) and
      is_map(intent["input"]) and intent["input"]["id"] == intent["issue_id"]
  end
end
