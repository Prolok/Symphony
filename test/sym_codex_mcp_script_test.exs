defmodule SymCodexMcpScriptTest do
  alias SymphonyElixir.Codex.{CommentTool, MergeTool}
  use ExUnit.Case

  @script_path Path.expand("../sym-codex-mcp", __DIR__)
  @mix_runtime_source Path.expand("../scripts/mix-runtime", __DIR__)

  test "sym-codex-mcp keeps Mix artifacts local to its source checkout" do
    root_dir = Path.join(System.tmp_dir!(), "sym-codex-mcp-isolation-#{System.unique_integer([:positive])}")
    source_repo = Path.join(root_dir, "old-worktree")
    bin_dir = Path.join(root_dir, "bin")
    foreign_deps = Path.join(root_dir, "main/deps")
    foreign_build = Path.join(root_dir, "main/_build")

    File.mkdir_p!(Path.join(source_repo, "scripts"))
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(foreign_deps)
    File.mkdir_p!(foreign_build)
    File.cp!(@mix_runtime_source, Path.join(source_repo, "scripts/mix-runtime"))
    File.chmod!(Path.join(source_repo, "scripts/mix-runtime"), 0o755)
    File.write!(Path.join(source_repo, "mix.exs"), "")
    File.write!(Path.join(source_repo, "WORKFLOW.md"), "")
    File.write!(Path.join(foreign_deps, "sentinel"), "newer lock deps\n")
    File.write!(Path.join(foreign_build, "sentinel"), "newer lock build\n")

    File.write!(Path.join(bin_dir, "mix"), """
    #!/usr/bin/env bash
    deps_path="${MIX_DEPS_PATH:-$PWD/deps}"
    build_path="${MIX_BUILD_PATH:-${MIX_BUILD_ROOT:-$PWD/_build}}"
    mkdir -p "$deps_path" "$build_path"
    printf '%s\\n' "$1" >> "$deps_path/sym-codex-mcp-touch"
    printf '%s\\n' "$1" >> "$build_path/sym-codex-mcp-touch"

    case "$1" in
      deps.loadpaths|compile)
        exit 0
        ;;
      run)
        exit 0
        ;;
    esac

    exit 1
    """)

    File.write!(Path.join(bin_dir, "mise"), """
    #!/usr/bin/env bash
    if [ "$1" = "exec" ] && [ "$2" = "--" ]; then
      shift 2
      exec "$@"
    fi
    exit 1
    """)

    File.chmod!(Path.join(bin_dir, "mix"), 0o755)
    File.chmod!(Path.join(bin_dir, "mise"), 0o755)

    on_exit(fn -> File.rm_rf(root_dir) end)

    assert {_output, 0} =
             System.cmd("/bin/bash", [@script_path],
               env: [
                 {"PATH", SymphonyElixir.TestSupport.script_path(bin_dir)},
                 {"SYMPHONY_SOURCE_REPO", source_repo},
                 {"MIX_DEPS_PATH", foreign_deps},
                 {"MIX_BUILD_ROOT", foreign_build},
                 {"MIX_BUILD_PATH", foreign_build}
               ],
               stderr_to_stdout: true
             )

    assert File.ls!(foreign_deps) == ["sentinel"]
    assert File.ls!(foreign_build) == ["sentinel"]
    assert File.exists?(Path.join(source_repo, "deps/sym-codex-mcp-touch"))
    assert File.exists?(Path.join(source_repo, "_build/sym-codex-mcp-touch"))
  end

  test "sym-codex-mcp serves initialize and tools/list over stdio" do
    source_repo = Path.expand("..", __DIR__)
    workflow_file = Path.join(source_repo, "WORKFLOW.md")
    runtime_path = elixir_runtime_path!()

    input =
      [
        ~s({"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}),
        ~s({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}})
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    input_file =
      Path.join(System.tmp_dir!(), "sym-codex-mcp-input-#{System.unique_integer([:positive])}.jsonl")

    File.write!(input_file, input)

    on_exit(fn ->
      File.rm(input_file)
    end)

    {output, 0} =
      System.cmd(
        "/bin/bash",
        ["--noprofile", "--norc", "-c", "cat \"$INPUT_FILE\" | \"$SCRIPT_PATH\""],
        env:
          SymphonyElixir.TestSupport.cleared_symphony_runtime_env() ++
            [
              {"INPUT_FILE", input_file},
              {"PATH", runtime_path},
              {"SCRIPT_PATH", @script_path},
              {"SYMPHONY_SOURCE_REPO", source_repo},
              {"SYMPHONY_WORKFLOW_FILE", workflow_file}
            ],
        stderr_to_stdout: true
      )

    [initialize_line, tools_list_line] =
      output
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "{"))

    initialize = Jason.decode!(initialize_line)
    tools_list = Jason.decode!(tools_list_line)

    assert initialize == %{
             "jsonrpc" => "2.0",
             "id" => 1,
             "result" => %{
               "protocolVersion" => "2025-06-18",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{
                 "name" => "symphony-linear",
                 "version" => "0.1.0"
               }
             }
           }

    assert [linear_tool, comment_tool, merge_tool] = get_in(tools_list, ["result", "tools"])
    assert comment_tool == CommentTool.tool_spec()
    assert merge_tool == MergeTool.tool_spec()

    assert [linear_tool] == [
             %{
               "name" => "linear_graphql",
               "description" => "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.\n",
               "inputSchema" => %{
                 "type" => "object",
                 "required" => ["query"],
                 "additionalProperties" => false,
                 "properties" => %{
                   "query" => %{
                     "type" => "string",
                     "description" => "GraphQL query or mutation document to execute against Linear."
                   },
                   "variables" => %{
                     "type" => ["object", "null"],
                     "description" => "Optional GraphQL variables object.",
                     "additionalProperties" => true
                   }
                 }
               }
             }
           ]
  end

  defp elixir_runtime_path! do
    bin_dir = Path.join(System.tmp_dir!(), "mcp-runtime-#{System.unique_integer([:positive])}")
    File.mkdir_p!(bin_dir)
    on_exit(fn -> File.rm_rf(bin_dir) end)

    for tool <- ["mise", "erl", "escript", "elixir", "mix"] do
      File.ln_s!(System.find_executable(tool) || flunk("#{tool} required"), Path.join(bin_dir, tool))
    end

    runtime_path = SymphonyElixir.TestSupport.script_path(bin_dir)

    assert {_, 0} =
             System.cmd(
               "/bin/bash",
               ["--noprofile", "--norc", "-c", "command -v elixir >/dev/null && command -v mix >/dev/null"],
               env: [{"PATH", runtime_path}],
               stderr_to_stdout: true
             )

    runtime_path
  end
end
