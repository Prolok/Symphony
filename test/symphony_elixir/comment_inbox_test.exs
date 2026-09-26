defmodule SymphonyElixir.CommentInboxTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.{CommentInbox, CommentJournal, CommentVersion, DurableState, IssueLease}

  setup do
    root = Path.join([File.cwd!(), "_build", "inputs-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    %{binding: %{"state_root" => root, "workspace_id" => "workspace", "installation_id" => "symphony", "user_id" => "app"}, issue: %{id: "one"}}
  end

  test "current snapshot tracks a restored version without discarding history and survives failed scans", ctx do
    first = comment("workpad", "Stand A")
    second = comment("workpad", "Stand B")
    assert {:ok, _} = scan(ctx, [first])
    assert {:ok, state} = scan(ctx, [second])
    assert state["current"] == %{"workpad" => CommentVersion.key(second)}
    assert {:ok, state} = scan(ctx, [first])
    assert state["current"] == %{"workpad" => CommentVersion.key(first)}
    assert map_size(state["versions"]) == 2
    fetch = fn -> {:error, {:comment_scan_incomplete, :missing_page, [second]}} end
    assert {:error, :missing_page} = CommentInbox.scan(ctx.binding, ctx.issue, fetch)
    assert {:ok, failed} = read(ctx)
    assert failed["current"] == state["current"]
    assert failed["scan_error"] != nil
    assert {:ok, empty} = scan(ctx, [])
    assert empty["current"] == %{}
    assert map_size(empty["versions"]) == 2
  end

  test "baseline preserves open historical guidance once; later edits are independent versions", ctx do
    historical = comment("old", "Offener Hinweis: Test für Fehler ergänzen")
    assert {:ok, state} = scan(ctx, [historical])
    assert [%{"origin" => "baseline", "sources" => [^historical]}] = CommentInbox.pending(state)
    refute CommentInbox.ready?(state)
    assert {:error, :invalid_comment_result} = ack(ctx, state["baseline"]["key"])
    assert {:ok, state} = deliver(ctx)
    assert {:ok, state} = ack(ctx, state["baseline"]["key"])
    assert CommentInbox.ready?(state)
    assert {:ok, state} = scan(ctx, [historical])
    assert CommentInbox.pending(state) == []

    first = comment("new", "noch nicht freigegeben")
    second = %{first | "body" => "freigegeben"}
    assert {:ok, _} = scan(ctx, [historical, first])
    assert {:ok, _} = deliver(ctx)
    assert {:ok, state} = scan(ctx, [historical, first, second, first])
    assert length(CommentInbox.pending(state)) == 2
    assert {:ok, state} = ack(ctx, CommentVersion.key(first))
    assert [%{"source" => ^second, "status" => "recognized"}] = CommentInbox.pending(state)
    assert {:ok, state} = deliver(ctx)
    assert state["versions"][CommentVersion.key(second)]["delivery"] == %{"session_id" => "resumed"}
    assert {:ok, state} = ack(ctx, CommentVersion.key(second))
    assert CommentInbox.ready?(state)
  end

  test "failed scan neither baselines nor deletes; resolution stays open, deleted work is delivered for assessment", ctx do
    assert {:error, :rate_limited} = CommentInbox.scan(ctx.binding, ctx.issue, fn -> {:error, :rate_limited} end)
    assert {:ok, %{"baseline" => nil, "last_successful_scan" => nil, "scan_error" => ":rate_limited"}} = read(ctx)
    establish(ctx)
    source = comment("reply", "Korrektur")
    assert {:ok, state} = scan(ctx, [source])
    last = state["last_successful_scan"]
    assert {:error, :offline} = CommentInbox.scan(ctx.binding, ctx.issue, fn -> {:error, :offline} end)
    assert {:ok, state} = read(ctx)
    assert state["last_successful_scan"] == last
    assert state["versions"][CommentVersion.key(source)]["deleted"] == false
    resolved = Map.put(source, "resolvedAt", "2026-09-12T12:00:01Z")
    assert {:ok, state} = scan(ctx, [resolved])
    assert length(CommentInbox.pending(state)) == 2
    assert {:ok, _} = deliver(ctx)
    assert {:ok, state} = scan(ctx, [])
    assert Enum.all?(CommentInbox.pending(state), & &1["deleted"])
    assert {:ok, _} = CommentInbox.acknowledge(ctx.binding, ctx.issue, [result(source), result(resolved)], fn _ -> :ok end)
  end

  test "own outputs and integrations do not activate; changed app text and unknown origin stay visible", ctx do
    establish(ctx)
    own = put_in(comment("own", "Review veröffentlicht"), ["user"], %{"id" => "app", "app" => true})
    bot = Map.put(comment("bot", "automatisch"), "botActor", %{"id" => "integration"})
    external = Map.put(comment("external", "extern"), "externalUser", %{"id" => "external"})
    behalf = Map.put(comment("behalf", "vertretung"), "onBehalfOf", %{"id" => "someone"})
    app = put_in(comment("app", "integration"), ["user", "app"], true)
    unknown = Map.delete(comment("unknown", "unklar"), "user")
    changed = %{own | "id" => "changed"}

    classify = fn source ->
      case source["id"] do
        "own" -> :own
        "changed" -> :pending
        _ -> :foreign
      end
    end

    assert {:ok, state} = scan(ctx, [own, bot, external, behalf, app, unknown, changed], classify: classify)
    assert Enum.sort(Enum.map(CommentInbox.pending(state), & &1["origin"])) == ["changed_app_output", "unknown"]
    assert {:ok, _} = deliver(ctx)
    assert {:error, :journal_broken} = scan(ctx, [own], classify: fn _ -> {:error, :journal_broken} end)
    assert {:ok, state} = read(ctx)
    assert length(CommentInbox.pending(state)) == 2
  end

  test "deletion after acknowledgement has an independent restartable assessment", ctx do
    establish(ctx)
    source = comment("done", "Änderung übernehmen")
    scan(ctx, [source])
    deliver(ctx)
    ack(ctx, CommentVersion.key(source))
    assert {:ok, state} = scan(ctx, [])
    refute CommentInbox.ready?(state)
    assert [deletion] = CommentInbox.pending(state)
    assert deletion["deleted"]
    assert deletion["key"] != CommentVersion.key(source)
    assert deletion["previous_result"] == result(source)
    assert {:ok, state} = ack(ctx, CommentVersion.key(source))
    refute CommentInbox.ready?(state)
    assert {:ok, state} = Task.async(fn -> deliver(ctx) end) |> Task.await()
    assert [%{"key" => key, "deleted" => true}] = CommentInbox.pending(state)
    assert {:ok, state} = ack(ctx, key, "Begonnene Auswirkungen eingeordnet; nichts erneut ausgeführt")
    assert CommentInbox.ready?(state)
    assert {:ok, state} = scan(ctx, [])
    assert CommentInbox.pending(state) == []
  end

  test "deletion cannot be swallowed by an acknowledgement of the delivered baseline", ctx do
    source = comment("historical", "Offener Hinweis")
    scan(ctx, [source])
    {:ok, state} = deliver(ctx)
    baseline = state["baseline"]["key"]
    scan(ctx, [])
    assert {:ok, state} = ack(ctx, baseline)
    assert [%{"deleted" => true}] = CommentInbox.pending(state)
  end

  test "deleting one source preserves another independently open input", ctx do
    establish(ctx)
    deleted = comment("deleted", "Erste Eingabe")
    retained = comment("retained", "Unabhängige Eingabe")
    scan(ctx, [deleted, retained])
    assert {:ok, state} = scan(ctx, [retained])
    assert state["versions"][CommentVersion.key(deleted)]["deleted"]
    refute state["versions"][CommentVersion.key(retained)]["deleted"]
    assert length(CommentInbox.pending(state)) == 2
  end

  test "a historical source deleted before baseline processing is visibly withdrawn at delivery", ctx do
    source = comment("historical", "Noch offener Hinweis")
    assert {:ok, _} = scan(ctx, [source])
    assert {:ok, _} = scan(ctx, [])
    assert {:ok, state} = deliver(ctx)
    assert [%{"origin" => "baseline", "sources" => [%{"deleted" => true, "id" => "historical"}]}] = CommentInbox.pending(state)
  end

  test "workpad failure and crash after write leave delivered versions replayable; result retry is idempotent", ctx do
    establish(ctx)
    source = comment("one", "Bitte prüfen")
    scan(ctx, [source])
    deliver(ctx)
    results = [result(source)]
    assert {:error, :write_failed} = CommentInbox.acknowledge(ctx.binding, ctx.issue, results, fn _ -> {:error, :write_failed} end)
    owner = self()

    writer = fn received ->
      send(owner, {:workpad_written, received})
      :ok
    end

    assert {:error, :disk_full} = CommentInbox.acknowledge(ctx.binding, ctx.issue, results, writer, writer: fn _, _ -> {:error, :disk_full} end)
    assert_receive {:workpad_written, ^results}
    assert {:ok, state} = Task.async(fn -> CommentInbox.deliver(ctx.binding, ctx.issue, %{"session_id" => "new-process"}) end) |> Task.await()
    assert [%{"status" => "delivered"}] = CommentInbox.pending(state)
    assert {:ok, _} = CommentInbox.acknowledge(ctx.binding, ctx.issue, results, writer)
    assert {:ok, _} = CommentInbox.acknowledge(ctx.binding, ctx.issue, results, writer)
    assert {:error, :invalid_comment_result} = ack(ctx, CommentVersion.key(source), "andere Begründung")
  end

  test "scan and acknowledgement serialize and preserve concurrent new input", ctx do
    establish(ctx)
    first = comment("one", "eins")
    second = comment("two", "zwei")
    scan(ctx, [first])
    deliver(ctx)
    owner = self()

    ack =
      Task.async(fn ->
        CommentInbox.acknowledge(ctx.binding, ctx.issue, [result(first)], fn _ ->
          send(owner, :writing)

          receive do
            :continue -> :ok
          end
        end)
      end)

    assert_receive :writing, 1_000
    scan = Task.async(fn -> scan(ctx, [first, second]) end)
    refute Task.yield(scan, 100)
    send(ack.pid, :continue)
    assert {:ok, _} = Task.await(ack)
    assert {:ok, state} = Task.await(scan)
    assert [%{"source" => ^second}] = CommentInbox.pending(state)
  end

  test "invalid results cannot clear input, replacement must reference another version of the same comment", ctx do
    establish(ctx)
    first = comment("one", "eins")
    second = %{first | "body" => "zwei"}
    other = comment("other", "unabhängig")
    scan(ctx, [first, second, other])
    deliver(ctx)

    for results <- [
          nil,
          [],
          [result(first), result(first)],
          [%{"key" => "missing", "outcome" => "übernommen", "reason" => "x"}],
          [Map.put(result(first), "reason", " ")],
          [Map.put(result(first), "outcome", "unbekannt")],
          [Map.merge(result(first), %{"outcome" => "ersetzt", "replacement" => CommentVersion.key(other)})],
          [Map.merge(result(first), %{"outcome" => "ersetzt", "replacement" => CommentVersion.key(first)})]
        ] do
      assert {:error, :invalid_comment_result} = CommentInbox.acknowledge(ctx.binding, ctx.issue, results, fn _ -> flunk("unexpected write") end)
    end

    replacement = Map.merge(result(first), %{"outcome" => "ersetzt", "replacement" => CommentVersion.key(second)})
    assert {:ok, _} = CommentInbox.acknowledge(ctx.binding, ctx.issue, [replacement], fn _ -> :ok end)
  end

  test "project, workspace and issue identity are separate and corrupt state is never reset", ctx do
    establish(ctx)
    second = %{ctx | issue: %{id: "two"}}
    assert {:ok, %{"baseline" => nil}} = read(second)
    foreign = %{ctx | binding: %{ctx.binding | "workspace_id" => "other"}}
    assert {:error, :comment_inbox_corrupt} = read(foreign)
    [path] = Path.wildcard(Path.join([ctx.binding["state_root"], "inputs", "*.json"]))
    {:ok, state} = read(ctx)
    :ok = DurableState.write(path, %{state | "baseline" => %{"sources" => []}})
    assert {:error, :comment_inbox_corrupt} = read(ctx)
    :ok = DurableState.write(path, %{state | "versions" => %{"broken" => %{}}})
    assert {:error, :comment_inbox_corrupt} = read(ctx)
    assert :ok = DurableState.write(path, %{"versions" => []})
    assert {:error, :comment_inbox_corrupt} = scan(ctx, [])
    File.write!(path, "broken")
    assert {:error, :runtime_state_corrupt} = read(ctx)
  end

  test "version fingerprint retains equal-time edits and normalizes the complete observed source" do
    source = comment("one", "Grüße")
    assert {:ok, normalized} = CommentVersion.normalize(source)
    assert CommentVersion.raw(normalized) == source
    assert CommentVersion.key(normalized) == CommentVersion.key(source)
    refute CommentVersion.key(source) == CommentVersion.key(%{source | "body" => "Änderung"})
    assert {:ok, %{created_at: nil, updated_at: nil}} = CommentVersion.normalize(%{"id" => "x", "body" => "x", "updatedAt" => "invalid"})

    for invalid <- [%{}, %{"id" => "", "body" => "x"}, %{"id" => "x", "body" => nil}] do
      assert {:error, :linear_invalid_comment} = CommentVersion.normalize(invalid)
    end
  end

  @tag timeout: 60_000
  test "independent BEAM processes resume after recognition, delivery and a crash after the workpad write", ctx do
    helper = Path.expand("../support/linear_app/input_process.exs", __DIR__)
    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    run = fn mode -> System.cmd(System.find_executable("elixir"), paths ++ [helper, ctx.binding["state_root"], mode], stderr_to_stdout: true) end

    for mode <- ["baseline", "recognize", "deliver"] do
      assert {_, 0} = run.(mode)
    end

    assert {_, 9} = run.("crash_after_write")
    assert File.exists?(Path.join(ctx.binding["state_root"], "workpad-result"))
    {output, 0} = run.("deliver")
    assert [%{"status" => "delivered", "delivery" => %{"session_id" => "restarted"}}] = Jason.decode!(output)["pending"]
    {output, 0} = run.("ack")
    assert Jason.decode!(output)["ready"]
  end

  test "partial first scans preserve known inputs without establishing a historical baseline", ctx do
    source = comment("one", "bekannte offene Eingabe")
    fetch = fn -> {:error, {:comment_scan_incomplete, :missing_page, [source]}} end
    assert {:error, :missing_page} = CommentInbox.scan(ctx.binding, ctx.issue, fetch)
    assert {:ok, %{"baseline" => nil} = state} = read(ctx)
    assert [%{"source" => ^source}] = CommentInbox.pending(state)
    assert {:ok, state} = scan(ctx, [source])
    assert length(CommentInbox.pending(state)) == 2
    assert {:error, :comment_absence_unverified} = CommentInbox.scan(ctx.binding, ctx.issue, fn -> {:ok, []} end)
    assert {:error, :comment_scan_inconsistent} = scan(ctx, [], confirm_absence: fn _ -> {:present, source} end)
    assert {:ok, state} = read(ctx)
    refute state["versions"][CommentVersion.key(source)]["deleted"]
  end

  test "a write completes during a delayed fetch and its echo remains own", ctx do
    owner = self()
    own = %{"id" => "own", "body" => "App-Ausgabe", "user" => %{"id" => "app"}, "issue" => %{"id" => ctx.issue.id}, "updatedAt" => "2026-09-26T08:00:00Z"}

    scan =
      Task.async(fn ->
        CommentInbox.scan(ctx.binding, ctx.issue, fn ->
          send(owner, :fetch_started)

          receive do
            :finish_fetch -> {:ok, [own]}
          end
        end)
      end)

    assert_receive :fetch_started, 1_000
    payload = %{"query" => "mutation { commentCreate(input: {id: \"own\", issueId: \"one\", body: \"App-Ausgabe\"}) { success } }"}

    assert {:ok, _} =
             CommentJournal.execute(ctx.binding, payload, fn _ ->
               {:ok, %{status: 200, body: %{"data" => %{"commentCreate" => %{"symphonyReceipt" => own}}}}}
             end)

    send(scan.pid, :finish_fetch)
    assert {:ok, state} = Task.await(scan)
    assert state["versions"][CommentVersion.key(own)]["origin"] == "own"
    assert Enum.all?(CommentInbox.pending(state), &(&1["origin"] != "human"))
  end

  test "one scan reads each active intent once for many comments", ctx do
    directory = Path.join(ctx.binding["state_root"], "comments")
    File.mkdir_p!(directory)

    for number <- 1..12 do
      id = "operation-#{number}"

      record = %{
        "operation_id" => id,
        "comment_id" => id,
        "workspace_id" => "workspace",
        "installation_id" => "symphony",
        "operation" => "commentCreate",
        "issue_id" => "one",
        "author_id" => "app",
        "written_at" => "2026-09-26T08:00:00Z",
        "input" => %{"body" => "App-Ausgabe"}
      }

      File.write!(Path.join(directory, id <> ".intent.json"), Jason.encode!(record))
      confirmed = %{"id" => id, "body" => "App-Ausgabe", "user" => %{"id" => "app"}, "issue" => %{"id" => "one"}}
      File.write!(Path.join(directory, id <> ".confirmed.json"), Jason.encode!(%{"comment" => confirmed}))
    end

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    reader = fn file ->
      Agent.update(counter, &(&1 + 1))
      DurableState.read(Path.join(directory, file))
    end

    assert {:ok, _} =
             scan(ctx, Enum.map(1..30, &comment("human-#{&1}", "Eingabe")),
               journal_reader: reader,
               journal_request: fn _ -> flunk("confirmed receipts need no remote reconciliation") end
             )

    assert Agent.get(counter, & &1) == 12
  end

  test "a pending own receipt is reconciled from the scan view", ctx do
    directory = Path.join(ctx.binding["state_root"], "comments")
    File.mkdir_p!(directory)
    own = %{"id" => "late-own", "body" => "App-Ausgabe", "user" => %{"id" => "app"}, "issue" => %{"id" => "one"}, "updatedAt" => "2026-09-26T08:00:00Z"}

    record = %{
      "operation_id" => "late-own",
      "comment_id" => "late-own",
      "workspace_id" => "workspace",
      "installation_id" => "symphony",
      "operation" => "commentCreate",
      "issue_id" => "one",
      "author_id" => "app",
      "written_at" => "2026-09-26T08:00:00Z",
      "input" => %{"body" => "App-Ausgabe"}
    }

    File.write!(Path.join(directory, "late-own.intent.json"), Jason.encode!(record))
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    reader = fn file ->
      Agent.update(counter, &(&1 + 1))
      DurableState.read(Path.join(directory, file))
    end

    assert {:ok, state} =
             scan(ctx, [own],
               journal_reader: reader,
               journal_request: fn _ -> {:ok, %{status: 200, body: %{"data" => %{"comment" => own}}}} end
             )

    assert Agent.get(counter, & &1) == 1
    assert state["versions"][CommentVersion.key(own)]["origin"] == "own"
  end

  test "a short journal contention is retried inside the scan", ctx do
    owner = self()

    holder =
      Task.async(fn ->
        IssueLease.with_journal_lock(ctx.binding["state_root"], fn ->
          send(owner, :journal_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :journal_held, 1_000
    {:ok, fetches} = Agent.start_link(fn -> 0 end)

    scan =
      Task.async(fn ->
        CommentInbox.scan(
          ctx.binding,
          ctx.issue,
          fn ->
            Agent.update(fetches, &(&1 + 1))
            send(owner, :scan_fetched)
            {:ok, []}
          end,
          scan_lock_timeout: 1
        )
      end)

    assert_receive :scan_fetched, 1_000
    Process.sleep(100)
    send(holder.pid, :release)
    assert :ok = Task.await(holder)
    assert {:ok, _} = Task.await(scan)
    assert Agent.get(fetches, & &1) >= 2
  end

  defp comment(id, body), do: %{"id" => id, "body" => body, "user" => %{"id" => "human", "app" => false}, "createdAt" => "2026-09-12T12:00:00Z", "updatedAt" => "2026-09-12T12:00:00Z"}
  defp result(source), do: %{"key" => CommentVersion.key(source), "outcome" => "übernommen", "reason" => "Im Plan berücksichtigt"}
  defp scan(ctx, comments, opts \\ []), do: CommentInbox.scan(ctx.binding, ctx.issue, fn -> {:ok, comments} end, Keyword.put_new(opts, :confirm_absence, fn _ -> :deleted end))
  defp read(ctx), do: CommentInbox.read(ctx.binding, ctx.issue)
  defp deliver(ctx), do: CommentInbox.deliver(ctx.binding, ctx.issue, %{"session_id" => "resumed"})
  defp ack(ctx, key, reason \\ "Im Plan berücksichtigt"), do: CommentInbox.acknowledge(ctx.binding, ctx.issue, [%{"key" => key, "outcome" => "übernommen", "reason" => reason}], fn _ -> :ok end)

  defp establish(ctx) do
    {:ok, _} = scan(ctx, [])
    {:ok, state} = deliver(ctx)
    {:ok, _} = ack(ctx, state["baseline"]["key"])
  end
end
