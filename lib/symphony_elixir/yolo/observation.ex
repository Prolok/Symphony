defmodule SymphonyElixir.Yolo.Observation do
  @moduledoc "Relay-driven semantic observations; own confirmed comments do not restart PO work."
  alias SymphonyElixir.CommentCheckpoint
  alias SymphonyElixir.Relay.Store, as: Digest

  @spec capture([map()], map(), keyword()) :: {:ok, map(), String.t()} | {:error, term()}
  def capture(issues, previous, opts \\ []) do
    issues
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, %{}}, fn issue, {:ok, acc} ->
      case observe(issue, previous[issue.id], opts) do
        {:ok, observation} -> {:cont, {:ok, Map.put(acc, issue.id, observation)}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, observations} -> {:ok, observations, fingerprint(observations)}
      error -> error
    end
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(observations), do: Digest.digest(Enum.map(Enum.sort(observations), fn {id, data} -> {id, data["semantic"]} end))

  defp observe(issue, previous, opts) do
    signal = Digest.digest({issue.updated_at, issue.last_comment_signal, semantic_issue(issue)})

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

        {:ok, %{"signal" => signal, "semantic" => Digest.digest({semantic_issue(issue), comments})}}
      else
        {:error, _} = error -> error
        _ -> {:error, :yolo_comments_incomplete}
      end
    end
  end

  defp semantic_issue(issue) do
    Map.take(issue, [:id, :title, :description, :state, :assignee_id, :delegate_id, :blocked_by, :project_id, :team_id])
    |> Map.put(:labels, issue.labels |> Enum.reject(&(&1 in [~s(skip "freigabe implementierung"), ~s(skip "freigabe review")])) |> Enum.sort())
  end
end
