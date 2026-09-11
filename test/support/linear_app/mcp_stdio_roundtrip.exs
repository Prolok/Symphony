# No bootstrap/env loading, application startup, HTTP client or model network.
expected = System.argv() |> List.first() |> Base.decode64!()

client = fn query, variables, [] ->
  case query do
    "mutation Create($body: String!) { fixtureCreate(body: $body) { body } }" ->
      ^expected = variables["body"]
      Process.put(:fixture_body, variables["body"])
      {:ok, %{"data" => %{"body" => variables["body"]}}}

    "query { fixture { body } }" ->
      {:ok, %{"data" => %{"body" => Process.get(:fixture_body)}}}
  end
end

SymphonyElixir.Codex.MCPServer.main([], bootstrap_fun: fn -> :ok end, linear_client: client)
