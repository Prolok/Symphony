defmodule SymphonyElixir.Linear.CommentInbox do
  @moduledoc "Project-local, restartable input versions, serialized with the existing host journal lock."

  alias SymphonyElixir.Linear.{CommentJournal, CommentVersion, DurableState, IssueLease}

  @open ~w(recognized delivered)
  @outcomes ["übernommen", "Rückfrage", "nicht anwendbar", "ersetzt"]

  @spec scan(map(), map(), (-> {:ok, [map()]} | {:error, term()}), keyword()) :: {:ok, map()} | {:error, term()}
  def scan(binding, issue, fetch, opts \\ []) do
    transaction(binding, issue, opts, fn state ->
      result =
        CommentJournal.observe(binding, Keyword.get(opts, :journal_request), fn ->
          observe_fetch(fetch.(), state, binding, opts)
        end)

      case result do
        {:ok, _state} -> result
        {:save_error, _state, _reason} -> result
        {:error, reason} -> {:save_error, Map.put(state, "scan_error", inspect(reason)), reason}
      end
    end)
  end

  defp observe_fetch({:ok, comments}, state, binding, opts), do: observe(state, comments, binding, opts)

  defp observe_fetch({:error, {:comment_scan_incomplete, reason, comments}}, state, binding, opts),
    do: observe_partial(state, comments, reason, binding, opts)

  defp observe_fetch({:error, _} = error, _state, _binding, _opts), do: error

  @spec read(map(), map()) :: {:ok, map()} | {:error, term()}
  def read(binding, issue) do
    case DurableState.read(path(binding, issue)) do
      {:ok, state} ->
        if state["binding"] == identity(binding, issue) and valid_state?(state),
          do: {:ok, state},
          else: {:error, :comment_inbox_corrupt}

      {:error, :enoent} ->
        {:ok, initial(binding, issue)}

      error ->
        error
    end
  end

  defp valid_state?(state) do
    is_map(state["versions"]) and Enum.all?(state["versions"], &valid_stored_version?/1) and
      valid_baseline?(state["baseline"])
  end

  defp valid_baseline?(nil), do: true

  defp valid_baseline?(%{"key" => "baseline:" <> _, "status" => status, "sources" => sources}) do
    status in ["recognized", "delivered", "processed"] and is_list(sources)
  end

  defp valid_baseline?(_baseline), do: false

  defp valid_stored_version?({key, %{"source" => %{"id" => id, "body" => body}} = version}) do
    is_binary(id) and is_binary(body) and key == version["key"] and
      version["status"] in ["recognized", "delivered", "processed", "historical", "context"] and
      is_boolean(version["deleted"]) and is_integer(version["sequence"])
  end

  defp valid_stored_version?(_entry), do: false

  @spec deliver(map(), map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def deliver(binding, issue, context, opts \\ []) do
    transaction(binding, issue, opts, fn state ->
      versions = Map.new(state["versions"], fn {key, version} -> {key, delivered(version, context)} end)
      baseline = if state["baseline"], do: delivered(state["baseline"], context)
      {:ok, %{state | "versions" => versions, "baseline" => baseline}}
    end)
  end

  @doc "Persist business results only after the callback confirms their workpad write."
  @spec acknowledge(map(), map(), [map()], ([map()] -> :ok | {:error, term()}), keyword()) ::
          {:ok, map()} | {:error, term()}
  def acknowledge(binding, issue, results, write_workpad, opts \\ []) do
    transaction(binding, issue, opts, fn state ->
      with :ok <- validate_results(state, results),
           :ok <- write_workpad.(results) do
        {:ok, Enum.reduce(results, state, &finish/2)}
      end
    end)
  end

  @spec pending(map()) :: [map()]
  def pending(state) do
    (List.wrap(state["baseline"]) ++ Map.values(state["versions"]))
    |> Enum.filter(&(&1["status"] in @open))
    |> Enum.sort_by(&{&1["observed_at"], &1["key"]})
  end

  @spec ready?(map()) :: boolean()
  def ready?(state), do: not is_nil(state["last_successful_scan"]) and is_nil(state["scan_error"]) and pending(state) == []

  defp transaction(binding, issue, opts, callback) do
    IssueLease.with_journal_lock(path(binding, issue), fn ->
      with {:ok, state} <- read(binding, issue) do
        save_result(callback.(state), binding, issue, opts)
      end
    end)
  end

  defp save_result({:ok, state}, binding, issue, opts) do
    with :ok <- persist(binding, issue, state, opts), do: {:ok, state}
  end

  defp save_result({:save_error, state, reason}, binding, issue, opts) do
    with :ok <- persist(binding, issue, state, opts), do: {:error, reason}
  end

  defp save_result(error, _binding, _issue, _opts), do: error

  defp persist(binding, issue, state, opts), do: Keyword.get(opts, :writer, &DurableState.write/2).(path(binding, issue), state)

  defp observe(state, comments, binding, opts) do
    now = timestamp()
    classify = Keyword.get(opts, :classify, &CommentJournal.classify(binding, &1))

    with {:ok, observed} <- classify_all(comments, classify, now) do
      baseline? = is_nil(state["baseline"])
      versions = Enum.reduce(observed, state["versions"], &insert(&1, &2, baseline?))
      ids = MapSet.new(observed, & &1["source"]["id"])
      baseline = state["baseline"] || baseline(observed, now)

      case check_absent(versions, ids, opts) do
        {:ok, versions} ->
          baseline = mark_deleted_baseline_sources(baseline, versions)
          {:ok, Map.merge(state, %{"baseline" => baseline, "versions" => versions, "last_successful_scan" => now, "scan_error" => nil})}

        {:error, reason} ->
          observe_partial(state, comments, reason, binding, opts)
      end
    end
  end

  defp observe_partial(state, comments, reason, binding, opts) do
    classify = Keyword.get(opts, :classify, &CommentJournal.classify(binding, &1))

    with {:ok, observed} <- classify_all(comments, classify, timestamp()) do
      versions = Enum.reduce(observed, state["versions"], &insert(&1, &2, false))
      {:save_error, Map.merge(state, %{"versions" => versions, "scan_error" => inspect(reason)}), reason}
    end
  end

  defp classify_all(comments, classify, now) do
    Enum.reduce_while(comments, {:ok, []}, fn comment, {:ok, acc} ->
      raw = CommentVersion.raw(comment)

      case classify.(raw) do
        {:error, _} = error ->
          {:halt, error}

        classification ->
          origin = origin(classification, raw)

          version = %{
            "key" => CommentVersion.key(raw),
            "source" => raw,
            "origin" => origin,
            "status" => if(origin in ["human", "changed_app_output", "unknown"], do: "recognized", else: "context"),
            "observed_at" => now,
            "deleted" => false
          }

          {:cont, {:ok, acc ++ [version]}}
      end
    end)
  end

  defp origin(:own, _raw), do: "own"
  defp origin(:pending, _raw), do: "changed_app_output"

  defp origin(:foreign, raw) do
    cond do
      get_in(raw, ["user", "app"]) == true or not is_nil(raw["botActor"]) or not is_nil(raw["externalUser"]) or not is_nil(raw["onBehalfOf"]) -> "integration"
      get_in(raw, ["user", "app"]) == false and is_binary(get_in(raw, ["user", "id"])) -> "human"
      true -> "unknown"
    end
  end

  defp insert(version, versions, baseline?) do
    version = if baseline?, do: Map.put(version, "status", "historical"), else: version
    Map.put_new(versions, version["key"], Map.put(version, "sequence", map_size(versions) + 1))
  end

  defp check_absent(versions, ids, opts) do
    missing = versions |> Map.values() |> Enum.reject(&(&1["deleted"] or MapSet.member?(ids, &1["source"]["id"]))) |> Enum.uniq_by(& &1["source"]["id"])
    confirm = Keyword.get(opts, :confirm_absence, fn _ -> {:error, :comment_absence_unverified} end)

    Enum.reduce_while(missing, {:ok, versions}, fn version, {:ok, versions} ->
      id = version["source"]["id"]

      case confirm.(id) do
        :deleted -> {:cont, {:ok, Map.new(versions, fn {key, entry} -> {key, if(entry["source"]["id"] == id, do: Map.put(entry, "deleted", true), else: entry)} end)}}
        {:present, _} -> {:halt, {:error, :comment_scan_inconsistent}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp baseline(observed, now) do
    keys = observed |> Enum.map(& &1["key"]) |> Enum.sort()
    %{"key" => "baseline:" <> CommentVersion.digest(keys), "status" => "recognized", "observed_at" => now, "origin" => "baseline", "sources" => Enum.map(observed, & &1["source"])}
  end

  defp mark_deleted_baseline_sources(baseline, versions) do
    deleted_ids = versions |> Map.values() |> Enum.filter(& &1["deleted"]) |> MapSet.new(& &1["source"]["id"])

    Map.update!(baseline, "sources", &Enum.map(&1, fn source -> mark_deleted_source(source, deleted_ids) end))
  end

  defp mark_deleted_source(source, ids), do: if(MapSet.member?(ids, source["id"]), do: Map.put(source, "deleted", true), else: source)

  defp delivered(%{"status" => status} = version, context) when status in @open do
    version |> Map.put("status", "delivered") |> Map.put("delivery", context) |> Map.put_new("delivered_at", timestamp())
  end

  defp delivered(version, _context), do: version

  defp validate_results(state, results) when is_list(results) and results != [] do
    keys = Enum.map(results, fn result -> if is_map(result), do: result["key"] end)

    if Enum.all?(results, &is_map/1) and length(keys) == length(Enum.uniq(keys)) and Enum.all?(results, &valid_result?(state, &1)),
      do: :ok,
      else: {:error, :invalid_comment_result}
  end

  defp validate_results(_state, _results), do: {:error, :invalid_comment_result}

  defp valid_result?(state, result) do
    version = lookup(state, result["key"])

    is_map(version) and version["status"] in ["delivered", "processed"] and
      result["outcome"] in @outcomes and is_binary(result["reason"]) and String.trim(result["reason"]) != "" and
      (result["outcome"] != "ersetzt" or valid_replacement?(state, version, result["replacement"])) and
      (version["status"] != "processed" or version["result"] == result)
  end

  defp valid_replacement?(state, version, key) do
    replacement = lookup(state, key)

    is_map(replacement) and key != version["key"] and not is_nil(version["source"]) and
      get_in(replacement, ["source", "id"]) == version["source"]["id"] and replacement["sequence"] > version["sequence"]
  end

  defp lookup(state, key) do
    if get_in(state, ["baseline", "key"]) == key, do: state["baseline"], else: state["versions"][key]
  end

  defp finish(result, state) do
    version = lookup(state, result["key"]) |> Map.merge(%{"status" => "processed", "result" => result, "processed_at" => timestamp()})

    if get_in(state, ["baseline", "key"]) == result["key"],
      do: Map.put(state, "baseline", version),
      else: put_in(state, ["versions", result["key"]], version)
  end

  defp initial(binding, issue), do: %{"binding" => identity(binding, issue), "versions" => %{}, "baseline" => nil, "scan_error" => nil, "last_successful_scan" => nil}
  defp identity(binding, issue), do: %{"workspace_id" => binding["workspace_id"], "installation_id" => binding["installation_id"], "state_root" => binding["state_root"], "issue_id" => issue.id}
  defp path(binding, issue), do: Path.join([binding["state_root"], "inputs", CommentVersion.digest(issue.id) <> ".json"])
  defp timestamp, do: DateTime.to_iso8601(DateTime.utc_now())
end
