defmodule SymphonyElixir.Yolo.OperatorHandoff do
  @moduledoc "Source-bound operator duties in confirmed workpads, independent of comment timestamps."
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Workpad

  @marker "```symphony-operator-handoff"
  @fields ~w(version action head_sha source_sha256 expected resume_state)
  @phases ["Planung (AI)", "In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)", "Merge (AI)"]

  @spec evidence(map(), map()) :: {:ok, [String.t()]} | {:error, atom()}
  def evidence(%{state: "BLOCKER"}, inbox) do
    with current when is_map(current) <- inbox["current"],
         versions when is_map(versions) <- inbox["versions"],
         true <- Enum.all?(current, fn {id, key} -> get_in(versions, [key, "source", "id"]) == id end),
         :ok <- validate_current(Map.take(versions, Map.values(current))) do
      # Keep every observed duty in the semantic receipt. Removing/reformatting
      # a workpad or restoring an older duty must never resurrect a decision.
      evidence =
        versions
        |> Map.values()
        |> Enum.flat_map(&historical_evidence/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, evidence}
    else
      _ -> {:error, :yolo_operator_handoff_incomplete}
    end
  end

  def evidence(_issue, _inbox), do: {:ok, []}

  defp historical_evidence(version) do
    with true <- own_workpad?(version),
         {:ok, duty} when is_map(duty) <- parse(version["source"]["body"]) do
      [Digest.digest(duty)]
    else
      _ -> []
    end
  end

  defp validate_current(versions) do
    workpads = versions |> Map.values() |> Enum.filter(&Workpad.comment_matches?(get_in(&1, ["source", "body"])))

    if length(workpads) <= 1 and Enum.all?(workpads, &(not own_workpad?(&1) or match?({:ok, _}, parse(&1["source"]["body"])))),
      do: :ok,
      else: :error
  end

  defp own_workpad?(version) do
    version["origin"] == "own" and version["advisory_suppressed"] != true and Workpad.comment_matches?(get_in(version, ["source", "body"]))
  end

  defp parse(body) do
    if String.contains?(body, @marker) do
      matches = Regex.scan(~r/^```symphony-operator-handoff[ \t]*\r?\n(.*?)^```[ \t]*(?:\r?\n|$)/ms, body, capture: :all_but_first)

      case {length(String.split(body, @marker)), matches} do
        {2, [[json]]} -> decode(json)
        _ -> :error
      end
    else
      {:ok, nil}
    end
  end

  defp decode(json) do
    with {:ok, duty} when is_map(duty) <- Jason.decode(json),
         true <- Enum.sort(Map.keys(duty)) == Enum.sort(@fields),
         true <- duty["version"] === 1 and duty["resume_state"] in @phases,
         true <- digest?(duty["head_sha"], 40) and digest?(duty["source_sha256"], 64),
         true <- Enum.all?(~w(action expected), &(is_binary(duty[&1]) and String.trim(duty[&1]) != "")) do
      {:ok, Map.new(duty, fn {key, value} -> {key, if(is_binary(value), do: String.replace(value, ~r/\s+/u, " ") |> String.trim(), else: value)} end)}
    else
      _ -> :error
    end
  end

  defp digest?(value, size), do: is_binary(value) and byte_size(value) == size and Regex.match?(~r/\A[0-9a-f]+\z/, value)
end
