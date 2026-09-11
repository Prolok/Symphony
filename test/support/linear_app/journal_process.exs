alias Absinthe.Language, as: L
alias SymphonyElixir.Linear.{CommentJournal, IssueLease}

emit = fn event -> IO.puts(Jason.encode!(event)) end
emit.(%{event: "ready", pid: System.pid()})
command = IO.read(:line) |> Jason.decode!()
binding = command["binding"]
remote = Path.join(binding["state_root"], "remote")
File.mkdir_p!(remote)

value = fn
  recurse, %L.ObjectValue{fields: fields}, variables -> Map.new(fields, &{&1.name, recurse.(recurse, &1.value, variables)})
  _recurse, %L.Variable{name: name}, variables -> Map.fetch!(variables, name)
  _recurse, %{value: value}, _variables -> value
end

# Parse the actual outgoing GraphQL. Never obtain the remote body from intents.
request = fn payload ->
  {:ok, %{input: %{definitions: [operation]}}} = Absinthe.Phase.Parse.run(payload["query"])
  [field] = operation.selection_set.selections
  arguments = Map.new(field.arguments, &{&1.name, value.(value, &1.value, payload["variables"] || %{})})

  case field.name do
    "comment" ->
      comment = File.read!(Path.join(remote, arguments["id"])) |> Jason.decode!()
      {:ok, %{status: 200, body: %{"data" => %{"comment" => comment}}}}

    "viewer" ->
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app"}}}}}

    mutation when mutation in ["commentCreate", "commentUpdate"] ->
      emit.(%{event: "http", operation: mutation})
      if command["gate"], do: "continue\n" = IO.read(:line)
      input = arguments["input"]
      id = arguments["id"] || input["id"]
      path = Path.join(remote, id)

      comment =
        if mutation == "commentCreate" do
          %{"id" => id, "issue" => %{"id" => input["issueId"]}, "user" => %{"id" => "app"}}
        else
          File.read!(path) |> Jason.decode!()
        end
        |> Map.merge(%{"body" => input["body"], "updatedAt" => command["phase"]})

      # Exclusive creation makes a repeated remote creation fail the subprocess.
      modes = if mutation == "commentCreate", do: [:write, :exclusive], else: [:write]
      File.write!(path, Jason.encode!(comment), modes)

      if command["lose_response"],
        do: {:error, :connection_lost},
        else: {:ok, %{status: 200, body: %{"data" => %{(field.alias || field.name) => %{"symphonyReceipt" => comment}}}}}
  end
end

emit.(%{event: "started"})

result =
  case command["action"] do
    "lease" ->
      IssueLease.with_lock(binding["workspace_id"], command["issue"], fn ->
        emit.(%{event: "owned"})
        if command["gate"], do: "continue\n" = IO.read(:line)
        :ok
      end)

    "reconcile" ->
      CommentJournal.reconcile(binding, request)

    _ ->
      CommentJournal.execute(binding, command["payload"], request, %{"phase" => command["phase"]}, lock_timeout: command["timeout"] || 10_000)
  end

case result do
  {:error, reason} -> emit.(%{event: "result", error: inspect(reason)})
  _ -> emit.(%{event: "result", ok: true})
end
