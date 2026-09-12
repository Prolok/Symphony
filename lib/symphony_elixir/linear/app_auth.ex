defmodule SymphonyElixir.Linear.AppAuth do
  @moduledoc """
  OAuth2 client credentials. Each BEAM runtime owns an in-memory token cache;
  independent CLI/MCP runtimes acquire independent tokens with the same scopes.
  No tokens are persisted and personal credentials are never consulted.
  """

  use GenServer

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.{Assignees, CommentJournal}

  @identity_query "query SymphonyAppIdentity { viewer { id app email organization { id } } }"
  @expiry_margin 120
  @required ~w(client_secret_env workspace_id user_id client_id state_root installation_id)

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(%{auth_mode: "app", app: app, endpoint: endpoint, assignee: assignee}) do
    cond do
      not Enum.all?(@required, &nonempty?(app[&1])) -> {:error, :missing_linear_app_binding}
      not Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, app["client_secret_env"]) -> {:error, :invalid_linear_client_secret_reference}
      endpoint != "https://api.linear.app/graphql" -> {:error, :invalid_linear_app_endpoint}
      not Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, app["installation_id"]) -> {:error, :invalid_linear_installation_id}
      Path.type(app["state_root"]) != :absolute -> {:error, :invalid_linear_app_state_root}
      not valid_issue_scope?(app["allowed_issue_ids"]) -> {:error, :invalid_linear_app_issue_scope}
      not valid_assignees?(assignee, app["user_id"]) -> {:error, :linear_app_requires_human_assignee}
      true -> :ok
    end
  end

  def validate(_tracker), do: {:error, :invalid_linear_app_configuration}

  defp valid_assignees?(assignee, app_user) do
    (Config.yolo?() and Assignees.parse(assignee) == []) or Assignees.human?(assignee, app_user)
  end

  defp valid_issue_scope?(nil), do: true
  defp valid_issue_scope?(ids) when is_list(ids), do: Enum.all?(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
  defp valid_issue_scope?(_ids), do: false

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def format_status(status), do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})

  @impl true
  def handle_call({:token, binding, opts}, _from, state) do
    case Config.linear_client_secret(binding) do
      {:ok, secret} ->
        key = cache_key(binding, secret)
        now = Keyword.get(opts, :now, fn -> System.monotonic_time(:second) end).()
        {result, entry} = cached_token(state[key], binding, secret, now, opts)
        {:reply, result, Map.put(state, key, entry)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:invalidate, token}, _from, state) do
    {:reply, :ok, Map.reject(state, fn {_key, current} -> current[:access_token] == token.access_token end)}
  end

  @spec request(map(), map(), (map(), list() -> term()), keyword()) :: {:ok, map()} | {:error, term()}
  def request(tracker, payload, request_fun, opts \\ []) do
    opts = Keyword.put(opts, :assignee, tracker.assignee)

    with :ok <- validate(tracker),
         {:ok, cache} <- cache(Keyword.get(opts, :cache)),
         {:ok, token} <- verified_token(cache, tracker.app, request_fun, opts, true) do
      execute(cache, tracker.app, token, payload, request_fun, opts)
    end
  rescue
    _ -> {:error, :linear_app_runtime_failed}
  catch
    _, _ -> {:error, :linear_app_runtime_failed}
  end

  defp execute(cache, binding, token, payload, request_fun, opts) do
    journal = Keyword.get(opts, :journal, &CommentJournal.execute/4)
    secrets = [token.access_token, token.secret]
    request = &business_request(cache, token, request_fun, &1, secrets)
    # Redact before journal persistence, including caller-supplied text/context.
    journal.(binding, redact(payload, secrets), request, redact(Keyword.get(opts, :context, %{}), secrets))
  end

  defp business_request(cache, token, request_fun, payload, secrets) do
    result = redacted_request(request_fun, payload, headers(token), secrets)
    if match?({:ok, %{status: 401}}, result), do: GenServer.call(cache, {:invalidate, token})
    result
  end

  defp cache(nil) do
    case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp cache(pid), do: {:ok, pid}

  defp verified_token(cache, binding, request, opts, retry?) do
    with {:ok, token} <- GenServer.call(cache, {:token, binding, opts}, 30_000) do
      identity = verify_identity(token, binding, request, opts[:assignee])
      check_identity(identity, token, cache, binding, request, opts, retry?)
    end
  end

  defp check_identity(:ok, token, _cache, _binding, _request, _opts, _retry?), do: {:ok, token}

  defp check_identity({:error, :linear_app_token_expired}, token, cache, binding, request, opts, retry?) do
    :ok = GenServer.call(cache, {:invalidate, token})
    if retry?, do: verified_token(cache, binding, request, opts, false), else: {:error, :linear_app_identity_denied}
  end

  defp check_identity(error, _token, _cache, _binding, _request, _opts, _retry?), do: error

  defp cache_key(binding, secret), do: {binding, :crypto.hash(:sha256, secret)}

  defp cached_token(%{error: reason, retry_at: retry_at} = entry, _binding, _secret, now, _opts) when now < retry_at do
    {{:error, reason}, entry}
  end

  defp cached_token(%{expires_at: expires_at} = token, _binding, _secret, now, _opts)
       when expires_at > now + @expiry_margin do
    {{:ok, token}, token}
  end

  defp cached_token(_entry, binding, secret, now, opts) do
    case acquire(binding, secret, now, Keyword.get(opts, :token_request, &token_request/1)) do
      {:ok, token} -> {{:ok, token}, token}
      {:error, reason} = error -> {error, %{error: reason, retry_at: now + 30}}
    end
  end

  defp acquire(binding, secret, now, request) do
    form = %{"grant_type" => "client_credentials", "scope" => "read,write", "client_id" => binding["client_id"], "client_secret" => secret}

    case request.(form) do
      {:ok, %{status: 200, body: body}} -> parse_token(body, secret, now)
      {:ok, %{status: status}} when status in [400, 401, 403] -> {:error, :linear_app_credentials_denied}
      {:ok, %{status: 429}} -> {:error, :linear_app_rate_limited}
      _ -> {:error, :linear_app_token_unavailable}
    end
  rescue
    _ -> {:error, :linear_app_token_unavailable}
  catch
    _, _ -> {:error, :linear_app_token_unavailable}
  end

  defp parse_token(%{"access_token" => access, "token_type" => "Bearer", "expires_in" => ttl, "scope" => scope}, secret, now)
       when is_binary(access) and byte_size(access) > 0 and
              is_integer(ttl) and ttl > @expiry_margin and ttl <= 2_592_000 do
    if valid_scope?(scope),
      do: {:ok, %{access_token: access, secret: secret, expires_at: now + ttl}},
      else: {:error, :invalid_linear_app_token}
  end

  defp parse_token(_body, _secret, _now), do: {:error, :invalid_linear_app_token}

  defp valid_scope?(scope) when is_binary(scope), do: valid_scope?(String.split(scope, ~r/[ ,]+/, trim: true))
  defp valid_scope?(scope) when is_list(scope), do: Enum.sort(scope) == ["read", "write"]
  defp valid_scope?(_scope), do: false

  defp token_request(form) do
    Req.post("https://api.linear.app/oauth/token",
      form: form,
      retry: false,
      redirect: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 10_000]
    )
  end

  defp redacted_request(request_fun, payload, headers, secrets) do
    case safe_request(request_fun, payload, headers) do
      {:ok, response} -> {:ok, redact(response, secrets)}
      error -> error
    end
  end

  defp verify_identity(token, binding, request_fun, assignee) do
    case safe_request(request_fun, %{query: @identity_query, variables: %{}}, headers(token)) do
      {:ok, %{status: 200, body: body}} ->
        verify_viewer(body, binding, assignee)

      {:ok, %{status: 400, body: body}} when is_map(body) ->
        identity_error(body, :linear_app_identity_unavailable)

      {:ok, %{status: 403, body: body}} ->
        identity_error(body, :linear_app_identity_denied)

      {:ok, %{status: 401}} ->
        {:error, :linear_app_token_expired}

      {:ok, %{status: 403}} ->
        {:error, :linear_app_identity_denied}

      {:ok, %{status: 429}} ->
        {:error, :linear_app_rate_limited}

      _ ->
        {:error, :linear_app_identity_unavailable}
    end
  end

  defp verify_viewer(body, binding, assignee) do
    if rate_limited?(body), do: {:error, :linear_app_rate_limited}, else: match_viewer(body, binding, assignee)
  end

  defp identity_error(body, fallback) do
    if rate_limited?(body), do: {:error, :linear_app_rate_limited}, else: {:error, fallback}
  end

  defp match_viewer(%{"data" => %{"viewer" => %{"id" => user, "app" => true, "organization" => %{"id" => workspace}} = viewer}} = body, binding, assignee) do
    cond do
      user != binding["user_id"] or workspace != binding["workspace_id"] or Map.get(body, "errors", []) not in [nil, []] ->
        {:error, :linear_app_identity_mismatch}

      is_binary(viewer["email"]) and String.downcase(viewer["email"]) in Assignees.parse(assignee) ->
        {:error, :linear_app_requires_human_assignee}

      true ->
        :ok
    end
  end

  defp match_viewer(_body, _binding, _assignee), do: {:error, :linear_app_identity_unavailable}

  defp rate_limited?(body) do
    Enum.any?(Map.get(body, "errors") || [], &(get_in(&1, ["extensions", "code"]) == "RATELIMITED"))
  end

  defp safe_request(request_fun, payload, headers) do
    case request_fun.(payload, headers) do
      {:ok, response} -> {:ok, response}
      _ -> {:error, :linear_app_request_unavailable}
    end
  rescue
    _ -> {:error, :linear_app_request_unavailable}
  end

  defp headers(token), do: [{"Authorization", "Bearer " <> token.access_token}, {"Content-Type", "application/json"}]

  defp redact(value, secrets) when is_binary(value), do: String.replace(value, Enum.uniq(secrets), "[REDACTED]")
  defp redact(value, secrets) when is_list(value), do: Enum.map(value, &redact(&1, secrets))
  defp redact(%_{} = value, secrets), do: value |> Map.from_struct() |> redact(secrets)
  defp redact(value, secrets) when is_map(value), do: Map.new(value, fn {key, item} -> {redact(key, secrets), redact(item, secrets)} end)
  defp redact(value, _secrets), do: value

  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
end
