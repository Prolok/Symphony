defmodule SymphonyElixir.RelayClientTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Relay.{Client, Config, Contract}

  @relay %{"endpoint" => "https://relay.example", "key_env" => "RELAY_TEST_SECRET"}
  defp key, do: [key: fn -> {:ok, "synthetic-workspace-key"} end]

  test "native HTTP binds the bearer key, bounded streaming, methods and paths; redirects stay disabled" do
    for {operation, method, suffix, body} <- [
          {:register, "PUT", "", %{"kind" => "symphony", "assigneeIds" => ["human"]}},
          {:poll, "GET", "/events", nil},
          {:ack, "POST", "/ack", %{"receipt" => "receipt"}},
          {:resync, "POST", "/resync", %{"phase" => "begin"}}
        ] do
      http = fn opts ->
        assert opts[:redirect] == false
        assert opts[:retry] == false
        assert opts[:receive_timeout] == 5_000

        Req.request(
          Keyword.put(opts, :plug, fn conn ->
            assert conn.method == method
            assert conn.request_path == "/v1/consumers/one" <> suffix
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer synthetic-workspace-key"]
            {:ok, bytes, conn} = Plug.Conn.read_body(conn)
            assert if(body, do: Jason.decode!(bytes), else: nil) == body
            Req.Test.json(conn, %{"version" => 1})
          end)
        )
      end

      assert {:ok, %{"version" => 1}} = Client.request(@relay, %{}, "one", operation, body, key() ++ [http: http])
    end
  end

  test "missing or wrong key and malformed endpoints never reach a foreign workspace" do
    missing = fn -> {:error, :relay_key_unavailable} end
    assert {:error, :relay_key_unavailable} = Client.request(@relay, %{}, "one", :poll, nil, key: missing)

    for endpoint <- [nil, "http://relay.example", "https://user:password@relay.example", "https://relay.example?key=foo", "https://relay.example#fragment"] do
      refute Config.endpoint?(endpoint)
      assert {:error, :invalid_relay_binding} = Client.request(%{"endpoint" => endpoint}, %{}, "one", :poll, nil, key())
    end

    assert {:error, :invalid_relay_binding} = Client.request(@relay, %{}, "../other", :poll, nil, key())

    assert {:error, {:relay_http, 401, "unauthorized"}} =
             Client.request(@relay, %{}, "one", :poll, nil, key() ++ [http: fn _ -> {:ok, %{status: 401, body: ~s({"version":1,"error":"unauthorized"})}} end])
  end

  test "oversized bodies, unknown versions, malformed JSON, exceptions and disconnects are sanitized" do
    outcomes = [
      {{:ok, %{status: 200, body: ~s({"version":2})}}, :relay_upgrade_required},
      {{:ok, %{status: 200, body: "secret-provider-text"}}, :invalid_relay_response},
      {{:ok, %{status: 503, body: ~s({"version":1,"error":"secret-provider-text"})}}, {:relay_http, 503, "unknown"}},
      {{:error, "synthetic-workspace-key"}, :relay_transport_unavailable},
      {{:ok, %{status: 200, body: String.duplicate("x", 524_289)}}, :relay_transport_unavailable}
    ]

    for {response, error} <- outcomes do
      assert {:error, ^error} = Client.request(@relay, %{}, "one", :poll, nil, key() ++ [http: fn _ -> response end])
    end

    for http <- [fn _ -> raise "secret" end, fn _ -> exit(:secret) end] do
      assert {:error, :relay_transport_unavailable} = Client.request(@relay, %{}, "one", :poll, nil, key() ++ [http: http])
    end

    http = fn opts ->
      {_, response} =
        case opts[:into].({:data, String.duplicate("x", 524_289)}, {Req.new(), Req.Response.new(body: "")}) do
          {:halt, pair} -> pair
        end

      {:ok, response}
    end

    assert {:error, :relay_response_too_large} = Client.request(@relay, %{}, "one", :poll, nil, key() ++ [http: http])
  end

  test "loopback HTTP is enabled only by the explicit local test transport option" do
    relay = %{"endpoint" => "http://127.0.0.1:1234"}
    assert {:error, :invalid_relay_binding} = Client.request(relay, %{}, "one", :poll, nil, key())
    http = fn _ -> {:ok, %{status: 200, body: ~s({"version":1})}} end
    assert {:ok, _} = Client.request(relay, %{}, "one", :poll, nil, key() ++ [allow_loopback: true, http: http])
  end

  test "consumer, generation, subscription and page positions are verified against local binding" do
    view = %{
      "version" => 1,
      "consumerId" => "one",
      "subscription" => %{"kind" => "symphony", "assigneeIds" => ["human"]},
      "generation" => "generation",
      "cursor" => 0,
      "status" => "snapshot_required",
      "snapshotToken" => "token",
      "snapshotExpiresAt" => 10,
      "retentionMs" => 20
    }

    assert :ok = Contract.consumer(view, "one", view["subscription"])

    for bad <- [Map.put(view, "consumerId", "two"), Map.put(view, "version", 2), Map.put(view, "generation", "../")],
        do: assert({:error, :invalid_relay_response} = Contract.consumer(bad, "one", view["subscription"]))

    page = %{"version" => 1, "generation" => "generation", "events" => [], "receipt" => nil, "scannedThrough" => 0, "head" => 0, "retentionMs" => 20}
    assert :ok = Contract.page(page, "workspace", "generation", 0)

    for bad <- [Map.put(page, "generation", "other"), Map.put(page, "head", -1), Map.put(page, "scannedThrough", 101), Map.put(page, "events", [nil])],
        do: assert({:error, :invalid_relay_response} = Contract.page(bad, "workspace", "generation", 0))

    assert :ok = Contract.ack(%{"version" => 1, "cursor" => 2}, 2)
    assert {:error, :invalid_relay_response} = Contract.ack(%{"version" => 1, "cursor" => 3}, 2)

    delivered = %{page | "receipt" => "receipt", "scannedThrough" => 1, "head" => 1}

    event = %{
      "version" => 1,
      "workspaceId" => "workspace",
      "eventId" => "event",
      "position" => 1,
      "broadcast" => true,
      "acceptedAt" => 1,
      "publishedAt" => 1,
      "assigneeIds" => [],
      "signal" => "unknown"
    }

    for events <- [[nil], [event]],
        do: assert({:error, :invalid_relay_response} = Contract.page(%{delivered | "events" => events}, "workspace", "generation", 0))
  end

  test "the same consumer name under two workspace keys has independent scope; invalid keys cannot create consumers" do
    server = start_supervised!(SymphonyElixir.RelayFixture)
    subscription = %{"kind" => "symphony", "assigneeIds" => ["human"]}
    http = fn opts -> Req.request(Keyword.put(opts, :plug, &SymphonyElixir.RelayFixture.http(&1, server, %{"key-one" => "one", "key-two" => "two"}))) end

    request = fn key ->
      opts = [key: fn -> {:ok, key} end, http: http]
      Client.request(@relay, %{}, "consumer", :register, subscription, opts)
    end

    assert {:error, {:relay_http, 401, "unauthorized"}} = request.("wrong")
    assert SymphonyElixir.RelayFixture.calls(server) == []
    assert {:ok, one} = request.("key-one")
    assert {:ok, two} = request.("key-two")
    assert one["generation"] != two["generation"]
    assert SymphonyElixir.RelayFixture.consumer(server, "one", "consumer") != nil
    assert SymphonyElixir.RelayFixture.consumer(server, "two", "consumer") != nil
  end
end
