defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, HookRunner, PathSafety, RuntimePaths, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @review_autocommit_marker_filename "symphony.review-ai-autocommit.done"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace}

          {:error, _reason} = error ->
            cleanup_failed_new_workspace(workspace, created?, worker_host, issue_context)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  @spec ensure_expected_worktree(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def ensure_expected_worktree(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    expected_branch = "symphony/#{issue_context.issue_identifier}"

    with :ok <- validate_workspace_path(workspace, worker_host),
         {:ok, branch_name} <- ensure_expected_branch(workspace, expected_branch, issue_context, worker_host) do
      if branch_name == expected_branch do
        :ok
      else
        {:error, {:unexpected_workspace_branch, workspace, branch_name, expected_branch}}
      end
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp cleanup_failed_new_workspace(_workspace, false, _worker_host, _issue_context), do: :ok

  defp cleanup_failed_new_workspace(workspace, true, nil, issue_context) do
    case validate_workspace_path(workspace, nil) do
      :ok ->
        script =
          cleanup_failed_new_workspace_script(
            RuntimePaths.project_root(),
            workspace,
            issue_context
          )

        case System.cmd("sh", ["-lc", script],
               env: RuntimePaths.cleaned_builtin_system_env(),
               stderr_to_stdout: true
             ) do
          {_output, 0} ->
            :ok

          {output, status} ->
            Logger.warning("Workspace cleanup after failed after_create hook failed #{issue_log_context(issue_context)} worker_host=local status=#{status} output=#{inspect(output)}")
        end

      {:error, reason} ->
        Logger.warning("Workspace cleanup after failed after_create hook skipped #{issue_log_context(issue_context)} worker_host=local workspace=#{workspace} error=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace(workspace, true, worker_host, issue_context)
       when is_binary(worker_host) do
    case validate_workspace_path(workspace, worker_host) do
      :ok ->
        script =
          cleanup_failed_new_workspace_script(
            RuntimePaths.project_root(),
            workspace,
            issue_context
          )

        case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
          {:ok, {_output, 0}} ->
            :ok

          {:ok, {output, status}} ->
            Logger.warning("Workspace cleanup after failed after_create hook failed #{issue_log_context(issue_context)} worker_host=#{worker_host} status=#{status} output=#{inspect(output)}")

          {:error, reason} ->
            Logger.warning("Workspace cleanup after failed after_create hook failed #{issue_log_context(issue_context)} worker_host=#{worker_host} error=#{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Workspace cleanup after failed after_create hook skipped #{issue_log_context(issue_context)} worker_host=#{worker_host} workspace=#{workspace} error=#{inspect(reason)}")
    end
  end

  defp cleanup_failed_new_workspace_script(source_repo, workspace, issue_context) do
    branch = "symphony/#{issue_context.issue_identifier}"

    [
      "set -eu",
      "source_repo=#{shell_escape(source_repo)}",
      "workspace=#{shell_escape(workspace)}",
      "branch=#{shell_escape(branch)}",
      "if git -C \"$source_repo\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
      "  if git -C \"$source_repo\" worktree list --porcelain | grep -Fqx \"worktree $workspace\"; then",
      "    git -C \"$source_repo\" worktree remove --force \"$workspace\"",
      "    git -C \"$source_repo\" worktree prune",
      "  fi",
      "  if git -C \"$source_repo\" rev-parse --verify --quiet \"refs/heads/$branch\" >/dev/null 2>&1; then",
      "    if ! git -C \"$source_repo\" show-ref --verify --quiet \"refs/remotes/origin/$branch\"; then",
      "      git -C \"$source_repo\" branch -D \"$branch\"",
      "    fi",
      "  fi",
      "fi",
      "rm -rf \"$workspace\""
    ]
    |> Enum.join("\n")
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  @spec run_after_create_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_after_create_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_create do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_create", worker_host)
    end
  end

  @spec git_status_snapshot(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def git_status_snapshot(workspace, worker_host \\ nil) when is_binary(workspace) do
    case worker_host do
      nil ->
        local_git_status_snapshot(workspace)

      worker_host when is_binary(worker_host) ->
        remote_git_status_snapshot(workspace, worker_host)
    end
  end

  @spec current_branch(Path.t(), worker_host()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(workspace, worker_host \\ nil) when is_binary(workspace) do
    case worker_host do
      nil ->
        local_current_branch(workspace)

      worker_host when is_binary(worker_host) ->
        remote_current_branch(workspace, worker_host)
    end
  end

  @spec commit_all_changes(Path.t(), String.t(), worker_host()) ::
          {:ok, :clean | :committed | :not_git_repo} | {:error, term()}
  def commit_all_changes(workspace, message, worker_host \\ nil)
      when is_binary(workspace) and is_binary(message) do
    trimmed_message = String.trim(message)

    if trimmed_message == "" do
      {:error, {:workspace_git_commit_message_missing, worker_host || :local}}
    else
      commit_all_changes_with_message(workspace, trimmed_message, worker_host)
    end
  end

  @spec prepare_review_autocommit(Path.t(), String.t(), worker_host()) ::
          {:ok, :already_recorded | :clean | :committed | :not_git_repo} | {:error, term()}
  def prepare_review_autocommit(workspace, message, worker_host \\ nil)
      when is_binary(workspace) and is_binary(message) do
    case review_autocommit_marker_present?(workspace, worker_host) do
      {:ok, true} ->
        {:ok, :already_recorded}

      {:ok, false} ->
        workspace
        |> commit_all_changes(message, worker_host)
        |> record_review_autocommit_result(workspace, worker_host)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec clear_review_autocommit_marker(Path.t(), worker_host()) ::
          :ok | {:error, term()}
  def clear_review_autocommit_marker(workspace, worker_host \\ nil) when is_binary(workspace) do
    case delete_review_autocommit_marker(workspace, worker_host) do
      :ok -> :ok
      {:ok, :missing} -> :ok
      {:ok, :not_git_repo} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clear_review_autocommit_marker_for_existing_issue_workspace(
          map() | String.t() | nil,
          worker_host()
        ) :: :ok | {:error, term()}
  def clear_review_autocommit_marker_for_existing_issue_workspace(
        issue_or_identifier,
        worker_host \\ nil
      ) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)

    with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
         :ok <- validate_workspace_path(workspace, worker_host) do
      case workspace_presence(workspace, worker_host) do
        {:ok, :present} -> clear_review_autocommit_marker(workspace, worker_host)
        {:ok, :missing} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  @spec git_status_snapshot_for_existing_issue_workspace(
          map() | String.t() | nil,
          worker_host()
        ) :: {:ok, String.t() | :missing | :not_git_repo} | {:error, term()}
  def git_status_snapshot_for_existing_issue_workspace(
        issue_or_identifier,
        worker_host \\ nil
      ) do
    issue_context = issue_context(issue_or_identifier)
    safe_id = safe_identifier(issue_context.issue_identifier)

    with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
         :ok <- validate_workspace_path(workspace, worker_host) do
      case workspace_presence(workspace, worker_host) do
        {:ok, :present} ->
          workspace
          |> git_status_snapshot(worker_host)
          |> normalize_existing_workspace_git_status()

        {:ok, :missing} ->
          {:ok, :missing}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp local_git_status_snapshot(workspace) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      case System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"],
             cd: workspace,
             env: RuntimePaths.cleaned_builtin_system_env(),
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          {:ok, String.trim_trailing(output)}

        {output, status} ->
          {:error, {:workspace_git_status_failed, :local, status, output}}
      end
    end
  end

  defp normalize_existing_workspace_git_status({:error, reason}) do
    if not_git_repository_error?(reason) do
      {:ok, :not_git_repo}
    else
      {:error, reason}
    end
  end

  defp normalize_existing_workspace_git_status(result), do: result

  defp remote_git_status_snapshot(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      case run_remote_command(worker_host, remote_git_status_script(workspace), Config.settings!().hooks.timeout_ms) do
        {:ok, {output, 0}} ->
          {:ok, output |> IO.iodata_to_binary() |> String.trim_trailing()}

        {:ok, {output, status}} ->
          {:error, {:workspace_git_status_failed, worker_host, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp remote_git_status_script(workspace) when is_binary(workspace) do
    [
      remote_hook_env_exports(),
      "cd #{shell_escape(workspace)}",
      "git status --porcelain=v1 --untracked-files=all"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp local_current_branch(workspace) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      case System.cmd("git", ["branch", "--show-current"],
             cd: workspace,
             env: RuntimePaths.cleaned_builtin_system_env(),
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          parse_current_branch_output(output, :local)

        {output, status} ->
          {:error, {:workspace_git_branch_failed, :local, status, output}}
      end
    end
  end

  defp remote_current_branch(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      case run_remote_command(
             worker_host,
             remote_current_branch_script(workspace),
             Config.settings!().hooks.timeout_ms
           ) do
        {:ok, {output, 0}} ->
          parse_current_branch_output(output, worker_host)

        {:ok, {output, status}} ->
          {:error, {:workspace_git_branch_failed, worker_host, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp remote_current_branch_script(workspace) when is_binary(workspace) do
    [
      remote_hook_env_exports(),
      "cd #{shell_escape(workspace)}",
      "git branch --show-current"
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp parse_current_branch_output(output, location) do
    case output |> IO.iodata_to_binary() |> String.trim() do
      "" -> {:error, {:workspace_git_branch_missing, location}}
      branch_name -> {:ok, branch_name}
    end
  end

  defp commit_all_changes_with_message(workspace, message, worker_host)
       when is_binary(workspace) and is_binary(message) do
    case git_status_snapshot(workspace, worker_host) do
      {:ok, ""} ->
        {:ok, :clean}

      {:ok, _status} ->
        commit_workspace_changes(workspace, message, worker_host)

      {:error, reason} ->
        normalize_commit_all_changes_error(reason)
    end
  end

  defp commit_workspace_changes(workspace, message, nil)
       when is_binary(workspace) and is_binary(message) do
    local_commit_all_changes(workspace, message)
  end

  defp commit_workspace_changes(workspace, message, worker_host)
       when is_binary(workspace) and is_binary(message) and is_binary(worker_host) do
    remote_commit_all_changes(workspace, message, worker_host)
  end

  defp normalize_commit_all_changes_error(reason) do
    if not_git_repository_error?(reason) do
      {:ok, :not_git_repo}
    else
      {:error, reason}
    end
  end

  defp local_commit_all_changes(workspace, message)
       when is_binary(workspace) and is_binary(message) do
    with :ok <- validate_workspace_path(workspace, nil),
         :ok <- local_git_add_all(workspace) do
      local_git_commit_with_message(workspace, message)
    end
  end

  defp local_git_add_all(workspace) when is_binary(workspace) do
    case System.cmd("git", ["add", "-A"],
           cd: workspace,
           env: RuntimePaths.cleaned_builtin_system_env(),
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:workspace_git_commit_failed, :local, status, output}}
    end
  end

  defp local_git_commit_with_message(workspace, message)
       when is_binary(workspace) and is_binary(message) do
    case System.cmd(
           "git",
           ["commit" | commit_message_args(message)],
           cd: workspace,
           env: RuntimePaths.cleaned_builtin_system_env(),
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        {:ok, :committed}

      {output, status} ->
        {:error, {:workspace_git_commit_failed, :local, status, output}}
    end
  end

  defp commit_message_args(message) when is_binary(message) do
    [subject | body_lines] =
      message
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.split("\n")

    subject_args = ["-m", String.trim(subject)]
    body = body_lines |> Enum.join("\n") |> String.trim()

    if body == "" do
      subject_args
    else
      subject_args ++ ["-m", body]
    end
  end

  defp remote_commit_message_args(message) when is_binary(message) do
    message
    |> commit_message_args()
    |> Enum.map_join(" ", &shell_escape/1)
  end

  defp remote_commit_all_changes(workspace, message, worker_host)
       when is_binary(workspace) and is_binary(message) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      script =
        [
          remote_hook_env_exports(),
          "cd #{shell_escape(workspace)}",
          "git add -A && git commit #{remote_commit_message_args(message)}"
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
        {:ok, {_output, 0}} ->
          {:ok, :committed}

        {:ok, {output, status}} ->
          {:error, {:workspace_git_commit_failed, worker_host, status, output}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp review_autocommit_marker_present?(workspace, worker_host) when is_binary(workspace) do
    case marker_file_exists?(workspace, worker_host) do
      {:ok, :missing} ->
        {:ok, false}

      {:ok, :not_git_repo} ->
        {:ok, false}

      {:ok, false} ->
        {:ok, false}

      {:ok, true} ->
        {:ok, true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_review_autocommit_marker(workspace, worker_host) when is_binary(workspace) do
    write_review_autocommit_marker(workspace, worker_host)
  end

  defp record_review_autocommit_result({:ok, :clean}, workspace, worker_host) do
    with :ok <- put_review_autocommit_marker(workspace, worker_host) do
      {:ok, :clean}
    end
  end

  defp record_review_autocommit_result({:ok, :committed}, workspace, worker_host) do
    with :ok <- put_review_autocommit_marker(workspace, worker_host) do
      {:ok, :committed}
    end
  end

  defp record_review_autocommit_result(result, _workspace, _worker_host), do: result

  defp marker_file_exists?(workspace, nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      case review_autocommit_marker_path(workspace, nil) do
        {:ok, :not_git_repo} -> {:ok, :not_git_repo}
        {:ok, marker_path} -> {:ok, File.exists?(marker_path)}
        other -> other
      end
    end
  end

  defp marker_file_exists?(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      case review_autocommit_marker_path(workspace, worker_host) do
        {:ok, :not_git_repo} ->
          {:ok, :not_git_repo}

        {:ok, marker_path} ->
          workspace
          |> remote_review_autocommit_marker_exists_script(marker_path)
          |> run_remote_command(worker_host, Config.settings!().hooks.timeout_ms)
          |> handle_remote_marker_result(worker_host, &handle_marker_exists_result/2)

        other ->
          other
      end
    end
  end

  defp write_review_autocommit_marker(workspace, nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      case review_autocommit_marker_path(workspace, nil) do
        {:ok, :not_git_repo} ->
          {:ok, :not_git_repo}

        {:ok, marker_path} ->
          write_review_autocommit_marker_at_path(marker_path, :local)

        other ->
          other
      end
    end
  end

  defp write_review_autocommit_marker(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      case review_autocommit_marker_path(workspace, worker_host) do
        {:ok, :not_git_repo} ->
          {:ok, :not_git_repo}

        {:ok, marker_path} ->
          workspace
          |> remote_write_review_autocommit_marker_script(marker_path)
          |> run_remote_command(worker_host, Config.settings!().hooks.timeout_ms)
          |> handle_remote_marker_result(worker_host, &handle_marker_write_result/2)

        other ->
          other
      end
    end
  end

  defp delete_review_autocommit_marker(workspace, nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      case review_autocommit_marker_path(workspace, nil) do
        {:ok, :not_git_repo} ->
          {:ok, :not_git_repo}

        {:ok, marker_path} ->
          delete_review_autocommit_marker_at_path(marker_path, :local)

        other ->
          other
      end
    end
  end

  defp delete_review_autocommit_marker(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      case review_autocommit_marker_path(workspace, worker_host) do
        {:ok, :not_git_repo} ->
          {:ok, :not_git_repo}

        {:ok, marker_path} ->
          workspace
          |> remote_delete_review_autocommit_marker_script(marker_path)
          |> run_remote_command(worker_host, Config.settings!().hooks.timeout_ms)
          |> handle_remote_marker_result(worker_host, &handle_marker_delete_result/2)

        other ->
          other
      end
    end
  end

  defp review_autocommit_marker_path(workspace, nil) when is_binary(workspace) do
    with :ok <- validate_workspace_path(workspace, nil) do
      "git"
      |> System.cmd(
        ["rev-parse", "--path-format=absolute", "--git-path", @review_autocommit_marker_filename],
        cd: workspace,
        env: RuntimePaths.cleaned_builtin_system_env(),
        stderr_to_stdout: true
      )
      |> handle_git_path_result(:local)
    end
  end

  defp review_autocommit_marker_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    with :ok <- validate_workspace_path(workspace, worker_host) do
      workspace
      |> remote_review_autocommit_marker_path_script()
      |> run_remote_command(worker_host, Config.settings!().hooks.timeout_ms)
      |> handle_remote_marker_result(worker_host, &handle_git_path_result/2)
    end
  end

  defp remote_review_autocommit_marker_path_script(workspace) when is_binary(workspace) do
    remote_git_marker_script(
      workspace,
      "git rev-parse --path-format=absolute --git-path #{shell_escape(@review_autocommit_marker_filename)}"
    )
  end

  defp remote_review_autocommit_marker_exists_script(workspace, marker_path)
       when is_binary(workspace) and is_binary(marker_path) do
    remote_git_marker_script(
      workspace,
      "if [ -f #{shell_escape(marker_path)} ]; then printf 'present\\n'; else printf 'missing\\n'; fi"
    )
  end

  defp remote_write_review_autocommit_marker_script(workspace, marker_path)
       when is_binary(workspace) and is_binary(marker_path) do
    remote_git_marker_script(workspace, "printf 'true\\n' > #{shell_escape(marker_path)}")
  end

  defp remote_delete_review_autocommit_marker_script(workspace, marker_path)
       when is_binary(workspace) and is_binary(marker_path) do
    remote_git_marker_script(workspace, "rm -f #{shell_escape(marker_path)}")
  end

  defp remote_git_marker_script(workspace, command) when is_binary(workspace) and is_binary(command) do
    [
      remote_hook_env_exports(),
      "cd #{shell_escape(workspace)}",
      command
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp handle_remote_marker_result({:ok, command_result}, location, handler)
       when is_function(handler, 2) do
    handler.(command_result, location)
  end

  defp handle_remote_marker_result({:error, reason}, _location, _handler), do: {:error, reason}

  defp handle_git_path_result({output, 0}, _location) do
    {:ok, output |> IO.iodata_to_binary() |> String.trim()}
  end

  defp handle_git_path_result({output, status}, location) do
    handle_git_path_failure(location, status, output)
  end

  defp handle_marker_exists_result({output, 0}, location) do
    case output |> IO.iodata_to_binary() |> String.trim() do
      "present" -> {:ok, true}
      "missing" -> {:ok, :missing}
      other -> {:error, {:workspace_review_autocommit_marker_read_failed, location, :unexpected_output, other}}
    end
  end

  defp handle_marker_exists_result({output, status}, location) do
    {:error, {:workspace_review_autocommit_marker_read_failed, location, status, output}}
  end

  defp handle_marker_write_result({_output, 0}, _location), do: :ok

  defp handle_marker_write_result({output, status}, location) do
    {:error, {:workspace_review_autocommit_marker_write_failed, location, status, output}}
  end

  defp handle_marker_delete_result({_output, 0}, _location), do: :ok

  defp handle_marker_delete_result({output, status}, location) do
    {:error, {:workspace_review_autocommit_marker_delete_failed, location, status, output}}
  end

  defp write_review_autocommit_marker_at_path(marker_path, location)
       when is_binary(marker_path) do
    case File.write(marker_path, "true\n") do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_review_autocommit_marker_write_failed, location, reason}}
    end
  end

  defp delete_review_autocommit_marker_at_path(marker_path, location)
       when is_binary(marker_path) do
    case File.rm(marker_path) do
      :ok -> :ok
      {:error, :enoent} -> {:ok, :missing}
      {:error, reason} -> {:error, {:workspace_review_autocommit_marker_delete_failed, location, reason}}
    end
  end

  defp workspace_presence(workspace, nil) when is_binary(workspace) do
    if File.dir?(workspace), do: {:ok, :present}, else: {:ok, :missing}
  end

  defp workspace_presence(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        remote_hook_env_exports(),
        "if [ -d #{shell_escape(workspace)} ]; then printf 'present\\n'; else printf 'missing\\n'; fi"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        case output |> IO.iodata_to_binary() |> String.trim() do
          "present" -> {:ok, :present}
          "missing" -> {:ok, :missing}
          other -> {:error, {:workspace_presence_unexpected_output, worker_host, other}}
        end

      {:ok, {output, status}} ->
        {:error, {:workspace_presence_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_git_path_failure(location, 128, output) do
    case not_git_repository_output?(output) do
      true -> {:ok, :not_git_repo}
      false -> {:error, {:workspace_git_path_failed, location, 128, output}}
    end
  end

  defp handle_git_path_failure(location, status, output) do
    {:error, {:workspace_git_path_failed, location, status, output}}
  end

  defp not_git_repository_error?({:workspace_git_status_failed, _location, 128, output}) do
    not_git_repository_output?(output)
  end

  defp not_git_repository_error?(_reason), do: false

  defp not_git_repository_output?(output) do
    normalized_output =
      output
      |> IO.iodata_to_binary()
      |> String.downcase()

    String.contains?(normalized_output, [
      "not a git repository",
      "inside a git repository",
      "kein git-repository"
    ])
  end

  defp ensure_expected_branch(workspace, _expected_branch, issue_context, worker_host)
       when is_binary(workspace) do
    case current_branch(workspace, worker_host) do
      {:ok, branch_name} ->
        {:ok, branch_name}

      {:error, _reason} ->
        case run_after_create_hook(workspace, issue_context, worker_host) do
          :ok -> current_branch(workspace, worker_host)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    HookRunner.run_local(
      command,
      workspace,
      hook_name,
      env: RuntimePaths.cleaned_builtin_system_env(),
      timeout_ms: Config.settings!().hooks.timeout_ms,
      log_context: %{
        issue_id: issue_context.issue_id,
        issue_identifier: issue_context.issue_identifier,
        workspace: workspace,
        worker_host: "local"
      }
    )
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        remote_hook_env_exports(),
        "cd #{shell_escape(workspace)} && #{command}"
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp remote_hook_env_exports do
    unsets =
      (RuntimePaths.runtime_env_names() ++ Config.linear_secret_env_names())
      |> Enum.map_join("\n", fn key -> "unset #{key}" end)

    exports =
      RuntimePaths.builtin_env()
      |> Map.put("SYMPHONY_LINEAR_SECRET_ACCESS", "denied")
      |> Map.put("SYMPHONY_LINEAR_AUTH_MODE", Config.settings!().tracker.auth_mode)
      |> Enum.map_join("\n", fn {key, value} ->
        "export #{key}=#{shell_escape(value)}"
      end)

    [unsets, exports]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
