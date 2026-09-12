alias SymphonyElixir.Linear.{CommentInbox, CommentVersion}
[root, mode] = System.argv()
binding = %{"state_root" => root, "workspace_id" => "workspace", "installation_id" => "symphony", "user_id" => "app"}
issue = %{id: "issue"}
source = %{"id" => "human", "body" => "Korrektur", "updatedAt" => "2026-09-12T12:00:00Z", "user" => %{"id" => "human", "app" => false}}
result = %{"key" => CommentVersion.key(source), "outcome" => "übernommen", "reason" => "Im Plan berücksichtigt"}

response =
  case mode do
    "baseline" ->
      {:ok, _} = CommentInbox.scan(binding, issue, fn -> {:ok, []} end)
      {:ok, state} = CommentInbox.deliver(binding, issue, %{"session_id" => "baseline"})
      CommentInbox.acknowledge(binding, issue, [%{result | "key" => state["baseline"]["key"]}], fn _ -> :ok end)

    "recognize" ->
      CommentInbox.scan(binding, issue, fn -> {:ok, [source]} end)

    "deliver" ->
      CommentInbox.deliver(binding, issue, %{"session_id" => "restarted"})

    action when action in ["crash_after_write", "ack"] ->
      CommentInbox.acknowledge(binding, issue, [result], fn _ ->
        File.write!(Path.join(root, "workpad-result"), Jason.encode!(result))
        if mode == "crash_after_write", do: System.halt(9)
        :ok
      end)
  end

{:ok, state} = response
IO.puts(Jason.encode!(%{"pending" => CommentInbox.pending(state), "ready" => CommentInbox.ready?(state)}))
