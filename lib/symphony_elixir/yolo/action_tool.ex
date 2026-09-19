defmodule SymphonyElixir.Yolo.ActionTool do
  @moduledoc "Bound PO actions, also exposing the same follow-up contract to regular workers."
  alias SymphonyElixir.Yolo.{Followup, Handoff}

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => "symphony_yolo_action",
      "description" =>
        "Durable aggregation/follow-up creation and human handoff. Use stable operation_key on retries. Creation confirms generated label and origin/dependency links before success; aggregate closes origins only after links. Handoff requires actual report in the existing workpad and all creations completed.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["kind"],
        "properties" => %{
          "kind" => %{"type" => "string", "enum" => ["aggregate", "followup", "handoff"]},
          "origin_ids" => %{"type" => "array", "items" => %{"type" => "string"}},
          "operation_key" => %{"type" => "string"},
          "title" => %{"type" => "string"},
          "description" => %{"type" => "string"},
          "validation" => %{"type" => "string"},
          "blocked_by" => %{"type" => "array", "items" => %{"type" => "string"}},
          "issue_id" => %{"type" => "string"},
          "report" => %{"type" => "string"}
        }
      }
    }
  end

  @spec execute(term(), keyword()) :: map()
  def execute(args, opts \\ []) do
    result =
      case args do
        %{"kind" => "handoff"} -> Handoff.invoke(args, opts)
        _ -> Followup.invoke(args, opts)
      end

    success = result == :ok or match?({:ok, _}, result)

    payload =
      case result do
        :ok -> %{completed: true}
        {:ok, issue} -> %{completed: true, issue: issue}
        error -> %{error: inspect(error)}
      end

    output = Jason.encode!(payload)
    %{"success" => success, "output" => output, "contentItems" => [%{"type" => "inputText", "text" => output}]}
  end

  @spec mcp_call(term(), keyword()) :: map()
  def mcp_call(args, opts \\ []) do
    result = execute(args, opts)
    %{"isError" => not result["success"], "content" => [%{"type" => "text", "text" => result["output"]}]}
  end
end
