defmodule SymphonyElixir.ReviewStateTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ReviewState
  alias SymphonyElixir.Linear.DurableState

  # Minimal wire projection from the PRO-705 operator evidence supplied in PRO-704:
  # parent rollout line 140, 2026-09-13 08:31:42.081Z. No collab spawn accompanied it.
  @native_parent "01a099e1-5aa8-73f0-bc95-355f7dfd9f00"
  @native_turn "01a099e1-60a7-70d3-a53b-624389ba4c4a"
  @native_started %{
    "type" => "subAgentActivity",
    "kind" => "started",
    "id" => "call_S6LccyQh1cb0Np1Gi5lac4DD",
    "agentThreadId" => "01a099e4-c58d-7611-b7a8-59d4105dd486",
    "agentPath" => "/root/review_round_1"
  }

  setup ctx do
    root = Path.join([File.cwd!(), "_build", "review-state-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    issue = %Issue{id: "issue", identifier: "PRO-704", state: "Review (AI)"}
    {:ok, context} = ReviewState.open(issue, root, nil, review_state_root: root)
    :ok = ReviewState.bind_thread(context, Map.get(ctx, :parent, "parent"))
    {:ok, context: context, root: root, issue: issue}
  end

  @tag parent: @native_parent
  test "reported native start counts once without a collab spawn and keeps its original parent turn", ctx do
    for invalid <- [
          put_in(native_event("item/started", @native_started), ["params", "threadId"], "foreign"),
          put_in(native_event("item/started", @native_started), ["params", "turnId"], nil)
        ] do
      assert [] = ReviewState.observe(ctx.context, invalid)
    end

    assert ReviewState.read(ctx.context)["calls"] == %{}

    for method <- ["item/started", "item/completed", "item/completed"] do
      assert [] = ReviewState.observe(ctx.context, native_event(method, @native_started))
    end

    record = ReviewState.read(ctx.context)
    assert record["calls"] == %{@native_started["id"] => @native_turn}
    assert record["agents"] == %{@native_started["agentThreadId"] => @native_turn}

    # A second protocol representation of the same call must also remain idempotent.
    collab = %{"type" => "collabAgentToolCall", "tool" => "spawnAgent", "id" => @native_started["id"], "senderThreadId" => @native_parent, "receiverThreadIds" => [@native_started["agentThreadId"]]}
    completed = @native_started |> Map.put("kind", "completed") |> Map.put("id", "completion-event")

    for item <- [@native_started, collab, completed, completed] do
      replay = put_in(native_event("item/completed", item), ["params", "turnId"], "later-parent-turn")
      ReviewState.observe(ctx.context, replay)
      assert ReviewState.read(ctx.context) == record
    end
  end

  @tag parent: @native_parent
  test "full native history repairs missing starts while preserving stored results and delivery", ctx do
    completed = @native_started |> Map.put("kind", "completed") |> Map.put("id", "completion-event")
    child_id = @native_started["agentThreadId"]
    assert [^child_id] = ReviewState.observe(ctx.context, native_event("item/completed", completed))

    child = %{
      "id" => child_id,
      "parentThreadId" => @native_parent,
      "cwd" => ctx.root,
      "turns" => [Map.put(turn("Keine Findings."), "id", "01a099e4-c601-72a0-96ae-a11fdb0b4fbb")]
    }

    assert [_] = ReviewState.capture(ctx.context, child_id, child)
    {_, [delivered_id]} = ReviewState.pending_context(ctx.context)
    ReviewState.delivered(ctx.context, [delivered_id], "previous-resume")
    child = Map.update!(child, "turns", &(&1 ++ [turn("Findings: preserve the outstanding retry.")]))
    assert [_] = ReviewState.capture(ctx.context, child_id, child)

    before_restore = ReviewState.read(ctx.context)
    assert before_restore["calls"] == %{}
    {:ok, reopened} = ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)

    history = %{
      "id" => @native_parent,
      "parentThreadId" => nil,
      "cwd" => ctx.root,
      "turns" => [
        %{"id" => @native_turn, "itemsView" => "full", "items" => [@native_started, @native_started, completed]},
        %{"id" => "later-parent-turn", "itemsView" => "full", "items" => [completed]}
      ]
    }

    for _ <- 1..2 do
      assert [^child_id] = ReviewState.restore_parent(reopened, history)
      assert [] = ReviewState.capture(reopened, child_id, child)
      after_restore = ReviewState.read(reopened)
      assert after_restore["calls"] == %{@native_started["id"] => @native_turn}
      assert Map.delete(after_restore, "calls") == Map.delete(before_restore, "calls")
      assert {text, [_]} = ReviewState.pending_context(reopened)
      assert text =~ "1 bereits gestartete Reviewaufrufe; Budget unverändert"
      assert text =~ "preserve the outstanding retry"
      refute text =~ "Keine Findings."
    end
  end

  test "activity without a valid start call ID binds the child but never invents a call", ctx do
    for kind <- ["started", "completed"], id <- [nil, "", " "] do
      item = activity() |> Map.put("kind", kind) |> Map.put("id", id)
      ReviewState.observe(ctx.context, event(item))
    end

    ReviewState.observe(ctx.context, event(Map.put(activity(), "kind", "started")))
    assert ReviewState.read(ctx.context)["calls"] == %{}
    assert ReviewState.read(ctx.context)["agents"] == %{"child" => "turn"}
  end

  test "empty activity and waits never supply a result; unrelated provenance fails closed", ctx do
    context = ctx.context

    for payload <- [
          %{},
          %{"method" => "item/completed", "params" => %{"threadId" => "other", "turnId" => "turn", "item" => activity()}},
          event(%{"type" => "collabAgentToolCall", "tool" => "wait", "agentsStates" => %{}}),
          event(%{"type" => "collabAgentToolCall", "tool" => "spawnAgent", "id" => "bad", "senderThreadId" => "other"})
        ] do
      assert [] = ReviewState.observe(context, payload)
    end

    assert ["child"] = ReviewState.observe(context, event(activity()))
    assert {"", []} = ReviewState.pending_context(context)
    assert [] = ReviewState.capture(context, "child", child(ctx.root, []))
    assert [] = ReviewState.capture(context, "child", child(ctx.root, [Map.put(turn(""), "items", [])]))
    assert {"", []} = ReviewState.pending_context(context)

    for thread <- [child("/wrong-workspace", []), child(ctx.root, []) |> Map.put("parentThreadId", "other"), child(ctx.root, []) |> Map.put("id", "other")] do
      assert_raise RuntimeError, "review_thread_binding_mismatch", fn -> ReviewState.capture(context, "child", thread) end
    end

    assert_raise RuntimeError, "review_child_unbound", fn -> ReviewState.capture(context, "unknown", child(ctx.root, [])) end

    assert_raise RuntimeError, "review_history_incomplete", fn ->
      ReviewState.capture(context, "child", child(ctx.root, [%{"id" => "turn", "status" => "completed", "itemsView" => "summary", "items" => []}]))
    end

    for {status, phase, text} <- [{"failed", "final_answer", "Findings"}, {"interrupted", "final_answer", "Findings"}, {"completed", "commentary", "Findings"}, {"completed", "final_answer", " "}] do
      turn = turn(text) |> Map.put("status", status) |> put_in(["items", Access.at(0), "phase"], phase)
      assert [] = ReviewState.capture(context, "child", child(ctx.root, [turn]))
    end
  end

  test "stable result IDs are idempotent and reject changed finals", ctx do
    assert ["child"] = ReviewState.observe(ctx.context, event(activity()))
    assert [%{"text" => "Keine Findings."}] = ReviewState.capture(ctx.context, "child", child(ctx.root, [turn("Keine Findings.")]))
    assert [] = ReviewState.capture(ctx.context, "child", child(ctx.root, [turn("Keine Findings.")]))
    assert {text, [id]} = ReviewState.pending_context(ctx.context)
    assert text =~ "Keine Findings."
    assert :ok = ReviewState.delivered(ctx.context, [id], "parent-turn")
    assert {"", []} = ReviewState.pending_context(ctx.context)
    assert_raise RuntimeError, "review_result_changed", fn -> ReviewState.capture(ctx.context, "child", child(ctx.root, [turn("Changed")])) end
    assert_raise RuntimeError, "review_thread_binding_mismatch", fn -> ReviewState.bind_thread(ctx.context, "other") end
  end

  test "stored results must remain present in the bound child's complete history", ctx do
    assert ["child"] = ReviewState.observe(ctx.context, event(activity()))
    assert [%{"text" => "Finding"}] = ReviewState.capture(ctx.context, "child", child(ctx.root, [turn("Finding")]))

    record = ReviewState.read(ctx.context)
    [{_key, result}] = Map.to_list(record["results"])
    forged = %{result | "turn_id" => "unknown-turn", "item_id" => "unknown-item"}
    forged_key = "parent/child/unknown-turn/unknown-item"
    assert :ok = DurableState.write(ctx.context.path, put_in(record, ["results"], %{forged_key => forged}))
    assert {:ok, reopened} = ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)

    assert_raise RuntimeError, "review_result_history_mismatch", fn ->
      ReviewState.capture(reopened, "child", child(ctx.root, [turn("Finding")]))
    end
  end

  test "completed legacy messages without phase preserve their final text", ctx do
    ReviewState.observe(ctx.context, event(activity()))
    legacy = put_in(turn("Legacy finding"), ["items", Access.at(0), "phase"], nil)
    assert [%{"text" => "Legacy finding"}] = ReviewState.capture(ctx.context, "child", child(ctx.root, [legacy]))
  end

  test "damaged state and different workspace or host prevent resume", ctx do
    assert {:error, :review_state_invalid} = ReviewState.open(ctx.issue, "other", nil, review_state_root: ctx.root)
    assert {:error, :review_state_invalid} = ReviewState.open(ctx.issue, ctx.root, "other-host", review_state_root: ctx.root)
    record = ReviewState.read(ctx.context)

    for key <- ["calls", "results"] do
      assert :ok = DurableState.write(ctx.context.path, Map.put(record, key, []))
      assert {:error, :review_state_invalid} = ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)
    end

    orphan = %{
      "parent_thread_id" => "parent",
      "child_thread_id" => "unknown-child",
      "turn_id" => "child-turn",
      "item_id" => "final",
      "text" => "Finding",
      "delivered_in_turn" => nil
    }

    key = "parent/unknown-child/child-turn/final"
    assert :ok = DurableState.write(ctx.context.path, put_in(record, ["results"], %{key => orphan}))
    assert {:error, :review_state_invalid} = ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)

    assert :ok = DurableState.write(ctx.context.path, Map.put(record, "version", 2))
    assert {:error, :review_state_invalid} = ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)
    assert_raise RuntimeError, "review_state_invalid", fn -> ReviewState.read(ctx.context) end
    File.write!(ctx.context.path, "broken")
    assert {:error, :runtime_state_corrupt} = ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)
    assert_raise RuntimeError, ":runtime_state_corrupt", fn -> ReviewState.read(ctx.context) end
  end

  test "failed durable write prevents a successful result receipt", ctx do
    # The final name is valid; the atomic temporary name exceeds NAME_MAX.
    context = %{ctx.context | path: Path.join(ctx.root, String.duplicate("x", 240))}
    assert_raise RuntimeError, ":runtime_state_persist_failed", fn -> ReviewState.bind_thread(context, "parent") end
  end

  test "non-review stages never resume a stored review", ctx do
    for state <- ["Review", "Fertig", "Test (AI)", "Freigabe Review"] do
      assert {:ok, nil} = ReviewState.open(%{ctx.issue | state: state}, ctx.root, nil, review_state_root: ctx.root)
    end

    assert %{} = ReviewState.read(nil)
    assert :ok = ReviewState.bind_thread(nil, "parent")
    assert :ok = ReviewState.delivered(nil, [], "turn")
    assert [] = ReviewState.observe(nil, event(activity()))
    assert {"", []} = ReviewState.pending_context(nil)
    assert {:ok, nil} = ReviewState.open(%{ctx.issue | state: "Review"}, ctx.root, nil)
  end

  test "leaving review removes only the bound issue record", ctx do
    settings = put_in(Config.settings!().tracker.app["state_root"], ctx.root)
    project = %SymphonyElixir.ProjectContext{root: File.cwd!(), settings: settings}
    SymphonyElixir.ProjectContext.with_context(project, fn -> assert :ok = ReviewState.clear(ctx.issue) end)
    refute File.exists?(ctx.context.path)
    SymphonyElixir.ProjectContext.with_context(project, fn -> assert :ok = ReviewState.clear(ctx.issue) end)
    settings = put_in(settings.tracker.app["state_root"], nil)
    SymphonyElixir.ProjectContext.with_context(%{project | settings: settings}, fn -> assert :ok = ReviewState.clear(ctx.issue) end)
  end

  test "a persisted departure blocks reuse until cleanup completes", ctx do
    settings = put_in(Config.settings!().tracker.app["state_root"], ctx.root)
    project = %SymphonyElixir.ProjectContext{root: File.cwd!(), settings: settings}

    SymphonyElixir.ProjectContext.with_context(project, fn ->
      assert {:ok, :absent} = ReviewState.persisted_binding(%{})
      assert :ok = ReviewState.mark_departed(%{})
      assert {:ok, :absent} = ReviewState.persisted_binding(%{id: "missing-review"})
      assert :ok = ReviewState.mark_departed(%{id: "missing-review"})

      assert {:ok, %{workspace: workspace, worker_host: nil, departed: false}} =
               ReviewState.persisted_binding(ctx.issue)

      assert workspace == ctx.root
      assert :ok = ReviewState.mark_departed(ctx.issue)

      assert {:ok, %{workspace: ^workspace, worker_host: nil, departed: true}} =
               ReviewState.persisted_binding(ctx.issue)

      assert {:error, :review_state_departed} =
               ReviewState.open(ctx.issue, ctx.root, nil, review_state_root: ctx.root)

      assert {:error, :review_state_departed} = ReviewState.worker_host(ctx.issue)
      assert :ok = ReviewState.clear(ctx.issue)
      assert {:ok, :absent} = ReviewState.persisted_binding(ctx.issue)
    end)

    no_root = put_in(settings.tracker.app["state_root"], nil)

    SymphonyElixir.ProjectContext.with_context(%{project | settings: no_root}, fn ->
      assert {:ok, :absent} = ReviewState.persisted_binding(ctx.issue)
      assert :ok = ReviewState.mark_departed(ctx.issue)
    end)
  end

  test "persisted departure inspection rejects invalid or corrupt state", ctx do
    settings = put_in(Config.settings!().tracker.app["state_root"], ctx.root)
    project = %SymphonyElixir.ProjectContext{root: File.cwd!(), settings: settings}

    SymphonyElixir.ProjectContext.with_context(project, fn ->
      assert :ok = DurableState.write(ctx.context.path, %{})
      assert {:error, :review_state_invalid} = ReviewState.persisted_binding(ctx.issue)
      assert {:error, :review_state_invalid} = ReviewState.mark_departed(ctx.issue)

      File.write!(ctx.context.path, "broken")
      assert {:error, :runtime_state_corrupt} = ReviewState.persisted_binding(ctx.issue)
      assert {:error, :runtime_state_corrupt} = ReviewState.mark_departed(ctx.issue)
    end)
  end

  test "worker host lookup is bound, validates state, and ignores non-review stages", ctx do
    settings = put_in(Config.settings!().tracker.app["state_root"], ctx.root)
    project = %SymphonyElixir.ProjectContext{root: File.cwd!(), settings: settings}

    SymphonyElixir.ProjectContext.with_context(project, fn ->
      assert {:ok, {:bound, nil}} = ReviewState.worker_host(ctx.issue)
      assert {:ok, :unbound} = ReviewState.worker_host(%{ctx.issue | state: "Test (AI)"})
      assert {:ok, :unbound} = ReviewState.worker_host(%{})

      record = ReviewState.read(ctx.context)
      assert :ok = DurableState.write(ctx.context.path, Map.put(record, "calls", []))
      assert {:error, :review_state_invalid} = ReviewState.worker_host(ctx.issue)

      assert :ok = DurableState.write(ctx.context.path, %{})
      assert {:error, :review_state_invalid} = ReviewState.worker_host(ctx.issue)

      File.write!(ctx.context.path, "broken")
      assert {:error, :runtime_state_corrupt} = ReviewState.worker_host(ctx.issue)
    end)

    no_root = put_in(settings.tracker.app["state_root"], nil)

    SymphonyElixir.ProjectContext.with_context(%{project | settings: no_root}, fn ->
      assert {:ok, :unbound} = ReviewState.worker_host(ctx.issue)
    end)
  end

  defp event(item), do: %{"method" => "item/completed", "params" => %{"threadId" => "parent", "turnId" => "turn", "item" => item}}
  defp native_event(method, item), do: %{"method" => method, "params" => %{"threadId" => @native_parent, "turnId" => @native_turn, "item" => item}}
  defp activity, do: %{"type" => "subAgentActivity", "kind" => "completed", "agentThreadId" => "child"}
  defp child(workspace, turns), do: %{"id" => "child", "parentThreadId" => "parent", "cwd" => workspace, "turns" => turns}
  defp turn(text), do: %{"id" => "turn", "status" => "completed", "itemsView" => "full", "items" => [%{"type" => "agentMessage", "phase" => "final_answer", "id" => "final", "text" => text}]}
end
