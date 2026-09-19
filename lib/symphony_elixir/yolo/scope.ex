defmodule SymphonyElixir.Yolo.Scope do
  @moduledoc "Runtime-owned membership of one PO session, including its bound MCP transport."
  alias SymphonyElixir.{Config, ProjectContext}
  alias SymphonyElixir.Linear.WriteContext

  @spec current() :: map() | nil
  def current do
    case WriteContext.current()["yolo_scope"] do
      value when is_binary(value) ->
        decode_scope(Jason.decode(value))

      _ ->
        nil
    end
  end

  defp decode_scope({:ok, %{"members" => ids, "agent_id" => agent, "project_context_id" => project} = scope}) when is_list(ids) do
    context = ProjectContext.current()
    if context && context.id == project && Config.yolo_agent_id() == agent, do: scope
  end

  defp decode_scope(_), do: nil

  @spec member?(String.t()) :: boolean()
  def member?(id) do
    case current() do
      %{"members" => ids} -> id in ids
      _ -> false
    end
  end

  @spec with_members([String.t()], (-> result)) :: result when result: term()
  def with_members(ids, callback) do
    scope = current()
    WriteContext.with_context(%{yolo_scope: Jason.encode!(Map.update!(scope, "members", &Enum.uniq(&1 ++ ids)))}, callback)
  end

  @spec with_scope(String.t(), [map()], String.t(), (-> result), keyword()) :: result when result: term()
  def with_scope(group, issues, run_id, callback, opts \\ []) do
    scope = %{"group" => group, "run_id" => run_id, "members" => Enum.map(issues, & &1.id), "agent_id" => Config.yolo_agent_id(), "project_context_id" => ProjectContext.current().id}

    scope =
      case Keyword.get(opts, :workspace) do
        %{path: path, sha: sha} -> Map.merge(scope, %{"workspace" => path, "sha" => sha, "workspace_root" => Config.settings!().workspace.root})
        nil -> scope
      end

    WriteContext.with_context(%{yolo_scope: Jason.encode!(scope), run_id: run_id, phase: "YOLO #{group}"}, callback)
  end
end
