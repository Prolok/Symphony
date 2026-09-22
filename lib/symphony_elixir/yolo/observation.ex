defmodule SymphonyElixir.Yolo.Observation do
  @moduledoc "Relay-driven semantic observations; own confirmed comments do not restart PO work."
  alias SymphonyElixir.CommentCheckpoint
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Yolo.{Dependencies, ReviewReadiness}

  @spec capture([map()], map(), keyword()) :: {:ok, map(), String.t()} | {:error, term()}
  def capture(issues, previous, opts \\ []) do
    with {:ok, generations} <- ReviewReadiness.generations(issues) do
      capture_members(issues, previous, generations, opts)
    end
  end

  defp capture_members(issues, previous, generations, opts) do
    issues
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, %{}}, fn issue, {:ok, acc} ->
      case observe(issue, previous[issue.id], generations[issue.id], opts) do
        {:ok, observation} -> {:cont, {:ok, Map.put(acc, issue.id, observation)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, observations} ->
        observations = bind_chains(issues, observations)
        {:ok, observations, fingerprint(observations)}

      error ->
        error
    end
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(observations), do: Digest.digest(Enum.map(Enum.sort(observations), fn {id, data} -> {id, data["semantic"]} end))

  defp observe(issue, previous, generation, opts) do
    semantic = semantic_issue(issue)
    semantic = if generation > 0, do: Map.put(semantic, :dependency_generation, generation), else: semantic
    signal = Digest.digest({2, issue.updated_at, issue.last_comment_signal, semantic})

    if is_map(previous) and previous["signal"] == signal do
      {:ok, previous}
    else
      scan = Keyword.get(opts, :scan, &CommentCheckpoint.scan/1)

      with {:ok, inbox} <- scan.(issue),
           true <- not is_nil(inbox["last_successful_scan"]) and is_nil(inbox["scan_error"]) do
        comments =
          inbox["versions"]
          |> Map.values()
          |> Enum.reject(&(&1["origin"] in ["own", "integration"]))
          |> Enum.map(&{&1["key"], &1["deleted"]})
          |> Enum.sort()

        source = Digest.digest({semantic, comments})
        legacy = semantic_issue(issue) |> Map.put(:state, issue.state) |> Map.put(:blocked_by, Enum.map(issue.blocked_by, &Map.delete(&1, :state_type)))
        {:ok, %{"signal" => signal, "semantic" => source, "source" => source, "legacy_semantic" => if(generation == 0, do: Digest.digest({legacy, comments}))}}
      else
        {:error, _} = error -> error
        _ -> {:error, :yolo_comments_incomplete}
      end
    end
  end

  defp bind_chains(issues, observations) do
    issues
    |> Enum.filter(&(&1.state == "Yolo Review"))
    |> Dependencies.components()
    |> Enum.reduce(observations, fn members, acc ->
      chain = members |> Enum.map(&{&1.id, observations[&1.id]["source"] || observations[&1.id]["semantic"]}) |> Enum.sort() |> Digest.digest()

      Enum.reduce(members, acc, fn issue, result ->
        Map.update!(result, issue.id, &Map.put(&1, "semantic", Digest.digest({&1["source"] || &1["semantic"], chain})))
      end)
    end)
  end

  defp semantic_issue(issue) do
    Map.take(issue, [:id, :title, :description, :state, :assignee_id, :delegate_id, :blocked_by, :project_id, :team_id])
    |> Map.put(:state, if(issue.state in ["Backlog", "Todo", "Definiert"], do: "incoming", else: issue.state))
    |> Map.put(:blocked_by, Enum.sort_by(issue.blocked_by, & &1.id))
    |> Map.put(:labels, issue.labels |> Enum.reject(&(&1 in [~s(skip "freigabe implementierung"), ~s(skip "freigabe review")])) |> Enum.sort())
  end
end
