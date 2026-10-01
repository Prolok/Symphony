defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :branch_name,
    :url,
    :assignee_id,
    :delegate_id,
    :team_id,
    :project_id,
    :project_context_id,
    :project_name,
    :workspace_id,
    :last_comment_signal,
    :relay_event,
    in_project_scope: false,
    blocked_by: [],
    relations_complete: false,
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type comment_signal :: %{
          optional(:relay_epoch) => String.t(),
          optional(:id) => String.t() | nil,
          optional(:created_at) => DateTime.t() | nil,
          optional(:updated_at) => DateTime.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          assignee_id: String.t() | nil,
          delegate_id: String.t() | nil,
          team_id: String.t() | nil,
          project_id: String.t() | nil,
          project_context_id: String.t() | nil,
          project_name: String.t() | nil,
          workspace_id: String.t() | nil,
          last_comment_signal: comment_signal() | nil,
          relay_event: map() | nil,
          in_project_scope: boolean(),
          blocked_by: [map()],
          relations_complete: boolean(),
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end

  @doc "Canonical dependency order: relations by ID, then wait markers; all content is retained."
  @spec normalize_blockers([map()]) :: [map()]
  def normalize_blockers(blockers) do
    Enum.sort_by(blockers, &{Map.get(&1, :marker, false) == true, Map.get(&1, :id), &1})
  end

  @spec normalize_dependencies(t()) :: t()
  def normalize_dependencies(issue), do: %{issue | blocked_by: normalize_blockers(issue.blocked_by)}

  @doc "Restore JSON dependency keys without discarding marker metadata or changing historical order."
  @spec restore_blockers([map()]) :: [map()]
  def restore_blockers(blockers) do
    fields = Map.new([:id, :identifier, :state, :state_type, :marker, :workspace_id, :context_id, :error], &{Atom.to_string(&1), &1})
    Enum.map(blockers, fn blocker -> Map.new(blocker, fn {key, value} -> {Map.get(fields, key, key), value} end) end)
  end
end
