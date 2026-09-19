defmodule SymphonyElixir.TestRunReadinessTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.TestRun.Readiness

  test "preflight drains a replay but never retries an external error" do
    initial = %{status: :catching_up, error: nil, page: 0}
    tick = fn state -> %{state | page: state.page + 1, status: if(state.page == 2, do: :ready, else: :catching_up)} end
    assert :ok = Readiness.await(initial, tick: tick, sleep: fn _ -> :ok end)
    assert {:error, {:test_relay_preflight, :unavailable}} = Readiness.await(initial, tick: fn _ -> %{status: :unavailable, error: :http_503} end)
    assert {:error, :test_relay_preflight_timeout} = Readiness.await(initial, tick: & &1, timeout: 0)
  end

  test "public failure codes never copy provider payloads or arbitrary messages" do
    assert Readiness.public_error({:error, {:linear_api_request, :linear_app_request_unavailable}}) ==
             %{code: "linear_app_request_unavailable"}

    assert Readiness.public_error({:linear_api_request, {"provider", "secret"}}) == %{code: "test_runtime_failed"}
    assert Readiness.public_error({:error, :missing}) == %{code: "missing"}
    assert Readiness.public_error({:linear_api_status, 503, %{secret: "hidden"}}) == %{code: "linear_http", status: 503}
    assert Readiness.public_error({:test_relay_preflight, :unavailable}) == %{code: "test_relay_preflight", state: "unavailable"}

    assert Readiness.public_error({:test_scenario_states_unavailable, ["Umsetzungsticket erstellt"]}) ==
             %{code: "test_scenario_states_unavailable", states: ["Umsetzungsticket erstellt"]}

    assert Readiness.public_error({:transport, "secret"}) == %{code: "test_runtime_failed"}
  end
end
