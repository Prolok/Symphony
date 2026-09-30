defmodule SymphonyElixir.OpenClawConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext

  test "lifecycle binding falls back to the public project JSON value" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    encoded = Jason.encode!(bridge_config())
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\nOPENCLAW_LINEAR_BRIDGE='#{encoded}'\nSYMPHONY_LINEAR_BRIDGE_CUSTOM=\"not-public-even-if-malformed\n")
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert context.settings.tracker.openclaw_linear_bridge == bridge_config()
    assert context.env["OPENCLAW_LINEAR_BRIDGE"] == encoded
    refute Map.has_key?(context.env, "SYMPHONY_LINEAR_BRIDGE_CUSTOM")
  end

  defp bridge_config do
    %{"producer_id" => "symphony-example", "consumer_account_id" => "account-example", "key_id" => "example-key"}
  end

  test "project bridge fallback respects local overrides, central precedence and isolated environment" do
    {root, workflow} = bridge_project()
    write_bridge_env(root, Jason.encode!(bridge_config()))
    local = Map.put(bridge_config(), "consumer_account_id", "local-account")
    File.write!(Path.join(root, ".symphony/.env.local"), "OPENCLAW_LINEAR_BRIDGE='#{Jason.encode!(local)}'\n")

    for central <- [nil, "null"] do
      write_central_bridge(workflow, central)
      assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert context.settings.tracker.openclaw_linear_bridge == local
    end

    central = Map.put(bridge_config(), "producer_id", "central-producer")
    write_central_bridge(workflow, Jason.encode!(central))
    File.write!(Path.join(root, ".symphony/.env.local"), "OPENCLAW_LINEAR_BRIDGE='invalid-unused-fallback'\n")
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert context.settings.tracker.openclaw_linear_bridge == central

    File.rm!(Path.join(root, ".symphony/.env.local"))

    for invalid <- ["false", "[]", Jason.encode!(%{"producer_id" => "incomplete"})] do
      write_central_bridge(workflow, invalid)
      assert {:error, {:invalid_workflow_config, message}} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert message =~ "openclaw_linear_bridge"
    end

    write_central_bridge(workflow, nil)
    write_bridge_env(root, nil)
    previous = System.get_env("OPENCLAW_LINEAR_BRIDGE")
    System.put_env("OPENCLAW_LINEAR_BRIDGE", Jason.encode!(central))
    on_exit(fn -> restore_env("OPENCLAW_LINEAR_BRIDGE", previous) end)
    assert {:ok, inactive} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert inactive.settings.tracker.openclaw_linear_bridge == nil
    refute Map.has_key?(inactive.env, "OPENCLAW_LINEAR_BRIDGE")
  end

  test "invalid public bridge values reject the project and reload without leaking raw values" do
    {root, _workflow} = bridge_project()
    write_bridge_env(root, Jason.encode!(bridge_config()))
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})

    invalid_bindings =
      [Map.delete(bridge_config(), "key_id"), %{}] ++
        for {field, values} <- [
              {"producer_id", ["bad slug", nil]},
              {"consumer_account_id", [String.duplicate("a", 129), 12]},
              {"key_id", ["bad\nkey", ""]},
              {"secret_env", ["LINEAR_APP_SECRET", 12, "SYMPHONY_LINEAR_BRIDGE_"]},
              {"gateway_port", [0, -1, 65_536, 19_892.0, nil, true, "19892", "$PORT"]},
              {"inline_key", ["synthetic-private-detail"]}
            ],
            value <- values,
            do: Map.put(bridge_config(), field, value)

    invalid_values = ["", "{synthetic-private-detail", "null", "true", "12", "[]", "\"synthetic-private-detail\""] ++ Enum.map(invalid_bindings, &Jason.encode!/1)

    for value <- invalid_values do
      write_bridge_env(root, value)
      assert {:error, {:invalid_workflow_config, message}} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert message =~ "openclaw_linear_bridge"
      refute message =~ "synthetic-private-detail"
      logs = capture_log(fn -> assert ProjectContext.refresh(context) == context end)
      assert logs =~ "project_root=#{context.root}"
      assert logs =~ "invalid_workflow_config"
      assert logs =~ "openclaw_linear_bridge"
      refute logs =~ "synthetic-private-detail"
    end

    for port <- [1, 18_789, 65_535] do
      valid = Map.put(bridge_config(), "gateway_port", port)
      write_bridge_env(root, Jason.encode!(valid))
      assert {:ok, restarted} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert restarted.settings.tracker.openclaw_linear_bridge == valid
    end
  end

  test "every project bridge binding change requires restart and preserves exported runtime binding" do
    {root, _workflow} = bridge_project()
    write_bridge_env(root, nil)
    assert {:ok, inactive} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    write_bridge_env(root, Jason.encode!(bridge_config()))
    assert {:ok, active} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert_restart_required(inactive)
    active_env = ProjectContext.with_context(active, &Config.linear_runtime_env/0)
    inactive_env = ProjectContext.with_context(inactive, &Config.linear_runtime_env/0)
    refute active_env["SYMPHONY_LINEAR_BINDING_HASH"] == inactive_env["SYMPHONY_LINEAR_BINDING_HASH"]

    changes =
      [nil] ++
        for {key, value} <- [
              {"producer_id", "other-producer"},
              {"consumer_account_id", "other-account"},
              {"key_id", "other-key"},
              {"gateway_port", 19_892},
              {"secret_env", "SYMPHONY_LINEAR_BRIDGE_OTHER"}
            ],
            do: Map.put(bridge_config(), key, value)

    for changed <- changes do
      write_bridge_env(root, if(changed, do: Jason.encode!(changed)))
      assert_restart_required(active)
      assert {:ok, restarted} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert restarted.settings.tracker.openclaw_linear_bridge == changed
      runtime = ProjectContext.with_context(restarted, &Config.linear_runtime_env/0)
      refute runtime["SYMPHONY_LINEAR_BINDING_HASH"] == active_env["SYMPHONY_LINEAR_BINDING_HASH"]
    end

    System.put_env("SYMPHONY_WORKFLOW_FILE", active.workflow_path)

    ProjectContext.with_context(nil, fn ->
      assert :ok = ProjectContext.restore(active_env["SYMPHONY_PROJECT_CONTEXT"], Path.join(root, ".symphony"))
      assert Config.openclaw_linear_bridge() == bridge_config()
      assert Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"] == active_env["SYMPHONY_LINEAR_BINDING_HASH"]
    end)

    System.put_env("SYMPHONY_LINEAR_AUTH_MODE", "app")
    System.put_env("SYMPHONY_LINEAR_BINDING_HASH", active_env["SYMPHONY_LINEAR_BINDING_HASH"])
    unresolved = %{inactive | settings: nil}
    assert {:error, :linear_runtime_binding_changed} = ProjectContext.with_context(unresolved, &Config.settings/0)
    assert {:ok, _} = ProjectContext.with_context(%{active | settings: nil}, &Config.settings/0)
  end

  defp bridge_project do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    {root, File.read!(Workflow.workflow_file_path())}
  end

  defp write_bridge_env(root, value) do
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n" <> if(value, do: "OPENCLAW_LINEAR_BRIDGE='#{value}'\n", else: ""))
  end

  defp write_central_bridge(workflow, value) do
    File.write!(Workflow.workflow_file_path(), if(value, do: String.replace(workflow, "tracker:\n", "tracker:\n  openclaw_linear_bridge: #{value}\n"), else: workflow))
  end

  defp assert_restart_required(context) do
    logs = capture_log(fn -> assert ProjectContext.refresh(context) == context end)
    assert logs =~ "project_root=#{context.root}"
    assert logs =~ "project_binding_change_requires_restart"
  end

  test "OpenClaw selection is project local, trimmed and requires a Linear YOLO binding" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    env = Path.join(root, ".symphony/.env")

    for value <- [nil, "", "   ", "  product-owner  "] do
      File.write!(env, "LINEAR_ASSIGNEE=human@example.com\nLINEAR_YOLO_AGENT=Pai\n" <> if(value, do: "OPENCLAW_YOLO_AGENT=#{value}\n", else: ""))
      assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})

      ProjectContext.with_context(context, fn ->
        assert Config.openclaw_yolo_agent() == if(value == "  product-owner  ", do: "product-owner", else: nil)
      end)
    end

    File.write!(env, "LINEAR_ASSIGNEE=human@example.com\nOPENCLAW_YOLO_AGENT=product-owner\n")
    assert {:error, :openclaw_requires_linear_yolo_agent} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
  end

  test "optional lifecycle binding is validated, strips private names and requires restart on change" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    workflow = File.read!(Workflow.workflow_file_path())
    bridge = "  openclaw_linear_bridge:\n    producer_id: symphony-example\n    consumer_account_id: account-example\n    key_id: example-key\n    secret_env: SYMPHONY_LINEAR_BRIDGE_CUSTOM\n"
    File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> bridge))
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\nSYMPHONY_LINEAR_BRIDGE_CUSTOM=\"not-public-even-if-malformed\n")
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert context.settings.tracker.openclaw_linear_bridge["producer_id"] == "symphony-example"
    refute Map.has_key?(context.env, "SYMPHONY_LINEAR_BRIDGE_CUSTOM")
    File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> String.replace(bridge, "account-example", "other-account")))
    assert ProjectContext.refresh(context) == context
    assert {:ok, other} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert other.settings.tracker.openclaw_linear_bridge["consumer_account_id"] == "other-account"
    File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> String.replace(bridge, "SYMPHONY_LINEAR_BRIDGE_CUSTOM", "LINEAR_APP_SECRET")))
    assert {:error, _} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
  end

  test "lifecycle gateway port is an optional integer and changes require restart" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    workflow = File.read!(Workflow.workflow_file_path())
    bridge = "  openclaw_linear_bridge:\n    producer_id: symphony-example\n    consumer_account_id: account-example\n    key_id: example-key\n    gateway_port: 19892\n"
    File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> bridge))
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    assert context.settings.tracker.openclaw_linear_bridge["gateway_port"] == 19_892

    for port <- ["1", "18789", "65535"] do
      changed = String.replace(bridge, "19892", port)
      File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> changed))
      assert ProjectContext.refresh(context) == context
      assert {:ok, restarted} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert restarted.settings.tracker.openclaw_linear_bridge["gateway_port"] == String.to_integer(port)
    end

    for port <- ["0", "-1", "65536", "19892.0", "null", "true", "\"19892\"", "ws://remote:19892", "$PORT"] do
      changed = String.replace(bridge, "19892", port)
      File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> changed))
      assert {:error, _} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
      assert ProjectContext.refresh(context) == context
    end

    for field <- ~w(gateway_url gateway_host gateway_token) do
      changed = bridge <> "    #{field}: forbidden\n"
      File.write!(Workflow.workflow_file_path(), String.replace(workflow, "tracker:\n", "tracker:\n" <> changed))
      assert {:error, _} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    end
  end

  test "projects retain independent selections across export, restore and rejected reload" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    env = Path.join(root, ".symphony/.env")
    base = "LINEAR_ASSIGNEE=human@example.com\nLINEAR_YOLO_AGENT=Pai\n"
    File.write!(env, base <> "OPENCLAW_YOLO_AGENT=po\n")
    assert {:ok, active} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    active = %{active | yolo_agent_id: "pai", human_handoff_id: "human", assignee_ids: ["human"]}
    File.write!(env, base)
    assert {:ok, inactive} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    inactive = %{inactive | id: root <> "/other"}
    ProjectContext.with_context(inactive, fn -> assert Config.openclaw_yolo_agent() == nil end)
    ProjectContext.with_context(active, fn -> assert Config.openclaw_yolo_agent() == "po" end)

    for contents <- [base, base <> "OPENCLAW_YOLO_AGENT=other\n", "OPENCLAW_YOLO_AGENT=po\n"] do
      File.write!(env, contents)
      assert ProjectContext.refresh(active) == active
    end

    System.put_env("SYMPHONY_WORKFLOW_FILE", active.workflow_path)

    ProjectContext.with_context(active, fn ->
      encoded = ProjectContext.runtime_env()["SYMPHONY_PROJECT_CONTEXT"]
      ProjectContext.bind(nil)
      assert :ok = ProjectContext.restore(encoded, Path.join(root, ".symphony"))
      assert Config.openclaw_yolo_agent() == "po"
      assert Config.yolo_agent_id() == "pai"
    end)

    File.write!(env, base <> "OPENCLAW_YOLO_AGENT=Other:Agent\n")
    assert {:error, :invalid_openclaw_agent_id} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
  end
end
