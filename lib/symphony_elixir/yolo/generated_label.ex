defmodule SymphonyElixir.Yolo.GeneratedLabel do
  @moduledoc "Resolve or create the generated label once, preserving an uncertain creation ID."
  alias SymphonyElixir.Yolo.{API, Operations}

  @spec resolve(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(team, opts) do
    Operations.run("label:" <> team, %{"team" => team}, fn intent -> resolve_locked(team, intent, opts) end)
  end

  defp resolve_locked(team, intent, opts) do
    document =
      "query YoloGeneratedLabel($filter: IssueLabelFilter!, $after: String) { issueLabels(filter: $filter, first: 100, after: $after) { nodes { id name team { id } } pageInfo { hasNextPage endCursor } } }"

    with {:ok, labels} <- API.pages(document, %{filter: %{name: %{eqIgnoreCase: "symphony-generated"}}}, ["issueLabels"], opts) do
      case Enum.filter(labels, &(get_in(&1, ["team", "id"]) in [nil, team])) do
        [%{"id" => id}] -> {:ok, id}
        [] -> create(team, intent, opts)
        _ -> {:error, :yolo_generated_label_ambiguous}
      end
    end
  end

  defp create(team, intent, opts) do
    id = intent["issue_id"]
    document = "mutation YoloGeneratedLabelCreate($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id } } }"
    with :ok <- API.confirmed(document, %{input: %{id: id, name: "symphony-generated", teamId: team}}, ["issueLabelCreate", "issueLabel"], id, opts), do: {:ok, id}
  end
end
