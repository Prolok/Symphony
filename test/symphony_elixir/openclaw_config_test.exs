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
