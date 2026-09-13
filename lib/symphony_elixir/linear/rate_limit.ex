defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc "Shared, durable server cooldown for the bound Linear app; contains no credentials."

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{DurableState, IssueLease}

  @spec check(map(), keyword()) :: :ok | {:error, term()}
  def check(binding, opts \\ []) do
    case DurableState.read(path(binding)) do
      {:error, :enoent} ->
        :ok

      {:ok, %{"retry_at_ms" => deadline, "app" => app}} when is_integer(deadline) ->
        cond do
          app != identity(binding) -> {:error, :linear_rate_limit_binding_mismatch}
          deadline > now(opts) -> limited(deadline, opts)
          true -> :ok
        end

      _ ->
        {:error, :linear_rate_limit_state_unavailable}
    end
  end

  @spec request(map(), (-> term()), keyword()) :: term()
  def request(binding, callback, opts \\ []) do
    with :ok <- check(binding, opts) do
      result = callback.()

      finish_request(binding, deadline(result, now(opts)), result, opts)
    end
  end

  defp finish_request(_binding, nil, result, _opts), do: result

  defp finish_request(binding, deadline, result, _opts) do
    # Preserve the first provider response for diagnostics and journal outcome
    # handling. Subsequent requests observe the shared deadline in check/2.
    with :ok <- persist(binding, deadline), do: result
  end

  @spec remaining_ms() :: non_neg_integer()
  def remaining_ms do
    case Config.settings!().tracker do
      %{kind: "linear", app: binding} ->
        case check(binding) do
          {:error, {:linear_app_rate_limited, %{retry_after_ms: remaining}}} -> remaining
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp persist(binding, deadline) do
    target = path(binding)

    IssueLease.with_journal_lock(Path.dirname(target), fn -> persist_locked(binding, target, deadline) end)
  end

  defp persist_locked(binding, target, deadline) do
    case DurableState.read(target) do
      {:error, :enoent} ->
        write(binding, target, deadline)

      {:ok, %{"retry_at_ms" => previous, "app" => app}} when is_integer(previous) ->
        if app == identity(binding) do
          write(binding, target, max(previous, deadline))
        else
          {:error, :linear_rate_limit_binding_mismatch}
        end

      _ ->
        {:error, :linear_rate_limit_state_unavailable}
    end
  end

  defp write(binding, target, deadline), do: DurableState.write(target, %{"app" => identity(binding), "retry_at_ms" => deadline})

  defp limited(deadline, opts) do
    {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline, retry_after_ms: max(deadline - now(opts), 0)}}}
  end

  defp now(opts), do: Keyword.get(opts, :rate_limit_now, fn -> System.system_time(:millisecond) end).()

  defp identity(binding), do: [binding["workspace_id"], binding["client_id"]]

  defp path(binding) do
    key = :crypto.hash(:sha256, Jason.encode!(identity(binding))) |> Base.encode16(case: :lower)
    Path.join(Config.linear_rate_limit_root(), key <> ".json")
  end

  defp deadline({:ok, response}, now) when is_map(response) do
    headers = normalize_headers(Map.get(response, :headers, %{}))

    if limited_response?(response, headers) do
      deadlines = [retry_after(headers["retry-after"], now) | reset_deadlines(headers, now)]
      deadlines |> Enum.filter(&(is_integer(&1) and &1 > now)) |> Enum.max(fn -> nil end)
    end
  end

  defp deadline(_result, _now), do: nil

  defp limited_response?(response, headers) do
    exhausted = Enum.any?(headers, fn {key, value} -> String.ends_with?(key, "remaining") and value == "0" end)
    status = Map.get(response, :status)

    status == 429 or graphql_limited?(Map.get(response, :body)) or
      (status == 403 and (exhausted or Map.has_key?(headers, "retry-after")))
  end

  defp graphql_limited?(body) when is_map(body) do
    Enum.any?(Map.get(body, "errors") || [], &(get_in(&1, ["extensions", "code"]) == "RATELIMITED"))
  end

  defp graphql_limited?(_body), do: false

  defp normalize_headers(headers) when is_map(headers) or is_list(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value |> List.wrap() |> List.first() |> to_string()} end)
  end

  defp normalize_headers(_headers), do: %{}

  defp retry_after(value, now) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> now + seconds * 1_000
      _ -> http_date(value)
    end
  end

  defp retry_after(_value, _now), do: nil

  defp http_date(value) do
    case Req.Utils.parse_http_date(value) do
      {:ok, date} -> DateTime.to_unix(date, :millisecond)
      _ -> nil
    end
  end

  defp reset_deadlines(headers, now) do
    for {key, value} <- headers,
        String.contains?(key, ["ratelimit", "rate-limit"]),
        String.ends_with?(key, "reset"),
        {epoch, ""} <- [Integer.parse(value)],
        deadline = if(epoch < 10_000_000_000, do: epoch * 1_000, else: epoch),
        deadline > now,
        do: deadline
  end
end
