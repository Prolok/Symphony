defmodule SymphonyElixir.RelayMeasurementTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias SymphonyElixir.Linear.RateLimit
  alias SymphonyElixir.Relay.Client

  alias SymphonyElixir.BudgetCapture, as: SymphonyBudgetCapture

  test "normal CLI opts into capture before discovery and records through application shutdown" do
    base = Path.join([File.cwd!(), "_build", "launcher-#{System.unique_integer([:positive])}"])
    output = base <> ".jsonl"
    plan = base <> ".json"

    metadata = %{
      variant: "feature",
      evidence: "fixture",
      revision: "uncommitted",
      source_sha256: String.duplicate("a", 64),
      instrumentation_sha256: String.duplicate("b", 64),
      workload_sha256: String.duplicate("c", 64),
      workspace_ids: ["one", "two"],
      secret: "must-not-be-recorded"
    }

    phases = for name <- ~w(cold_start idle active burst reconcile outage checkpoint), do: %{name: name, duration_ms: 80}
    File.write!(plan, Jason.encode!(%{output: output, metadata: metadata, phases: phases}))

    on_exit(fn ->
      SymphonyBudgetCapture.close_run(:test_cleanup)
      File.rm(plan)
      File.rm(output)
    end)

    refute Process.whereis(SymphonyBudgetCapture)
    assert :ok = SymphonyBudgetCapture.start_run(nil)
    assert :ok = SymphonyBudgetCapture.close_run(:disabled)
    refute Process.whereis(SymphonyBudgetCapture)

    emit = fn kind ->
      :telemetry.execute(
        [:symphony, :linear, :request],
        %{requests: 1, duration_ms: 1},
        %{workspace_id: "one", kind: kind, status: 200, headers: %{}}
      )
    end

    deps = %{
      default_workflow_path: fn -> "fixture-workflow" end,
      env_files_dir: &File.cwd!/0,
      file_regular?: fn _ -> true end,
      set_workflow_file_path: fn _ -> :ok end,
      load_env_files: fn _ ->
        emit.(:discovery)
        :ok
      end,
      validate_startup_requirements: fn ->
        emit.(:auth)
        :ok
      end,
      ensure_all_started: fn -> {:ok, []} end
    }

    assert :ok = SymphonyElixir.CLI.evaluate(["--budget-capture", plan], deps)
    Process.sleep(800)
    emit.(:shutdown_restore)
    assert :ok = SymphonyElixir.Application.stop(nil)
    refute Process.whereis(SymphonyBudgetCapture)
    text = File.read!(output)
    refute text =~ "must-not-be-recorded"
    rows = decode_capture(text)
    assert Enum.map(rows, & &1["sequence"]) == Enum.to_list(0..(length(rows) - 1))
    assert Enum.map(Enum.filter(rows, &(&1["event"] == "phase_start")), & &1["phase"]) == Enum.map(phases, & &1.name)
    requests = Enum.filter(rows, &(&1["event"] == "request"))
    assert Enum.map(requests, & &1["phase"]) == ["cold_start", "cold_start", "setup"]
    assert List.last(rows)["shutdown"] == "application_stopped"
    assert List.last(rows)["recorder_intact"]
    assert List.last(rows)["attestation"] == %{}
    assert {:error, _} = SymphonyBudgetCapture.start_run(plan)
    assert File.read!(output) == text

    File.rm!(output)
    baseline_metadata = Map.merge(metadata, %{variant: "baseline", revision: "65927695ab49a2113121632177267c44bfb5a768"})
    File.write!(plan, Jason.encode!(%{output: output, metadata: baseline_metadata, phases: phases}))
    assert :ok = SymphonyBudgetCapture.start_run(plan)
    :telemetry.detach(SymphonyBudgetCapture)
    # A lost observer and an early concurrent shutdown must remain incomplete.
    recorder = Process.whereis(SymphonyBudgetCapture)
    :sys.suspend(recorder)
    closers = for _ <- 1..8, do: Task.async(fn -> SymphonyBudgetCapture.close_run(:startup_error) end)
    await_recorder_calls(recorder, 8)
    :sys.resume(recorder)
    Enum.each(closers, fn task -> assert Task.await(task) == :ok end)

    rows = decode_capture(File.read!(output))
    assert Enum.count(rows, &(&1["event"] == "finish")) == 1
    refute List.last(rows)["recorder_intact"]
    assert List.last(rows)["shutdown"] == "startup_error"
    refute Enum.any?(rows, &(&1["event"] == "phase_end"))

    File.rm!(output)
    assert :ok = SymphonyBudgetCapture.start_run(plan)
    recorder = Process.whereis(SymphonyBudgetCapture)
    timer = Agent.get(recorder, & &1.timer)
    :sys.suspend(recorder)
    closer = Task.async(fn -> SymphonyBudgetCapture.close_run(:startup_error) end)
    await_recorder_calls(recorder, 1)
    Process.exit(recorder, :kill)
    assert Task.await(closer) == :ok
    :timer.cancel(timer)
    :telemetry.detach(SymphonyBudgetCapture)
    refute Enum.any?(decode_capture(File.read!(output)), &(&1["event"] == "finish"))
  end

  test "invalid public plans are rejected before capture" do
    base = Path.join([File.cwd!(), "_build", "invalid-launcher-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm(base) end)
    assert {:error, _} = SymphonyBudgetCapture.start_run(base)
    File.write!(base, "invalid json with private-value")
    assert {:error, message} = SymphonyBudgetCapture.start_run(base)
    refute message =~ "private-value"

    for metadata <- [
          [],
          %{},
          %{
            variant: "feature",
            evidence: "fixture",
            revision: "uncommitted",
            source_sha256: String.duplicate("a", 64),
            instrumentation_sha256: String.duplicate("b", 64),
            workload_sha256: String.duplicate("c", 64),
            workspace_ids: []
          }
        ] do
      File.write!(base, Jason.encode!(%{output: "/unused", metadata: metadata, phases: []}))
      assert {:error, _} = SymphonyBudgetCapture.start_run(base)
      refute Process.whereis(SymphonyBudgetCapture)
    end
  end

  defp await_recorder_calls(pid, count) do
    ready =
      Enum.any?(1..100, fn _ ->
        {:messages, messages} = Process.info(pid, :messages)

        if Enum.count(messages, &match?({:"$gen_call", _, {:get, _}}, &1)) >= count do
          true
        else
          Process.sleep(1)
          false
        end
      end)

    assert ready
  end

  defp decode_capture(text) do
    text |> String.split("\n", trim: true) |> Enum.map(&(String.replace_prefix(&1, "Budget capture=", "") |> Jason.decode!()))
  end

  test "recorder captures actual HTTP attempts and explicit phases, never key failures or secrets" do
    path = Path.join([File.cwd!(), "_build", "capture-#{System.unique_integer([:positive])}.jsonl"])
    on_exit(fn -> File.rm(path) end)
    :ok = SymphonyBudgetCapture.start(path, %{evidence: "fixture"})
    relay = %{"endpoint" => "https://relay.test"}
    app = %{"workspace_id" => "fixture"}

    for phase <- ~w(cold_start idle active burst reconcile outage checkpoint) do
      SymphonyBudgetCapture.phase(phase, 0.1, fn ->
        send(self(), {:phase, phase})
      end)
    end

    assert {:error, :missing_key} = Client.request(relay, app, "consumer", :poll, nil, key: fn -> {:error, :missing_key} end)

    assert {:error, :relay_transport_unavailable} =
             Client.request(relay, app, "consumer", :poll, nil, key: fn -> raise "private-secret" end)

    assert {:error, :relay_transport_unavailable} =
             Client.request(relay, app, "consumer", :poll, nil, key: fn -> exit(:private_secret_store_unavailable) end)

    assert {:ok, _} =
             Client.request(relay, app, "consumer", :poll, nil,
               key: fn -> {:ok, "private-secret"} end,
               http: fn _ -> {:ok, %{status: 200, body: ~s({"version":1})}} end
             )

    failed_http = [key: fn -> {:ok, "private-secret"} end, http: fn _ -> raise "private-secret" end]
    exited_http = [key: fn -> {:ok, "private-secret"} end, http: fn _ -> exit(:timeout) end]
    assert {:error, _} = Client.request(relay, app, "consumer", :poll, nil, failed_http)
    assert {:error, _} = Client.request(relay, app, "consumer", :poll, nil, exited_http)
    :ok = SymphonyBudgetCapture.finish(%{restore_verified: true})
    text = File.read!(path)
    refute text =~ "private-secret"
    records = text |> String.split("\n", trim: true) |> Enum.map(&(String.replace_prefix(&1, "Budget capture=", "") |> Jason.decode!()))
    requests = Enum.filter(records, &(&1["event"] == "request"))
    assert length(requests) == 3
    assert Enum.map(requests, & &1["metadata"]["status"]) == [200, "transport_error", "transport_error"]
    assert Enum.map(records, & &1["sequence"]) == Enum.to_list(0..(length(records) - 1))
    assert List.last(records)["event"] == "finish"
  end

  test "failed capture actions cannot produce a complete run" do
    path = Path.join([File.cwd!(), "_build", "failed-capture-#{System.unique_integer([:positive])}.jsonl"])

    on_exit(fn ->
      :telemetry.detach(SymphonyBudgetCapture)
      File.rm(path)
    end)

    :ok = SymphonyBudgetCapture.start(path, %{evidence: "fixture"})
    assert_raise RuntimeError, fn -> SymphonyBudgetCapture.phase("cold_start", 0.001, fn -> raise "failed" end) end
    assert_raise MatchError, fn -> SymphonyBudgetCapture.finish(%{}) end
    Agent.get(SymphonyBudgetCapture, &File.close(&1.file))
    Agent.stop(SymphonyBudgetCapture)
  end

  test "concurrent telemetry remains inside its recorded phase boundaries" do
    path = Path.join([File.cwd!(), "_build", "concurrent-capture-#{System.unique_integer([:positive])}.jsonl"])
    on_exit(fn -> File.rm(path) end)
    :ok = SymphonyBudgetCapture.start(path, %{evidence: "fixture"})

    producer =
      Task.async(fn ->
        for _ <- 1..200 do
          :telemetry.execute([:symphony, :relay, :request], %{requests: 1}, %{kind: :fixture_concurrency})
          Process.sleep(1)
        end
      end)

    for phase <- ~w(cold_start idle active burst reconcile outage checkpoint),
        do: SymphonyBudgetCapture.phase(phase, 0.03)

    Task.await(producer)
    :ok = SymphonyBudgetCapture.finish(%{})

    records =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&(String.replace_prefix(&1, "Budget capture=", "") |> Jason.decode!()))

    assert Enum.count(records, &(get_in(&1, ["metadata", "kind"]) == "fixture_concurrency")) == 200

    Enum.reduce(records, "setup", fn record, current ->
      case record["event"] do
        "phase_start" ->
          record["phase"]

        "phase_end" ->
          assert record["phase"] == current
          "setup"

        _ ->
          assert record["phase"] == current
          current
      end
    end)
  end

  test "opt-in measurements count actual transports and allowed headers, never local suppressions" do
    previous = Application.get_env(:symphony_elixir, :linear_budget_measurements, false)
    Application.put_env(:symphony_elixir, :linear_budget_measurements, true)
    handler = "measurement-#{System.unique_integer([:positive])}"
    owner = self()
    :telemetry.attach(handler, [:symphony, :linear, :request], fn _, measure, meta, pid -> send(pid, {:measurement, measure, meta}) end, owner)

    on_exit(fn ->
      :telemetry.detach(handler)
      Application.put_env(:symphony_elixir, :linear_budget_measurements, previous)
    end)

    binding = %{"workspace_id" => "measurement", "client_id" => handler}
    private_value = "measurement-private-value-never-log"
    response = {:ok, %{status: 429, headers: %{"x-complexity" => ["17"], "retry-after" => ["30"], "authorization" => [private_value]}, body: %{}}}

    log =
      capture_log(fn ->
        assert ^response = RateLimit.request(binding, fn -> response end, budget_kind: :candidates)
        assert {:error, {:linear_app_rate_limited, _}} = RateLimit.request(binding, fn -> flunk("suppressed request reached transport") end)
      end)

    assert log =~ "Linear request measurement="
    refute log =~ private_value
    assert_received {:measurement, %{requests: 1, duration_ms: duration}, metadata}
    assert %{workspace_id: "measurement", kind: :candidates, headers: headers} = metadata
    assert duration >= 0
    assert headers["x-complexity"] == "17"
    refute Map.has_key?(headers, "authorization")
    refute_received {:measurement, _, _}
  end
end
