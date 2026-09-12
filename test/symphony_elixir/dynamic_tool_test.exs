defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Codex.LinearGraphqlTool

  test "tool_specs advertises the linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql"
             },
             %{"name" => "symphony_comments"},
             %{"name" => "symphony_merge"}
           ] = DynamicTool.tool_specs()

    assert description =~ "Linear"
  end

  test "unsupported tools return a failure payload with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql", "symphony_comments", "symphony_merge"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "linear_graphql returns successful GraphQL responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "linear_graphql accepts the symphony_linear MCP server-qualified name" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "symphony_linear.linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_alias"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
    assert Jason.decode!(response["output"]) == %{"data" => %{"viewer" => %{"id" => "usr_alias"}}}
  end

  test "linear_graphql accepts a raw GraphQL query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql ignores legacy operationName arguments" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_789"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "linear_graphql passes multi-operation documents through unchanged" do
    test_pid = self()

    query = """
    query Viewer { viewer { id } }
    query Teams { teams { nodes { id } } }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        linear_client: fn forwarded_query, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded_query, variables, opts})
          {:ok, %{"errors" => [%{"message" => "Must provide operation name if query contains multiple operations."}]}}
        end
      )

    assert_received {:linear_client_called, forwarded_query, %{}, []}
    assert forwarded_query == String.trim(query)
    assert response["success"] == false
  end

  test "linear_graphql rejects blank raw query strings even when using the default client" do
    response = DynamicTool.execute("linear_graphql", "   ")

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }
  end

  test "linear_graphql marks GraphQL error responses as failures while preserving the body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }
  end

  test "linear_graphql marks atom-key GraphQL error responses as failures" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert response["success"] == false
  end

  test "linear_graphql validates required arguments before calling Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"variables" => %{"commentId" => "comment-1"}},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` requires a non-empty `query` string."
             }
           }

    blank_query =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "   "},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when the query is blank")
        end
      )

    assert blank_query["success"] == false
  end

  test "linear_graphql rejects invalid argument types" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        [:not, :valid],
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when arguments are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
             }
           }
  end

  test "linear_graphql rejects invalid variables" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "variables" => ["bad"]},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when variables are invalid")
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "`linear_graphql.variables` must be a JSON object when provided."
             }
           }
  end

  test "linear_graphql formats transport and auth failures" do
    missing_token =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :missing_linear_api_token} end
      )

    assert missing_token["success"] == false

    assert Jason.decode!(missing_token["output"]) == %{
             "error" => %{
               "message" => "Symphony benötigt die projektgebundene Linear-App-Konfiguration und OAuth2 Client Credentials in .symphony/.env(.local)."
             }
           }

    status_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_status, 503}} end
      )

    assert Jason.decode!(status_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 503.",
               "status" => 503
             }
           }

    request_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, {:linear_api_request, :timeout}} end
      )

    assert Jason.decode!(request_error["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed before receiving a successful response.",
               "reason" => ":timeout"
             }
           }
  end

  test "linear client enriches HTTP 400, 401, 403, and rate-limit responses" do
    cases = [
      {400, %{"errors" => [%{"message" => "Unknown field", "extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}}]}, [], "graphql", ["GRAPHQL_VALIDATION_FAILED"]},
      {401, %{"errors" => [%{"message" => "Unauthorized", "extensions" => %{"code" => "UNAUTHENTICATED"}}]}, [], "auth", ["UNAUTHENTICATED"]},
      {403, %{"errors" => [%{"message" => "Forbidden", "extensions" => %{"code" => "FORBIDDEN"}}]}, [], "auth", ["FORBIDDEN"]},
      {403, %{"errors" => [%{"message" => "Forbidden with budget", "extensions" => %{"code" => "FORBIDDEN"}}]}, [{"x-ratelimit-requests-remaining", "42"}], "auth", ["FORBIDDEN"]},
      {403, %{"errors" => [%{"message" => "Rate limit retry"}]}, [{"retry-after", "12"}], "rate_limited", []},
      {403, %{"errors" => [%{"message" => "Rate limit remaining"}]}, [{"x-ratelimit-remaining", "0"}], "rate_limited", []},
      {403, %{"errors" => [%{"message" => "Linear rate limit remaining"}]},
       [
         {"x-ratelimit-requests-remaining", "0"},
         {"x-ratelimit-endpoint-requests-remaining", "0.0"},
         {"x-ratelimit-complexity-remaining", "42"}
       ], "rate_limited", []},
      {403, %{"errors" => [%{"message" => "Rate limited", "extensions" => %{"code" => "RATELIMITED"}}]}, [{"retry-after", "12"}], "rate_limited", ["RATELIMITED"]},
      {429, %{"errors" => [%{"message" => "Too many requests", "extensions" => %{"code" => "RATELIMITED"}}]}, [{"retry-after", "12"}, {"x-ratelimit-remaining", "0"}], "rate_limited", ["RATELIMITED"]}
    ]

    Enum.each(cases, fn {status, body, headers, classification, codes} ->
      capture_log(fn ->
        SymphonyElixir.TestSupport.stub_linear_client(fn _payload, _headers ->
          {:ok, %{status: status, body: body, headers: headers}}
        end)

        assert {:error, {:linear_api_status, ^status, diagnostics}} =
                 Client.graphql("query Viewer { viewer { id } }", %{})

        assert diagnostics.status == status
        assert diagnostics.classification == classification
        assert diagnostics.extensions_codes == codes
        assert diagnostics.errors == body["errors"]
        assert diagnostics.body_excerpt =~ hd(body["errors"])["message"]

        if classification == "rate_limited" do
          assert diagnostics.rate_limit["limited"] == true
        else
          refute diagnostics.rate_limit["limited"] == true
        end

        Enum.each(headers, fn {header_name, header_value} ->
          assert diagnostics.rate_limit[header_name] == header_value
        end)
      end)
    end)
  end

  test "linear_graphql formats enriched HTTP diagnostics" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:error,
           {:linear_api_status, 401,
            %{
              status: 401,
              classification: "auth",
              body_excerpt: ~s({"errors":[{"message":"Unauthorized"}]}),
              errors: [%{"message" => "Unauthorized", "extensions" => %{"code" => "UNAUTHENTICATED"}}],
              extensions_codes: ["UNAUTHENTICATED"],
              rate_limit: %{}
            }}}
        end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL request failed with HTTP 401 (auth/permission).",
               "status" => 401,
               "classification" => "auth",
               "bodyExcerpt" => ~s({"errors":[{"message":"Unauthorized"}]}),
               "errors" => [%{"message" => "Unauthorized", "extensions" => %{"code" => "UNAUTHENTICATED"}}],
               "extensionsCodes" => ["UNAUTHENTICATED"]
             }
           }

    forbidden =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:error,
           {:linear_api_status, 403,
            %{
              status: 403,
              classification: "auth",
              body_excerpt: "Forbidden",
              errors: [%{"message" => "Forbidden", "extensions" => %{"code" => "FORBIDDEN"}}],
              extensions_codes: ["FORBIDDEN"],
              rate_limit: %{}
            }}}
        end
      )

    assert get_in(Jason.decode!(forbidden["output"]), ["error", "status"]) == 403
    assert get_in(Jason.decode!(forbidden["output"]), ["error", "extensionsCodes"]) == ["FORBIDDEN"]

    schema_error =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:error,
           {:linear_api_status, 400,
            %{
              status: 400,
              classification: "graphql",
              body_excerpt: "Unknown field",
              errors: [%{"message" => "Unknown field", "extensions" => %{"code" => "GRAPHQL_VALIDATION_FAILED"}}],
              extensions_codes: ["GRAPHQL_VALIDATION_FAILED"],
              rate_limit: %{}
            }}}
        end
      )

    assert get_in(Jason.decode!(schema_error["output"]), ["error", "message"]) ==
             "Linear GraphQL request failed with HTTP 400."

    rate_limited =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:error,
           {:linear_api_status, 429,
            %{
              status: 429,
              classification: "rate_limited",
              body_excerpt: "Too many requests",
              errors: [%{"message" => "Too many requests", "extensions" => %{"code" => "RATELIMITED"}}],
              extensions_codes: ["RATELIMITED"],
              rate_limit: %{"limited" => true, "retry-after" => "30"}
            }}}
        end
      )

    decoded_rate_limit = Jason.decode!(rate_limited["output"])
    assert get_in(decoded_rate_limit, ["error", "message"]) =~ "rate limited"
    assert get_in(decoded_rate_limit, ["error", "rateLimit", "limited"]) == true
    assert get_in(decoded_rate_limit, ["error", "rateLimit", "retry-after"]) == "30"
  end

  test "linear_graphql formats unexpected failures from the client" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:error, :boom} end
      )

    assert response["success"] == false

    assert Jason.decode!(response["output"]) == %{
             "error" => %{
               "message" => "Linear GraphQL tool execution failed.",
               "reason" => ":boom"
             }
           }
  end

  test "linear_graphql falls back to inspect for non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  test "linear_graphql direct entry points support their default option arities" do
    assert LinearGraphqlTool.tool_name() == "linear_graphql"
    assert LinearGraphqlTool.canonical_tool_name(" linear_graphql ") == "linear_graphql"
    assert LinearGraphqlTool.canonical_tool_name("symphony_linear.linear_graphql") == "linear_graphql"
    assert LinearGraphqlTool.canonical_tool_name("not_linear_graphql") == nil
    assert LinearGraphqlTool.canonical_tool_name(nil) == nil
    assert LinearGraphqlTool.mcp_tool()["name"] == "linear_graphql"

    assert LinearGraphqlTool.execute("   ") == %{
             "success" => false,
             "output" => "{\n  \"error\": {\n    \"message\": \"`linear_graphql` requires a non-empty `query` string.\"\n  }\n}",
             "contentItems" => [
               %{
                 "type" => "inputText",
                 "text" => "{\n  \"error\": {\n    \"message\": \"`linear_graphql` requires a non-empty `query` string.\"\n  }\n}"
               }
             ]
           }

    assert LinearGraphqlTool.mcp_call(%{"query" => "   "}) == %{
             "content" => [
               %{
                 "type" => "text",
                 "text" => "{\n  \"error\": {\n    \"message\": \"`linear_graphql` requires a non-empty `query` string.\"\n  }\n}"
               }
             ],
             "isError" => true
           }

    assert LinearGraphqlTool.invoke(%{"query" => "   "}) == {
             :error,
             %{
               "error" => %{
                 "message" => "`linear_graphql` requires a non-empty `query` string."
               }
             }
           }
  end
end
