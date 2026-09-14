defmodule SymphonyElixir.LinearRateLimitTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.{DurableState, RateLimit}

  setup do
    root = Path.join([File.cwd!(), "_build", "cooldown-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, binding: %{"state_root" => root, "workspace_id" => "workspace", "client_id" => root}, now: 1_800_000_000_000}
  end

  test "confirmed server deadlines block both transports and survive process restart", %{binding: binding, now: now} do
    for {status, headers, body, delay} <- [
          {429, [{"Retry-After", "3600"}], %{}, 3_600_000},
          {403, %{"x-ratelimit-requests-remaining" => ["0"], "x-ratelimit-requests-reset" => [to_string(now + 60_000)]}, %{}, 60_000},
          {200, %{"x-ratelimit-requests-remaining" => ["0"], "x-ratelimit-requests-reset" => [to_string(now + 60_000)]}, %{}, 60_000},
          {200, %{"retry-after" => ["10"], "x-ratelimit-requests-remaining" => ["0"], "x-ratelimit-requests-reset" => [to_string(div(now, 1_000) + 20)]},
           %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}, 20_000},
          {429, %{"retry-after" => ["Fri, 15 Jan 2027 09:00:00 GMT"]}, %{}, 3_600_000}
        ] do
      scoped = Map.put(binding, "client_id", "app-#{System.unique_integer([:positive])}")
      response = %Req.Response{status: status, headers: headers, body: body}
      opts = [rate_limit_now: fn -> now end]
      result = RateLimit.request(scoped, fn -> {:ok, response} end, opts)
      assert {:ok, ^response} = result
      assert {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline}}} = RateLimit.check(scoped, opts)
      assert deadline == now + delay

      other_project = scoped |> Map.put("state_root", Path.join(scoped["state_root"], "other-project/.symphony/state")) |> Map.put("allowed_issue_ids", ["other-project"])
      denied = fn -> flunk("early request") end
      result = Task.async(fn -> RateLimit.request(other_project, denied, opts) end) |> Task.await()
      assert {:error, {:linear_app_rate_limited, %{retry_at_ms: ^deadline}}} = result

      assert :ok = RateLimit.check(scoped, rate_limit_now: fn -> deadline end)
      elapsed = [rate_limit_now: fn -> deadline end]
      assert {:ok, :recovered} = RateLimit.request(scoped, fn -> {:ok, :recovered} end, elapsed)
    end
  end

  test "diagnostic headers and malformed deadlines do not manufacture a cooldown", %{binding: binding, now: now} do
    for response <- [
          %Req.Response{status: 200, headers: %{"retry-after" => ["3600"]}},
          %Req.Response{status: 403, headers: %{"x-ratelimit-requests-remaining" => ["5"], "x-ratelimit-requests-reset" => [to_string(now + 60_000)]}},
          %Req.Response{status: 401, headers: %{"retry-after" => ["3600"]}}
        ] do
      assert {:ok, ^response} = RateLimit.request(binding, fn -> {:ok, response} end, rate_limit_now: fn -> now end)
      assert :ok = RateLimit.check(binding)
    end

    assert {:error, :transport} = RateLimit.request(binding, fn -> {:error, :transport} end)
  end

  test "later responses extend the stored deadline and fail closed on concurrent corruption", %{binding: binding, now: now} do
    request = fn -> {:ok, %{status: 429, headers: %{"retry-after" => "60"}}} end
    assert {:ok, _} = RateLimit.request(binding, request, rate_limit_now: fn -> now end)
    path = cooldown_path(binding)
    assert {:ok, _} = RateLimit.request(binding, request, rate_limit_now: fn -> now + 60_000 end)
    assert {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline}}} = RateLimit.check(binding, rate_limit_now: fn -> now end)
    assert deadline == now + 120_000

    for {record, error} <- [
          {%{"app" => ["wrong", "app"], "retry_at_ms" => deadline}, :linear_rate_limit_binding_mismatch},
          {%{}, :linear_rate_limit_state_unavailable}
        ] do
      File.rm!(path)

      concurrent_write = fn ->
        DurableState.write(path, record)
        request.()
      end

      assert {:error, ^error} = RateLimit.request(binding, concurrent_write, rate_limit_now: fn -> now end)
    end
  end

  test "corrupt or mismatched cooldown state fails before HTTP", %{binding: binding, now: now} do
    request = fn -> {:ok, %{status: 429, headers: %{"retry-after" => "60"}}} end
    assert {:ok, %{status: 429}} = RateLimit.request(binding, request, rate_limit_now: fn -> now end)

    path = cooldown_path(binding)
    assert :ok = DurableState.write(path, %{"app" => ["wrong", "app"], "retry_at_ms" => now + 60_000})
    assert {:error, :linear_rate_limit_binding_mismatch} = RateLimit.request(binding, fn -> flunk("HTTP with wrong binding") end)
    File.write!(path, "broken")
    assert {:error, :linear_rate_limit_state_unavailable} = RateLimit.request(binding, fn -> flunk("HTTP with corrupt state") end)
  end

  test "request, endpoint and complexity budgets are independent and diagnostics are allowlisted", %{binding: binding, now: now} do
    headers = [
      {"X-RateLimit-Requests-Remaining", ["15"]},
      {"X-RateLimit-Requests-Reset", to_string(now + 3_600_000)},
      {"X-RateLimit-Endpoint-Requests-Remaining", "0.0"},
      {"X-RateLimit-Endpoint-Requests-Reset", to_string(now + 10_000)},
      {"X-RateLimit-Complexity-Remaining", "0"},
      {"X-RateLimit-Complexity-Reset", to_string(now + 20_000)},
      {"X-Complexity", "12"},
      {"X-RateLimit-Complexity-Limit", "2000000"},
      {"X-RateLimit-Requests-Limit", "5000"},
      {"X-RateLimit-Endpoint-Requests-Limit", "100"},
      {"Authorization", "secret"},
      {"X-RateLimit-Secret", "secret"},
      {"x-complexity-untrusted", "secret"}
    ]

    diagnostics = RateLimit.hints(200, headers, [])
    assert diagnostics["limited"]
    assert diagnostics["x-complexity"] == "12"
    refute inspect(diagnostics) =~ "secret"
    assert RateLimit.hints(200, [:malformed], []) == %{}
    opts = [rate_limit_now: fn -> now end]
    response = %{status: 200, headers: headers, body: %{}}
    assert {:ok, ^response} = RateLimit.request(binding, fn -> {:ok, response} end, opts)
    assert {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline}}} = RateLimit.check(binding, opts)
    assert deadline == now + 20_000
    refute RateLimit.hints(200, %{"X-Complexity" => "secret"}, []) |> Map.has_key?("x-complexity")
  end

  test "missing, invalid and expired deadlines select bounded exponential jitter only once", %{binding: binding, now: now} do
    for {headers, index} <-
          Enum.with_index([
            nil,
            %{"Retry-After" => "nonsense"},
            %{"retry-after" => "-1"},
            %{"retry-after" => "0"},
            %{"retry-after" => "Fri, 31 Feb 2027 09:00:00 GMT"},
            %{"x-ratelimit-requests-remaining" => "0", "x-ratelimit-requests-reset" => to_string(now - 1)}
          ]) do
      scoped = Map.put(binding, "client_id", "#{binding["client_id"]}-#{index}")
      response = %{status: 429, headers: headers}

      Enum.reduce([30_000, 60_000, 120_000, 240_000, 300_000, 300_000], now, fn base, current ->
        opts = [rate_limit_now: fn -> current end, rate_limit_jitter: fn maximum -> maximum end]
        assert {:ok, ^response} = RateLimit.request(scoped, fn -> {:ok, response} end, opts)
        assert {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline}}} = RateLimit.check(scoped, opts)
        assert deadline == current + base + div(base, 4)

        for _ <- 1..3 do
          forbidden = fn -> flunk("HTTP during pause") end
          result = RateLimit.request(scoped, forbidden, opts)
          assert {:error, {:linear_app_rate_limited, %{retry_at_ms: ^deadline}}} = result
        end

        deadline
      end)
    end
  end

  test "concurrent responses never shorten the host pause or repeatedly extend fallback", %{binding: binding, now: now} do
    parent = self()
    opts = [rate_limit_now: fn -> now end, rate_limit_jitter: fn _ -> 0 end]

    tasks =
      for delay <- ["60", "10", nil] do
        Task.async(fn ->
          RateLimit.request(
            binding,
            fn ->
              send(parent, {:ready, self()})

              receive do
                :respond -> {:ok, %{status: 429, headers: if(delay, do: %{"retry-after" => delay}, else: %{})}}
              end
            end,
            opts
          )
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _})

    for task <- tasks do
      send(task.pid, :respond)
      assert {:ok, _} = Task.await(task)
    end

    assert {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline}}} = RateLimit.check(binding, opts)
    assert deadline == now + 60_000
  end

  test "successful responses log only allowed budget values and bound context" do
    binding = %{"workspace_id" => "logging", "client_id" => Ecto.UUID.generate()}
    headers = %{"X-Complexity" => "7", "X-RateLimit-Complexity-Remaining" => "99", "authorization" => "synthetic-secret", "x-ratelimit-secret" => "synthetic-secret"}

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        RateLimit.request(binding, fn -> {:ok, %{status: 200, headers: headers, body: "synthetic-payload"}} end,
          context: %{"issue_id" => "issue", "issue_identifier" => "PRO-1", "session_id" => "session"}
        )
      end)

    assert log =~ "x-complexity"
    assert log =~ "issue_id=issue"
    assert log =~ "session_id=session"
    refute log =~ "synthetic-secret"
    refute log =~ "synthetic-payload"
  end

  defp cooldown_path(binding) do
    key = :crypto.hash(:sha256, Jason.encode!([binding["workspace_id"], binding["client_id"]])) |> Base.encode16(case: :lower)
    Path.join(SymphonyElixir.Config.linear_rate_limit_root(), key <> ".json")
  end
end
