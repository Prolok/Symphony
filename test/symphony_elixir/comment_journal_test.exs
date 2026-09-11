defmodule SymphonyElixir.CommentJournalTest do
  use ExUnit.Case, async: true

  alias Absinthe.Language, as: L
  alias Absinthe.Phase.Parse
  alias SymphonyElixir.Linear.{CommentJournal, CommentMutations, DurableState, WorkpadTransfer}

  setup do
    root = Path.join([File.cwd!(), "_build", "journal-test-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, binding: %{"state_root" => root, "workspace_id" => "workspace", "user_id" => "app", "installation_id" => "install"}}
  end

  @tag timeout: 60_000
  test "independent runtimes serialize the same project journal across issues and later phases" do
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    helper = Path.expand("../support/linear_app/journal_process.py", __DIR__)
    {output, status} = System.cmd(System.find_executable("python3"), [helper, System.find_executable("elixir")] ++ code_paths, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "pending recovery and true issue exclusion passed"
  end

  test "parallel clients cannot enter the same journal transaction during HTTP", %{binding: binding} do
    owner = self()

    first =
      Task.async(fn ->
        CommentJournal.execute(binding, create_payload(), fn _ ->
          send(owner, :inside_http)

          receive do
            :finish -> {:error, :connection_lost}
          end
        end)
      end)

    assert_receive :inside_http, 1_000

    assert {:error, :comment_journal_busy} =
             CommentJournal.execute(binding, create_payload(), fn _ -> flunk("concurrent write") end, %{}, lock_timeout: 100)

    query = %{"query" => "query { viewer { id } }"}
    read_request = fn ^query -> {:error, :backend_failure} end
    assert {:error, :backend_failure} = CommentJournal.execute(binding, query, read_request)

    update = %{"query" => "mutation { issueUpdate(id: \"other\", input: {title: \"later\"}) { success } }"}
    assert {:ok, :updated} = CommentJournal.execute(binding, update, fn ^update -> {:ok, :updated} end)
    assert [_] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    send(first.pid, :finish)
    assert {:error, :connection_lost} = Task.await(first)

    assert {:error, {:comment_write_unresolved, [_]}} =
             CommentJournal.execute(binding, create_payload(), fn _ -> {:error, :connection_lost} end)
  end

  test "aliases, variables, defaults, root fragments and inline inputs are instrumented" do
    payload = %{
      "query" => """
      mutation Write($input: CommentCreateInput!, $body: String! = "updated") {
        ...Create
        ... on Mutation { edited: commentUpdate(id: "old", input: {body: $body}) { success } }
        issueUpdate(id: "issue", input: {title: "preserved"}) { success }
      }
      fragment Create on Mutation { created: commentCreate(input: $input) { success } }
      """,
      "variables" => %{"input" => %{"issueId" => "issue", "body" => "created"}}
    }

    assert {:ok, prepared, [create, update]} = CommentMutations.prepare(payload)
    assert {:ok, _} = Ecto.UUID.cast(create["comment_id"])
    assert create["field"] == "created"
    assert update["comment_id"] == "old"
    assert update["input"]["body"] == "updated"
    assert prepared["query"] =~ "symphonyReceipt: comment"
    assert prepared["query"] =~ "issueUpdate"
    refute prepared["query"] =~ "$input"
    assert {:ok, _} = Parse.run(prepared["query"])
  end

  test "read queries retain their exact payload and operation selection is explicit" do
    query = %{"query" => "query { viewer { id } }", "variables" => %{}}
    assert {:ok, ^query, []} = CommentMutations.prepare(query)
    assert {:error, :invalid_graphql_document} = CommentMutations.prepare(%{"query" => "mutation {"})

    assert {:error, :invalid_graphql_document} =
             CommentMutations.prepare(%{"query" => "query A { viewer { id } } query B { viewer { id } }"})

    assert {:ok, _, []} = CommentMutations.prepare(%{"query" => "query A { viewer { id } } query B { viewer { id } }", "operationName" => "A"})
  end

  test "rewritten GraphQL roundtrips exact string values from variables, literals and defaults" do
    bodies = [
      "",
      " \t\n\r\n ",
      "\n\n  eingerückt\n    weitere Zeile\n\n",
      "## Symphony Workpad\n\nStand\n",
      "  Randabstände  ",
      "\"Quotes\" und \"\"\"Blockgrenzen\"\"\"\nBackslash: \\n \\r C:\\tmp\\ende\\\n",
      "\r\nZeile\r\nTab\tBackspace\bFormfeed\f\r\n",
      "\u0000\u0001\u001F",
      "\nGrüße 日本語 😀 e\u0301\u00A0\n",
      "\n\"}) { success } injected: commentCreate(input: {body: \"fremd\"}) #\n"
    ]

    for body <- bodies, source <- [:variable, :literal, :default] do
      encoded = Jason.encode!(body)

      {definitions, input, variables} =
        case source do
          :variable -> {"($input: CommentCreateInput!)", "$input", %{"input" => %{"issueId" => "issue", "body" => body}}}
          :literal -> {"", "{issueId: \"issue\", body: #{encoded}}", %{}}
          :default -> {"($body: String! = #{encoded})", "{issueId: \"issue\", body: $body}", %{}}
        end

      payload = %{"query" => "mutation#{definitions} { commentCreate(input: #{input}) { success } }", "variables" => variables}
      assert {:ok, prepared, [receipt]} = CommentMutations.prepare(payload)
      assert [%{name: "commentCreate", arguments: %{"input" => actual}}] = parsed_fields(prepared)
      assert actual == receipt["input"]
      assert actual["body"] === body, "changed #{source} body #{inspect(body)}"
    end
  end

  test "strings in nested input, retained defaults, directives and adjacent mutations also roundtrip" do
    body = "\n  Stand \"\"\" mit \\ und ä😀\n\n"
    encoded = Jason.encode!(body)

    payload = %{
      "query" => """
      mutation($title: String! = #{encoded}, $input: CommentCreateInput!) @custom(value: #{encoded}) {
        commentCreate(input: $input) { success }
        commentUpdate(id: "old", input: {body: #{encoded}}) { success }
        issueUpdate(id: "issue", input: {title: $title, description: #{encoded}}) { success }
      }
      """,
      "variables" => %{"input" => %{"issueId" => "issue", "bodyData" => %{"nested" => [body, %{"text" => body}], "flags" => [true, false, nil, 2, 1.5]}}}
    }

    assert {:ok, prepared, [create, update]} = CommentMutations.prepare(payload)
    assert [created, edited, adjacent] = parsed_fields(prepared)
    assert created.arguments["input"] == create["input"]
    assert Map.delete(created.arguments["input"], "id") == payload["variables"]["input"]
    assert edited.arguments["input"] == update["input"]
    assert edited.arguments["input"]["body"] === body
    assert adjacent.arguments["input"] == %{"title" => body, "description" => body}
    assert {:ok, %{input: %{definitions: [operation]}}} = Parse.run(prepared["query"])
    assert [%{arguments: [%{value: %L.StringValue{value: ^body}}]}] = operation.directives
  end

  test "caller blockstrings preserve their parsed value when rewritten as ordinary strings" do
    payload = %{"query" => ~s|mutation { commentCreate(input: {issueId: "issue", body: """\n  Plan\n    eingerückt\n  Ende\n"""}) { success } }|}
    [original] = parsed_fields(payload)
    assert {:ok, prepared, [_]} = CommentMutations.prepare(payload)
    [rewritten] = parsed_fields(prepared)
    assert rewritten.arguments["input"]["body"] === original.arguments["input"]["body"]
  end

  test "parsed app creation and immediate edit confirm exact bodies without blocking later writes", %{binding: binding} do
    body = "\n\n## Symphony Workpad\n\n  Grüße \"\"\" \\ 😀\n\n"
    Process.put(:remote_comments, %{})
    request = &graphql_request/1
    assert {:ok, _} = CommentJournal.execute(binding, variable_create("new", body), request)
    created = Process.get(:remote_comments)["new"]
    assert created["body"] === body
    assert CommentJournal.classify(binding, created) == :own
    assert length(journal_files(binding, "confirmed")) == 1

    edited_body = body <> "\nErgänzung\n\n"
    update = %{"query" => "mutation($body: String!) { commentUpdate(id: \"new\", input: {body: $body}) { success } }", "variables" => %{"body" => edited_body}}
    assert {:ok, _} = CommentJournal.execute(binding, update, request)
    edited = Process.get(:remote_comments)["new"]
    assert edited["body"] === edited_body
    assert CommentJournal.classify(binding, edited) == :own
    assert length(journal_files(binding, "confirmed")) == 2
    [edit_intent] = Enum.filter(journal_records(binding), &(&1["operation"] == "commentUpdate"))
    assert edit_intent["previous_version"] == created["updatedAt"]
    assert {:ok, _} = CommentJournal.execute(binding, variable_create("later", "Weiter\n"), request)
    assert map_size(Process.get(:remote_comments)) == 2
    assert length(journal_files(binding, "confirmed")) == 3
  end

  test "legacy newline conflicts block writes until exact operator repair and cannot cause duplicate creation", %{binding: binding} do
    body = "## Symphony Workpad\n\nKünstlicher Stand\n"
    payload = variable_create("legacy", body)
    Process.put(:remote_comments, %{})
    assert {:ok, _} = CommentJournal.execute(binding, payload, &legacy_graphql_request/1)
    [intent_path] = journal_files(binding, "intent")
    original_intent = File.read!(intent_path)
    assert journal_files(binding, "confirmed") == []
    truncated = Process.get(:remote_comments)["legacy"]
    assert truncated["body"] === String.trim_trailing(body, "\n")
    assert CommentJournal.classify(binding, truncated) == :pending

    conflicts = [
      truncated,
      %{truncated | "body" => body, "user" => %{"id" => "human"}},
      %{truncated | "body" => body, "issue" => %{"id" => "other"}},
      %{truncated | "id" => "other", "body" => body}
    ]

    for remote <- conflicts do
      assert {:ok, [%{"state" => "conflict"}]} = CommentJournal.reconcile(binding, fn _ -> response(%{"comment" => remote}) end)
    end

    other_issue = put_in(variable_create("other-comment", "Weiter"), ["variables", "input", "issueId"], "other-issue")
    blocked = CommentJournal.execute(binding, other_issue, &lookup_only/1)
    assert {:error, {:comment_write_unresolved, [%{"state" => "conflict"}]}} = blocked

    assert File.read!(intent_path) == original_intent
    assert journal_files(binding, "confirmed") == []
    # Simulate the operator restoring the exact intended body at the verified ID.
    put_remote(%{truncated | "body" => body, "updatedAt" => "operator-repair"})
    assert {:ok, [%{"state" => "confirmed"}]} = CommentJournal.reconcile(binding, &lookup_only/1)
    assert {:error, {:comment_write_recovered, ["legacy"]}} = CommentJournal.execute(binding, payload, fn _ -> flunk("duplicate creation") end)
    assert File.read!(intent_path) == original_intent
    assert {:ok, _} = CommentJournal.execute(binding, variable_create("later", "Weiter\n"), &graphql_request/1)
  end

  test "lost response after a parsed multiline creation recovers without generating another comment", %{binding: binding} do
    payload = %{"query" => "mutation($body: String!) { commentCreate(input: {issueId: \"issue\", body: $body}) { success } }", "variables" => %{"body" => "\n\nStand \\ \"\"\" 😀\n\n"}}
    Process.put(:remote_comments, %{})

    lost_response = fn outgoing ->
      assert {:ok, _} = graphql_request(outgoing)
      {:error, :lost_response}
    end

    assert {:error, :lost_response} = CommentJournal.execute(binding, payload, lost_response)
    [created] = remote_comments()
    assert created["body"] === payload["variables"]["body"]
    assert journal_files(binding, "confirmed") == []
    assert {:error, {:comment_write_recovered, [id]}} = CommentJournal.execute(binding, payload, &lookup_only/1)
    assert id == created["id"]
    assert length(journal_files(binding, "intent")) == 1
    assert length(journal_files(binding, "confirmed")) == 1
    assert remote_comments() == [created]
  end

  test "transfer activation through parsed journal writes preserves the target and later edits", %{binding: binding} do
    prepare_transfer(binding)
    api = &transfer_api(binding, &1, &2)
    assert {:ok, active} = WorkpadTransfer.activate(binding, "issue", api)
    target = Process.get(:remote_comments)[active["target_id"]]
    assert target["body"] === expected_target(active)
    assert length(journal_files(binding, "confirmed")) == 2
    assert :ok = WorkpadTransfer.ready(binding, "issue", remote_comments())
    edited_body = target["body"] <> "\nSpäterer Stand\n"
    assert :ok = api.(:update, %{"id" => target["id"], "body" => edited_body})
    assert {:ok, ^active} = WorkpadTransfer.activate(binding, "issue", api)
    assert Process.get(:remote_comments)[target["id"]]["body"] === edited_body
    assert length(remote_comments()) == 2
  end

  test "retired transfer with a legacy pending creation resumes only after exact repair", %{binding: binding} do
    prepare_transfer(binding)
    legacy_api = fn action, input -> transfer_api(binding, action, input, &legacy_graphql_request/1) end
    api = &transfer_api(binding, &1, &2)
    assert {:error, {:comment_write_unresolved, [%{"state" => "conflict"}]}} = WorkpadTransfer.activate(binding, "issue", legacy_api)
    assert {:ok, %{"phase" => "retired"} = record} = WorkpadTransfer.read(binding, "issue")
    assert length(remote_comments()) == 2
    [intent_path] = journal_files(binding, "intent")
    original_intent = File.read!(intent_path)
    assert {:error, :workpad_target_changed} = WorkpadTransfer.activate(binding, "issue", api)
    assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, "issue", remote_comments())
    target = Process.get(:remote_comments)[record["target_id"]]
    assert target["body"] <> "\n" === expected_target(record)
    put_remote(%{target | "body" => expected_target(record), "updatedAt" => "operator-repair"})
    # The normal activation reconciles the old creation before its verification edit.
    assert {:ok, active} = WorkpadTransfer.activate(binding, "issue", api)
    assert active["active_id"] == record["target_id"]
    assert :ok = WorkpadTransfer.ready(binding, "issue", remote_comments())
    assert length(remote_comments()) == 2
    assert File.read!(intent_path) == original_intent
    assert length(journal_files(binding, "confirmed")) == 2

    confirmation =
      intent_path
      |> String.replace_suffix(".intent.json", ".confirmed.json")
      |> File.read!()
      |> Jason.decode!()

    assert confirmation["recovered"] == true
  end

  test "skipped comments do not produce an intent, and invalid inputs stop before writing" do
    assert {:ok, _, []} = CommentMutations.prepare(%{"query" => "mutation { commentCreate(input: {body: \"ignored\"}) @skip(if: true) { success } }"})
    query = "mutation { ... on Mutation { commentCreate(input:{body:\"skip\"}) @skip(if:true){success} } commentCreate(input:{body:\"keep\"}){success} }"
    assert {:ok, prepared, [_]} = CommentMutations.prepare(%{"query" => query})
    assert {:ok, _} = Parse.run(prepared["query"])
    refute prepared["query"] =~ "... on"

    assert {:error, :invalid_comment_mutation} =
             CommentMutations.prepare(%{"query" => "mutation { commentUpdate(input: {body: \"no id\"}) { success } }"})

    assert {:error, :invalid_comment_mutation} =
             CommentMutations.prepare(%{"query" => "mutation { ...F } fragment F on Mutation { ...F }"})
  end

  test "intent is readable before remote write and own ID/body survive a new reader", %{binding: binding} do
    request = fn payload ->
      assert [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
      record = path |> File.read!() |> Jason.decode!()
      assert payload["query"] =~ record["comment_id"]
      comment = comment(record)
      assert CommentJournal.classify(binding, comment) == :own
      Process.put(:written_comment, comment)
      response(%{"commentCreate" => %{"symphonyReceipt" => comment}})
    end

    assert {:ok, _} = CommentJournal.execute(binding, create_payload(), request, %{"phase" => "Review (AI)", "session_id" => "session"})
    comment = Process.get(:written_comment)
    assert Task.async(fn -> CommentJournal.classify(binding, comment) end) |> Task.await() == :own
    assert [_] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.confirmed.json"]))
  end

  test "lost response after remote success can be reconciled without another creation", %{binding: binding} do
    request = fn _ -> {:error, :connection_lost} end
    assert {:error, :connection_lost} = CommentJournal.execute(binding, create_payload(), request)
    [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    record = path |> File.read!() |> Jason.decode!()

    assert {:ok, [%{"state" => "confirmed"}]} =
             CommentJournal.reconcile(binding, fn payload ->
               assert payload["query"] =~ "query SymphonyReceipt"
               assert payload["variables"]["id"] == record["comment_id"]
               response(%{"comment" => comment(record)})
             end)

    no_duplicate = fn _ -> flunk("repeated delivery cannot create a second comment") end
    assert {:error, {:comment_write_recovered, [_]}} = CommentJournal.execute(binding, create_payload(), no_duplicate)
  end

  test "partial success with errors preserves both intentions and confirms the successful field", %{binding: binding} do
    payload = %{"query" => "mutation { one: commentCreate(input:{issueId:\"issue\",body:\"created\"}){success} two: commentUpdate(id:\"old\",input:{body:\"edited\"}){success} }"}

    assert {:ok, %{body: %{"errors" => [_]}}} =
             CommentJournal.execute(binding, payload, fn request ->
               if request["query"] =~ "SymphonyReceipt" do
                 response(%{"comment" => %{"id" => "old", "body" => "before", "user" => %{"id" => "app"}, "issue" => %{"id" => "issue"}}})
               else
                 records = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"])) |> Enum.map(&(File.read!(&1) |> Jason.decode!()))
                 record = Enum.find(records, &(&1["field"] == "one"))
                 {:ok, %{status: 200, body: %{"data" => %{"one" => %{"symphonyReceipt" => comment(record)}, "two" => nil}, "errors" => [%{"message" => "cannot update"}]}}}
               end
             end)

    assert length(Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))) == 2
    assert length(Path.wildcard(Path.join([binding["state_root"], "comments", "*.confirmed.json"]))) == 1
  end

  test "changed body, wrong author and unresolved app outputs never become foreign input", %{binding: binding} do
    assert CommentJournal.classify(binding, %{"id" => "unknown", "user" => %{"id" => "app"}}) == :pending
    assert CommentJournal.classify(binding, %{"id" => "unknown", "user" => %{"id" => "human"}}) == :foreign
    assert {:error, :lost} = CommentJournal.execute(binding, create_payload(), fn _ -> {:error, :lost} end)
    [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    record = path |> File.read!() |> Jason.decode!()
    assert CommentJournal.classify(binding, %{comment(record) | "body" => "changed"}) == :pending

    assert {:ok, [%{"state" => "conflict"}]} =
             CommentJournal.reconcile(binding, fn _ -> response(%{"comment" => %{comment(record) | "body" => "changed"}}) end)

    assert {:ok, [%{"state" => "pending"}]} = CommentJournal.reconcile(binding, fn _ -> {:error, :offline} end)
  end

  test "incomplete local evidence fails visibly and prevents treating a comment as foreign", %{binding: binding} do
    assert {:error, :lost} = CommentJournal.execute(binding, create_payload(), fn _ -> {:error, :lost} end)
    [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    File.write!(path, "{")
    assert {:error, :comment_journal_corrupt} = CommentJournal.classify(binding, %{"id" => "unknown"})
    assert {:error, :comment_journal_corrupt} = CommentJournal.reconcile(binding, fn _ -> flunk("no request") end)
  end

  test "duplicate fragment fields share one UUID and nested receipt aliases cannot suppress metadata" do
    query = "mutation { ...F ...F } fragment F on Mutation { commentCreate(input:{issueId: \"issue\",body: \"same\"}) {success} }"
    assert {:ok, _, [_]} = CommentMutations.prepare(%{"query" => query})
    collision = "mutation { commentCreate(input:{issueId: \"issue\"}) { ... on CommentPayload { symphonyReceipt: comment { id } } } }"
    assert {:error, :invalid_comment_mutation} = CommentMutations.prepare(%{"query" => collision})
    conflict = "mutation { same:commentCreate(input:{body:\"one\"}) {success} same:commentCreate(input:{body:\"two\"}){success} }"
    assert {:error, :invalid_comment_mutation} = CommentMutations.prepare(%{"query" => conflict})
    assert {:error, :invalid_comment_mutation} = CommentMutations.prepare(%{"query" => "mutation { commentCreate(input:$missing){success} }"})
  end

  test "JSON input values and custom directives retain their GraphQL representation" do
    payload = %{
      "query" => "mutation($input:CommentCreateInput!){commentCreate(input:$input) @custom {success}}",
      "variables" => %{input: %{issueId: "issue", bodyData: %{flags: [true, false, nil, 2, 1.5]}}}
    }

    assert {:ok, prepared, [receipt]} = CommentMutations.prepare(payload)
    assert receipt["input"]["bodyData"]["flags"] == [true, false, nil, 2, 1.5]
    assert {:ok, _, [_]} = CommentMutations.prepare(%{"query" => "mutation{commentCreate(input:{bodyData:{a:[null,1]}}){success}}"})
    assert prepared["query"] =~ "@custom"
  end

  test "automatic recovery blocks blind creation and unknown outcomes stay pending", %{binding: binding} do
    assert {:error, :lost} = CommentJournal.execute(binding, create_payload(), fn _ -> {:error, :lost} end)
    [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    record = File.read!(path) |> Jason.decode!()
    offline = fn _ -> {:error, :offline} end
    assert {:error, {:comment_write_unresolved, [_]}} = CommentJournal.execute(binding, create_payload(), offline)

    assert {:error, {:comment_write_recovered, [_]}} =
             CommentJournal.execute(binding, create_payload(), fn request ->
               assert request["query"] =~ "SymphonyReceipt"
               response(%{"comment" => comment(record)})
             end)
  end

  test "unverified update identity and unwritable state prevent any mutation", %{binding: binding} do
    update = %{"query" => "mutation{commentUpdate(id:\"old\",input:{body:\"new\"}){success}}"}
    offline = fn _ -> {:error, :offline} end
    human = fn _ -> response(%{"comment" => %{"user" => %{"id" => "human"}}}) end
    assert {:error, :comment_update_identity_unverified} = CommentJournal.execute(binding, update, offline)
    assert {:error, :comment_update_identity_unverified} = CommentJournal.execute(binding, update, human)
    File.mkdir_p!(binding["state_root"])
    File.write!(Path.join(binding["state_root"], "comments"), "cannot be a directory")
    no_write = fn _ -> flunk("no write") end
    assert {:error, :comment_journal_unavailable} = CommentJournal.execute(binding, create_payload(), no_write)
    assert {:error, :comment_journal_unavailable} = CommentJournal.classify(binding, %{"id" => "unknown"})
  end

  test "non-body updates and workpad receipts retain output type", %{binding: binding} do
    payload = %{"query" => "mutation {commentCreate(input:{issueId:\"issue\",body:\"## Symphony Workpad\\nExisting work\"}){success}}"}
    assert {:ok, _} = CommentJournal.execute(binding, payload, fn _ -> response(%{}) end)
    [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    assert %{"output_type" => "workpad"} = File.read!(path) |> Jason.decode!()
    File.rm!(path)
    assert {:ok, _} = CommentJournal.execute(binding, %{"query" => "mutation {commentCreate(input:{issueId:\"issue\",bodyData:{text:\"structured\"}}){success}}"}, fn _ -> response(%{}) end)
  end

  test "failure before intent prevents HTTP; failure after API success retains recoverable intent", %{binding: binding} do
    fail = fn _, _ -> {:error, :synthetic_disk_failure} end
    no_write = fn _ -> flunk("no write") end
    failed = CommentJournal.execute(binding, create_payload(), no_write, %{}, state_writer: fail)
    assert {:error, :comment_journal_persist_failed} = failed

    writer = fn path, record ->
      if String.ends_with?(path, ".confirmed.json"), do: fail.(path, record), else: DurableState.write(path, record)
    end

    request = fn _ ->
      [path] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
      receipt = File.read!(path) |> Jason.decode!()
      response(%{"commentCreate" => %{"symphonyReceipt" => comment(receipt)}})
    end

    result = CommentJournal.execute(binding, create_payload(), request, %{}, state_writer: writer)
    assert {:error, :comment_journal_persist_failed} = result
    assert [_] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.intent.json"]))
    assert [] = Path.wildcard(Path.join([binding["state_root"], "comments", "*.confirmed.json"]))
  end

  defp parsed_fields(payload) do
    assert {:ok, %{input: %{definitions: [operation]}}} = Parse.run(payload["query"])
    defaults = Map.new(operation.variable_definitions, &{&1.variable.name, parsed_value(&1.default_value, %{})})
    variables = Map.merge(defaults, Map.get(payload, "variables", %{}))
    Enum.map(operation.selection_set.selections, &%{name: &1.name, field: &1.alias || &1.name, arguments: Map.new(&1.arguments, fn arg -> {arg.name, parsed_value(arg.value, variables)} end)})
  end

  defp parsed_value(%L.Variable{name: name}, variables), do: Map.fetch!(variables, name)
  defp parsed_value(%L.ObjectValue{fields: fields}, variables), do: Map.new(fields, &{&1.name, parsed_value(&1.value, variables)})
  defp parsed_value(%L.ListValue{values: values}, variables), do: Enum.map(values, &parsed_value(&1, variables))
  defp parsed_value(%L.NullValue{}, _variables), do: nil
  defp parsed_value(nil, _variables), do: nil
  defp parsed_value(%{value: value}, _variables), do: value

  defp variable_create(id, body) do
    %{"query" => "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }", "variables" => %{"input" => %{"id" => id, "issueId" => "issue", "body" => body}}}
  end

  defp journal_files(binding, kind), do: Path.wildcard(Path.join([binding["state_root"], "comments", "*.#{kind}.json"]))
  defp journal_records(binding), do: Enum.map(journal_files(binding, "intent"), &(File.read!(&1) |> Jason.decode!()))
  defp remote_comments, do: Map.values(Process.get(:remote_comments))
  defp put_remote(comment), do: Process.put(:remote_comments, Map.put(Process.get(:remote_comments), comment["id"], comment))

  defp lookup_only(payload) do
    assert [%{name: "comment", arguments: %{"id" => id}}] = parsed_fields(payload)
    response(%{"comment" => Process.get(:remote_comments)[id]})
  end

  # The remote stores only values parsed from the outgoing GraphQL, never the intent.
  defp graphql_request(payload) do
    case parsed_fields(payload) do
      [%{name: "comment"}] ->
        lookup_only(payload)

      [%{name: operation, field: field, arguments: arguments}] ->
        input = arguments["input"]

        comment =
          case operation do
            "commentCreate" ->
              refute Map.has_key?(Process.get(:remote_comments), input["id"])
              %{"id" => input["id"], "body" => input["body"], "user" => %{"id" => "app"}, "issue" => %{"id" => input["issueId"]}}

            "commentUpdate" ->
              Process.get(:remote_comments) |> Map.fetch!(arguments["id"]) |> Map.put("body", input["body"])
          end

        comment = Map.put(comment, "updatedAt", "version-#{System.unique_integer([:positive])}")
        put_remote(comment)
        response(%{field => %{"success" => true, "symphonyReceipt" => comment}})
    end
  end

  defp legacy_graphql_request(payload) do
    assert {:ok, %{input: document}} = Parse.run(payload["query"])
    graphql_request(%{payload | "query" => inspect(document, pretty: true, limit: :infinity)})
  end

  defp prepare_transfer(binding) do
    source = %{"id" => "old", "body" => "## Symphony Workpad\n\n  Stand \"zitiert\" \\ Grüße 😀\n\n", "user" => %{"id" => "human"}}
    Process.put(:remote_comments, %{"old" => source})

    legacy = fn
      :identity, _ ->
        {:ok, %{"workspace_id" => "workspace", "user_id" => "human"}}

      :list, _ ->
        {:ok, remote_comments()}

      :update, input ->
        put_remote(%{source | "body" => input["body"]})
        :ok
    end

    assert {:ok, _} = WorkpadTransfer.begin(binding, "issue", "app", %{"turns_stopped" => true, "files" => %{"config" => "synthetic"}}, legacy)
    assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, "issue", remote_comments())
    assert {:ok, _} = WorkpadTransfer.retire(binding, "issue", legacy)
    assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, "issue", remote_comments())
  end

  defp transfer_api(binding, action, input, request \\ &graphql_request/1)
  defp transfer_api(_binding, :identity, _input, _request), do: {:ok, %{"workspace_id" => "workspace", "user_id" => "app"}}
  defp transfer_api(_binding, :list, _input, _request), do: {:ok, remote_comments()}

  defp transfer_api(binding, action, input, request) do
    payload =
      case action do
        :create ->
          variable_create(input["id"], input["body"])

        :update ->
          %{
            "query" => "mutation($id: String!, $input: CommentUpdateInput!) { commentUpdate(id: $id, input: $input) { success } }",
            "variables" => %{"id" => input["id"], "input" => Map.delete(input, "id")}
          }
      end

    case CommentJournal.execute(binding, payload, request) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp expected_target(record), do: record["source"]["body"] <> "\n\nVorgänger: old (Übergabe " <> record["transfer_id"] <> ")\n"

  defp create_payload, do: %{"query" => "mutation { commentCreate(input: {issueId: \"issue\", body: \"created\"}) { success } }", "variables" => %{}}
  defp comment(record), do: %{"id" => record["comment_id"], "body" => record["input"]["body"], "updatedAt" => "2026-09-10T00:00:00Z", "user" => %{"id" => "app"}, "issue" => %{"id" => "issue"}}
  defp response(data), do: {:ok, %{status: 200, body: %{"data" => data}}}
end
