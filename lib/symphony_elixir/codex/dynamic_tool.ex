defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Codex.CommentTool
  alias SymphonyElixir.Codex.LinearGraphqlTool
  alias SymphonyElixir.Codex.MergeTool

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case LinearGraphqlTool.canonical_tool_name(tool) || tool do
      name when name in ["symphony_merge", "symphony_linear.symphony_merge"] ->
        MergeTool.execute(arguments, opts)

      name when name in ["symphony_comments", "symphony_linear.symphony_comments"] ->
        CommentTool.execute(arguments, opts)

      "linear_graphql" ->
        LinearGraphqlTool.execute(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [LinearGraphqlTool.tool_spec(), CommentTool.tool_spec(), MergeTool.tool_spec()]
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "output" => Jason.encode!(payload, pretty: true),
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => Jason.encode!(payload, pretty: true)
        }
      ]
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
