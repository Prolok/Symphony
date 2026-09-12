defmodule SymphonyElixir.Codex.CommentTool do
  @moduledoc "Shared comment checkpoint tool for dynamic and bound MCP transports."
  alias SymphonyElixir.CommentCheckpoint
  alias SymphonyElixir.Linear.WriteContext

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => "symphony_comments",
      "description" => "Read a fresh safe comment checkpoint or acknowledge named delivered versions with a business result in the issue workpad.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["operation"],
        "properties" => %{
          "operation" => %{"type" => "string", "enum" => ["checkpoint", "acknowledge"]},
          "issue_id" => %{"type" => "string", "description" => "Current bound Linear issue UUID; defaults to the worker issue."},
          "results" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["key", "outcome", "reason"],
              "properties" => %{
                "key" => %{"type" => "string"},
                "outcome" => %{"type" => "string", "enum" => ["übernommen", "Rückfrage", "nicht anwendbar", "ersetzt"]},
                "reason" => %{"type" => "string"},
                "replacement" => %{"type" => "string"}
              }
            }
          }
        }
      }
    }
  end

  @spec invoke(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def invoke(arguments, opts \\ []) do
    with %{"operation" => operation} <- arguments,
         {:ok, issue} <- CommentCheckpoint.bound_issue(arguments["issue_id"] || WriteContext.current()["issue_id"], opts) do
      case operation do
        "checkpoint" -> CommentCheckpoint.checkpoint(issue, opts)
        "acknowledge" -> CommentCheckpoint.acknowledge(issue, arguments["results"], opts)
        _ -> {:error, :invalid_comment_operation}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_comment_arguments}
    end
  end

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    {success, output} = response(invoke(arguments, opts))
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  @spec mcp_call(term(), keyword()) :: map()
  def mcp_call(arguments, opts \\ []) do
    {success, output} = response(invoke(arguments, opts))
    %{"isError" => not success, "content" => [%{"type" => "text", "text" => output}]}
  end

  defp response({:ok, result}), do: {true, Jason.encode!(result)}
  defp response({:error, reason}), do: {false, Jason.encode!(%{"error" => inspect(reason)})}
end
