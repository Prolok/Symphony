defmodule SymphonyElixir.OpenClawLinearBridgeTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.{Config, EnvFile, ProjectContext}
  alias SymphonyElixir.Linear.DurableState
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.{Journal, LinearBridge}
  alias SymphonyElixir.Yolo.OpenClaw.LinearBridge.{Delivery, Projection}

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    context = put_in(context.settings.tracker.openclaw_linear_bridge, config())
    context = put_in(context.settings.tracker.openclaw_yolo_agent, "po")
    ProjectContext.bind(context)
    %{context: context, root: root}
  end

  defp config, do: %{"producer_id" => "symphony-example", "consumer_account_id" => "account-example", "key_id" => "producer-key-example"}
  defp fixture(name), do: File.read!("test/fixtures/openclaw/linear_bridge/#{name}.json") |> Jason.decode!()

  defp order(name \\ "incoming") do
    payload = fixture(name)
    b = payload["binding"]

    %{
      "id" => b["order_id"],
      "group" => b["group"],
      "project_id" => b["project_id"],
      "agent" => b["openclaw_agent_id"],
      "linear_workspace_id" => b["linear_workspace_id"],
      "linear_agent_id" => b["linear_agent_id"],
      "workspace" => b["workspace"],
      "sha" => b["source_sha"],
      "payload_sha256" => b["payload_sha256"],
      "session_id" => b["native"]["sessionKey"],
      "state" => "intent",
      "writable" => true,
      "members" => Enum.with_index(b["issue_ids"], fn id, i -> %{"id" => id, "identifier" => "EX-#{i}", "state" => "Backlog"} end)
    }
  end

  defp options(transport, time \\ 0), do: [transport: transport, bridge_key: fn _ -> {:ok, :binary.copy(<<42>>, 32)} end, bridge_now: fn _ -> time end]

  defp ack(wire, disposition \\ "stored") do
    raw = Base.decode64!(wire["payload_b64"])
    payload = Jason.decode!(raw)

    %{
      "version" => 1,
      "producer_id" => payload["producer_id"],
      "consumer_account_id" => payload["consumer_account_id"],
      "order_id" => payload["binding"]["order_id"],
      "sequence" => payload["sequence"],
      "payload_sha256" => OpenClaw.digest(raw),
      "disposition" => disposition
    }
  end

  defp transport(callback) do
    fn ["gateway", "call", "linearbridge.symphony.lifecycle.v1", "--params", raw, "--json", "--timeout", "10000", "--port", "18789"] ->
      wire = Jason.decode!(raw)
      callback.(wire)
    end
  end

  test "disabled bridge never reads a key or invokes transport, including legacy journals", %{context: context} do
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_linear_bridge, nil))
    assert :ok = Journal.write(order())
    assert {:ok, current} = Journal.read("incoming")
    refute Map.has_key?(current, "linear_bridge")
    deny = fn _ -> flunk("disabled bridge I/O") end
    assert :ok = Delivery.flush(transport: deny, bridge_key: deny)
    ProjectContext.bind(context)
    assert {:ok, _} = Journal.update(current, %{"acceptance_observed" => true})
    assert :ok = Delivery.flush(transport: deny, bridge_key: deny)
  end

  test "atomic snapshots preserve all members, original binding and monotone evidence" do
    assert :ok = Journal.write(order("review"))
    assert {:ok, initial} = Journal.read("review")
    assert length(initial["linear_bridge"]["snapshots"]) == 1
    assert {:ok, accepted} = Journal.update(initial, %{"state" => "accepted", "acceptance_observed" => true})
    assert {:ok, current} = Journal.update(initial, %{"state" => "unknown", "writable" => false, "acceptance_observed" => false})
    snapshots = current["linear_bridge"]["snapshots"]
    assert Enum.map(snapshots, & &1["sequence"]) == [1, 2, 3]
    assert Enum.all?(snapshots, &(length(&1["projection"]["binding"]["issue_ids"]) == 2))
    assert List.last(snapshots)["projection"]["observation"]["acceptance_observed"]
    assert snapshots |> Enum.map(& &1["projection"]["binding"]) |> Enum.uniq() |> length() == 1
    assert {:error, :openclaw_immutable_order} = Journal.update(accepted, %{"members" => []})
    assert {:error, :openclaw_immutable_order} = Journal.update(accepted, %{"linear_bridge" => %{}})
    assert {:ok, unchanged} = Journal.update(current, %{"error" => "another transport timeout"})
    assert unchanged["linear_bridge"] == current["linear_bridge"]
  end

  test "lost reply replays exact bytes after restart without execution; late ack cannot finish a newer snapshot", %{context: context} do
    assert :ok = Journal.write(order())
    parent = self()

    lost =
      transport(fn wire ->
        send(parent, {:lost, wire})
        {:error, :openclaw_transport_timeout}
      end)

    assert :ok = Delivery.flush(options(lost))
    assert_received {:lost, original}
    assert {:ok, initial} = Journal.read("incoming")
    assert {:ok, accepted} = Journal.update(initial, %{"state" => "accepted", "acceptance_observed" => true})
    # New process with the restored project sees the durable attempt and cooldown.
    deny = transport(fn _ -> flunk("retry before cooldown") end)
    task = Task.async(fn -> ProjectContext.with_context(context, fn -> Delivery.flush(options(deny, 29_999)) end) end)
    assert :ok = Task.await(task)

    duplicate =
      transport(fn wire ->
        assert wire == original
        {:ok, Jason.encode!(ack(wire, "duplicate"))}
      end)

    task = Task.async(fn -> ProjectContext.with_context(context, fn -> Delivery.flush(options(duplicate, 30_000)) end) end)
    assert :ok = Task.await(task)
    assert {:ok, receipt} = DurableState.read(Delivery.receipt_path(initial))
    assert receipt["ack_sequence"] == 1
    assert {:ok, ^accepted} = Journal.read("incoming")

    stored =
      transport(fn wire ->
        assert Jason.decode!(Base.decode64!(wire["payload_b64"]))["sequence"] == 2
        {:ok, Jason.encode!(ack(wire))}
      end)

    assert :ok = Delivery.flush(options(stored, 30_000))
    assert {:ok, %{"ack_sequence" => 2}} = DurableState.read(Delivery.receipt_path(initial))
  end

  test "new snapshot written during RPC and terminal archive stay independent from acknowledgement" do
    assert :ok = Journal.write(order())
    assert {:ok, original} = Journal.read("incoming")

    transport =
      transport(fn wire ->
        assert {:ok, finished} = Journal.update(original, %{"state" => "completed", "writable" => false, "terminal" => %{"runId" => original["id"], "status" => "ok", "endedAt" => 2}})
        assert {:ok, ^finished} = Journal.update(original, %{"state" => "running"})
        replacement = order() |> Map.put("id", "cccccccc-cccc-4ccc-8ccc-cccccccccccc") |> Map.update!("session_id", &String.replace(&1, original["id"], "cccccccc-cccc-4ccc-8ccc-cccccccccccc"))
        assert :ok = Journal.write(replacement)
        {:ok, Jason.encode!(ack(wire))}
      end)

    assert :ok = Delivery.flush(options(transport))
    assert {:ok, archived} = Journal.history("incoming", original["id"])
    assert length(archived["linear_bridge"]["snapshots"]) == 2
    parent = self()

    final =
      transport(fn wire ->
        send(parent, {:delivered, Jason.decode!(Base.decode64!(wire["payload_b64"]))})
        {:ok, Jason.encode!(ack(wire))}
      end)

    assert :ok = Delivery.flush(options(final))
    assert_received {:delivered, %{"binding" => %{"order_id" => "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}, "observation" => %{"state" => "completed"}}}
    assert_received {:delivered, %{"binding" => %{"order_id" => "cccccccc-cccc-4ccc-8ccc-cccccccccccc"}, "observation" => %{"state" => "intent"}}}
    assert {:ok, ^archived} = Journal.history("incoming", original["id"])
  end

  test "every mismatched echo, member binding hash, foreign or old generation and unknown field leaves delivery open" do
    assert :ok = Journal.write(order("review"))
    assert {:ok, current} = Journal.read("review")
    snapshot = hd(current["linear_bridge"]["snapshots"])
    wire = %{"payload_b64" => snapshot["payload_b64"]}
    reply = ack(wire)

    for key <- Map.keys(reply), value <- [nil, "foreign", 0] do
      assert {:error, :openclaw_bridge_ack_mismatch} = LinearBridge.acknowledge(Map.put(reply, key, value), current, snapshot)
    end

    assert {:error, :openclaw_bridge_ack_mismatch} = LinearBridge.acknowledge(Map.put(reply, "extra", true), current, snapshot)
    for disposition <- ~w(stored duplicate stale), do: assert(:ok == LinearBridge.acknowledge(Map.put(reply, "disposition", disposition), current, snapshot))
    bad = transport(fn wire -> {:ok, Jason.encode!(Map.put(ack(wire), "payload_sha256", String.duplicate("0", 64)))} end)
    assert :ok = Delivery.flush(options(bad))
    assert {:ok, %{"ack_sequence" => 0}} = DurableState.read(Delivery.receipt_path(current))
  end

  test "a changed recipient or key cannot reroute an original outbox", %{context: context} do
    assert :ok = Journal.write(order())
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_linear_bridge["consumer_account_id"], "foreign"))
    deny = fn _ -> flunk("must preserve original account") end
    assert :ok = Delivery.flush(transport: deny, bridge_key: deny)
    assert {:ok, current} = Journal.read("incoming")
    assert {:ok, %{"ack_sequence" => 0}} = DurableState.read(Delivery.receipt_path(current))
  end

  test "unknown and abort acknowledgement have no terminal evidence; rejection and operator originals are projected" do
    uncertain = Map.merge(order(), %{"state" => "unknown", "cancel_requested" => true, "abort_acknowledged" => true})
    assert {:ok, payload} = Projection.payload(uncertain, config(), 1)
    assert payload["observation"]["terminal"] == nil
    refute payload["observation"]["acceptance_observed"]
    refute payload["observation"]["execution_observed"]
    proof = %{"method" => "agent", "phase" => "pre_acceptance", "code" => "INVALID_REQUEST", "reason" => "cwd_reserved", "request_sha256" => String.duplicate("f", 64)}
    proof = Map.merge(proof, Map.take(uncertain, ~w(id agent session_id payload_sha256)))
    rejected = Map.merge(uncertain, %{"state" => "rejected", "rejection" => proof})
    assert {:ok, payload} = Projection.payload(rejected, config(), 2)
    assert payload["observation"]["rejection"] == Map.put(proof, "kind", "gateway")
    recovery = Map.new(~w(source_sha256 execution_source_sha256 evidence_sha256), &{&1, String.duplicate("1", 64)})
    recovery = Map.put(recovery, "kind", "terminal_original")
    terminal = %{"runId" => uncertain["id"], "status" => "killed", "state" => "cancelled", "startedAt" => 1, "endedAt" => 2, "messageId" => "private-extra"}
    assert {:ok, payload} = Projection.payload(Map.merge(uncertain, %{"terminal" => terminal, "recovery" => recovery}), config(), 3)
    assert payload["observation"]["terminal"]["kind"] == "operator_terminal_original"
    refute Map.has_key?(payload["observation"]["terminal"], "messageId")

    retirement = %{
      "kind" => "fenced_interruption",
      "stop_basis" => "abort_acknowledged",
      "retired_at" => "2026-09-23T12:00:00Z",
      "history_sha256" => String.duplicate("f", 64),
      "physical_session_id" => "physical",
      "last_run_id" => "native-followup",
      "session_end" => %{"lastRunId" => "native-followup", "status" => "killed", "startedAt" => 1, "endedAt" => 2},
      "retained_inputs" => ["private"]
    }

    assert {:ok, payload} = Projection.payload(Map.merge(uncertain, %{"state" => "retired", "retirement" => retirement}), config(), 4)
    assert payload["observation"]["retirement"] == Map.delete(retirement, "retained_inputs")
  end

  test "invalid or incomplete journal membership is never silently normalized" do
    original = order("review")

    for changed <- [
          Map.put(original, "members", []),
          Map.update!(original, "members", &(&1 ++ &1)),
          Map.put(original, "linear_workspace_id", "not-uuid"),
          Map.put(original, "session_id", "other-generation")
        ] do
      assert {:error, :openclaw_bridge_binding_invalid} = Projection.payload(changed, config(), 1)
    end
  end

  test "failed receipt persistence before send never invokes the consumer" do
    assert :ok = Journal.write(order())
    assert {:ok, current} = Journal.read("incoming")
    File.mkdir_p!(Delivery.receipt_path(current))
    deny = fn _ -> flunk("corrupt receipt cannot authorize sending") end
    assert :ok = Delivery.flush(transport: deny, bridge_key: deny)
    assert {:ok, ^current} = Journal.read("incoming")
  end

  test "lost receipt write after consumer acceptance replays the same bytes" do
    assert :ok = Journal.write(order())
    assert {:ok, current} = Journal.read("incoming")
    path = Delivery.receipt_path(current)
    parent = self()

    accepted =
      transport(fn wire ->
        send(parent, {:accepted_before_crash, wire})
        File.rm!(path)
        File.mkdir!(path)
        {:ok, Jason.encode!(ack(wire))}
      end)

    assert :ok = Delivery.flush(options(accepted))
    assert_received {:accepted_before_crash, original}
    File.rmdir!(path)

    retried =
      transport(fn wire ->
        assert wire == original
        {:ok, Jason.encode!(ack(wire, "duplicate"))}
      end)

    assert :ok = Delivery.flush(options(retried, 30_000))
    assert {:ok, %{"ack_sequence" => 1}} = DurableState.read(path)
    assert {:ok, ^current} = Journal.read("incoming")
  end

  test "OpenClaw disable keeps an existing bridge outbox pending without I/O", %{context: context} do
    assert :ok = Journal.write(order())
    ProjectContext.bind(put_in(context.settings.tracker.openclaw_yolo_agent, nil))
    deny = fn _ -> flunk("OpenClaw disabled") end
    assert :ok = Delivery.flush(transport: deny, bridge_key: deny)
    assert :ok = Delivery.tick(transport: deny, bridge_key: deny)
  end

  test "trusted key access rejects denial, malformed Base64 and short keys", %{root: root} do
    name = "SYMPHONY_LINEAR_BRIDGE_KEY"
    previous = System.get_env("SYMPHONY_LINEAR_SECRET_ACCESS")
    on_exit(fn -> if previous, do: System.put_env("SYMPHONY_LINEAR_SECRET_ACCESS", previous), else: System.delete_env("SYMPHONY_LINEAR_SECRET_ACCESS") end)
    System.delete_env("SYMPHONY_LINEAR_SECRET_ACCESS")
    path = Path.join(root, ".symphony/.env.local")

    for encoded <- ["not-base64", Base.encode64("short")] do
      File.write!(path, name <> "=" <> encoded <> "\n")
      assert {:error, :openclaw_bridge_key_unavailable} = Config.openclaw_bridge_key(config())
    end

    key = :binary.copy(<<42>>, 32)
    File.write!(path, name <> "=" <> Base.encode64(key) <> "\n")
    assert {:ok, ^key} = Config.openclaw_bridge_key(config())
    System.put_env("SYMPHONY_LINEAR_SECRET_ACCESS", "denied")
    assert {:error, :openclaw_bridge_key_unavailable} = Config.openclaw_bridge_key(config())
  end

  test "concurrent delivery is fenced independently of execution journal updates", %{context: context} do
    assert :ok = Journal.write(order())
    parent = self()

    blocking =
      transport(fn wire ->
        send(parent, {:in_bridge_rpc, self()})

        receive do
          :finish_bridge_rpc -> {:ok, Jason.encode!(ack(wire))}
        after
          5_000 -> flunk("test consumer timed out")
        end
      end)

    task = Task.async(fn -> ProjectContext.with_context(context, fn -> Delivery.flush(options(blocking)) end) end)
    assert_receive {:in_bridge_rpc, sender}, 2_000
    assert {:error, :issue_already_owned} = Delivery.flush(options(blocking))
    assert {:ok, current} = Journal.read("incoming")
    assert {:ok, _} = Journal.update(current, %{"state" => "accepted", "acceptance_observed" => true})
    send(sender, :finish_bridge_rpc)
    assert :ok = Task.await(task)
    refute_received {:in_bridge_rpc, _}
    assert {:ok, %{"ack_sequence" => 1}} = DurableState.read(Delivery.receipt_path(current))
  end

  test "public configuration and all child environments exclude bridge secrets", %{root: root} do
    name = "SYMPHONY_LINEAR_BRIDGE_CUSTOM"
    File.write!(Path.join(root, ".symphony/.env"), name <> "=synthetic-key\nSYMPHONY_LINEAR_BRIDGE_KEY=synthetic-default\nPUBLIC=yes\n")
    assert {:ok, public} = EnvFile.read_public(Path.join(root, ".symphony"))
    assert public == %{"PUBLIC" => "yes"}
    previous = System.get_env(name)
    System.put_env(name, "synthetic-key")
    on_exit(fn -> if previous, do: System.put_env(name, previous), else: System.delete_env(name) end)
    assert {^name, nil} = List.keyfind(Config.without_linear_secret([]), name, 0)
    assert LinearBridge.valid_config?(config())
    refute LinearBridge.valid_config?(Map.put(config(), "secret_env", "LINEAR_APP_SECRET"))
    refute LinearBridge.valid_config?(Map.put(config(), "secret_env", 12))
    refute LinearBridge.valid_config?(Map.put(config(), "key_id", "line\nbreak"))
    refute LinearBridge.valid_config?(Map.put(config(), "key", "inline-secret"))
  end

  test "wire message authenticates the exact full journal projection" do
    payload = File.read!("test/fixtures/openclaw/linear_bridge/incoming.json") |> Jason.decode!()
    raw = Jason.encode!(payload)
    key = :binary.copy(<<42>>, 32)
    assert {:ok, wire} = LinearBridge.sign(raw, "producer-key-example", key)
    assert wire["version"] == 1
    assert Base.decode64!(wire["payload_b64"]) == raw
    assert wire["mac"] == Base.encode16(:crypto.mac(:hmac, :sha256, key, "linearbridge.symphony.lifecycle.v1\nproducer-key-example\n" <> wire["payload_b64"]), case: :lower)
  end
end
