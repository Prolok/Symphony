defmodule SymphonyElixir.Relay.Client do
  @moduledoc "Bounded HTTPS transport for LinearRelay v1; never exposes credentials or provider payload errors."

  alias SymphonyElixir.Relay.Config
  @limit 524_288
  @codes ~w(not_found invalid_receipt invalid_generation snapshot_required resync_required unauthorized unavailable too_large)

  @spec request(map(), map(), String.t(), atom(), map() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def request(relay, app, consumer, operation, body \\ nil, opts \\ []) do
    with true <- Config.endpoint?(relay["endpoint"]) or loopback?(relay["endpoint"], opts),
         true <- Config.id?(consumer),
         {:ok, key} <- Keyword.get(opts, :key, fn -> Config.key(relay, app) end).() do
      {method, suffix} = route(operation)
      url = String.trim_trailing(relay["endpoint"], "/") <> "/v1/consumers/" <> consumer <> suffix

      options = [
        method: method,
        url: url,
        headers: [{"authorization", "Bearer " <> key}],
        retry: false,
        redirect: false,
        receive_timeout: 5_000,
        connect_options: [timeout: 3_000],
        decode_body: false,
        into: &collect/2
      ]

      options = if body, do: Keyword.put(options, :json, body), else: options
      result = measured_request(app, operation, fn -> Keyword.get(opts, :http, &Req.request/1).(options) end)
      decode(result)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_relay_binding}
    end
  rescue
    _ -> {:error, :relay_transport_unavailable}
  catch
    :exit, _ -> {:error, :relay_transport_unavailable}
  end

  defp measured_request(app, operation, callback) do
    started = System.monotonic_time(:millisecond)

    # Count attempted HTTP calls, including exceptions/exits; binding/key
    # rejections above do not reach the transport and are not requests.
    result =
      try do
        callback.()
      rescue
        _ -> {:error, :relay_transport_unavailable}
      catch
        :exit, _ -> {:error, :relay_transport_unavailable}
      end

    status =
      case result do
        {:ok, %{status: status}} -> status
        _ -> "transport_error"
      end

    :telemetry.execute(
      [:symphony, :relay, :request],
      %{requests: 1, duration_ms: System.monotonic_time(:millisecond) - started},
      %{workspace_id: app["workspace_id"], kind: operation, status: status}
    )

    result
  end

  defp route(:register), do: {:put, ""}
  defp route(:poll), do: {:get, "/events"}
  defp route(:ack), do: {:post, "/ack"}
  defp route(:resync), do: {:post, "/resync"}

  defp loopback?(url, opts) do
    uri = URI.parse(url || "")

    opts[:allow_loopback] == true and uri.scheme == "http" and uri.host in ["127.0.0.1", "::1"] and
      uri.userinfo == nil and uri.query == nil and uri.fragment == nil
  end

  defp collect({:data, bytes}, {request, response}) do
    body = response.body || ""

    if byte_size(body) + byte_size(bytes) <= @limit,
      do: {:cont, {request, %{response | body: body <> bytes}}},
      else: {:halt, {request, %{response | body: :too_large}}}
  end

  defp decode({:ok, %{body: :too_large}}), do: {:error, :relay_response_too_large}

  defp decode({:ok, %{status: status, body: bytes}}) when is_binary(bytes) and byte_size(bytes) <= @limit do
    case Jason.decode(bytes) do
      {:ok, %{"version" => 1} = body} -> response(status, body)
      {:ok, %{"version" => _}} -> {:error, :relay_upgrade_required}
      _ -> {:error, :invalid_relay_response}
    end
  end

  defp decode(_), do: {:error, :relay_transport_unavailable}

  defp response(status, body) when status in 200..299, do: {:ok, body}

  defp response(status, body) do
    code = if body["error"] in @codes, do: body["error"], else: "unknown"
    {:error, {:relay_http, status, code}}
  end
end
