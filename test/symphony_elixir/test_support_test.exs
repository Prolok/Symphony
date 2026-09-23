defmodule SymphonyElixir.TestSupportTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport

  test "fixture isolation clears and restores inherited OpenClaw notification sessions" do
    key = "OPENCLAW_YOLO_NOTIFY_SESSION"
    previous = System.get_env(key)
    on_exit(fn -> restore_env(key, previous) end)

    for inherited <- ["agent:synthetic:main", nil] do
      restore_env(key, inherited)
      snapshot = TestSupport.scrub_symphony_runtime_env()

      try do
        assert System.get_env(key) == nil
        System.put_env(key, "agent:fixture:main")
      after
        TestSupport.restore_env_snapshot(snapshot)
      end

      assert System.get_env(key) == inherited
    end
  end

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

  @tag tmp_dir: true
  test "independent BEAM fixtures cannot adopt or clean each other's workflow roots", %{tmp_dir: tmp_dir} do
    first = start_fixture(tmp_dir)

    try do
      first_root = fixture_root(first)
      marker = Path.join(first_root, "owner")
      owner = File.read!(marker)
      second = start_fixture(tmp_dir)

      try do
        second_root = fixture_root(second)
        refute first_root == second_root
        assert File.read!(marker) == owner
        stop_fixture(second)
        refute File.exists?(second_root)
        assert File.read!(marker) == owner
        stop_fixture(first)
        refute File.exists?(first_root)
      after
        close_fixture(second)
      end
    after
      close_fixture(first)
    end
  end

  defp start_fixture(tmp_dir) do
    support = Path.expand("../support/test_support.exs", __DIR__)
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    script = """
    root = SymphonyElixir.TestSupport.workflow_root!()
    File.write!(Path.join(root, "owner"), System.pid())
    IO.puts(root)
    IO.read(:line)
    File.rm_rf!(root)
    """

    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary,
      :exit_status,
      {:line, 4_096},
      {:env, [{~c"TMPDIR", String.to_charlist(Path.expand(tmp_dir))}, {~c"ERL_FLAGS", ~c"+S 1:1"}]},
      {:args, paths ++ ["-r", support, "-e", script]}
    ])
  end

  defp fixture_root(port) do
    assert_receive {^port, {:data, {:eol, root}}}, 5_000
    assert File.dir?(root)
    root
  end

  defp stop_fixture(port) do
    assert Port.command(port, "cleanup\n")
    assert_receive {^port, {:exit_status, 0}}, 5_000
  end

  defp close_fixture(port) do
    if Port.info(port), do: Port.close(port)
  end
end
