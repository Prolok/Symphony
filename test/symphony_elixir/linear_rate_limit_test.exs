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
          {200, %{"retry-after" => ["10"], "x-ratelimit-requests-reset" => [to_string(div(now, 1_000) + 20)]}, %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}, 20_000},
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
          %Req.Response{status: 401, headers: %{"retry-after" => ["3600"]}},
          %Req.Response{status: 429, headers: %{"retry-after" => ["nonsense"]}},
          %Req.Response{status: 429, headers: %{"retry-after" => ["Fri, 31 Feb 2027 09:00:00 GMT"]}},
          %Req.Response{status: 429, headers: %{"retry-after" => ["-1"]}},
          %{status: 429, headers: nil},
          %{status: 429, headers: %{"retry-after" => ["0"]}}
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

  defp cooldown_path(binding) do
    key = :crypto.hash(:sha256, Jason.encode!([binding["workspace_id"], binding["client_id"]])) |> Base.encode16(case: :lower)
    Path.join(SymphonyElixir.Config.linear_rate_limit_root(), key <> ".json")
  end
end
