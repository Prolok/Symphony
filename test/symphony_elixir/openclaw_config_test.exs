defmodule SymphonyElixir.OpenClawConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.ProjectContext

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
