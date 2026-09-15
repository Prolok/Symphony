defmodule SymphonyElixir.RelayCacheTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Relay.{Session, Store}
  alias SymphonyElixir.RelayFixture, as: Server

  setup do
    root = Path.join([File.cwd!(), "_build", "relay-case-#{System.unique_integer([:positive])}"])
    server = start_supervised!(Server)
    clock = start_supervised!({Agent, fn -> 1_000 end})
    on_exit(fn -> File.rm_rf!(root) end)
    config = %{"state_root" => root, "reconcile_ms" => 3_600_000}
    {:ok, root: root, config: config, server: server, clock: clock}
  end

  defp open(c, opts \\ []) do
    consumer = opts[:consumer] || "one"
    workspace = opts[:workspace] || "workspace"
    defaults = [request: &Server.request(c.server, workspace, consumer, &1, &2), snapshot: fn _ -> {:ok, [issue()]} end, fetch: fn _ -> {:ok, [issue()]} end, clock: fn -> Agent.get(c.clock, & &1) end]
    Session.open(c.config, workspace, consumer, opts[:assignees] || ["human"], opts[:binding] || "binding", Keyword.merge(defaults, opts))
  end

  defp issue(time \\ "2026-09-14T20:00:00Z"), do: %{"id" => "issue", "updatedAt" => time, "title" => time}
  defp retry(s), do: %{s | retry_at: 0}

  test "subscription precedes snapshot; changes during snapshot replay before ready", c do
    parent = self()

    {:ok, s} =
      open(c,
        snapshot: fn _ ->
          assert Server.consumer(c.server, "workspace", "one").ready == false
          Server.publish(c.server, "workspace")
          {:ok, [issue()]}
        end,
        fetch: fn ids ->
          send(parent, {:fetch, ids})
          {:ok, [issue("2026-09-14T20:01:00Z")]}
        end
      )

    s = Session.tick(s)
    assert s.status == :ready
    assert s.record["cursor"] == 1
    assert s.record["issues"]["issue"]["updatedAt"] == "2026-09-14T20:01:00Z"
    assert_received {:fetch, ["issue"]}
    assert Enum.map(Server.calls(c.server), &elem(&1, 2)) == [:register, :resync, :poll, :ack]
    assert {:ok, record} = DurableState.read(s.path)
    assert record == s.record
    assert {:ok, restarted} = open(c)
    assert Session.tick(restarted).status == :ready
  end

  test "incomplete snapshot cannot complete; lost completion can be repeated", c do
    {:ok, s} = open(c, snapshot: fn _ -> {:error, :partial_page} end)
    s = Session.tick(s)
    assert s.status == :degraded
    refute Enum.any?(Server.calls(c.server), &(elem(&1, 3) == %{"phase" => "complete", "token" => s.record["token"]}))
    assert s.record["phase"] == "snapshot"
    assert {:ok, restart} = open(c)
    s = Session.tick(restart)
    assert s.status == :ready
    # Persisted snapshot followed by an unknown complete outcome.
    {:ok, _} = Server.request(c.server, "workspace", "one", :resync, %{"phase" => "begin"})
    Server.fault(c.server, "workspace", "one", :resync, {:error, :timeout})
    {:ok, again} = open(c)
    failed = Session.tick(again)
    assert failed.record["phase"] == "complete"
    assert Session.tick(retry(failed)).status == :ready
  end

  test "failed persistence never acks; restart repeats durable batch after lost ack", c do
    {:ok, s} = open(c)
    s = Session.tick(s)
    Server.publish(c.server, "workspace")
    failed = Session.tick(%{s | persist: fn _, _ -> {:error, :disk_full} end})
    assert failed.error == :disk_full
    refute Enum.any?(Server.calls(c.server), &(elem(&1, 2) == :ack))
    parent = self()

    request = fn op, body ->
      result = Server.request(c.server, "workspace", "one", op, body)

      if op == :ack do
        assert {:ok, %{"pending" => %{"receipt" => receipt}}} = DurableState.read(s.path)
        assert receipt == body["receipt"]
        send(parent, :durable_before_ack)
        {:error, :lost_ack_response}
      else
        result
      end
    end

    after_ack = Session.tick(%{s | request: request})
    assert_received :durable_before_ack
    assert after_ack.record["pending"] != nil
    assert Server.consumer(c.server, "workspace", "one").cursor == 1
    {:ok, restarted} = open(c)
    restarted = Session.tick(restarted)
    assert restarted.status == :ready
    assert restarted.record["pending"] == nil
    assert restarted.record["cursor"] == 1
  end

  test "burst IDs coalesce; empty filtered pages ack; stale source never replaces newer state", c do
    parent = self()

    {:ok, s} =
      open(c,
        fetch: fn ids ->
          send(parent, {:ids, ids})
          {:ok, [issue("2020-01-01T00:00:00Z")]}
        end
      )

    s = Session.tick(s)
    for _ <- 1..4, do: Server.publish(c.server, "workspace")
    s = Session.tick(s)
    assert_received {:ids, ["issue"]}
    refute_received {:ids, _}
    assert s.record["issues"]["issue"] == issue()
    Server.publish(c.server, "workspace", %{"assigneeIds" => ["unsubscribed"]})
    s = Session.tick(s)
    assert s.record["cursor"] == 5
    refute_received {:ids, _}
    assert length(Server.consumer(c.server, "workspace", "one").acks) == 2
  end

  test "two consumers and two workspaces have independent receipts and caches", c do
    {:ok, a} = open(c)
    {:ok, b} = open(c, consumer: "two")
    {:ok, other} = open(c, workspace: "other")
    [a, b, other] = Enum.map([a, b, other], &Session.tick/1)
    Server.publish(c.server, "workspace")
    a = Session.tick(a)
    assert a.record["cursor"] == 1
    assert b.record["cursor"] == 0
    assert Server.consumer(c.server, "workspace", "two").cursor == 0
    assert Session.tick(other).record["cursor"] == 0
    assert Session.tick(b).record["cursor"] == 1
    assert Enum.uniq([a.path, b.path, other.path]) |> length() == 3
  end

  test "a blocker event refreshes dependent candidates before the sparse reconcile", c do
    parent = self()
    blocked = Map.put(issue(), "inverseRelations", %{"nodes" => [%{"type" => "blocks", "issue" => %{"id" => "blocker", "state" => %{"name" => "In Arbeit (AI)"}}}]})
    unblocked = put_in(blocked, ["inverseRelations", "nodes"], [%{"type" => "blocks", "issue" => %{"id" => "blocker", "state" => %{"name" => "Fertig"}}}])

    unrelated =
      issue()
      |> Map.put("id", "unrelated")
      |> Map.put("inverseRelations", %{"nodes" => [%{"type" => "relatesTo", "issue" => %{"id" => "blocker"}}, %{"type" => "blocks", "issue" => nil}]})

    {:ok, s} =
      open(c,
        snapshot: fn _ -> {:ok, [blocked, unrelated]} end,
        fetch: fn ids ->
          send(parent, {:refreshed, Enum.sort(ids)})
          {:ok, if("issue" in ids, do: [unblocked], else: [])}
        end
      )

    s = Session.tick(s)
    deadline = s.record["reconcile_at"]
    Server.publish(c.server, "workspace", %{"issueId" => "blocker"})
    s = Session.tick(s)
    assert_received {:refreshed, ["blocker", "issue"]}
    assert s.status == :ready
    assert s.record["issues"]["issue"] == unblocked
    assert s.record["issues"]["unrelated"] == unrelated
    assert s.record["reconcile_at"] == deadline
    assert {:ok, restarted} = open(c)
    assert restarted.record["issues"]["issue"] == unblocked
  end

  test "retention loss, server signals, receipt conflict and consumer expiry resnapshot conservatively", c do
    {:ok, s} = open(c)
    s = Session.tick(s)

    for {status, code} <- [{410, "resync_required"}, {409, "invalid_generation"}, {404, "not_found"}] do
      Server.fault(c.server, "workspace", "one", :poll, {:error, {:relay_http, status, code}})
      failed = Session.tick(s)
      assert failed.status == :resyncing
      assert Session.tick(failed) == failed
      recovered = Session.tick(retry(failed))
      assert recovered.status == :ready
    end

    Server.publish(c.server, "workspace", %{"type" => "RelayGap", "action" => "expired_input", "signal" => "resync_required", "broadcast" => true})
    recovered = Session.tick(%{s | registered: false})
    assert recovered.status == :ready
    assert recovered.record["generation"] != s.record["generation"]
    Server.forget(c.server, "workspace", "one")
    failed = Session.tick(recovered)
    assert failed.status == :resyncing
    assert Session.tick(retry(failed)).status == :ready
  end

  test "unknown envelopes and foreign workspaces remain unacked; auth and outage back off", c do
    {:ok, s} = open(c)
    s = Session.tick(s)

    for attrs <- [%{"version" => 2}, %{"workspaceId" => "foreign"}, %{"type" => "Unknown"}] do
      page = %{
        "version" => 1,
        "generation" => s.record["generation"],
        "events" => [Map.merge(Server.publish(c.server, "workspace"), attrs)],
        "receipt" => "receipt",
        "scannedThrough" => 3,
        "head" => 3,
        "retentionMs" => 1
      }

      Server.fault(c.server, "workspace", "one", :poll, {:ok, page})
      assert Session.tick(s).status == :upgrade_required
    end

    refute Enum.any?(Server.calls(c.server), &(elem(&1, 2) == :ack))

    for {reason, expected} <- [
          {{:relay_http, 401, "unauthorized"}, :access_error},
          {{:relay_http, 403, "unauthorized"}, :access_error},
          {{:relay_http, 503, "unavailable"}, :degraded},
          {:relay_upgrade_required, :upgrade_required}
        ] do
      Server.fault(c.server, "workspace", "one", :poll, {:error, reason})
      failed = Session.tick(s)
      assert failed.status == expected
      assert failed.retry_at > 30_000
      before = Server.calls(c.server)
      Session.tick(failed)
      assert Server.calls(c.server) == before
    end
  end

  test "removed issues disappear, unknown running IDs are queued, sparse reconcile advances comment epochs", c do
    {:ok, s} = open(c, fetch: fn _ -> {:ok, []} end)
    s = Session.tick(s)
    assert Session.watch(s, ["issue"]) == s
    watched = Session.watch(s, ["running"])
    assert watched.status == :catching_up
    assert "running" in watched.record["dirty"]
    assert Session.tick(watched).status == :ready
    Server.publish(c.server, "workspace", %{"action" => "remove"})
    removed = Session.tick(s)
    assert removed.record["issues"] == %{}
    Agent.update(c.clock, fn _ -> removed.record["reconcile_at"] end)
    assert Session.tick(removed).record["epochs"]["issue"] > removed.record["epochs"]["issue"]
    # Local state loss on an existing remote consumer demands begin + snapshot.
    File.rm!(s.path)
    {:ok, fresh} = open(c)
    assert Session.tick(fresh).record["generation"] != s.record["generation"]
  end

  test "corrupt cache and invalid subscription cannot bootstrap, binding changes require new snapshot", c do
    {:ok, s} = open(c)
    s = Session.tick(s)
    {:ok, changed} = open(c, binding: "changed")
    assert Session.tick(changed).record["generation"] != s.record["generation"]
    File.write!(s.path, "invalid")
    assert {:error, :relay_cache_corrupt} = open(c)
    assert {:error, :relay_requires_one_to_twenty_humans} = open(c, assignees: [])
    assert {:error, :relay_requires_one_to_twenty_humans} = open(c, assignees: Enum.map(1..21, &to_string/1))
    assert Store.path(c.config, "w", "a") != Store.path(c.config, "w", "b")
  end

  test "registration and bootstrap errors retain recovery state without releasing candidates", c do
    {:ok, s} = open(c)
    Server.fault(c.server, "workspace", "one", :register, {:error, :offline})
    assert Session.tick(s).error == :offline
    Server.fault(c.server, "workspace", "one", :register, {:ok, %{}})
    assert Session.tick(s).status == :upgrade_required

    failed = Session.tick(%{s | snapshot: fn _ -> {:error, :partial_snapshot} end})
    assert failed.record["phase"] == "snapshot"
    assert Session.tick(%{failed | snapshot: s.snapshot, retry_at: 0}).status == :ready
    {:ok, s} = open(c)
    s = Session.tick(s)
    assert Session.tick(%{s | record: Map.put(s.record, "phase", "register")}).status == :ready

    resync = %{s | record: Map.put(s.record, "phase", "resync")}
    Server.fault(c.server, "workspace", "one", :resync, {:error, :offline})
    assert Session.tick(resync).error == :offline
    Server.fault(c.server, "workspace", "one", :resync, {:ok, %{}})
    assert Session.tick(resync).status == :upgrade_required

    request = fn op, body ->
      if op == :resync and body["phase"] == "complete",
        do: {:ok, %{}},
        else: s.request.(op, body)
    end

    invalid = Session.tick(%{resync | request: request})
    assert invalid.status == :upgrade_required
    assert invalid.record["phase"] == "complete"
    assert Session.tick(%{invalid | request: s.request, retry_at: 0}).status == :ready
  end

  test "invalid ack and failed hydration preserve the durable dirty set; reconcile errors preserve issues", c do
    {:ok, s} = open(c)
    s = Session.tick(s)
    Server.publish(c.server, "workspace")
    Server.fault(c.server, "workspace", "one", :ack, {:ok, %{"version" => 1, "cursor" => 99}})
    invalid = Session.tick(s)
    assert invalid.status == :upgrade_required
    assert invalid.record["pending"] != nil
    failed = Session.tick(%{invalid | fetch: fn _ -> {:error, :partial_fetch} end, retry_at: 0})
    assert failed.record["pending"] == nil
    assert failed.record["dirty"] == ["issue"]
    assert failed.record["issues"] == s.record["issues"]
    recovered = Session.tick(%{failed | fetch: s.fetch, retry_at: 0})
    assert recovered.status == :ready
    Agent.update(c.clock, fn _ -> recovered.record["reconcile_at"] end)
    failed = Session.tick(%{recovered | snapshot: fn _ -> {:error, :incomplete_reconcile} end})
    assert failed.error == :incomplete_reconcile
    assert failed.record["issues"] == recovered.record["issues"]
  end

  test "explicit resync signals are accepted durably and reconfigure or watch failures remain blocked", c do
    {:ok, s} = open(c)
    s = Session.tick(s)
    Server.publish(c.server, "workspace", %{"type" => "RelayGap", "action" => "expired_input", "signal" => "resync_required"})
    resynced = Session.tick(s)
    assert resynced.status == :ready
    assert resynced.record["generation"] != s.record["generation"]
    assert Session.reconfigure(resynced, "binding") == resynced
    changed = Session.reconfigure(resynced, "new-binding")
    assert changed.status == :resyncing
    assert Session.tick(changed).status == :ready
    failed = %{resynced | persist: fn _, _ -> {:error, :disk_full} end}
    assert Session.reconfigure(failed, "new").error == :disk_full
    assert Session.watch(failed, ["new"]).error == :disk_full

    {:ok, wide} = open(c, consumer: "wide", assignees: [], workspace_wide: true)
    wide = Session.tick(wide)
    Server.publish(c.server, "workspace", %{"assigneeIds" => ["another-human"]})
    assert Session.tick(wide).record["cursor"] > wide.record["cursor"]
  end

  test "legacy issues without parseable timestamps can still be hydrated", c do
    {:ok, s} = open(c, snapshot: fn _ -> {:ok, [issue("legacy")]} end)
    s = Session.tick(s)
    Server.publish(c.server, "workspace")
    assert Session.tick(s).record["issues"]["issue"] == issue()
  end
end
