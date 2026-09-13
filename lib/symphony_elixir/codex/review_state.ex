defmodule SymphonyElixir.Codex.ReviewState do
  @moduledoc "Durable continuation of one issue's current review in its original Codex thread."

  alias SymphonyElixir.{Config, RuntimePaths}
  alias SymphonyElixir.Linear.DurableState

  @spec open(map() | nil, Path.t(), String.t() | nil, keyword()) :: {:ok, map() | nil} | {:error, term()}
  def open(issue, workspace, host, opts \\ []) do
    root = Keyword.get(opts, :review_state_root, Config.settings!().tracker.app["state_root"])

    enabled = Config.settings!().tracker.kind == "linear" or Keyword.has_key?(opts, :review_state_root)

    if enabled and is_map(issue) and issue.state == "Review (AI)" and is_binary(root) do
      open_bound(issue, workspace, host, root)
    else
      {:ok, nil}
    end
  end

  defp open_bound(issue, workspace, host, root) do
    binding = %{"project" => RuntimePaths.project_root(), "issue_id" => issue.id, "workspace" => workspace, "worker_host" => host}
    context = %{path: state_path(root, issue.id), binding: binding}

    case DurableState.read(context.path) do
      {:error, :enoent} ->
        {:ok, context}

      {:ok, record} ->
        cond do
          not valid?(record, binding) -> {:error, :review_state_invalid}
          record["departed"] == true -> {:error, :review_state_departed}
          true -> {:ok, context}
        end

      error ->
        error
    end
  end

  @spec persisted_binding(map()) ::
          {:ok,
           :absent
           | %{
               workspace: Path.t(),
               worker_host: String.t() | nil,
               departed: boolean()
             }}
          | {:error, term()}
  def persisted_binding(%{id: issue_id}) when is_binary(issue_id) do
    case Config.settings!().tracker.app["state_root"] do
      root when is_binary(root) -> read_persisted_binding(root, issue_id)
      _root -> {:ok, :absent}
    end
  end

  def persisted_binding(_issue), do: {:ok, :absent}

  @spec mark_departed(map()) :: :ok | {:error, term()}
  def mark_departed(%{id: issue_id}) when is_binary(issue_id) do
    case Config.settings!().tracker.app["state_root"] do
      root when is_binary(root) -> mark_persisted_departed(root, issue_id)
      _root -> :ok
    end
  end

  def mark_departed(_issue), do: :ok

  @spec worker_host(map()) :: {:ok, :unbound | {:bound, String.t() | nil}} | {:error, term()}
  def worker_host(%{id: issue_id, state: "Review (AI)"}) when is_binary(issue_id) do
    case Config.settings!().tracker.app["state_root"] do
      root when is_binary(root) -> read_worker_host(root, issue_id)
      _root -> {:ok, :unbound}
    end
  end

  def worker_host(_issue), do: {:ok, :unbound}

  defp read_worker_host(root, issue_id) do
    case DurableState.read(state_path(root, issue_id)) do
      {:error, :enoent} -> {:ok, :unbound}
      {:ok, %{"binding" => binding} = record} when is_map(binding) -> worker_host_from_record(record, binding, issue_id)
      {:ok, _record} -> {:error, :review_state_invalid}
      error -> error
    end
  end

  defp read_persisted_binding(root, issue_id) do
    case read_persisted_record(root, issue_id) do
      {:ok, :absent} ->
        {:ok, :absent}

      {:ok, {_path, record, binding}} ->
        {:ok,
         %{
           workspace: binding["workspace"],
           worker_host: binding["worker_host"],
           departed: record["departed"] == true
         }}

      error ->
        error
    end
  end

  defp mark_persisted_departed(root, issue_id) do
    case read_persisted_record(root, issue_id) do
      {:ok, :absent} -> :ok
      {:ok, {path, record, _binding}} -> DurableState.write(path, Map.put(record, "departed", true))
      error -> error
    end
  end

  defp read_persisted_record(root, issue_id) do
    path = state_path(root, issue_id)

    case DurableState.read(path) do
      {:error, :enoent} ->
        {:ok, :absent}

      {:ok, %{"binding" => binding} = record} when is_map(binding) ->
        if valid_worker_binding?(record, binding, issue_id),
          do: {:ok, {path, record, binding}},
          else: {:error, :review_state_invalid}

      {:ok, _record} ->
        {:error, :review_state_invalid}

      error ->
        error
    end
  end

  defp worker_host_from_record(record, binding, issue_id) do
    cond do
      not valid_worker_binding?(record, binding, issue_id) -> {:error, :review_state_invalid}
      record["departed"] == true -> {:error, :review_state_departed}
      true -> {:ok, {:bound, binding["worker_host"]}}
    end
  end

  defp valid_worker_binding?(record, binding, issue_id) do
    valid?(record, binding) and binding["project"] == RuntimePaths.project_root() and
      binding["issue_id"] == issue_id and nonempty?(binding["workspace"]) and
      (is_nil(binding["worker_host"]) or nonempty?(binding["worker_host"]))
  end

  @spec read(map() | nil) :: map()
  def read(nil), do: %{}

  def read(context) do
    case DurableState.read(context.path) do
      {:error, :enoent} ->
        %{"version" => 1, "binding" => context.binding, "thread_id" => nil, "calls" => %{}, "agents" => %{}, "results" => %{}}

      {:ok, record} ->
        if valid?(record, context.binding), do: record, else: raise("review_state_invalid")

      {:error, reason} ->
        raise inspect(reason)
    end
  end

  @spec bind_thread(map() | nil, String.t()) :: :ok
  def bind_thread(nil, _thread_id), do: :ok

  def bind_thread(context, thread_id) do
    record = read(context)
    if record["thread_id"] not in [nil, thread_id], do: raise("review_thread_binding_mismatch")
    write!(context, Map.put(record, "thread_id", thread_id))
  end

  @spec observe(map() | nil, map()) :: [String.t()]
  def observe(nil, _payload), do: []

  def observe(context, %{"method" => method, "params" => params}) when method in ["item/started", "item/completed"] do
    record = read(context)

    if params["threadId"] == record["thread_id"] and is_binary(params["turnId"]) do
      {updated, completed} = observe_item(record, params["item"], params["turnId"])
      if updated != record, do: write!(context, updated)
      completed
    else
      []
    end
  end

  def observe(_context, _payload), do: []

  @spec restore_parent(map(), map()) :: [String.t()]
  def restore_parent(context, thread) do
    record = read(context)
    validate_thread!(context, thread, record["thread_id"], nil)

    updated =
      Enum.reduce(thread["turns"], record, fn turn, acc ->
        require_full!(turn)
        Enum.reduce(turn["items"], acc, fn item, current -> elem(observe_item(current, item, turn["id"]), 0) end)
      end)

    if updated != record, do: write!(context, updated)
    Map.keys(updated["agents"])
  end

  @spec capture(map(), String.t(), map()) :: [map()]
  def capture(context, child_id, thread) do
    record = read(context)
    unless Map.has_key?(record["agents"], child_id), do: raise("review_child_unbound")
    validate_thread!(context, thread, child_id, record["thread_id"])

    results =
      for turn <- thread["turns"],
          turn["status"] == "completed",
          :ok = require_full!(turn),
          item <- final_messages(turn),
          is_binary(item["id"]),
          is_binary(item["text"]),
          String.trim(item["text"]) != "" do
        %{"parent_thread_id" => record["thread_id"], "child_thread_id" => child_id, "turn_id" => turn["id"], "item_id" => item["id"], "text" => item["text"], "delivered_in_turn" => nil}
      end

    validate_stored_results!(record, child_id, results)
    {updated, fresh} = Enum.reduce(results, {record, []}, &put_result/2)

    if updated != record, do: write!(context, updated)
    fresh
  end

  defp final_messages(turn) do
    messages = Enum.filter(turn["items"], &(&1["type"] == "agentMessage"))

    case Enum.filter(messages, &(&1["phase"] == "final_answer")) do
      [] -> unknown_phase_final(List.last(messages))
      finals -> finals
    end
  end

  # The protocol explicitly permits absent phases for legacy providers.
  # Only the last assistant message of an already completed turn qualifies.
  defp unknown_phase_final(%{"type" => "agentMessage"} = item) do
    if is_nil(item["phase"]), do: [item], else: []
  end

  defp unknown_phase_final(_item), do: []

  defp validate_stored_results!(record, child_id, observed) do
    observed_keys = MapSet.new(observed, &result_key/1)

    Enum.each(record["results"], fn {key, result} ->
      if result["child_thread_id"] == child_id and not MapSet.member?(observed_keys, key),
        do: raise("review_result_history_mismatch")
    end)
  end

  defp put_result(result, {acc, fresh}) do
    key = result_key(result)

    case acc["results"][key] do
      nil ->
        {put_in(acc, ["results", key], result), fresh ++ [result]}

      previous ->
        if previous["text"] != result["text"], do: raise("review_result_changed")
        {acc, fresh}
    end
  end

  @spec pending_context(map() | nil) :: {String.t(), [String.t()]}
  def pending_context(nil), do: {"", []}

  def pending_context(context) do
    record = read(context)
    pending = record["results"] |> Enum.filter(fn {_, result} -> is_nil(result["delivered_in_turn"]) end) |> Enum.sort()

    if pending == [] do
      {"", []}
    else
      text = Enum.map_join(pending, "\n\n", fn {id, result} -> "Resultat #{id}:\n#{result["text"]}" end)

      {"\n\nGesicherte Original-Reviewergebnisse aus demselben Parentthread (#{map_size(record["calls"])} bereits gestartete Reviewaufrufe; Budget unverändert). " <>
         "Verarbeite diese Resultate anhand ihrer stabilen IDs und des vorhandenen Reviewprotokolls; bereits behandelte Findings nicht erneut bearbeiten. " <>
         "Kein neuer Reviewstart zum Wiederbeschaffen dieser Ergebnisse. Ein späteres Keine-Findings-Ergebnis erledigt keine früheren offenen Findings.\n" <> text, Enum.map(pending, &elem(&1, 0))}
    end
  end

  @spec delivered(map() | nil, [String.t()], String.t()) :: :ok
  def delivered(nil, _ids, _turn), do: :ok

  def delivered(context, ids, turn) do
    record = read(context)
    updated = Enum.reduce(ids, record, fn id, acc -> put_in(acc, ["results", id, "delivered_in_turn"], turn) end)
    if updated != record, do: write!(context, updated), else: :ok
  end

  @spec clear(map()) :: :ok | {:error, term()}
  def clear(issue) do
    case Config.settings!().tracker.app["state_root"] do
      root when is_binary(root) ->
        case File.rm(state_path(root, issue.id)) do
          {:error, :enoent} -> :ok
          result -> result
        end

      _ ->
        :ok
    end
  end

  defp observe_item(record, %{"type" => "collabAgentToolCall", "tool" => "spawnAgent", "id" => id, "senderThreadId" => sender} = item, turn)
       when is_binary(id) do
    if sender == record["thread_id"] do
      record = %{record | "calls" => Map.put_new(record["calls"], id, turn)}
      agents = Enum.reduce(item["receiverThreadIds"] || [], record["agents"], fn child, acc -> Map.put_new(acc, child, turn) end)
      {Map.put(record, "agents", agents), []}
    else
      {record, []}
    end
  end

  defp observe_item(record, %{"type" => "subAgentActivity", "kind" => kind, "agentThreadId" => child} = item, turn) when is_binary(child) do
    record =
      if kind == "started" and nonempty?(item["id"]) do
        %{record | "calls" => Map.put_new(record["calls"], item["id"], turn)}
      else
        record
      end

    record = %{record | "agents" => Map.put_new(record["agents"], child, turn)}
    {record, if(kind == "completed", do: [child], else: [])}
  end

  defp observe_item(record, _item, _turn), do: {record, []}

  defp validate_thread!(context, thread, id, parent) do
    unless thread["id"] == id and thread["parentThreadId"] == parent and thread["cwd"] == context.binding["workspace"] and is_list(thread["turns"]) do
      raise "review_thread_binding_mismatch"
    end
  end

  defp require_full!(%{"itemsView" => "full", "items" => items}) when is_list(items), do: :ok
  defp require_full!(_turn), do: raise("review_history_incomplete")

  defp valid?(record, binding) do
    record["version"] == 1 and record["binding"] == binding and
      record["departed"] in [nil, false, true] and
      (is_nil(record["thread_id"]) or is_binary(record["thread_id"])) and
      Enum.all?(~w(calls agents), &valid_ids?(record[&1])) and
      valid_results?(record["results"], record["thread_id"], record["agents"])
  end

  defp valid_ids?(ids) when is_map(ids), do: Enum.all?(ids, fn {id, turn} -> nonempty?(id) and nonempty?(turn) end)
  defp valid_ids?(_ids), do: false

  defp valid_results?(results, parent, agents) when is_map(results) and is_map(agents) do
    Enum.all?(results, fn {key, result} ->
      is_map(result) and Enum.all?(~w(parent_thread_id child_thread_id turn_id item_id text), &nonempty?(result[&1])) and
        result["parent_thread_id"] == parent and Map.has_key?(agents, result["child_thread_id"]) and
        key == result_key(result) and
        (is_nil(result["delivered_in_turn"]) or nonempty?(result["delivered_in_turn"]))
    end)
  end

  defp valid_results?(_results, _parent, _agents), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp write!(context, record) do
    case DurableState.write(context.path, record) do
      :ok -> :ok
      {:error, reason} -> raise inspect(reason)
    end
  end

  defp result_key(result), do: Enum.map_join(~w(parent_thread_id child_thread_id turn_id item_id), "/", &result[&1])

  defp state_path(root, issue_id) do
    key = :crypto.hash(:sha256, Jason.encode!([RuntimePaths.project_root(), issue_id])) |> Base.encode16(case: :lower)
    Path.join([root, "reviews", key <> ".json"])
  end
end
