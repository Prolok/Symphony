defmodule SymphonyElixir.CommentInboxTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.{CommentInbox, CommentVersion, DurableState}

  setup do
    root = Path.join([File.cwd!(), "_build", "inputs-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    %{binding: %{"state_root" => root, "workspace_id" => "workspace", "installation_id" => "symphony", "user_id" => "app"}, issue: %{id: "one"}}
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
