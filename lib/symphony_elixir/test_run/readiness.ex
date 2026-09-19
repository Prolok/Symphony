defmodule SymphonyElixir.TestRun.Readiness do
  @moduledoc "Bounded relay catch-up during preflight; external errors are never silently retried."
  alias SymphonyElixir.Relay.Session

  @spec await(map(), keyword()) :: :ok | {:error, term()}
  def await(session, opts \\ []) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    wait(session, clock.() + Keyword.get(opts, :timeout, 5_000), clock, opts)
  end

  defp wait(session, deadline, clock, opts) do
    next = Keyword.get(opts, :tick, &Session.tick/1).(session)

    cond do
      next.status == :ready ->
        :ok

      next.error != nil ->
        {:error, {:test_relay_preflight, next.status}}

      clock.() >= deadline ->
        {:error, :test_relay_preflight_timeout}

      true ->
        Keyword.get(opts, :sleep, &Process.sleep/1).(100)
        wait(next, deadline, clock, opts)
    end
  end

  @spec public_error(term()) :: map()
  def public_error({:error, reason}), do: public_error(reason)
  def public_error({:linear_api_request, :linear_app_request_unavailable}), do: %{code: "linear_app_request_unavailable"}
  def public_error({:linear_api_status, status, _}) when is_integer(status), do: %{code: "linear_http", status: status}
  def public_error({:test_relay_preflight, status}) when is_atom(status), do: %{code: "test_relay_preflight", state: Atom.to_string(status)}
  def public_error({:test_scenario_states_unavailable, states}) when is_list(states), do: %{code: "test_scenario_states_unavailable", states: states}
  def public_error(reason) when is_atom(reason), do: %{code: Atom.to_string(reason)}
  def public_error(_), do: %{code: "test_runtime_failed"}
end
