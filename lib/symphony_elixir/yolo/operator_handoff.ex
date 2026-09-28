defmodule SymphonyElixir.Yolo.OperatorHandoff do
  @moduledoc "Source-bound operator duties in confirmed workpads, independent of comment timestamps."
  alias SymphonyElixir.Config
  alias SymphonyElixir.Relay.Store, as: Digest
  alias SymphonyElixir.Workpad

  @marker "```symphony-operator-handoff"
  @fields ~w(version action head_sha source_sha256 expected resume_state)
  @phases ["Planung (AI)", "In Arbeit (AI)", "PreReview (AI)", "Review (AI)", "Test (AI)", "Merge (AI)", "Yolo Review"]
  @confirmation_fields ~w(version handoff_digest result evidence)

  @spec current(map(), map()) :: {:ok, String.t() | nil} | {:error, atom()}
  def current(%{state: "Yolo Review"}, inbox) do
    with current when is_map(current) <- inbox["current"] || %{},
         versions when is_map(versions) <- inbox["versions"],
         true <- Enum.all?(current, fn {id, key} -> get_in(versions, [key, "source", "id"]) == id end),
         :ok <- validate_current(Map.take(versions, Map.values(current))) do
      versions
      |> Map.take(Map.values(current))
      |> Map.values()
      |> Enum.find(&own_workpad?/1)
      |> current_digest()
    else
      _ -> {:error, :yolo_operator_handoff_incomplete}
    end
  end

  def current(_issue, _inbox), do: {:ok, nil}

  @spec confirmation(map(), map(), String.t() | nil) :: {:ok, String.t() | nil}
  def confirmation(%{state: "Yolo Review"}, inbox, digest) when is_binary(digest) do
    confirmed? = Enum.any?(inbox["current"] || %{}, &current_confirmation?(&1, inbox, digest))

    {:ok, if(confirmed?, do: digest)}
  end

  def confirmation(_issue, _inbox, _digest), do: {:ok, nil}

  defp current_confirmation?({id, key}, inbox, digest) do
    version = get_in(inbox, ["versions", key])
    source = if is_map(version), do: version["source"], else: nil

    is_map(source) and source["id"] == id and is_nil(source["editedAt"]) and version["deleted"] == false and
      version["origin"] == "integration" and version["advisory_suppressed"] != true and
      pai_source?(source) and confirmation_digest(source["body"]) == digest
  end

  defp pai_source?(source), do: get_in(source, ["user", "id"]) == Config.yolo_agent_id() and get_in(source, ["user", "app"]) == true

  defp current_digest(nil), do: {:ok, nil}

  defp current_digest(version) do
    case parse(version["source"]["body"]) do
      {:ok, %{"resume_state" => "Yolo Review"} = duty} -> {:ok, if(version["deleted"] == false, do: Digest.digest(duty))}
      _ -> {:ok, nil}
    end
  end

  defp confirmation_digest(body) when is_binary(body) do
    with [json] <- Regex.run(~r/\A\s*```symphony-operator-confirmation[ \t]*\r?\n(.*?)^```[ \t]*\s*\z/ms, body, capture: :all_but_first),
         {:ok, %{"version" => 1, "handoff_digest" => digest} = confirmation} <- Jason.decode(json),
         true <- valid_confirmation?(confirmation, digest) do
      digest
    else
      _ -> nil
    end
  end

  defp confirmation_digest(_), do: nil

  defp valid_confirmation?(confirmation, digest) do
    Enum.sort(Map.keys(confirmation)) == Enum.sort(@confirmation_fields) and digest?(digest, 64) and
      Enum.all?(~w(result evidence), &(is_binary(confirmation[&1]) and String.trim(confirmation[&1]) != ""))
  end

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
