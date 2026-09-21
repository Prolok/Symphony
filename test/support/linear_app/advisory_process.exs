alias SymphonyElixir.Linear.{CommentInbox, DurableState}
[path, mode] = System.argv()
{:ok, fixture} = DurableState.read(path)
binding = fixture["binding"]
issue = %{id: fixture["issue_id"]}
opts = [advisory_agent_ids: [fixture["agent"]], classify: fn _ -> :foreign end]
{:ok, _} = CommentInbox.scan(binding, issue, fn -> {:ok, fixture["comments"]} end, opts)
{:ok, state} = CommentInbox.deliver(binding, issue, %{})

state =
  if mode == "ack" do
    results = Enum.map(CommentInbox.pending(state), &%{"key" => &1["key"], "outcome" => "übernommen", "reason" => "Synthetische Kontrolle bestätigt"})
    {:ok, state} = CommentInbox.acknowledge(binding, issue, results, fn _ -> :ok end)
    state
  else
    state
  end

IO.puts(Jason.encode!(%{"inputs" => CommentInbox.pending(state)}))
