defmodule SymphonyElixir.Yolo.Group do
  @moduledoc "Project/agent PO groups; incoming states share one lock and one decision."
  alias SymphonyElixir.{Dialog, Yolo.Admission, Yolo.Dependencies, Yolo.Operations}
  alias SymphonyElixir.Linear.YoloAgent

  @terminal ["Review", "Fertig", "Abgebrochen", "Verworfen", "Duplicate", "Umsetzungsticket erstellt"]

  @spec name(map()) :: String.t() | nil
  def name(issue) do
    if YoloAgent.delegated?(issue) do
      case issue.state do
        state when state in ["Backlog", "Todo", "Definiert"] -> "incoming"
        "Planung" -> "planning"
        "In Arbeit" -> "in_progress"
        "BLOCKER" -> "blocker"
        "Yolo Review" -> "review"
        _ -> recovery_group(issue)
      end
    end
  end

  defp recovery_group(issue), do: if(Operations.recovering_origin?(issue), do: "incoming")

  @spec expected?(map()) :: boolean()
  def expected?(issue) do
    YoloAgent.delegated?(issue) and issue.state not in ["Yolo Review" | @terminal] and not Dialog.state?(issue.state)
  end

  @spec groups([map()]) :: map()
  def groups(issues) do
    issues = Enum.filter(issues, &Dependencies.dispatchable?/1)
    reviews = Dependencies.review_members(issues)
    pending = issues |> Enum.filter(&(Admission.eligible?(&1) and Admission.needed?(&1))) |> Enum.map(&name/1)

    issues
    |> Enum.filter(&(Admission.eligible?(&1) and not Admission.needed?(&1) and not Dialog.state?(&1.state)))
    |> Enum.group_by(&name/1)
    |> Map.delete(nil)
    |> Map.drop(pending)
    |> Map.delete("review")
    |> then(fn groups -> if reviews == [], do: groups, else: Map.put(groups, "review", reviews) end)
  end

  @spec terminal?(map()) :: boolean()
  def terminal?(issue), do: issue.state in @terminal
end
