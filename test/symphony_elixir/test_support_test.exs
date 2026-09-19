defmodule SymphonyElixir.TestSupportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport

  test "fixture isolation clears inherited Linear agent selection and restores set and unset values" do
    previous_agent = System.get_env("LINEAR_YOLO_AGENT")
    on_exit(fn -> restore_env("LINEAR_YOLO_AGENT", previous_agent) end)

    for inherited_agent <- ["synthetic-inherited-agent", nil] do
      restore_env("LINEAR_YOLO_AGENT", inherited_agent)
      snapshot = TestSupport.scrub_symphony_runtime_env()

      try do
        assert System.get_env("LINEAR_YOLO_AGENT") == nil
        assert Config.yolo_agent_name() == nil

        System.put_env("LINEAR_YOLO_AGENT", "synthetic-explicit-agent")
        assert Config.yolo_agent_name() == "synthetic-explicit-agent"
      after
        TestSupport.restore_env_snapshot(snapshot)
      end

      assert System.get_env("LINEAR_YOLO_AGENT") == inherited_agent
    end
  end
end
