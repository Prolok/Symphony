defmodule SymphonyElixir.LinearBudgetGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  alias SymphonyElixir.Linear.Budget

  test "reserve starts below twenty percent and summary groups request kinds per binding" do
    binding = %{"workspace_id" => "budget-#{System.unique_integer([:positive])}", "client_id" => "app"}
    now = System.monotonic_time(:millisecond)
    headers = %{"x-ratelimit-requests-limit" => "5000", "x-ratelimit-requests-remaining" => "1000"}
    :ok = Budget.record(binding, :comment_signal, headers, now: now)
    refute Budget.low?(binding)

    :ok = Budget.record(binding, :comments, %{headers | "x-ratelimit-requests-remaining" => "999"}, now: now + 1)
    assert Budget.low?(binding)

    log =
      capture_log(fn ->
        :ok = Budget.record(binding, :write, headers, now: now + 300_000)
        refute Budget.low?(binding)
      end)

    assert log =~ "Linear budget summary workspace_id=#{binding["workspace_id"]}"
    assert log =~ "comment_signal: 1"
    assert log =~ "comments: 1"
    assert log =~ "write: 1"
    assert log =~ "remaining=1000 limit=5000"
  end
end
