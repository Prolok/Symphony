defmodule SymphonyElixir.LinearAppHttpTest do
  use ExUnit.Case
  alias SymphonyElixir.Linear.AppAuth

  test "native token HTTP uses client credentials, fixed scopes and endpoint with no persistence" do
    previous = Req.default_options()
    name = "SYMPHONY_TEST_HTTP_SECRET"
    System.put_env(name, "synthetic-secret")

    on_exit(fn ->
      Req.default_options(previous)
      System.delete_env(name)
    end)

    owner = self()

    Req.default_options(
      plug: fn conn ->
        assert conn.host == "api.linear.app"
        assert conn.request_path == "/oauth/token"
        assert conn.method == "POST"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body) == %{"client_id" => "client", "grant_type" => "client_credentials", "scope" => "read,write", "client_secret" => "synthetic-secret"}
        send(owner, :token_request)
        Req.Test.json(conn, %{"access_token" => "synthetic-app", "token_type" => "Bearer", "expires_in" => 2_591_999, "scope" => "read write"})
      end
    )

    binding = %{"client_secret_env" => name, "workspace_id" => "workspace", "user_id" => "app", "client_id" => "client", "state_root" => Path.join(File.cwd!(), "_build"), "installation_id" => "test"}
    tracker = %{auth_mode: "app", app: binding, endpoint: "https://api.linear.app/graphql", assignee: "07fed51a-0ba0-4314-9179-a62cfb3af28d"}

    request = fn _, headers ->
      assert {"Authorization", "Bearer synthetic-app"} in headers
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app", "app" => true, "organization" => %{"id" => "workspace"}}}}}}
    end

    for _ <- 1..2, do: assert({:ok, _} = AppAuth.request(tracker, %{"query" => "{viewer{id}}"}, request))
    assert_received :token_request
    refute_received :token_request
  end
end
