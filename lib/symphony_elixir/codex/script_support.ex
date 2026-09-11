defmodule SymphonyElixir.Codex.ScriptSupport do
  @moduledoc false

  alias SymphonyElixir.{Config, Dialog, EnvFile, PromptBuilder, Tracker, Workflow}

  @spec workspace_root(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def workspace_root(workflow_path, env_files_dir)
      when is_binary(workflow_path) and is_binary(env_files_dir) do
    with :ok <- load_runtime_context(workflow_path, env_files_dir) do
      {:ok, Config.settings!().workspace.root}
    end
  end

  @spec manual_prompt(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def manual_prompt(workflow_path, interactive_workflow_path, issue_identifier, env_files_dir)
      when is_binary(workflow_path) and is_binary(interactive_workflow_path) and
             is_binary(issue_identifier) and is_binary(env_files_dir) do
    with {:ok, %{prompt: prompt}} <-
           manual_prompt_context(
             workflow_path,
             interactive_workflow_path,
             issue_identifier,
             env_files_dir
           ) do
      {:ok, prompt}
    end
  end

  @spec manual_prompt_context(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{prompt: String.t(), workflow_step: String.t() | nil, session_id: String.t() | nil}}
          | {:error, term()}
  def manual_prompt_context(workflow_path, interactive_workflow_path, issue_identifier, env_files_dir)
      when is_binary(workflow_path) and is_binary(interactive_workflow_path) and
             is_binary(issue_identifier) and is_binary(env_files_dir) do
    dialog_workflow_path =
      workflow_path
      |> Path.dirname()
      |> Path.join("WORKFLOW_DIALOG.md")

    manual_prompt_context(
      workflow_path,
      interactive_workflow_path,
      dialog_workflow_path,
      issue_identifier,
      env_files_dir
    )
  end

  @spec manual_prompt_context(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{prompt: String.t(), workflow_step: String.t() | nil, session_id: String.t() | nil}}
          | {:error, term()}
  def manual_prompt_context(
        workflow_path,
        interactive_workflow_path,
        dialog_workflow_path,
        issue_identifier,
        env_files_dir
      )
      when is_binary(workflow_path) and is_binary(interactive_workflow_path) and
             is_binary(dialog_workflow_path) and is_binary(issue_identifier) and
             is_binary(env_files_dir) do
    with :ok <- load_runtime_context(workflow_path, env_files_dir),
         {:ok, issue} <- Tracker.fetch_issue_by_identifier(issue_identifier) do
      manual_prompt_context_for_issue(issue, interactive_workflow_path, dialog_workflow_path, env_files_dir)
    end
  end

  @spec workflow_step(String.t(), String.t(), String.t()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def workflow_step(workflow_path, issue_identifier, env_files_dir)
      when is_binary(workflow_path) and is_binary(issue_identifier) and is_binary(env_files_dir) do
    with :ok <- load_runtime_context(workflow_path, env_files_dir),
         {:ok, issue} <- Tracker.fetch_issue_by_identifier(issue_identifier) do
      {:ok, issue.state}
    end
  end

  @spec dialog_workspace(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def dialog_workspace(workflow_path, issue_identifier, env_files_dir)
      when is_binary(workflow_path) and is_binary(issue_identifier) and is_binary(env_files_dir) do
    with :ok <- load_runtime_context(workflow_path, env_files_dir),
         {:ok, _issue} <- Tracker.fetch_issue_by_identifier(issue_identifier) do
      {:ok, Path.expand(env_files_dir)}
    end
  end

  defp manual_prompt_context_for_issue(issue, interactive_workflow_path, dialog_workflow_path, env_files_dir) do
    if Dialog.state?(issue.state) do
      dialog_prompt_context(issue, dialog_workflow_path, env_files_dir)
    else
      with {:ok, prompt_template} <- load_prompt_template(interactive_workflow_path) do
        {:ok,
         %{
           prompt: prompt_for_issue(issue, prompt_template),
           workflow_step: issue.state,
           session_id: nil
         }}
      end
    end
  end

  defp dialog_prompt_context(issue, dialog_workflow_path, env_files_dir) do
    previous_dialog_workflow_path = Application.get_env(:symphony_elixir, :dialog_workflow_file_path)
    Application.put_env(:symphony_elixir, :dialog_workflow_file_path, dialog_workflow_path)

    try do
      workspace = Path.expand(env_files_dir)

      with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id),
           {:ok, request} <- Dialog.next_request(issue, comments, workspace) do
        {:ok,
         %{
           prompt: prompt_from_dialog_request(request),
           workflow_step: issue.state,
           session_id: session_id_from_dialog_request(request, comments)
         }}
      end
    after
      if is_nil(previous_dialog_workflow_path) do
        Application.delete_env(:symphony_elixir, :dialog_workflow_file_path)
      else
        Application.put_env(:symphony_elixir, :dialog_workflow_file_path, previous_dialog_workflow_path)
      end
    end
  end

  defp prompt_from_dialog_request(:noop), do: ""
  defp prompt_from_dialog_request(%{prompt: prompt}) when is_binary(prompt), do: prompt

  defp session_id_from_dialog_request(:noop, comments), do: Dialog.session_id_from_comments(comments)
  defp session_id_from_dialog_request(%{session_id: session_id}, _comments), do: session_id

  @spec prompt_for_issue(map(), String.t()) :: String.t()
  defp prompt_for_issue(issue, prompt_template) when is_map(issue) and is_binary(prompt_template) do
    PromptBuilder.build_prompt(
      issue,
      prompt_template: prompt_template,
      session_mode: :manual
    )
  end

  defp load_prompt_template(workflow_path) when is_binary(workflow_path) do
    with {:ok, %{prompt_template: prompt_template}} <- Workflow.load(workflow_path) do
      {:ok, prompt_template}
    end
  end

  defp load_runtime_context(workflow_path, env_files_dir) do
    with :ok <- Workflow.set_workflow_file_path(workflow_path),
         :ok <- EnvFile.load_runtime(EnvFile.config_dir(env_files_dir)),
         {:ok, _apps} <- Application.ensure_all_started(:req) do
      :ok
    end
  end
end
