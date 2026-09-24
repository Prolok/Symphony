defmodule SymphonyElixir.Yolo.BlockerBrake do
  @moduledoc "Durable 24-hour same-cause brake before a second BLOCKER agent delivery."
  require Logger
  alias SymphonyElixir.{Config, Tracker, Workpad}
  alias SymphonyElixir.Linear.{DurableState, IssueLease}
  alias SymphonyElixir.Yolo.{API, Escalation}

  @window_ms 86_400_000

  @spec check([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def check(issues, opts \\ []) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, acc} ->
      case check_issue(issue, opts) do
        :run -> {:cont, {:ok, [issue | acc]}}
        :handed_off -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      error -> error
    end
  end

  @spec reserve([map()], String.t(), keyword()) :: :ok | {:error, term()}
  def reserve(issues, run_id, opts \\ []) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case reserve_issue(issue, run_id, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp reserve_issue(issue, run_id, opts) do
    with {:ok, cause} <- cause(issue, opts) do
      update(issue.id, &put_entry(&1, cause, run_id, now(opts)))
    end
  end

  defp put_entry(record, cause, run_id, timestamp) do
    entries = Enum.reject(record["entries"] || [], &(&1["run_id"] == run_id))
    %{"entries" => [%{"hash" => digest(cause), "cause" => cause, "run_id" => run_id, "at" => timestamp} | entries]}
  end

  @spec release([map()], String.t()) :: :ok | {:error, term()}
  def release(issues, run_id) do
    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      case update(issue.id, &remove_entry(&1, run_id)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_entry(record, run_id), do: Map.put(record, "entries", Enum.reject(record["entries"] || [], &(&1["run_id"] == run_id)))

  defp check_issue(issue, opts) do
    with {:ok, cause} <- cause(issue, opts),
         {:ok, record} <- read(issue.id) do
      same = Enum.find(record["entries"] || [], &(&1["hash"] == digest(cause) and (now(opts) - &1["at"]) in 0..@window_ms))
      if same, do: handoff(issue, cause, same, opts), else: :run
    end
  end

  defp handoff(issue, cause, first, opts) do
    human = Config.human_handoff_id()

    defaults = %{
      "cause" => cause,
      "attempts" => "PO-Lauf #{first["run_id"]} zur selben Ursache; erneuter BLOCKER binnen 24 Stunden",
      "proposal" => "Ausstehende Betreiberaktion aus dem letzten Workpad-Lauf prüfen und Hindernis beheben.",
      "decision" => "Mensch bestätigt Zugang/Freigabe oder die konkrete Fortsetzung nach Behebung."
    }

    details = Map.merge(defaults, last_escalation(issue, opts))

    with true <- is_binary(human),
         :ok <- note(issue, details, opts),
         :ok <- notify_once(issue, details, opts),
         :ok <- API.update(issue.id, %{assigneeId: human, delegateId: nil}, opts),
         {:ok, [fresh]} <- Keyword.get(opts, :fetch, &Tracker.fetch_issue_states_by_ids/1).([issue.id]),
         true <- fresh.state == "BLOCKER" and fresh.delegate_id == nil and fresh.assignee_id == human do
      :handed_off
    else
      {:error, _} = error -> error
      _ -> {:error, :blocker_brake_handoff_unconfirmed}
    end
  end

  defp notify_once(issue, details, opts) do
    case Escalation.notify(issue, %{"escalation" => details}, opts) do
      :ok ->
        :ok

      {:error, :yolo_escalation_delivery_unconfirmed} ->
        Logger.warning("BLOCKER escalation delivery unconfirmed issue_id=#{issue.id} issue_identifier=#{issue.identifier}; no duplicate send")
        note_uncertain_delivery(issue, opts)

      error ->
        error
    end
  end

  defp note_uncertain_delivery(issue, opts) do
    fetch = Keyword.get(opts, :workpad_comments, Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1))
    write = Keyword.get(opts, :workpad_write, Keyword.get(opts, :workpad, &Workpad.update_tracker_workpad/2))
    entry = "BLOCKER-Eskalationsversand unbestätigt; journalisierter Versuch wird nicht wiederholt."

    with {:ok, comments} <- fetch.(issue.id),
         {:ok, workpad} <- Workpad.find_comment(comments) do
      if String.contains?(workpad.body, entry), do: :ok, else: write.(issue.id, insert_note(workpad.body, entry))
    end
  end

  defp note(issue, details, opts) do
    fetch = Keyword.get(opts, :workpad_comments, Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1))
    write = Keyword.get(opts, :workpad_write, Keyword.get(opts, :workpad, &Workpad.update_tracker_workpad/2))
    entry = "BLOCKER-Schleifenbremse: Ursache #{details["cause"]}; Versuche #{details["attempts"]}; Vorschlag #{details["proposal"]}; Entscheidung #{details["decision"]}."

    with {:ok, comments} <- fetch.(issue.id),
         {:ok, workpad} <- Workpad.find_comment(comments) do
      if String.contains?(workpad.body, entry), do: :ok, else: write.(issue.id, insert_note(workpad.body, entry))
    end
  end

  defp insert_note(body, entry) do
    note = "- " <> entry <> "\n"

    if String.contains?(body, "### Kommentareingang"),
      do: String.replace(body, "### Kommentareingang", note <> "\n### Kommentareingang"),
      else: body <> "\n" <> note
  end

  defp cause(issue, opts) do
    fetch = Keyword.get(opts, :workpad_comments, Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1))

    with {:ok, comments} <- fetch.(issue.id),
         {:ok, workpad} <- Workpad.find_comment(comments) do
      validation = section(workpad.body, "Validierung")

      lines =
        validation
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(~r/^\s*[-*]\s+\[ \].*(?:Betreiber|Live|Host|Integration|Freigabe|Zugang|BLOCKER)/iu, &1))
        |> Enum.map(&String.trim/1)

      relevant =
        if lines == [],
          do: section(workpad.body, "Verlauf") |> String.split("\n") |> Enum.filter(&Regex.match?(~r/(?:Betreiber|Live|Host|Integration|Freigabe|Zugang|BLOCKER)/iu, &1)) |> List.last() |> List.wrap(),
          else: lines

      cond do
        relevant != [] -> {:ok, Enum.join(relevant, "\n")}
        map_size(last_escalation_body(workpad.body)) > 0 -> {:ok, last_escalation_body(workpad.body) |> Enum.sort() |> Jason.encode!()}
        String.trim(validation) != "" -> {:ok, String.trim(validation)}
        true -> {:error, :blocker_cause_missing}
      end
    end
  end

  defp last_escalation(issue, opts) do
    fetch = Keyword.get(opts, :workpad_comments, Keyword.get(opts, :comments, &Tracker.fetch_issue_comments/1))

    with {:ok, comments} <- fetch.(issue.id),
         {:ok, workpad} <- Workpad.find_comment(comments) do
      last_escalation_body(workpad.body)
    else
      _ -> %{}
    end
  end

  defp last_escalation_body(body) do
    case Regex.scan(~r/Eskalation:\s*```json\s*(\{.*?\})\s*```/su, body, capture: :all_but_first) |> List.last() do
      [encoded] -> decode_escalation(encoded)
      _ -> %{}
    end
  end

  defp decode_escalation(encoded) do
    case Jason.decode(encoded) do
      {:ok, %{} = details} ->
        if Escalation.validate(%{"escalation" => details}) == :ok,
          do: Map.take(details, ~w(cause attempts proposal decision)),
          else: %{}

      _ ->
        %{}
    end
  end

  defp section(body, name) do
    case Regex.run(Regex.compile!("(?:^|\\n)### " <> Regex.escape(name) <> "\\n(.*?)(?=\\n### |\\z)", "su"), body) do
      [_, content] -> content
      _ -> ""
    end
  end

  defp path(id), do: Path.join([Config.settings!().tracker.app["state_root"], "yolo", "blocker-causes", digest(id) <> ".json"])

  defp read(id) do
    case DurableState.read(path(id)) do
      {:error, :enoent} -> {:ok, %{"entries" => []}}
      {:ok, %{"entries" => entries} = record} when is_list(entries) -> {:ok, record}
      _ -> {:error, :blocker_cause_journal_corrupt}
    end
  end

  defp update(id, callback) do
    IssueLease.with_journal_lock(path(id) <> ".update", fn ->
      with {:ok, record} <- read(id), do: DurableState.write(path(id), callback.(record))
    end)
  end

  defp now(opts), do: Keyword.get(opts, :now, fn -> System.system_time(:millisecond) end).()
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
