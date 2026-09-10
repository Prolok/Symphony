defmodule SymphonyElixir.CommentJournalTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.DurableState

  alias Absinthe.Phase.Parse
  alias SymphonyElixir.Linear.{CommentJournal, CommentMutations}

  setup do
    root = Path.join([File.cwd!(), "_build", "journal-test-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, binding: %{"state_root" => root, "workspace_id" => "workspace", "user_id" => "app", "installation_id" => "install"}}
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
    assert {:error, :issue_already_owned} = CommentJournal.execute(binding, create_payload(), fn _ -> flunk("concurrent write") end)
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

  defp create_payload, do: %{"query" => "mutation { commentCreate(input: {issueId: \"issue\", body: \"created\"}) { success } }", "variables" => %{}}
  defp comment(record), do: %{"id" => record["comment_id"], "body" => record["input"]["body"], "updatedAt" => "2026-09-10T00:00:00Z", "user" => %{"id" => "app"}, "issue" => %{"id" => "issue"}}
  defp response(data), do: {:ok, %{status: 200, body: %{"data" => data}}}
end
