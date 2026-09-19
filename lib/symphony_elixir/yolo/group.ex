defmodule SymphonyElixir.Yolo.Group do
  @moduledoc "Project/agent PO groups; incoming states share one lock and one decision."
  alias SymphonyElixir.{Dialog, Yolo.Admission}
  alias SymphonyElixir.Linear.YoloAgent

  @terminal ["Fertig", "Abgebrochen", "Verworfen", "Duplicate", "Umsetzungsticket erstellt"]

  @spec name(map()) :: String.t() | nil
  def name(issue) do
    if YoloAgent.delegated?(issue) do
      case issue.state do
        state when state in ["Backlog", "Todo", "Definiert"] -> "incoming"
        "Planung" -> "planning"
        "In Arbeit" -> "in_progress"
        "BLOCKER" -> "blocker"
        "Review" -> "review"
        _ -> nil
      end
    end
  end

  @spec expected?(map()) :: boolean()
  def expected?(issue) do
    YoloAgent.delegated?(issue) and issue.state not in ["Review" | @terminal] and not Dialog.state?(issue.state)
  end

  @spec groups([map()]) :: map()
  def groups(issues) do
    waiting? = Enum.any?(issues, &expected?/1)
    pending = issues |> Enum.filter(&(Admission.eligible?(&1) and Admission.needed?(&1))) |> Enum.map(&name/1)

    issues
    |> Enum.filter(&(Admission.eligible?(&1) and not Admission.needed?(&1) and not Dialog.state?(&1.state)))
    |> Enum.group_by(&name/1)
    |> Map.delete(nil)
    |> Map.drop(pending)
    |> then(fn groups -> if waiting?, do: Map.delete(groups, "review"), else: groups end)
  end

  @spec terminal?(map()) :: boolean()
  def terminal?(issue), do: issue.state in @terminal
end
