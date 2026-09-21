defmodule AdvisoryIsolationProbe do
  @moduledoc "Operator-only probe inside an already authenticated synthetic scanner; starts no worker and writes no Linear data."

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{AdvisoryAgents, Client, CommentInbox}

  @spec run(String.t(), Path.t(), :baseline | :incremental | :resume) :: map()
  def run(issue_id, journal_root, mode) when mode in [:baseline, :incremental, :resume] do
    tracker = Config.settings!().tracker
    true = tracker.advisory_agent_ids != []
    :ok = AdvisoryAgents.verify()
    root = Path.expand(journal_root)
    active_root = Path.expand(tracker.app["state_root"])
    true = Path.type(journal_root) == :absolute and root != active_root and not String.starts_with?(root, active_root <> "/")
    binding = Map.put(tracker.app, "state_root", root)
    issue = %{id: issue_id}
    {:ok, previous} = CommentInbox.read(binding, issue)
    true = if mode == :resume, do: previous["baseline"] != nil, else: previous["baseline"] == nil

    opts = [
      advisory_agent_ids: tracker.advisory_agent_ids,
      resolve_advisory: &Client.fetch_comment_thread(issue_id, &1),
      confirm_absence: &Client.confirm_comment_absence(issue_id, &1)
    ]

    if mode == :incremental do
      {:ok, _} = CommentInbox.scan(binding, issue, fn -> {:ok, []} end, opts)
      {:ok, initial} = CommentInbox.deliver(binding, issue, %{})
      acknowledge(binding, issue, initial)
    end

    fetch = fn -> Client.scan_issue_comments(issue_id) end
    {:ok, _} = CommentInbox.scan(binding, issue, fetch, opts)
    {:ok, state} = CommentInbox.deliver(binding, issue, %{})
    inputs = CommentInbox.pending(state)
    false = String.contains?(Jason.encode!(inputs), "A1-")
    sources = Enum.flat_map(inputs, fn input -> input["sources"] || List.wrap(input["source"]) end)
    count = Enum.count(sources, &String.contains?(&1["body"], "CODING-CONTROL-20260921"))
    true = count == if(mode == :resume, do: 0, else: 1)
    acknowledge(binding, issue, state)
    {:ok, state} = CommentInbox.scan(binding, issue, fetch, opts)
    true = CommentInbox.ready?(state)

    %{
      "mode" => to_string(mode),
      "issue_id" => issue_id,
      "workspace_id" => binding["workspace_id"],
      "advisory_agent_ids" => tracker.advisory_agent_ids,
      "journal_root" => root,
      "coding_inputs" => count,
      "advisory_markers" => 0,
      "last_successful_scan" => state["last_successful_scan"]
    }
  end

  defp acknowledge(binding, issue, state) do
    results = Enum.map(CommentInbox.pending(state), &%{"key" => &1["key"], "outcome" => "übernommen", "reason" => "Synthetische Scannerprobe"})
    if results != [], do: CommentInbox.acknowledge(binding, issue, results, fn _ -> :ok end)
  end
end
