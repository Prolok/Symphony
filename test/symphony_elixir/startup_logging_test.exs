defmodule SymphonyElixir.StartupLoggingTest do
  use ExUnit.Case, async: true

  @startup_fixture """
  Code.compiler_options(ignore_module_conflict: true)

  # Replace only the external service lock and project discovery, in this BEAM.
  defmodule SymphonyElixir.ServiceMutex do
    def acquire(_name), do: :ok
  end

  defmodule SymphonyElixir.Projects do
    require Logger

    def prepare(_root, _workflow) do
      Logger.debug("startup-debug-sentinel")
      Logger.info("startup-info-sentinel")
      Logger.warning("startup-warning-sentinel")
      Logger.error("startup-error-sentinel")
      Logger.flush()

      if Process.get(:configure_disk) do
        :ok = SymphonyElixir.LogFile.configure()
        Logger.debug("disk-debug-sentinel")
        Logger.flush()
        :ok = :logger_disk_log_h.filesync(:symphony_disk_log)
      end

      {:error, :synthetic_discovery_failure}
    end
  end
  """

  setup do
    root = Path.join([File.cwd!(), "_build", "startup-logging-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    File.write!(Path.join(root, "WORKFLOW.md"), "---\n{}\n---\nSynthetic workflow\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  for stage <- [nil, "run", "prepare", "probe", "cleanup"] do
    @tag stage: stage
    test "CLI main filters early discovery debug logs in #{stage || "normal"} startup", %{root: root, stage: stage} do
      script =
        @startup_fixture <>
          """
          Application.put_env(:symphony_elixir, :test_instance, %{})
          SymphonyElixir.CLI.main([])
          """

      {output, status} = run_isolated(script, root, stage)

      assert status == 1, output
      assert output =~ "startup-info-sentinel"
      assert output =~ "startup-warning-sentinel"
      assert output =~ "startup-error-sentinel"

      if stage in [nil, "run"] do
        assert output =~ "synthetic_discovery_failure"
      else
        assert output =~ "Testlauf: gebundene Laufzeitoperation fehlgeschlagen"
      end

      refute output =~ "startup-debug-sentinel"
    end
  end

  test "custom logs root retains disk debug output after the early console filter", %{root: root} do
    logs_root = Path.join(root, "custom logs")

    script =
      @startup_fixture <>
        """
        Process.put(:configure_disk, true)
        SymphonyElixir.CLI.main(["--logs-root", #{inspect(logs_root)}])
        """

    {output, status} = run_isolated(script, root)

    assert status == 1, output
    assert output =~ "synthetic_discovery_failure"
    refute output =~ "startup-debug-sentinel"
    refute output =~ "disk-debug-sentinel"

    disk_output = logs_root |> Path.join("log/symphony.log.*") |> Path.wildcard() |> Enum.map_join(&File.read!/1)
    assert disk_output =~ "disk-debug-sentinel"
    refute File.exists?(Path.join(root, "log"))
  end

  test "console setup is repeatable and tolerates a missing handler without changing primary logging", %{root: root} do
    script = """
    alias SymphonyElixir.LogFile
    primary = :logger.get_primary_config()
    :ok = LogFile.configure_startup_console()
    :ok = LogFile.configure_startup_console()
    ^primary = :logger.get_primary_config()
    {:ok, %{level: :info}} = :logger.get_handler_config(:default)
    :ok = LogFile.configure()
    :ok = LogFile.configure_startup_console()
    {:error, {:not_found, :default}} = :logger.get_handler_config(:default)
    :ok = :logger.remove_handler(:symphony_disk_log)
    :ok = LogFile.configure_startup_console()
    ^primary = :logger.get_primary_config()
    [] = :logger.get_handler_ids()
    IO.puts("console-setup-ok")
    """

    {output, status} = run_isolated(script, root)
    assert status == 0, output
    assert output =~ "console-setup-ok"
  end

  defp run_isolated(script, root, stage \\ nil) do
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    env =
      SymphonyElixir.RuntimePaths.cleaned_system_env(%{
        "SYMPHONY_WORKFLOW_FILE" => Path.join(root, "WORKFLOW.md"),
        "SYMPHONY_ROOT_DIR" => root
      })
      |> List.keyreplace("SYMPHONY_TEST_RUN_STAGE", 0, {"SYMPHONY_TEST_RUN_STAGE", stage})

    # Combining the streams detects leaked debug output on either stdout or stderr.
    System.cmd(System.find_executable("elixir"), code_paths ++ ["-e", script], cd: root, env: env, stderr_to_stdout: true)
  end
end
