defmodule SymphonyElixir.CommentBackgroundTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.{CommentInbox, CommentVersion}

  setup do
    root = Path.join([File.cwd!(), "_build", "background-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    binding = %{"state_root" => root, "workspace_id" => "workspace", "installation_id" => "symphony", "user_id" => "app"}
    %{binding: binding, issue: %{id: "issue"}}
  end

  test "five-second ticks share a result; unchanged signals preserve the full-scan timestamp until safety scan", ctx do
    {:ok, counter} = Agent.start_link(fn -> %{signal: 0, full: 0} end)

    full = fn ->
      Agent.update(counter, &Map.update!(&1, :full, fn n -> n + 1 end))
      {:ok, [source()]}
    end

    signal = fn ->
      Agent.update(counter, &Map.update!(&1, :signal, fn n -> n + 1 end))
      {:ok, [source()]}
    end

    opts = [signal: signal, fetch_after_signal: fn _ -> full.() end]
    assert {:ok, first} = scan(ctx, 0, full, opts)

    for now <- 5_000..295_000//5_000 do
      assert {:ok, state} = scan(ctx, now, full, opts)
      assert state["last_successful_scan"] == first["last_successful_scan"]
    end

    assert Agent.get(counter, & &1) == %{signal: 10, full: 1}
    assert {:ok, _} = scan(ctx, 300_000, full, opts)
    assert Agent.get(counter, & &1) == %{signal: 11, full: 2}
    # Explicit action scans never consume the background TTL.
    assert {:ok, _} = CommentInbox.scan(ctx.binding, ctx.issue, full)
    assert Agent.get(counter, & &1.full) == 3
  end

  test "concurrent slow scans recheck due time after acquiring the journal lock", ctx do
    parent = self()

    fetch = fn ->
      send(parent, {:fetch, self()})

      receive do
        :continue -> {:ok, [source()]}
      end
    end

    opts = [fetch_after_signal: fn _ -> fetch.() end]
    first = Task.async(fn -> scan(ctx, 0, fetch, opts) end)
    assert_receive {:fetch, worker}, 2_000
    waiting = for _ <- 1..7, do: Task.async(fn -> scan(ctx, 0, fetch, opts) end)
    for task <- waiting, do: wait_for_lock(task.pid, 200)
    send(worker, :continue)
    for task <- [first | waiting], do: assert({:ok, _} = Task.await(task))
    refute_received {:fetch, _}
  end

  test "old edits and deletions under an unchanged latest signal appear at safety reconciliation", ctx do
    older = %{source() | "id" => "older", "body" => "old"}
    first = fn -> {:ok, [older, source()]} end
    assert {:ok, state} = scan(ctx, 0, first, fetch_after_signal: fn _ -> first.() end)
    edited = Map.merge(older, %{"body" => "equal-time edit", "parentId" => "latest"})
    changed = fn -> {:ok, [edited, source()]} end
    assert {:ok, ^state} = scan(ctx, 5_000, changed, fetch_after_signal: fn _ -> changed.() end)
    assert {:ok, state} = scan(ctx, 300_000, changed, fetch_after_signal: fn _ -> changed.() end)
    assert state["versions"][CommentVersion.key(edited)]["source"] == edited
    deletion = [fetch_after_signal: fn _ -> {:ok, [source()]} end, confirm_absence: fn "older" -> :deleted end]
    assert {:ok, state} = scan(ctx, 600_000, fn -> {:ok, [source()]} end, deletion)
    assert state["versions"][CommentVersion.key(older)]["deleted"]
    assert state["versions"][CommentVersion.key(edited)]["deleted"]
  end

  test "missing signals, errors, changed binding or runtime and removed state cannot reuse proof", ctx do
    parent = self()

    fetch = fn ->
      send(parent, :full)
      {:ok, [source()]}
    end

    opts = [fetch_after_signal: fn _ -> fetch.() end]
    assert {:ok, _} = scan(ctx, 0, fetch, opts)
    assert_received :full
    assert {:ok, _} = scan(ctx, 30_000, fetch, opts ++ [signal: fn -> {:ok, []} end])
    assert_received :full
    assert {:error, :offline} = scan(ctx, 60_000, fn -> {:error, :offline} end, signal: fn -> {:error, :offline} end)
    assert {:ok, state} = CommentInbox.read(ctx.binding, ctx.issue)
    assert is_nil(state["background"])
    assert state["scan_error"] == ":offline"
    assert {:ok, _} = scan(ctx, 60_001, fetch, opts)
    assert_received :full
    assert {:ok, _} = scan(ctx, 60_002, fetch, opts ++ [background_key: "other-generation"])
    assert_received :full
    File.rm_rf!(ctx.binding["state_root"])
    assert {:ok, _} = scan(ctx, 60_003, fetch, opts)
    assert_received :full
  end

  test "a malformed signal retains observed edits even if fallback pagination fails", ctx do
    signal = {:error, {:comment_scan_incomplete, :malformed, [source()]}}
    assert {:error, :malformed} = scan(ctx, 0, fn -> {:error, :offline} end, signal: fn -> signal end)
    assert {:ok, state} = CommentInbox.read(ctx.binding, ctx.issue)
    assert state["versions"][CommentVersion.key(source())]["source"] == source()
    assert state["baseline"] == nil
    assert state["last_successful_scan"] == nil
  end

  test "partial signals preserve both sources when fallback pages succeed or are partial", ctx do
    before = source()
    after_scan = %{before | "body" => "changed"}
    signal = {:error, {:comment_scan_incomplete, :malformed, [before]}}

    for result <- [{:ok, [after_scan]}, {:error, {:comment_scan_incomplete, :offline, [after_scan]}}] do
      assert {:error, :malformed} = scan(ctx, 0, fn -> result end, signal: fn -> signal end)
      assert {:ok, state} = CommentInbox.read(ctx.binding, ctx.issue)
      assert map_size(state["versions"]) == 2
      assert state["last_successful_scan"] == nil
    end
  end

  test "long project intervals govern both background checks and safety scans", ctx do
    parent = self()

    fetch = fn ->
      send(parent, :full)
      {:ok, [source()]}
    end

    opts = [background_interval: 600_000, fetch_after_signal: fn _ -> fetch.() end]
    assert {:ok, _} = scan(ctx, 0, fetch, opts)
    assert_received :full
    assert {:ok, _} = scan(ctx, 300_000, fetch, opts)
    refute_received :full
    assert {:ok, _} = scan(ctx, 600_000, fetch, opts)
    assert_received :full
  end

  defp wait_for_lock(pid, attempts) do
    if Process.info(pid, :current_function) == {:current_function, {SymphonyElixir.Linear.IssueLease, :hold, 6}} do
      :ok
    else
      assert attempts > 0, "background caller did not reach the journal lock"
      Process.sleep(10)
      wait_for_lock(pid, attempts - 1)
    end
  end

  defp scan(ctx, now, fetch, opts) do
    defaults = [background_key: "generation", background_interval: 30_000, background_now: fn -> now end]
    defaults = defaults ++ [signal: fn -> {:ok, [source()]} end, classify: fn _ -> :foreign end]
    CommentInbox.scan(ctx.binding, ctx.issue, fetch, Keyword.merge(defaults, opts))
  end

  defp source, do: %{"id" => "latest", "body" => "newest", "issue" => %{"id" => "issue"}, "updatedAt" => "2026-09-14T00:00:00Z", "user" => %{"id" => "human", "app" => false}}
end
