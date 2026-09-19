defmodule SymphonyElixir.LinearAppAuthTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.AppAuth

  setup do
    name = "SYMPHONY_TEST_SECRET_#{System.unique_integer([:positive])}"
    System.put_env(name, "synthetic-client-secret")
    on_exit(fn -> System.delete_env(name) end)
    cache = start_supervised!({AppAuth, []})
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    owner = self()

    token_request = fn form ->
      assert form == %{"grant_type" => "client_credentials", "scope" => "read,write", "client_id" => name, "client_secret" => "synthetic-client-secret"}
      number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:token_issued, number})
      token_response("synthetic-token-#{number}")
    end

    tracker = %{
      auth_mode: "app",
      endpoint: "https://api.linear.app/graphql",
      assignee: "00000000-0000-4000-8000-000000000001",
      app: %{"client_secret_env" => name, "client_id" => name, "workspace_id" => "workspace", "user_id" => "app", "state_root" => "/synthetic", "installation_id" => "synthetic"}
    }

    {:ok, tracker: tracker, cache: cache, token_request: token_request, counter: counter}
  end

  test "client credentials is the only auth contract and settings exclude credentials and removed provider fields" do
    assert {:ok, default} = Schema.parse(%{"tracker" => %{"api_key" => "synthetic-personal"}})
    assert default.tracker.auth_mode == "app"
    refute Map.has_key?(default.tracker, :api_key)
    assert {:error, _} = Schema.parse(%{"tracker" => %{"auth_mode" => "legacy"}})

    assert {:ok, app} =
             Schema.parse(%{
               "tracker" => %{
                 "auth_mode" => "app",
                 "api_key" => "synthetic-personal",
                 "app" => %{"client_secret_env" => "TEST_SECRET", "client_secret" => "synthetic-secret", "access_token" => "synthetic-token", "provider" => "removed"}
               }
             })

    refute Map.has_key?(app.tracker, :api_key)
    assert app.tracker.app["client_secret_env"] == "TEST_SECRET"
    assert app.tracker.app["installation_id"] == "symphony"
    refute inspect(app) =~ "synthetic-"
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"tracker" => %{"auth_mode" => "typo"}})
    assert {:error, {:invalid_workflow_config, _}} = Schema.parse(%{"tracker" => %{"app" => "invalid"}})
  end

  test "app requires a secret reference, explicit human scope and valid nonsecret binding", %{tracker: tracker} do
    assert :ok = AppAuth.validate(tracker)

    assert :ok = AppAuth.validate(%{tracker | assignee: "person@example.invalid"})

    for assignee <- [nil, "me", "ME", " me ", tracker.app["user_id"]] do
      assert {:error, :linear_app_requires_human_assignee} = AppAuth.validate(%{tracker | assignee: assignee})
    end

    for key <- ~w(client_secret_env workspace_id user_id client_id state_root installation_id) do
      assert {:error, :missing_linear_app_binding} = AppAuth.validate(%{tracker | app: Map.delete(tracker.app, key)})
    end

    for {key, value, error} <- [
          {"client_secret_env", "$INLINE=secret", :invalid_linear_client_secret_reference},
          {"state_root", "relative", :invalid_linear_app_state_root},
          {"installation_id", "../escape", :invalid_linear_installation_id},
          {"allowed_issue_ids", ["invalid"], :invalid_linear_app_issue_scope},
          {"allowed_issue_ids", "issue", :invalid_linear_app_issue_scope}
        ] do
      assert {:error, ^error} = AppAuth.validate(put_in(tracker, [:app, key], value))
    end

    for ids <- [[], [Ecto.UUID.generate()]], do: assert(:ok == AppAuth.validate(put_in(tracker, [:app, "allowed_issue_ids"], ids)))
    assert {:error, :invalid_linear_app_endpoint} = AppAuth.validate(%{tracker | endpoint: "https://example.com/graphql"})
    assert {:error, :invalid_linear_app_configuration} = AppAuth.validate(%{})
  end

  test "token cache is reused across callers in a runtime and renews at TTL", ctx do
    assert {:ok, _} = call(ctx)
    assert_received {:token_issued, 1}
    assert {:ok, _} = Task.async(fn -> call(ctx) end) |> Task.await()
    refute_received {:token_issued, 2}
    assert {:ok, _} = call(ctx, now: fn -> 2_592_080 end)
    assert_received {:token_issued, 2}
  end

  test "the authenticated app email cannot select the app as human assignee", ctx do
    tracker = %{ctx.tracker | assignee: " APP@example.invalid "}

    request = fn _, _ ->
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app", "app" => true, "email" => "app@example.invalid", "organization" => %{"id" => "workspace"}}}}}}
    end

    assert {:error, :linear_app_requires_human_assignee} = call(%{ctx | tracker: tracker}, request: request)
  end

  test "two independent runtime caches use the same identity without shared tokens", ctx do
    {:ok, other} = AppAuth.start_link()

    try do
      assert {:ok, _} = call(ctx)
      assert {:ok, _} = call(ctx, cache: other)
      assert_received {:token_issued, 1}
      assert_received {:token_issued, 2}
      assert {:ok, _} = call(ctx)
      refute_received {:token_issued, 3}
    after
      GenServer.stop(other)
    end
  end

  test "concurrent first callers acquire one token in the same runtime", ctx do
    1..8 |> Task.async_stream(fn _ -> call(ctx) end, max_concurrency: 8) |> Enum.each(fn result -> assert {:ok, {:ok, _}} = result end)
    assert_received {:token_issued, 1}
    refute_received {:token_issued, 2}
  end

  test "missing secret fails even after caching and never falls back", ctx do
    assert {:ok, _} = call(ctx)
    System.delete_env(ctx.tracker.app["client_secret_env"])
    assert {:error, :missing_linear_client_secret} = call(ctx)
    System.put_env(ctx.tracker.app["client_secret_env"], " ")
    assert {:error, :missing_linear_client_secret} = call(ctx)
  end

  test "wrong workspace, user, actor and GraphQL errors block every business request", ctx do
    for viewer <- [
          nil,
          %{"id" => "wrong", "app" => true, "organization" => %{"id" => "workspace"}},
          %{"id" => "app", "app" => true, "organization" => %{"id" => "wrong"}},
          %{"id" => "app", "app" => false, "organization" => %{"id" => "workspace"}}
        ] do
      request = fn payload, _ ->
        assert payload.query =~ "SymphonyAppIdentity"
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => viewer}}}}
      end

      assert {:error, _} = call(ctx, request: request)
    end

    assert {:error, :linear_app_identity_mismatch} =
             call(ctx,
               request: fn _, _ ->
                 {:ok, response} = identity()
                 {:ok, put_in(response, [:body, "errors"], [%{"message" => "denied"}])}
               end
             )
  end

  test "identity 401 permits exactly one new token and safe identity retry", ctx do
    request = fn payload, headers ->
      assert payload.query =~ "SymphonyAppIdentity"
      if {"Authorization", "Bearer synthetic-token-1"} in headers, do: {:ok, %{status: 401}}, else: identity()
    end

    assert {:ok, _} =
             call(ctx,
               request: fn payload, headers ->
                 if payload.query =~ "SymphonyAppIdentity", do: request.(payload, headers), else: identity()
               end
             )

    assert_received {:token_issued, 2}
    refute_received {:token_issued, 3}
    assert {:ok, %{status: 401}} = call(ctx, request: fn _, _ -> {:ok, %{status: 401}} end)
    assert {:error, :linear_app_identity_denied} = call(ctx, request: fn _, _ -> {:ok, %{status: 401}} end)
    assert_received {:token_issued, 3}
    assert_received {:token_issued, 4}
    refute_received {:token_issued, 5}
  end

  test "business 401 is returned once without mutation replay; next request obtains a new token", ctx do
    request = fn payload, _ ->
      if payload.query =~ "SymphonyAppIdentity" do
        identity()
      else
        send(self(), :mutation)
        {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
      end
    end

    assert {:ok, %{status: 401}} = call(ctx, request: request)
    assert_received :mutation
    refute_received :mutation
    assert {:ok, _} = call(ctx)
    assert_received {:token_issued, 2}
  end

  test "429, 5xx and lost business responses never replay or acquire extra tokens", ctx do
    for {result, index} <- Enum.with_index([{:ok, %{status: 429}}, {:ok, %{status: 503}}, {:error, "synthetic-token-1"}]) do
      request = fn payload, _ ->
        if payload.query =~ "SymphonyAppIdentity", do: identity(), else: result
      end

      expected = if elem(result, 0) == :error, do: {:error, :linear_app_request_unavailable}, else: result
      assert call(ctx, request: request, now: fn -> 200 + index * 31 end) == expected
    end

    assert_received {:token_issued, 1}
    refute_received {:token_issued, 2}
  end

  test "token errors and malformed TTL/scope/type are public and do not retry", ctx do
    for {{response, expected}, index} <-
          Enum.with_index([
            {{:ok, %{status: 400}}, :linear_app_credentials_denied},
            {{:ok, %{status: 401}}, :linear_app_credentials_denied},
            {{:ok, %{status: 403}}, :linear_app_credentials_denied},
            {{:ok, %{status: 429}}, :linear_app_rate_limited},
            {{:ok, %{status: 503}}, :linear_app_token_unavailable},
            {{:error, "synthetic-client-secret"}, :linear_app_token_unavailable}
          ]) do
      result = call(ctx, token_request: fn _ -> response end, now: fn -> 200 + index * 31 end)

      if expected == :linear_app_rate_limited,
        do: assert(match?({:error, {:linear_app_rate_limited, _}}, result)),
        else: assert(result == {:error, expected})
    end

    {:ok, response} = token_response("token")

    for {{key, bad}, index} <-
          Enum.with_index([
            {"scope", "read"},
            {"scope", ["read", "write", "admin"]},
            {"scope", nil},
            {"expires_in", 120},
            {"expires_in", 2_592_001},
            {"expires_in", "2592000"},
            {"access_token", ""},
            {"token_type", "Basic"}
          ]) do
      token_request = fn _ -> {:ok, put_in(response, [:body, key], bad)} end
      now = fn -> 1000 + index * 31 end
      assert {:error, :invalid_linear_app_token} = call(ctx, token_request: token_request, now: now)
    end

    for {fun, index} <- Enum.with_index([fn _ -> raise "synthetic-client-secret" end, fn _ -> throw("synthetic-client-secret") end]) do
      assert {:error, :linear_app_token_unavailable} = call(ctx, token_request: fun, now: fn -> 2000 + index * 31 end)
    end
  end

  test "token endpoint outages are bounded across concurrent callers and retry after cooldown", ctx do
    owner = self()

    failing = fn _ ->
      send(owner, :token_attempt)
      {:ok, %{status: 429}}
    end

    for _ <- 1..5, do: assert({:error, {:linear_app_rate_limited, _}} = call(ctx, token_request: failing))
    assert_received :token_attempt
    refute_received :token_attempt
    assert {:ok, _} = call(ctx, now: fn -> 230 end)
    assert_received {:token_issued, 1}
  end

  test "unexpected journal errors return only a fixed public error", ctx do
    assert {:error, :linear_app_runtime_failed} = call(ctx, journal: fn _, _, _, _ -> raise "synthetic-token-1" end)
  end

  test "unavailable request diagnostics retain safe transport reasons without retrying or leaking terms", ctx do
    owner = self()

    cases = [
      {fn -> {:error, %Req.TransportError{reason: :timeout}} end, "timeout"},
      {fn -> raise Req.TransportError, reason: :closed end, "closed"},
      {fn -> {:error, %Req.TransportError{reason: {:tls_alert, "synthetic-token-1"}}} end, "transport_error"},
      {fn -> {:error, "synthetic-token-1"} end, "returned_error"},
      {fn -> raise "synthetic-client-secret" end, "exception"},
      {fn -> {:invalid, "synthetic-token-1"} end, "unexpected_response"}
    ]

    for {failure, expected} <- cases do
      request = fn payload, _ ->
        if payload.query =~ "SymphonyAppIdentity" do
          identity()
        else
          send(owner, :business_request)
          failure.()
        end
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :linear_app_request_unavailable} = call(ctx, request: request)
        end)

      assert log =~ "Linear app request unavailable kind=write reason=#{expected} elapsed_ms="
      refute log =~ "synthetic-token"
      refute log =~ "synthetic-client-secret"
      assert_received :business_request
      refute_received :business_request
    end
  end

  test "old API scope array is accepted without changing requested scopes", ctx do
    assert {:ok, _} =
             call(ctx,
               token_request: fn _ ->
                 {:ok, response} = token_response("synthetic-token")
                 {:ok, put_in(response, [:body, "scope"], ["write", "read"])}
               end
             )
  end

  test "response, caller text, journal context and process diagnostics redact secrets", ctx do
    request = fn payload, _ ->
      if payload.query =~ "SymphonyAppIdentity", do: identity(), else: {:ok, %{status: 400, body: %{"synthetic-token-1" => ["synthetic-client-secret", %URI{host: "synthetic-token-1"}, 3]}}}
    end

    journal = fn _, payload, request, context ->
      refute inspect({payload, context}) =~ "synthetic-client-secret"
      request.(payload)
    end

    assert {:ok, %{body: %{"[REDACTED]" => ["[REDACTED]", %{host: "[REDACTED]"}, 3]}}} =
             call(ctx, request: request, journal: journal, context: %{"note" => "synthetic-client-secret"})

    status = :sys.get_status(ctx.cache) |> inspect()
    refute status =~ "synthetic-token"
    refute status =~ "synthetic-client-secret"
  end

  test "identity rate limits and errors stay distinct with no token churn", ctx do
    for {status, index} <- Enum.with_index([200, 400, 403, 429]) do
      assert {:error, {:linear_app_rate_limited, _}} =
               call(ctx,
                 rate_limit_now: fn -> 1_000_000 + index * 600_000 end,
                 request: fn _, _ ->
                   {:ok, %{status: status, body: %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}}}
                 end
               )
    end

    Process.put(:auth_rate_now, 4_000_000)

    for result <- [{:ok, %{status: 403}}, {:ok, %{status: 403, body: %{}}}] do
      assert {:error, :linear_app_identity_denied} = call(ctx, request: fn _, _ -> result end)
    end

    for body <- [%{}, "unavailable", nil] do
      request = fn _, _ -> {:ok, %{status: 400, body: body}} end
      assert {:error, :linear_app_identity_unavailable} = call(ctx, request: request)
    end

    for fun <- [fn _, _ -> {:error, "synthetic-token"} end, fn _, _ -> raise "synthetic-token" end] do
      assert {:error, :linear_app_identity_unavailable} = call(ctx, request: fun)
    end

    assert {:error, :linear_app_runtime_failed} = call(ctx, request: fn _, _ -> throw("synthetic-token") end)
    assert_received {:token_issued, 1}
    refute_received {:token_issued, 2}
  end

  test "confirmed retry-after survives another app cache and blocks identity and token requests", ctx do
    root = Path.join([File.cwd!(), "_build", "rate-limit-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    ctx = put_in(ctx, [:tracker, :app, "state_root"], root)
    now = 1_800_000_000_000

    request = fn _, _ ->
      {:ok, %{status: 403, headers: %{"retry-after" => ["3600"]}, body: %{}}}
    end

    assert {:error, {:linear_app_rate_limited, %{retry_at_ms: deadline}}} =
             call(ctx, request: request, rate_limit_now: fn -> now end)

    assert deadline == now + 3_600_000
    {:ok, cache} = AppAuth.start_link()
    ctx = %{ctx | cache: cache}
    ctx = put_in(ctx, [:tracker, :app, "state_root"], Path.join(root, "other-project/.symphony/state"))
    forbidden = fn _ -> flunk("token requested before retry-after") end

    denied_request = fn _, _ -> flunk("HTTP before retry-after") end
    retry_opts = [token_request: forbidden, request: denied_request, rate_limit_now: fn -> now + 5_000 end]
    assert {:error, {:linear_app_rate_limited, %{retry_at_ms: ^deadline}}} = call(ctx, retry_opts)

    assert {:ok, _} = call(ctx, rate_limit_now: fn -> deadline end)
  end

  test "token cooldown and errors observed inside the guarded request preserve their classification", ctx do
    deadline = %{retry_at_ms: 1_800_003_600_000, retry_after_ms: 3_600_000}
    limited = {:error, {:linear_app_rate_limited, deadline}}
    assert ^limited = call(ctx, request: fn _, _ -> limited end)

    assert {:error, :linear_rate_limit_state_unavailable} =
             call(ctx, request: fn _, _ -> {:error, :linear_rate_limit_state_unavailable} end)

    {:ok, cache} = AppAuth.start_link()
    assert ^limited = call(%{ctx | cache: cache}, token_request: fn _ -> limited end)

    root = Path.join([File.cwd!(), "_build", "token-cooldown-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    ctx = put_in(ctx, [:tracker, :app, "state_root"], root)
    now = 1_800_000_000_000
    token_request = fn _ -> {:ok, %{status: 429, headers: %{"retry-after" => "3600"}}} end
    assert ^limited = call(ctx, token_request: token_request, rate_limit_now: fn -> now end)
    assert ^limited = call(ctx, token_request: fn _ -> flunk("token request before cooldown") end, rate_limit_now: fn -> now end)
  end

  test "verified identity is shared by eight callers and renewed exactly at the expiry margin", ctx do
    owner = self()

    request = fn payload, _ ->
      if payload.query =~ "SymphonyAppIdentity", do: send(owner, :identity_checked)
      identity()
    end

    tasks = for _ <- 1..8, do: Task.async(fn -> call(ctx, request: request) end)
    for task <- tasks, do: assert({:ok, _} = Task.await(task))
    assert_received :identity_checked
    refute_received :identity_checked
    assert {:ok, _} = call(ctx, request: request, now: fn -> 2_592_078 end)
    refute_received :identity_checked
    assert {:ok, _} = call(ctx, request: request, now: fn -> 2_592_079 end)
    assert_received :identity_checked
    assert_received {:token_issued, 2}
  end

  test "cached app email is checked against every current assignee and missing credentials discard proof", ctx do
    owner = self()

    request = fn payload, _ ->
      if payload.query =~ "SymphonyAppIdentity", do: send(owner, :identity_checked), else: send(owner, :business)
      {:ok, response} = identity()
      {:ok, put_in(response, [:body, "data", "viewer", "email"], "app@example.invalid")}
    end

    assert {:ok, _} = call(ctx, request: request)
    assert_received :identity_checked
    assert_received :business
    selected = %{ctx | tracker: %{ctx.tracker | assignee: "APP@example.invalid"}}
    assert {:error, :linear_app_requires_human_assignee} = call(selected, request: request)
    refute_received :business
    System.delete_env(ctx.tracker.app["client_secret_env"])
    assert {:error, :missing_linear_client_secret} = call(ctx, request: request)
    System.put_env(ctx.tracker.app["client_secret_env"], "synthetic-client-secret")
    assert {:ok, _} = call(ctx, request: request)
    assert_received {:token_issued, 2}
    assert_received :identity_checked
  end

  test "scope changes require their own verified token and wrong workspace or actor never reaches business", ctx do
    owner = self()

    request = fn payload, _ ->
      if payload.query =~ "SymphonyAppIdentity", do: send(owner, :identity_checked), else: send(owner, :business)
      identity()
    end

    assert {:ok, _} = call(ctx, request: request)
    assert_received :identity_checked
    assert_received :business

    for {key, value} <- [{"allowed_issue_ids", [Ecto.UUID.generate()]}, {"state_root", "/another-synthetic"}] do
      assert {:ok, _} = call(put_in(ctx, [:tracker, :app, key], value), request: request)
      assert_received :identity_checked
      assert_received :business
    end

    for {key, value} <- [{"workspace_id", "wrong"}, {"user_id", "wrong"}] do
      assert {:error, :linear_app_identity_mismatch} = call(put_in(ctx, [:tracker, :app, key], value), request: request)
      refute_received :business
    end
  end

  test "a credential rotation while identity is in flight cannot authorize the old generation", ctx do
    owner = self()

    task =
      Task.async(fn ->
        call(ctx,
          token_request: fn _ -> token_response("same-token-text") end,
          request: fn payload, _ ->
            assert payload.query =~ "SymphonyAppIdentity"
            send(owner, {:verifying, self()})

            receive do
              :continue -> identity()
            end
          end
        )
      end)

    assert_receive {:verifying, worker}
    System.put_env(ctx.tracker.app["client_secret_env"], "rotated-synthetic-secret")
    send(worker, :continue)
    assert {:error, :linear_app_identity_unavailable} = Task.await(task)
    assert {:ok, _} = call(ctx, token_request: fn _ -> token_response("same-token-text") end)
  end

  test "business errors discard verification without replay and 403 invalidates the token", ctx do
    owner = self()

    for {response, index} <- Enum.with_index([{:ok, %{status: 503}}, {:error, :offline}, {:ok, %{status: 403}}]) do
      request = fn payload, _ ->
        if payload.query =~ "SymphonyAppIdentity" do
          send(owner, :identity_checked)
          identity()
        else
          send(owner, :business)
          response
        end
      end

      call(ctx, request: request, now: fn -> 200 + index end)
      assert_received :identity_checked
      assert_received :business
      refute_received :business
    end

    assert {:ok, _} = call(ctx)
    assert_received {:token_issued, 2}
  end

  test "temporary token provider failures are cached without being treated as authentication errors", ctx do
    parent = self()

    request = fn _ ->
      send(parent, :token_attempt)
      {:ok, %{status: 503}}
    end

    for now <- [200, 201, 229] do
      assert {:error, :linear_app_token_unavailable} = call(ctx, now: fn -> now end, token_request: request)
    end

    assert_received :token_attempt
    refute_received :token_attempt
    assert {:ok, _} = call(ctx, now: fn -> 230 end)
    assert_received {:token_issued, 1}
  end

  defp call(ctx, opts \\ []) do
    request = Keyword.get(opts, :request, fn _, _ -> identity() end)
    rate_now = Process.get(:auth_rate_now, Keyword.get(opts, :now, fn -> 200 end).() * 1_000)

    AppAuth.request(
      ctx.tracker,
      %{query: "mutation { write }", variables: %{}},
      request,
      Keyword.merge(
        [
          rate_limit_now: fn -> rate_now end,
          rate_limit_jitter: fn _ -> 0 end,
          cache: ctx.cache,
          token_request: ctx.token_request,
          now: fn -> 200 end,
          journal: fn _, payload, request, _ -> request.(payload) end
        ],
        opts
      )
    )
  end

  defp token_response(token), do: {:ok, %{status: 200, body: %{"access_token" => token, "token_type" => "Bearer", "expires_in" => 2_591_999, "scope" => "read write"}}}
  defp identity, do: {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app", "app" => true, "organization" => %{"id" => "workspace"}}}}}}
end
