defmodule SymphonyElixir.ProjectSelection do
  @moduledoc "Resolve manual issue commands using an existing project context or an explicit project qualifier."

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.{ProjectContext, Projects}

  @spec command_selection(Path.t(), Path.t(), String.t(), Path.t()) :: {:ok, map()} | {:error, term()}
  def command_selection(root, workflow, reference, cwd) do
    with :ok <- Projects.prepare(root, workflow),
         {:ok, _} <- Application.ensure_all_started(:req),
         {:ok, context, issue} <- resolve(reference, Projects.configured(), cwd) do
      {:ok, %{project_root: context.root, identifier: issue.identifier}}
    end
  end

  @spec resolve(String.t(), [ProjectContext.t()], Path.t() | nil) :: {:ok, ProjectContext.t(), map()} | {:error, term()}
  def resolve(reference, contexts \\ Projects.configured(), cwd \\ nil) do
    {qualifier, identifier} =
      case String.split(reference, ":", parts: 2) do
        [identifier] -> {nil, identifier}
        [qualifier, identifier] -> {qualifier, identifier}
      end

    with {:ok, candidates} <- candidates(contexts, qualifier, cwd) do
      results =
        Enum.map(candidates, fn context ->
          {context, ProjectContext.with_context(context, fn -> Client.fetch_issue_by_identifier(identifier) end)}
        end)

      matches = for {context, {:ok, issue}} <- results, do: {context, issue}
      errors = for {context, {:error, reason}} <- results, not scope_miss?(reason), do: {context.name, reason}

      case {errors, matches} do
        {[], [{context, issue}]} -> {:ok, context, issue}
        {[], []} -> {:error, {:issue_not_found_in_projects, identifier}}
        {[], _} -> {:error, {:ambiguous_issue_identifier, identifier, Enum.map(matches, fn {context, _} -> context.name end)}}
        {errors, _} -> {:error, {:project_lookup_failed, errors}}
      end
    end
  end

  defp scope_miss?({:issue_not_found, _}), do: true
  defp scope_miss?({:issue_outside_team_scope, _, _}), do: true
  defp scope_miss?(_), do: false

  defp candidates(contexts, qualifier, _cwd) when is_binary(qualifier) do
    case Enum.filter(contexts, &(&1.name == qualifier or &1.root == qualifier)) do
      [context] -> {:ok, [context]}
      _ -> {:error, {:ambiguous_or_unknown_project, qualifier}}
    end
  end

  defp candidates(contexts, nil, cwd) do
    scoped = Enum.filter(contexts, &within_project?(cwd, &1))
    {:ok, if(scoped == [], do: contexts, else: scoped)}
  end

  defp within_project?(nil, _context), do: false

  defp within_project?(cwd, context) do
    cwd = Path.expand(cwd)
    Enum.any?([context.root, context.settings.workspace.root], &(cwd == &1 or String.starts_with?(cwd, &1 <> "/")))
  end
end
