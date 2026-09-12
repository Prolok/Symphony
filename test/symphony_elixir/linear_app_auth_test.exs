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
      assert form == %{"grant_type" => "client_credentials", "scope" => "read,write", "client_id" => "client", "client_secret" => "synthetic-client-secret"}
      number = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      send(owner, {:token_issued, number})
      token_response("synthetic-token-#{number}")
    end

    tracker = %{
      auth_mode: "app",
      endpoint: "https://api.linear.app/graphql",
      assignee: "00000000-0000-4000-8000-000000000001",
      app: %{"client_secret_env" => name, "client_id" => "client", "workspace_id" => "workspace", "user_id" => "app", "state_root" => "/synthetic", "installation_id" => "synthetic"}
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
    assert {:error, :linear_app_identity_denied} = call(ctx, request: fn _, _ -> {:ok, %{status: 401}} end)
    assert_received {:token_issued, 3}
    refute_received {:token_issued, 4}
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
    for result <- [{:ok, %{status: 429}}, {:ok, %{status: 503}}, {:error, "synthetic-token-1"}] do
      request = fn payload, _ ->
        if payload.query =~ "SymphonyAppIdentity", do: identity(), else: result
      end

      expected = if elem(result, 0) == :error, do: {:error, :linear_app_request_unavailable}, else: result
      assert call(ctx, request: request) == expected
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
      assert {:error, ^expected} = call(ctx, token_request: fn _ -> response end, now: fn -> 200 + index * 31 end)
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

    for _ <- 1..5, do: assert({:error, :linear_app_rate_limited} = call(ctx, token_request: failing))
    assert_received :token_attempt
    refute_received :token_attempt
    assert {:ok, _} = call(ctx, now: fn -> 230 end)
    assert_received {:token_issued, 1}
  end

  test "unexpected journal errors return only a fixed public error", ctx do
    assert {:error, :linear_app_runtime_failed} = call(ctx, journal: fn _, _, _, _ -> raise "synthetic-token-1" end)
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
    for status <- [200, 400, 403, 429] do
      assert {:error, :linear_app_rate_limited} =
               call(ctx,
                 request: fn _, _ ->
                   {:ok, %{status: status, body: %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}}}
                 end
               )
    end

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

  defp call(ctx, opts \\ []) do
    request = Keyword.get(opts, :request, fn _, _ -> identity() end)

    AppAuth.request(
      ctx.tracker,
      %{query: "mutation { write }", variables: %{}},
      request,
      Keyword.merge(
        [cache: ctx.cache, token_request: ctx.token_request, now: fn -> 200 end, journal: fn _, payload, request, _ -> request.(payload) end],
        opts
      )
    )
  end

  defp token_response(token), do: {:ok, %{status: 200, body: %{"access_token" => token, "token_type" => "Bearer", "expires_in" => 2_591_999, "scope" => "read write"}}}
  defp identity, do: {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app", "app" => true, "organization" => %{"id" => "workspace"}}}}}}
end
