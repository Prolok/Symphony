defmodule SymphonyElixir.Yolo.RetryBackoff do
  @moduledoc "Shared retry timing for journalled YOLO recovery and notifications."

  @transient_reasons [
    :transport_error,
    :timeout,
    :timed_out,
    :offline,
    :rate_limited,
    :linear_app_rate_limited,
    :linear_app_request_unavailable,
    :relay_not_ready,
    :linear_budget_reserved,
    :issue_already_owned,
    :issue_lease_unavailable
  ]

  @spec count(map() | nil, String.t(), term()) :: pos_integer()
  def count(previous, signal, reason) do
    if is_map(previous) and previous["signal"] == signal and previous["reason"] == inspect(reason) and is_integer(previous["count"]) do
      previous["count"] + 1
    else
      1
    end
  end

  @spec delay(term(), pos_integer()) :: pos_integer()
  def delay(reason, count) do
    if transient?(reason) or count == 1, do: 30_000, else: min(900_000, (count - 1) * 300_000)
  end

  defp transient?(reason) when is_atom(reason), do: reason in @transient_reasons
  defp transient?({:notification_refresh_failed, reason}), do: transient?(reason)
  defp transient?({:linear_api_request, reason}), do: transient?(reason)
  defp transient?({:linear_api_status, _, %{classification: "rate_limited"}}), do: true
  defp transient?({:linear_api_status, status, _}) when status in [408, 429, 500, 502, 503, 504], do: true
  defp transient?({:wait_marker_unresolved, _identifier, reason}), do: transient?(reason)
  defp transient?({:wait_marker_unresolved, _identifier, reason, write_reason}), do: transient?(reason) or transient?(write_reason)
  defp transient?(%Req.TransportError{}), do: true
  defp transient?(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: transient?(elem(reason, 0))
  defp transient?(_), do: false
end
