defmodule SymphonyElixir.Yolo.FixContract do
  @moduledoc "Prevention and consolidation requirements for new follow-ups; existing intents retain their contract."
  alias SymphonyElixir.Linear.Description
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.{ActionScope, API, Operations, Relations, Scope}

  @marker "## Symphony Folgefix"
  @contract_block ~r/\n+## Symphony Folgefix\n+(```json\n(?:(?!\n```).)*\n```)/s
  @project_fixes "query YoloProjectFixes($id: String!, $after: String) { project(id: $id) { issues(first: 100, after: $after, includeArchived: true) { nodes { id description } pageInfo { hasNextPage endCursor } } } }"

  @spec validate(map(), keyword()) :: :ok | {:error, term()}
  def validate(%{"kind" => "aggregate"}, _opts), do: :ok

  def validate(%{"followup_type" => "new_requirement", "blocks_origins" => true}, _opts),
    do: {:error, :yolo_requirement_cannot_block_acceptance}

  def validate(%{"followup_type" => "new_requirement"}, _opts), do: :ok

  def validate(%{"followup_type" => type} = request, opts) when type in ~w(fix consolidation) do
    with :ok <- prevention(request),
         :ok <- consolidation(request),
         {:ok, issues} <- ActionScope.sources(request["origin_ids"], opts),
         true <- length(Enum.uniq_by(issues, &{&1.project_id, &1.team_id})) == 1 do
      chain(request, issues, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :yolo_followup_sources_changed}
    end
  end

  def validate(_, _), do: {:error, :yolo_followup_type_required}

  defp prevention(request) do
    item = request["prevention"]

    cond do
      not is_binary(request["component"]) or not Regex.match?(~r/\A[a-z0-9][a-z0-9_\.\/-]*\z/, request["component"]) ->
        {:error, :yolo_fix_component_required}

      not is_map(item) or item["kind"] not in ~w(test lint arch prereview) or not texts?(item, ~w(change validation)) ->
        {:error, :yolo_fix_prevention_required}

      item["kind"] == "prereview" and not local_prereview?() ->
        {:error, :yolo_fix_requires_test_or_rule}

      true ->
        :ok
    end
  end

  defp local_prereview? do
    root =
      case Scope.current() do
        %{"workspace" => workspace} -> workspace
        _ -> ProjectContext.current().root
      end

    File.regular?(Path.join(root, ".codex/skills/sym-prereview/SKILL.md"))
  end

  defp consolidation(%{"followup_type" => "consolidation", "consolidation" => item}) when is_map(item) do
    if texts?(item, ~w(cause cleanup fixes)) and is_integer(item["net_code_target"]) and item["net_code_target"] <= 0 do
      :ok
    else
      {:error, :yolo_consolidation_required}
    end
  end

  defp consolidation(%{"followup_type" => "consolidation"}), do: {:error, :yolo_consolidation_required}
  defp consolidation(_), do: :ok

  defp chain(request, [lead | _] = issues, opts) do
    case Scope.current() do
      %{"group" => "review"} -> review_chain(request, lead.project_id, issues, opts)
      _ -> :ok
    end
  end

  defp review_chain(%{"followup_type" => "consolidation"}, _project, _issues, _opts), do: :ok

  defp review_chain(request, project, issues, opts) do
    with {:ok, operations} <- Operations.all(),
         {:ok, tickets} <- API.pages(@project_fixes, %{id: project}, ["project", "issues"], opts) do
      local = for op <- operations, op["done"] == true and get_in(op, ["input", "projectId"]) == project and fix?(op["request"]), do: Map.put(op["request"], "id", op["issue_id"])
      remote = Enum.flat_map(tickets, &metadata/1)

      if Enum.any?(local ++ remote, &same_chain_or_component?(&1, request)), do: {:error, :yolo_consolidation_required}, else: legacy_origins(issues, opts)
    end
  end

  defp legacy_origins(issues, opts) do
    Enum.reduce_while(issues, :ok, fn issue, _ ->
      description = issue.description || ""
      legacy? = String.contains?(description, "\n## Ursprung\n") and not String.contains?(description, [@marker, "## Übernommene Anforderungen"])

      result = if legacy?, do: legacy_fix(issue.id, opts), else: :ok
      continue(result)
    end)
  end

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  defp legacy_fix(id, opts) do
    document = "query YoloLegacyFixLabels($id: String!, $after: String) { issue(id: $id) { labels(first: 100, after: $after) { nodes { id name } pageInfo { hasNextPage endCursor } } } }"

    with {:ok, labels} <- API.pages(document, %{id: id}, ["issue", "labels"], opts),
         {:ok, relations} <- Relations.read(id, opts) do
      generated? = Enum.any?(labels, &(&1["name"] == "symphony-generated"))
      blocking? = Enum.any?(relations, &(&1["type"] == "blocks" and get_in(&1, ["issue", "id"]) == id))
      if generated? and blocking?, do: {:error, :yolo_consolidation_required}, else: :ok
    end
  end

  defp fix?(request), do: request["followup_type"] in ~w(fix consolidation) or (is_nil(request["followup_type"]) and request["kind"] == "followup" and request["blocks_origins"] == true)

  defp same_chain_or_component?(prior, request) do
    prior["id"] in request["origin_ids"] or Enum.any?(prior["origin_ids"] || [], &(&1 in request["origin_ids"])) or
      prior["component"] == request["component"]
  end

  defp metadata(%{"id" => id, "description" => description}) when is_binary(description) do
    # Aggregation copies source descriptions; their contracts are not its own provenance.
    own_description = description |> String.split("\n## Übernommene Anforderungen\n", parts: 2) |> hd()

    case split_contract(own_description) do
      {_, "```json\n" <> json} ->
        decode_metadata(Jason.decode(String.trim_trailing(json, "\n```")), id)

      _ ->
        []
    end
  end

  defp metadata(_), do: []

  defp decode_metadata({:ok, %{"version" => 1} = item}, id) do
    if fix?(item) and is_list(item["origin_ids"]) and Enum.all?(item["origin_ids"], &is_binary/1) and is_binary(item["component"]), do: [Map.put(item, "id", id)], else: []
  end

  defp decode_metadata(_, _), do: []

  @spec description(map()) :: String.t()
  def description(%{"followup_type" => _} = request) do
    item = request |> Map.take(~w(followup_type origin_ids component prevention consolidation)) |> Map.put("version", 1)
    "\n\n#{@marker}\n\n```json\n#{Jason.encode!(item, pretty: true)}\n```"
  end

  def description(_), do: ""

  @doc "Keep provenance exact while retaining the established Linear normalization for the original description."
  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(expected, actual) when is_binary(expected) and is_binary(actual) do
    {expected_body, expected_contract} = split_contract(expected)
    {actual_body, actual_contract} = split_contract(actual)
    expected_contract == actual_contract and Description.equivalent?(expected_body, actual_body)
  end

  def equivalent?(expected, actual), do: Description.equivalent?(expected, actual)

  defp split_contract(text) do
    case @contract_block |> Regex.scan(text, return: :index) |> List.last() do
      [{start, block_length}, {contract_start, length}] ->
        remainder = binary_part(text, start + block_length, byte_size(text) - start - block_length)
        {binary_part(text, 0, start) <> remainder, binary_part(text, contract_start, length)}

      _ ->
        {text, nil}
    end
  end

  defp texts?(map, keys), do: Enum.all?(keys, &(is_binary(map[&1]) and String.trim(map[&1]) != ""))
end
