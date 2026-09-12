defmodule SymphonyElixir.Codex.MCPServerTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias SymphonyElixir.Codex.MCPServer
  alias SymphonyElixir.Workflow

  test "real stdio preserves UTF-8 bytes for escaped and literal JSON in both directions" do
    code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    helper = Path.expand("../support/linear_app/mcp_stdio_roundtrip.py", __DIR__)
    {output, status} = System.cmd(System.find_executable("python3"), [helper, System.find_executable("elixir")] ++ code_paths, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "framing and EOF passed"
  end

  test "an explicitly selected stderr device preserves Unicode response IDs" do
    request = %{"jsonrpc" => "2.0", "id" => "Grüße 😀", "method" => "ping"}
    {:ok, input} = StringIO.open(Jason.encode!(request) <> "\n")
    output = capture_io(:stderr, fn -> MCPServer.run([], input: input, output: :stderr) end)
    assert Jason.decode!(output) == %{"jsonrpc" => "2.0", "id" => "Grüße 😀", "result" => %{}}
  end

  test "main bootstraps before running the server loop" do
    test_pid = self()

    assert :ok =
             MCPServer.main(["--stdio"],
               bootstrap_fun: fn ->
                 send(test_pid, :bootstrapped)
                 :ok
               end,
               run_fun: fn args, opts ->
                 send(test_pid, {:ran, args, opts})
                 :ok
               end
             )

    assert_received :bootstrapped
    assert_received {:ran, ["--stdio"], []}
  end

  test "main and run support their stdio default arities" do
    previous_source_repo = System.get_env("SYMPHONY_SOURCE_REPO")
    previous_workflow_file = System.get_env("SYMPHONY_WORKFLOW_FILE")

    on_exit(fn ->
      restore_env("SYMPHONY_SOURCE_REPO", previous_source_repo)
      restore_env("SYMPHONY_WORKFLOW_FILE", previous_workflow_file)
    end)

    System.put_env("SYMPHONY_SOURCE_REPO", File.cwd!())
    System.put_env("SYMPHONY_WORKFLOW_FILE", Workflow.workflow_file_path())

    # OTP's binary get_line uses an atom prompt; StringIO cannot capture it.
    # MCP has no prompts, so exercise the byte stream without prompt capture.
    assert capture_io([input: "", capture_prompt: false], fn -> assert :ok = MCPServer.main() end) == ""

    assert capture_io([input: ~s({"jsonrpc":"2.0","id":12,"method":"ping"}\n), capture_prompt: false], fn ->
             assert :ok = MCPServer.run()
           end) == "{\"id\":12,\"jsonrpc\":\"2.0\",\"result\":{}}\n"
  end

  test "main reports bootstrap failures using the formatted reason" do
    cases = [
      {{:invalid_env_file, "/tmp/.env", 7, :badarg}, "/tmp/.env:7: :badarg"},
      {{:env_file_read_failed, "/tmp/.env", :enoent}, "/tmp/.env: :enoent"},
      {:boom, ":boom"}
    ]

    Enum.each(cases, fn {reason, expected_message} ->
      assert capture_io(:stderr, fn ->
               assert catch_throw(
                        MCPServer.main([],
                          bootstrap_fun: fn -> {:error, reason} end,
                          halt_fun: fn exit_code -> throw({:halt, exit_code}) end
                        )
                      ) == {:halt, 1}
             end) =~ "sym-codex-mcp: #{expected_message}"
    end)
  end

  test "initialize returns the negotiated protocol version and tool capability" do
    response =
      MCPServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{}
      })

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{
                 "name" => "symphony-linear",
                 "version" => to_string(Application.spec(:symphony_elixir, :vsn) || "0.1.0")
               }
             }
           }
  end

  test "notifications/initialized does not emit a response" do
    assert MCPServer.handle_request(%{
             "jsonrpc" => "2.0",
             "method" => "notifications/initialized"
           }) == nil
  end

  test "ping returns an empty result and notifications without ids stay silent" do
    assert MCPServer.handle_request(%{
             "jsonrpc" => "2.0",
             "id" => 99,
             "method" => "ping"
           }) == %{
             "jsonrpc" => "2.0",
             "id" => 99,
             "result" => %{}
           }

    assert MCPServer.handle_request(%{
             "jsonrpc" => "2.0",
             "method" => "not-a-real-notification"
           }) == nil
  end

  test "tools/list exposes the shared Linear, comment and bound merge tools" do
    response =
      MCPServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/list",
        "params" => %{}
      })

    assert [
             %{
               "name" => "linear_graphql",
               "description" => description,
               "inputSchema" => %{
                 "type" => "object",
                 "required" => ["query"],
                 "properties" => %{
                   "query" => _query,
                   "variables" => _variables
                 }
               }
             },
             %{"name" => "symphony_comments"},
             %{"name" => "symphony_merge"}
           ] = get_in(response, ["result", "tools"])

    assert description =~ "Linear"
  end

  test "tools/call forwards to linear_graphql and returns text content" do
    response =
      MCPServer.handle_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "linear_graphql",
            "arguments" => %{
              "query" => "query Viewer { viewer { id } }",
              "variables" => %{"includeTeams" => false}
            }
          }
        },
        linear_client: fn query, variables, opts ->
          assert query == "query Viewer { viewer { id } }"
          assert variables == %{"includeTeams" => false}
          assert opts == []
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert response == %{
             "jsonrpc" => "2.0",
             "id" => 3,
             "result" => %{
               "content" => [
                 %{
                   "type" => "text",
                   "text" => "{\n  \"data\": {\n    \"viewer\": {\n      \"id\": \"usr_123\"\n    }\n  }\n}"
                 }
               ],
               "isError" => false
             }
           }
  end

  test "tools/call accepts the symphony_linear MCP server-qualified name" do
    response =
      MCPServer.handle_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 31,
          "method" => "tools/call",
          "params" => %{
            "name" => "symphony_linear.linear_graphql",
            "arguments" => %{"query" => "query Viewer { viewer { id } }"}
          }
        },
        linear_client: fn query, variables, opts ->
          assert query == "query Viewer { viewer { id } }"
          assert variables == %{}
          assert opts == []
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_alias"}}}}
        end
      )

    assert get_in(response, ["result", "isError"]) == false
    assert get_in(response, ["result", "content", Access.at(0), "text"]) =~ "usr_alias"
  end

  test "tools/call returns isError for invalid tool input" do
    response =
      MCPServer.handle_request(%{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "linear_graphql",
          "arguments" => %{"variables" => %{"commentId" => "comment-1"}}
        }
      })

    assert get_in(response, ["result", "isError"]) == true

    assert get_in(response, ["result", "content"]) == [
             %{
               "type" => "text",
               "text" => "{\n  \"error\": {\n    \"message\": \"`linear_graphql` requires a non-empty `query` string.\"\n  }\n}"
             }
           ]
  end

  test "tools/call surfaces enriched linear_graphql HTTP diagnostics" do
    response =
      MCPServer.handle_request(
        %{
          "jsonrpc" => "2.0",
          "id" => 41,
          "method" => "tools/call",
          "params" => %{
            "name" => "linear_graphql",
            "arguments" => %{"query" => "query Viewer { viewer { id } }"}
          }
        },
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

    assert get_in(response, ["result", "isError"]) == true

    decoded =
      response
      |> get_in(["result", "content", Access.at(0), "text"])
      |> Jason.decode!()

    assert get_in(decoded, ["error", "status"]) == 403
    assert get_in(decoded, ["error", "classification"]) == "auth"
    assert get_in(decoded, ["error", "extensionsCodes"]) == ["FORBIDDEN"]
  end

  test "tools/call rejects unknown tools and malformed payloads" do
    assert MCPServer.handle_request(%{
             "jsonrpc" => "2.0",
             "id" => 5,
             "method" => "tools/call",
             "params" => %{
               "name" => "not_linear_graphql",
               "arguments" => %{}
             }
           }) == %{
             "jsonrpc" => "2.0",
             "id" => 5,
             "error" => %{
               "code" => -32_602,
               "message" => "Unknown tool: not_linear_graphql"
             }
           }

    assert MCPServer.handle_request(%{
             "jsonrpc" => "2.0",
             "id" => 6,
             "method" => "tools/call",
             "params" => %{"name" => 123}
           }) == %{
             "jsonrpc" => "2.0",
             "id" => 6,
             "error" => %{
               "code" => -32_602,
               "message" => "Invalid tool call"
             }
           }
  end

  test "handle_message validates json-rpc envelopes and surfaces parse errors" do
    assert MCPServer.handle_message("   \n") == nil

    assert MCPServer.handle_message("[]\n") == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_600,
               "message" => "Invalid Request"
             }
           }

    assert MCPServer.handle_message("{not json}\n") == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_700,
               "message" => "Parse error"
             }
           }
  end

  test "handle_request rejects invalid envelopes" do
    assert MCPServer.handle_request(%{"id" => 7}) == %{
             "jsonrpc" => "2.0",
             "id" => 7,
             "error" => %{
               "code" => -32_600,
               "message" => "Invalid Request"
             }
           }

    assert MCPServer.handle_request(%{"method" => "ping"}) == %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_600,
               "message" => "Invalid Request"
             }
           }

    assert MCPServer.handle_request(%{
             "jsonrpc" => "2.0",
             "id" => 8,
             "method" => "missing"
           }) == %{
             "jsonrpc" => "2.0",
             "id" => 8,
             "error" => %{
               "code" => -32_601,
               "message" => "Method not found"
             }
           }
  end

  test "run streams request lines and emits only non-nil responses" do
    {:ok, input} =
      StringIO.open("""

      {"jsonrpc":"2.0","id":11,"method":"ping"}
      []
      """)

    {:ok, output} = StringIO.open("")

    assert :ok = MCPServer.run([], input: input, output: output)

    {_input, response_lines} = StringIO.contents(output)

    assert response_lines
           |> String.split("\n", trim: true)
           |> Enum.map(&Jason.decode!/1) == [
             %{
               "jsonrpc" => "2.0",
               "id" => 11,
               "result" => %{}
             },
             %{
               "jsonrpc" => "2.0",
               "id" => nil,
               "error" => %{
                 "code" => -32_600,
                 "message" => "Invalid Request"
               }
             }
           ]
  end

  test "bootstrap loads .symphony env files and workflow path from the source repo environment" do
    source_repo =
      Path.join(System.tmp_dir!(), "symphony-mcp-source-#{System.unique_integer([:positive])}")

    workflow_file = Path.join(source_repo, "WORKFLOW.custom.md")
    previous_source_repo = System.get_env("SYMPHONY_SOURCE_REPO")
    previous_project_root = System.get_env("SYMPHONY_PROJECT_ROOT")
    previous_workflow_file = System.get_env("SYMPHONY_WORKFLOW_FILE")
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    File.mkdir_p!(source_repo)
    File.mkdir_p!(Path.join(source_repo, ".symphony"))
    File.write!(Path.join(source_repo, ".symphony/.env"), "LINEAR_API_KEY=bootstrap-token\n")
    write_workflow_file!(workflow_file)

    on_exit(fn ->
      restore_env("SYMPHONY_SOURCE_REPO", previous_source_repo)
      restore_env("SYMPHONY_PROJECT_ROOT", previous_project_root)
      restore_env("SYMPHONY_WORKFLOW_FILE", previous_workflow_file)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      File.rm_rf(source_repo)
    end)

    System.put_env("SYMPHONY_SOURCE_REPO", source_repo)
    System.delete_env("SYMPHONY_PROJECT_ROOT")
    System.put_env("SYMPHONY_WORKFLOW_FILE", workflow_file)
    System.put_env("LINEAR_API_KEY", "inherited-shell-token")

    assert :ok = MCPServer.bootstrap(logger_configurer: fn -> :ok end)
    assert Workflow.workflow_file_path() == workflow_file
    assert System.get_env("LINEAR_API_KEY") == "inherited-shell-token"
  end

  test "bootstrap removes the stdout logger handler from the MCP protocol stream" do
    source_repo =
      Path.join(System.tmp_dir!(), "symphony-mcp-source-#{System.unique_integer([:positive])}")

    workflow_file = Path.join(source_repo, "WORKFLOW.custom.md")
    previous_source_repo = System.get_env("SYMPHONY_SOURCE_REPO")
    previous_project_root = System.get_env("SYMPHONY_PROJECT_ROOT")
    previous_workflow_file = System.get_env("SYMPHONY_WORKFLOW_FILE")
    previous_default_logger = :logger.get_handler_config(:default)

    File.mkdir_p!(Path.join(source_repo, ".symphony"))
    write_workflow_file!(workflow_file)

    on_exit(fn ->
      restore_env("SYMPHONY_SOURCE_REPO", previous_source_repo)
      restore_env("SYMPHONY_PROJECT_ROOT", previous_project_root)
      restore_env("SYMPHONY_WORKFLOW_FILE", previous_workflow_file)
      restore_default_logger(previous_default_logger)
      File.rm_rf(source_repo)
    end)

    System.put_env("SYMPHONY_SOURCE_REPO", source_repo)
    System.delete_env("SYMPHONY_PROJECT_ROOT")
    System.put_env("SYMPHONY_WORKFLOW_FILE", workflow_file)

    assert :ok = MCPServer.bootstrap()
    assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)
  end

  test "bootstrap prefers project root env files over the Symphony source repo" do
    source_repo =
      Path.join(System.tmp_dir!(), "symphony-mcp-source-#{System.unique_integer([:positive])}")

    project_root =
      Path.join(System.tmp_dir!(), "symphony-mcp-project-#{System.unique_integer([:positive])}")

    workflow_file = Path.join(source_repo, "WORKFLOW.custom.md")
    previous_source_repo = System.get_env("SYMPHONY_SOURCE_REPO")
    previous_project_root = System.get_env("SYMPHONY_PROJECT_ROOT")
    previous_workflow_file = System.get_env("SYMPHONY_WORKFLOW_FILE")
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    File.mkdir_p!(Path.join(source_repo, ".symphony"))
    File.mkdir_p!(Path.join(project_root, ".symphony"))
    File.write!(Path.join(source_repo, ".symphony/.env"), "LINEAR_API_KEY=source-token\n")
    File.write!(Path.join(project_root, ".symphony/.env"), "LINEAR_API_KEY=project-token\n")
    write_workflow_file!(workflow_file)

    on_exit(fn ->
      restore_env("SYMPHONY_SOURCE_REPO", previous_source_repo)
      restore_env("SYMPHONY_PROJECT_ROOT", previous_project_root)
      restore_env("SYMPHONY_WORKFLOW_FILE", previous_workflow_file)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      File.rm_rf(source_repo)
      File.rm_rf(project_root)
    end)

    System.put_env("SYMPHONY_SOURCE_REPO", source_repo)
    System.put_env("SYMPHONY_PROJECT_ROOT", project_root)
    System.put_env("SYMPHONY_WORKFLOW_FILE", workflow_file)
    System.put_env("LINEAR_API_KEY", "inherited-shell-token")

    assert :ok = MCPServer.bootstrap(logger_configurer: fn -> :ok end)
    assert Workflow.workflow_file_path() == workflow_file
    assert System.get_env("LINEAR_API_KEY") == "inherited-shell-token"
  end

  defp restore_default_logger({:ok, config}) do
    :logger.remove_handler(:default)
    :logger.add_handler(:default, config.module, Map.drop(config, [:id, :module]))
  end

  defp restore_default_logger(_missing), do: :ok
end
