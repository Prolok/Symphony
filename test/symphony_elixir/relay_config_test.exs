defmodule SymphonyElixir.RelayConfigTest do
  use ExUnit.Case
  alias SymphonyElixir.{Config, EnvFile, ProjectContext, Relay}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Relay.Store

  setup do
    root = Path.join([File.cwd!(), "_build", "relay-config-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    old_access = System.get_env("SYMPHONY_LINEAR_SECRET_ACCESS")
    System.delete_env("SYMPHONY_LINEAR_SECRET_ACCESS")

    on_exit(fn ->
      File.rm_rf!(root)
      SymphonyElixir.TestSupport.restore_env("SYMPHONY_LINEAR_SECRET_ACCESS", old_access)
    end)

    relay = %{"endpoint" => "https://relay.test", "key_env" => "TEST_RELAY_KEY", "owners" => %{}, "state_root" => root, "reconcile_ms" => 300_000}
    {:ok, root: root, relay: relay}
  end

  test "config validates public bindings without a second routing source", %{relay: relay} do
    assert :ok = Relay.Config.validate(nil)
    assert :ok = Relay.Config.validate(relay)

    for {key, value, error} <- [
          {"endpoint", "http://relay.test", :invalid_relay_endpoint},
          {"key_env", "$SECRET", :invalid_relay_key_reference},
          {"consumer_id", "..", :invalid_relay_consumer_id},
          {"reconcile_ms", 5_000, :invalid_relay_reconcile_interval},
          {"state_root", "", :invalid_relay_state_root}
        ] do
      assert {:error, ^error} = Relay.Config.validate(Map.put(relay, key, value))
    end

    for owners <- [%{}, [], "invalid-json", %{"human" => "other"}] do
      assert :ok = Relay.Config.validate(Map.put(relay, "owners", owners))
    end
  end

  test "setup needs no owners", %{relay: relay} do
    assert :ok = Relay.Config.validate(Map.delete(relay, "owners"))
  end

  test "default poll interval is five seconds" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.polling.interval_ms == 5_000
  end

  test "owners and assignee ordering do not define consumer binding", %{relay: relay} do
    tracker = %Schema.Tracker{relay: relay, assignee: "a@example.com,b@example.com"}
    one = %ProjectContext{id: "project", settings: %Schema{tracker: tracker}}
    two = put_in(one.settings.tracker.assignee, " b@example.com, a@example.com ")
    two = put_in(two.settings.tracker.relay["owners"], %{"a" => "different"})
    assert Relay.binding_key([one]) == Relay.binding_key([two])
  end

  test "identity survives restart and rejects silently changing the configured executor", %{relay: relay} do
    assert {:error, :invalid_relay_consumer_id} = Store.identity(Map.put(relay, "consumer_id", ".."), "workspace")
    occupied = Path.join(relay["state_root"], "occupied")
    File.ln_s!("missing-target", occupied)
    assert {:error, :runtime_state_persist_failed} = Store.identity(Map.put(relay, "state_root", occupied), "workspace")
    assert {:ok, id} = Store.identity(relay, "workspace")
    assert {:ok, ^id} = Store.identity(relay, "workspace")
    assert {:ok, ^id} = Store.identity(Map.put(relay, "consumer_id", id), "workspace")
    assert {:error, :relay_identity_change_requires_handoff} = Store.identity(Map.put(relay, "consumer_id", "different"), "workspace")
    assert {:ok, different} = Store.identity(relay, "other-workspace")
    assert different != id
    path = Path.join(relay["state_root"], Store.digest("workspace") <> ".identity.json")
    File.write!(path, "broken")
    assert {:error, :relay_identity_unavailable} = Store.identity(relay, "workspace")
  end

  test "both direct and indirect key values are excluded before parsing public env", %{root: root} do
    File.write!(Path.join(root, ".env"), "KEY_SELECTOR=OLD_RELAY_KEY\nOLD_RELAY_KEY=old-secret\nLINEAR_RELAY_KEY=default-secret\nPUBLIC=value\n")
    File.write!(Path.join(root, ".env.local"), "KEY_SELECTOR=NEW_RELAY_KEY\nNEW_RELAY_KEY=new-secret\n")
    assert {:ok, values} = EnvFile.read_public(root, "LINEAR_APP_SECRET", "$KEY_SELECTOR")
    refute Map.has_key?(values, "OLD_RELAY_KEY")
    refute Map.has_key?(values, "NEW_RELAY_KEY")
    refute Map.has_key?(values, "LINEAR_RELAY_KEY")
    assert values["PUBLIC"] == "value"
    assert {:ok, "new-secret"} = Relay.Config.key(%{"key_env" => "NEW_RELAY_KEY"}, %{"env_dir" => root})
    File.write!(Path.join(root, ".env.local"), "NEW_RELAY_KEY=\n")
    assert {:error, :relay_key_unavailable} = Relay.Config.key(%{"key_env" => "NEW_RELAY_KEY"}, %{"env_dir" => root})
  end

  test "same workspace projects require identical relay config and identical shared keys", %{root: root, relay: relay} do
    File.write!(Path.join(root, ".env"), "TEST_RELAY_KEY=one\n")
    other = Path.join(root, "other")
    File.mkdir_p!(other)
    File.write!(Path.join(other, ".env"), "TEST_RELAY_KEY=one\n")
    contexts = Enum.map([root, other], fn dir -> %ProjectContext{settings: %Schema{tracker: %Schema.Tracker{relay: relay, app: %{"env_dir" => dir}}}} end)
    assert Relay.Config.shared(contexts) == :ok
    [first, second] = contexts
    assert Relay.Config.shared([first, put_in(second.settings.tracker.relay["owners"], "ignored-invalid-value")]) == :ok
    File.write!(Path.join(other, ".env"), "TEST_RELAY_KEY=two\n")
    assert {:error, :conflicting_workspace_relay_keys} = Relay.Config.shared(contexts)
    [one, two] = contexts
    assert {:error, :conflicting_workspace_relay_binding} = Relay.Config.shared([one, put_in(two.settings.tracker.relay["endpoint"], "https://other.test")])
    assert Relay.Config.shared([put_in(one.settings.tracker.relay, nil)]) == :ok
    File.write!(Path.join(other, ".env"), "TEST_RELAY_KEY=\n")
    assert {:error, :relay_key_unavailable} = Relay.Config.shared(contexts)
  end

  test "schema resolves relay references without copying keys and rebinds only after restart", %{relay: relay} do
    context = %ProjectContext{env: %{"RELAY_URL" => "https://relay.test", "RELAY_OWNERS" => ~s({"human":"one"})}}

    ProjectContext.with_context(context, fn ->
      assert {:ok, settings} = Schema.parse(%{"tracker" => %{"relay" => %{relay | "endpoint" => "$RELAY_URL", "owners" => "$RELAY_OWNERS"}}})
      assert settings.tracker.relay["endpoint"] == "https://relay.test"
      refute Map.has_key?(settings.tracker.relay, "owners")
    end)

    assert is_binary(Config.relay_state_root())
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"relay" => %{"owners" => "broken"}}})
    refute Map.has_key?(settings.tracker.relay, "owners")
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"relay" => %{"owners" => []}}})
    refute Map.has_key?(settings.tracker.relay, "owners")
    assert {:error, :invalid_relay_endpoint} = Relay.Config.shared([%ProjectContext{settings: %Schema{tracker: %Schema.Tracker{relay: %{relay | "endpoint" => nil}}}}])
  end

  test "a project env file cannot replace the trusted relay secret reference", %{root: root} do
    names = ~w(SYMPHONY_LINEAR_AUTH_MODE SYMPHONY_RELAY_KEY_ENV)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {key, value} -> SymphonyElixir.TestSupport.restore_env(key, value) end) end)
    System.put_env("SYMPHONY_LINEAR_AUTH_MODE", "app")
    System.put_env("SYMPHONY_RELAY_KEY_ENV", "TRUSTED_RELAY_KEY")
    File.write!(Path.join(root, ".env.local"), "SYMPHONY_RELAY_KEY_ENV=UNTRUSTED_KEY\n")
    assert {:error, :linear_runtime_binding_changed} = EnvFile.load_runtime(root)
    assert System.get_env("SYMPHONY_RELAY_KEY_ENV") == "TRUSTED_RELAY_KEY"
  end
end
