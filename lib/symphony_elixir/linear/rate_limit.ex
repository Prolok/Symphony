defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc "Shared, durable server cooldown for the bound Linear app; contains no credentials."

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Budget, DurableState, IssueLease}

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
      started = System.monotonic_time(:millisecond)

      result =
        try do
          callback.()
        catch
          kind, reason ->
            record_request(binding, {:error, :transport_error}, started, opts)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      record_request(binding, result, started, opts)
      finish_request(binding, deadline(result, now(opts)), result, opts)
    end
  end

  defp record_request(binding, result, started, opts) do
    diagnostics = response_hints(result)
    measurement = %{requests: 1, duration_ms: System.monotonic_time(:millisecond) - started}

    metadata = %{
      workspace_id: binding["workspace_id"],
      kind: Keyword.get(opts, :budget_kind, :other),
      status: response_status(result),
      headers: diagnostics
    }

    :telemetry.execute([:symphony, :linear, :request], measurement, metadata)
    Budget.record(binding, metadata.kind, diagnostics)

    if Application.get_env(:symphony_elixir, :linear_budget_measurements, false),
      do: Logger.debug("Linear request measurement=" <> Jason.encode!(Map.merge(measurement, metadata)))

    if diagnostics != %{}, do: Logger.debug("Linear budget headers=#{inspect(diagnostics)}#{context_log(opts)}")
  end

  defp finish_request(_binding, nil, result, _opts), do: result

  defp finish_request(binding, deadline, result, opts) do
    # Preserve the first provider response for diagnostics and journal outcome
    # handling. Subsequent requests observe the shared deadline in check/2.
    with :ok <- persist(binding, deadline, opts), do: result
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

  defp persist(binding, deadline, opts) do
    target = path(binding)
    IssueLease.with_journal_lock(Path.dirname(target), fn -> persist_locked(binding, target, deadline, opts) end)
  end

  defp persist_locked(binding, target, deadline, opts) do
    case DurableState.read(target) do
      {:error, :enoent} ->
        write(binding, target, deadline, %{}, opts)

      {:ok, %{"retry_at_ms" => previous, "app" => app} = record} when is_integer(previous) ->
        if app == identity(binding) do
          write(binding, target, deadline, record, opts)
        else
          {:error, :linear_rate_limit_binding_mismatch}
        end

      _ ->
        {:error, :linear_rate_limit_state_unavailable}
    end
  end

  defp write(binding, target, deadline, record, opts) do
    {deadline, attempt} = choose_deadline(deadline, record, opts)

    with :ok <- DurableState.write(target, %{"app" => identity(binding), "retry_at_ms" => deadline, "attempt" => attempt}) do
      if record["retry_at_ms"] != deadline,
        do: Logger.warning("Linear rate limit paused retry_at_ms=#{deadline} retry_after_ms=#{max(deadline - now(opts), 0)}#{context_log(opts)}")

      :ok
    end
  end

  defp choose_deadline(:backoff, %{"retry_at_ms" => previous} = record, opts) do
    if previous > now(opts), do: {previous, attempt(record)}, else: backoff(record, opts)
  end

  defp choose_deadline(:backoff, record, opts), do: backoff(record, opts)
  defp choose_deadline(deadline, record, _opts), do: {max(record["retry_at_ms"] || 0, deadline), 0}

  defp backoff(record, opts) do
    previous = record["retry_at_ms"] || 0
    attempt = if now(opts) > previous + 300_000, do: 0, else: attempt(record)
    base = min(30_000 * Integer.pow(2, min(attempt, 4)), 300_000)
    maximum = div(base, 4)
    jitter = Keyword.get(opts, :rate_limit_jitter, fn max -> :rand.uniform(max + 1) - 1 end).(maximum)
    {now(opts) + base + min(max(jitter, 0), maximum), min(attempt + 1, 5)}
  end

  defp attempt(%{"attempt" => attempt}) when is_integer(attempt) and attempt in 0..5, do: attempt
  defp attempt(_record), do: 0

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
    headers = budget_headers(Map.get(response, :headers, %{}))

    if limited?(response) do
      [retry_after(headers["retry-after"], now) | reset_deadlines(headers, now)]
      |> Enum.filter(&(is_integer(&1) and &1 > now))
      |> Enum.max(fn -> :backoff end)
    end
  end

  defp deadline(_result, _now), do: nil

  @spec limited?(map()) :: boolean()
  def limited?(response), do: response_hints({:ok, response})["limited"] == true

  @spec hints(integer() | nil, map() | list() | nil, [String.t()]) :: map()
  def hints(status, headers, codes) do
    headers = budget_headers(headers)

    limited =
      status == 429 or "RATELIMITED" in codes or
        (status != 401 and Enum.any?(headers, fn {key, value} -> String.ends_with?(key, "remaining") and exhausted?(value) end)) or
        (status == 403 and Map.has_key?(headers, "retry-after"))

    if limited, do: Map.put(headers, "limited", true), else: headers
  end

  defp response_hints({:ok, response}) when is_map(response) do
    hints(Map.get(response, :status), Map.get(response, :headers), error_codes(Map.get(response, :body)))
  end

  defp response_hints(_result), do: %{}
  defp response_status({:ok, %{status: status}}), do: status
  defp response_status(_result), do: "transport_error"
  defp error_codes(%{"errors" => errors}) when is_list(errors), do: Enum.map(errors, &get_in(&1, ["extensions", "code"]))
  defp error_codes(_body), do: []

  defp budget_headers(headers) when is_map(headers) or is_list(headers) do
    Enum.reduce(headers, %{}, fn
      {key, value}, acc ->
        key = String.downcase(to_string(key))
        value = value |> List.wrap() |> List.first() |> to_string() |> String.trim()
        if allowed_header?(key, value), do: Map.put(acc, key, value), else: acc

      _, acc ->
        acc
    end)
  end

  defp budget_headers(_headers), do: %{}
  defp allowed_header?("retry-after", value), do: is_integer(retry_after(value, 0))

  defp allowed_header?(key, value) do
    (key == "x-complexity" or Regex.match?(~r/\Ax-rate-?limit-(?:(?:requests|endpoint-requests|complexity)-)?(limit|remaining|reset)\z/, key)) and
      Regex.match?(~r/\A[0-9]{1,16}(?:\.[0-9]{1,6})?\z/, value)
  end

  defp exhausted?(value), do: Regex.match?(~r/\A0(?:\.0+)?\z/, value)

  defp context_log(opts) do
    context = Keyword.get(opts, :context, %{})

    Enum.map_join(~w(issue_id issue_identifier session_id), fn key ->
      if value = context[key], do: " #{key}=#{value}", else: ""
    end)
  end

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
        String.ends_with?(key, "reset"),
        exhausted?(Map.get(headers, String.replace_suffix(key, "reset", "remaining"), "unknown")),
        {epoch, ""} <- [Integer.parse(value)],
        deadline = if(epoch < 10_000_000_000, do: epoch * 1_000, else: epoch),
        deadline > now,
        do: deadline
  end
end
