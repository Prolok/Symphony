defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.Linear.IssueLease
  alias SymphonyElixir.Linear.WriteContext

  alias SymphonyElixir.{
    AutocommitMessage,
    Codex.AppServer,
    Config,
    Dialog,
    Linear.Issue,
    PromptBuilder,
    RuntimePaths,
    Tracker,
    Workflow,
    Workpad,
    Workspace
  }

  @type worker_host :: String.t() | nil
  @prereview_codex_state_name "prereview (ai)"
  @review_codex_state_name "review (ai)"
  @test_codex_state_name "test (ai)"
  @implementation_handoff_state_name "Freigabe Implementierung"
  @review_handoff_state_name "Freigabe Review"
  @review_no_findings_handoff_state_name "Test (AI)"
  @test_handoff_state_name "Merge (AI)"
  @merge_codex_state_name "merge (ai)"
  @merge_handoff_state_name "Review"
  @merge_rerun_state_name "Test (AI)"
  @manual_todo_state_name "todo"
  @manual_in_progress_state_name "in arbeit"
  @ignored_manual_state_names [
    @manual_todo_state_name,
    "in arbeit",
    "freigabe",
    "planung",
    "freigabe implementierung",
    "freigabe review",
    "freigabe final"
  ]
  @yolo_skip_state_names [
    "freigabe implementierung",
    "freigabe review"
  ]
  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    result =
      WriteContext.with_context(
        %{issue_id: issue.id, phase: issue.state, run_id: Ecto.UUID.generate()},
        fn -> IssueLease.run(issue, fn -> run_on_worker_host(issue, codex_update_recipient, opts, worker_host) end) end
      )

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    case maybe_skip_manual_issue_state(issue, issue_state_fetcher, worker_host) do
      {:ok, %Issue{}, :stop} ->
        :ok

      {:bootstrap_only, %Issue{} = manual_issue} ->
        bootstrap_manual_in_progress_issue(manual_issue, codex_update_recipient, worker_host)

      :todo_noop ->
        Logger.info("Skipping manual Todo issue state for #{issue_context(issue)} state=#{inspect(issue.state)}")
        :ok

      :manual_noop ->
        Logger.info("Skipping manual-only issue state for #{issue_context(issue)} state=#{inspect(issue.state)}")
        maybe_clear_review_autocommit_marker_for_existing_workspace(issue, worker_host)

      :dialog ->
        run_dialog_issue(issue, codex_update_recipient, worker_host, opts)

      :proceed ->
        run_regular_issue(issue, codex_update_recipient, opts, worker_host)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_regular_issue(issue, codex_update_recipient, opts, worker_host) do
    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host),
               :ok <- maybe_sync_issue_branch_name(issue, workspace, worker_host),
               :ok <- maybe_prepare_workspace_for_issue_run(issue, workspace, worker_host, opts) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_skip_manual_issue_state(%Issue{} = issue, issue_state_fetcher, _worker_host) do
    cond do
      Dialog.state?(issue.state) ->
        :dialog

      manual_todo_issue_state?(issue.state) ->
        :todo_noop

      manual_in_progress_issue_state?(issue.state) ->
        {:bootstrap_only, issue}

      not ignored_manual_state?(issue.state) ->
        :proceed

      not skip_current_manual_state?(issue) ->
        :manual_noop

      true ->
        case Workflow.resolve_next_status(issue.state, Issue.label_names(issue)) do
          next_state when is_binary(next_state) ->
            transition_issue_state(
              issue,
              issue_state_fetcher,
              next_state,
              :manual_skip_state_update_failed,
              "skipped manual issue state",
              :stop
            )

          _ ->
            :manual_noop
        end
    end
  end

  defp bootstrap_manual_in_progress_issue(%Issue{} = issue, codex_update_recipient, worker_host) do
    Logger.info("Bootstrapping workspace for manual in-progress issue #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        with :ok <- maybe_clear_review_autocommit_marker(issue, workspace, worker_host) do
          maybe_sync_issue_branch_name(issue, workspace, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp skip_current_manual_state?(%Issue{} = issue) do
    current_state = normalize_issue_state(issue.state)

    (Config.yolo?() and current_state in @yolo_skip_state_names) or
      issue
      |> Issue.label_names()
      |> Enum.map(&normalize_issue_state/1)
      |> Enum.any?(fn label ->
        label == ~s(skip "#{current_state}") or label == "skip #{current_state}"
      end)
  end

  defp manual_todo_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @manual_todo_state_name
  end

  defp manual_todo_issue_state?(_state_name), do: false

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_completion_contract_update(recipient, %Issue{id: issue_id}, contract)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:agent_completion_contract, issue_id, contract})
    :ok
  end

  defp send_completion_contract_update(_recipient, _issue, _contract), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    turn_context = %{
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      worker_host: worker_host,
      max_turns: max_turns
    }

    continue_run_codex_turns(:continue, turn_context, issue)
  end

  defp run_dialog_issue(%Issue{} = issue, codex_update_recipient, _worker_host, opts) do
    workspace = RuntimePaths.project_root()

    with {:ok, request} <- dialog_request(issue, workspace, opts) do
      case request do
        :noop ->
          Logger.info("Skipping dialog issue because the latest relevant comment is already a Symphony answer: #{issue_context(issue)}")
          :ok

        %{session_id: session_id} = request ->
          send_worker_runtime_info(codex_update_recipient, issue, nil, workspace)
          run_dialog_codex_turn(issue, workspace, request, session_id, codex_update_recipient)
      end
    end
  end

  defp dialog_request(%Issue{} = issue, workspace, opts) when is_binary(workspace) and is_list(opts) do
    case Keyword.get(opts, :dialog_request) do
      %{prompt: prompt} = request when is_binary(prompt) ->
        {:ok, request}

      :noop ->
        {:ok, :noop}

      _ ->
        with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id) do
          Dialog.next_request(issue, comments, workspace)
        end
    end
  end

  defp run_dialog_codex_turn(
         %Issue{} = issue,
         workspace,
         request,
         session_id,
         codex_update_recipient
       ) do
    with {:ok, before_repo_status} <- dialog_repo_status_snapshot(workspace) do
      workspace
      |> start_dialog_app_session(session_id)
      |> handle_dialog_session_start(
        issue,
        workspace,
        request,
        codex_update_recipient,
        before_repo_status
      )
    end
  end

  defp start_dialog_app_session(workspace, session_id) when is_binary(workspace) do
    AppServer.start_session(workspace,
      thread_id: session_id,
      dialog: true,
      allow_source_repo_cwd: true,
      launch_cwd: RuntimePaths.project_root()
    )
  rescue
    exception ->
      {:error, {:dialog_session_start_failed, Exception.format(:error, exception, __STACKTRACE__)}}
  catch
    kind, reason ->
      {:error, {:dialog_session_start_failed, Exception.format(kind, reason, __STACKTRACE__)}}
  end

  defp handle_dialog_session_start(
         {:ok, app_session},
         issue,
         workspace,
         request,
         codex_update_recipient,
         before_repo_status
       ) do
    run_dialog_app_session_turn(
      app_session,
      issue,
      workspace,
      request,
      codex_update_recipient,
      before_repo_status
    )
  end

  defp handle_dialog_session_start(
         {:error, reason},
         issue,
         workspace,
         request,
         _codex_update_recipient,
         before_repo_status
       ) do
    case ensure_dialog_repo_unchanged(workspace, before_repo_status) do
      :ok -> maybe_finalize_dialog_session_start_error(issue, request, reason)
      {:error, repo_reason} -> maybe_finalize_dirty_dialog_session_start_error(issue, request, reason, repo_reason)
    end
  end

  defp run_dialog_app_session_turn(
         app_session,
         issue,
         workspace,
         request,
         codex_update_recipient,
         before_repo_status
       ) do
    message_key = {__MODULE__, :dialog_messages}
    Process.put(message_key, [])

    on_message = fn message ->
      Process.put(message_key, [message | Process.get(message_key, [])])
      send_codex_update(codex_update_recipient, issue, message)
    end

    turn_result = run_dialog_app_turn(app_session, request.prompt, issue, on_message)
    repo_check_result = ensure_dialog_repo_unchanged(workspace, before_repo_status)

    case {repo_check_result, turn_result} do
      {:ok, {:ok, turn_session}} ->
        maybe_post_dialog_answer(issue, request, turn_session, message_key)

      {{:error, reason}, {:ok, turn_session}} ->
        maybe_post_dialog_repo_error_answer(issue, request, turn_session, reason)

      {{:error, reason}, {:error, _turn_reason}} ->
        maybe_post_dialog_repo_error_answer(issue, request, app_session, reason)

      {:ok, {:error, reason}} ->
        maybe_finalize_dialog_turn_error(issue, request, app_session, reason)
    end
  after
    Process.delete({__MODULE__, :dialog_messages})
    AppServer.stop_session(app_session)
  end

  defp maybe_post_dialog_answer(issue, request, turn_session, message_key) do
    with {:ok, comments} <- Tracker.fetch_issue_comments(issue.id),
         true <- Dialog.request_current?(request, comments),
         messages <- Process.get(message_key, []) |> Enum.reverse(),
         answer when is_binary(answer) <- Dialog.final_answer_from_messages(messages) do
      Tracker.create_comment(
        issue.id,
        Dialog.format_answer_comment(answer, turn_session[:thread_id], request.include_session?)
      )
    else
      false ->
        Logger.info("Skipping stale dialog answer because a newer user comment exists: #{issue_context(issue)}")
        :ok

      nil ->
        {:error, :dialog_answer_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_post_dialog_repo_error_answer(issue, request, turn_session, reason) do
    maybe_post_dialog_repo_error_answer(issue, request, turn_session, reason, [])
  end

  defp maybe_post_dialog_repo_error_answer(issue, request, turn_session, reason, opts) do
    session_id = dialog_session_id(turn_session)
    reset_session? = Keyword.get(opts, :reset_session?, false)
    source_key = Dialog.request_source_key(request)

    Logger.warning("Finalizing dialog issue after repository guard error for #{issue_context(issue)} session_id=#{session_id_for_log(session_id)} reason=#{inspect(reason)}")

    answer_comment =
      case dialog_request_freshness(issue, request, "repository error answer") do
        :current ->
          dialog_repo_error_answer_comment(turn_session, request, reset_session?, false, nil)

        :stale ->
          Logger.info("Posting nonblocking stale dialog repository error answer because a newer user comment exists: #{issue_context(issue)}")
          dialog_repo_error_answer_comment(turn_session, request, reset_session?, true, source_key)

        :unknown ->
          Logger.info("Posting source-scoped nonblocking dialog repository error answer because comment freshness could not be verified: #{issue_context(issue)}")
          dialog_repo_error_answer_comment(turn_session, request, reset_session?, true, source_key)
      end

    Tracker.create_comment(issue.id, answer_comment)
  end

  defp dialog_repo_error_answer_comment(_turn_session, _request, true, false, _source_key) do
    Dialog.format_session_reset_answer_comment(dialog_repo_error_answer())
  end

  defp dialog_repo_error_answer_comment(_turn_session, _request, true, true, source_key) do
    Dialog.format_nonblocking_session_reset_answer_comment(dialog_repo_error_answer(), source_key)
  end

  defp dialog_repo_error_answer_comment(turn_session, request, false, false, _source_key) do
    Dialog.format_answer_comment(dialog_repo_error_answer(), turn_session[:thread_id], request.include_session?)
  end

  defp dialog_repo_error_answer_comment(turn_session, request, false, true, source_key) do
    Dialog.format_nonblocking_answer_comment(
      dialog_repo_error_answer(),
      turn_session[:thread_id],
      request.include_session?,
      source_key
    )
  end

  defp dialog_request_freshness(issue, request, answer_context) do
    case Tracker.fetch_issue_comments(issue.id) do
      {:ok, comments} ->
        if Dialog.request_current?(request, comments), do: :current, else: :stale

      {:error, reason} ->
        Logger.warning("Could not refresh dialog comments before #{answer_context} for #{issue_context(issue)} reason=#{inspect(reason)}")
        :unknown
    end
  end

  defp maybe_finalize_dirty_dialog_session_start_error(issue, request, {:thread_resume_failed, session_id, _reason}, repo_reason)
       when is_binary(session_id) do
    case Map.get(request, :session_id) do
      ^session_id ->
        maybe_post_dialog_repo_error_answer(
          issue,
          request,
          %{thread_id: session_id},
          repo_reason,
          reset_session?: true
        )

      _other ->
        {:error, {:dialog_session_start_failed_after_repo_modified, {:thread_resume_failed, session_id}, repo_reason}}
    end
  end

  defp maybe_finalize_dirty_dialog_session_start_error(_issue, _request, reason, repo_reason) do
    {:error, {:dialog_session_start_failed_after_repo_modified, reason, repo_reason}}
  end

  defp maybe_finalize_dialog_session_start_error(issue, request, {:thread_resume_failed, session_id, reason})
       when is_binary(session_id) do
    case Map.get(request, :session_id) do
      ^session_id -> maybe_post_dialog_session_error_answer(issue, request, session_id, reason)
      _other -> {:error, {:thread_resume_failed, session_id, reason}}
    end
  end

  defp maybe_finalize_dialog_session_start_error(_issue, _request, reason), do: {:error, reason}

  defp maybe_post_dialog_session_error_answer(issue, request, session_id, reason) do
    source_key = Dialog.request_source_key(request)

    case dialog_request_freshness(issue, request, "dialog session error answer") do
      :current ->
        Logger.warning("Finalizing dialog issue after dialog session error for #{issue_context(issue)} session_id=#{session_id_for_log(session_id)} reason=#{inspect(reason)}")

        Tracker.create_comment(
          issue.id,
          Dialog.format_session_reset_answer_comment(dialog_session_error_answer())
        )

      freshness when freshness in [:stale, :unknown] ->
        Logger.info("Posting source-scoped nonblocking dialog session error answer for #{issue_context(issue)} freshness=#{freshness}")

        Tracker.create_comment(
          issue.id,
          Dialog.format_nonblocking_session_reset_answer_comment(dialog_session_error_answer(), source_key)
        )
    end
  end

  defp dialog_repo_error_answer do
    "Ich konnte die Dialoganfrage nicht abschließen, weil der Codex-Lauf Änderungen am Repository hinterlassen hat. Code-, Dokumentations- und Konfigurationsänderungen sind in `Todo (Dialog-AI)` nicht erlaubt. Bitte stelle die Anfrage so, dass sie ohne Repository-Änderungen beantwortet werden kann."
  end

  defp dialog_session_error_answer do
    "Ich konnte die bestehende Dialogsitzung nicht fortsetzen, weil der Codex-Lauf die gespeicherte Session nicht öffnen konnte. Bitte stelle die Anfrage erneut als neuen Linear-Kommentar."
  end

  defp maybe_finalize_dialog_turn_error(issue, request, app_session, reason) do
    if finalizable_dialog_turn_error?(reason) do
      maybe_post_dialog_turn_error_answer(issue, request, app_session, reason)
    else
      {:error, reason}
    end
  end

  defp finalizable_dialog_turn_error?({:approval_required, _payload}), do: true
  defp finalizable_dialog_turn_error?({:turn_input_required, _payload}), do: true
  defp finalizable_dialog_turn_error?({:turn_failed, _payload}), do: true
  defp finalizable_dialog_turn_error?(_reason), do: false

  defp maybe_post_dialog_turn_error_answer(issue, request, app_session, reason) do
    session_id = dialog_session_id(app_session)

    case dialog_request_freshness(issue, request, "non-interactive dialog error answer") do
      :current ->
        Logger.warning("Finalizing dialog issue after non-interactive turn error for #{issue_context(issue)} session_id=#{session_id_for_log(session_id)} reason=#{inspect(reason)}")

        Tracker.create_comment(
          issue.id,
          Dialog.format_answer_comment(
            dialog_turn_error_answer(reason),
            Map.get(app_session, :thread_id),
            Map.get(request, :include_session?, false)
          )
        )

      :stale ->
        Logger.info("Skipping stale dialog error answer because a newer user comment exists: #{issue_context(issue)}")
        :ok

      :unknown ->
        Logger.info("Posting source-scoped nonblocking dialog error answer because comment freshness could not be verified: #{issue_context(issue)}")

        Tracker.create_comment(
          issue.id,
          Dialog.format_nonblocking_answer_comment(
            dialog_turn_error_answer(reason),
            Map.get(app_session, :thread_id),
            Map.get(request, :include_session?, false),
            Dialog.request_source_key(request)
          )
        )
    end
  end

  defp dialog_turn_error_answer({:approval_required, _payload}) do
    "Ich konnte die Dialoganfrage nicht abschließen, weil der Codex-Lauf in dieser nicht-interaktiven Dialog-Sitzung eine interaktive Genehmigung benötigt hat. Bitte formuliere die nächste Anfrage so, dass sie ohne interaktive Genehmigung beantwortet werden kann."
  end

  defp dialog_turn_error_answer({:turn_input_required, _payload}) do
    "Ich konnte die Dialoganfrage nicht abschließen, weil der Codex-Lauf zusätzliche interaktive Eingabe benötigt hat. Bitte ergänze die fehlenden Angaben als neuen Linear-Kommentar."
  end

  defp dialog_turn_error_answer({:turn_failed, _payload}) do
    "Ich konnte die Dialoganfrage nicht abschließen, weil der Codex-Turn fehlgeschlagen ist. Bitte ergänze den Kontext oder stelle die Anfrage erneut als neuen Linear-Kommentar."
  end

  defp dialog_session_id(session) when is_map(session) do
    thread_id = session |> Map.get(:thread_id) |> non_empty_string_or(Map.get(session, "thread_id"))
    turn_id = session |> Map.get(:turn_id) |> non_empty_string_or(Map.get(session, "turn_id"))

    combine_dialog_session_id(thread_id, turn_id)
  end

  defp non_empty_string_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp non_empty_string_or(_value, fallback) when is_binary(fallback) and fallback != "", do: fallback
  defp non_empty_string_or(_value, _fallback), do: nil

  defp combine_dialog_session_id(nil, _turn_id), do: nil
  defp combine_dialog_session_id(thread_id, nil), do: thread_id
  defp combine_dialog_session_id(thread_id, turn_id), do: "#{thread_id}-#{turn_id}"

  defp session_id_for_log(session_id) when is_binary(session_id) and session_id != "", do: session_id
  defp session_id_for_log(_session_id), do: "unknown"

  defp run_dialog_app_turn(app_session, prompt, issue, on_message) when is_function(on_message, 1) do
    AppServer.run_turn(app_session, prompt, issue, on_message: on_message)
  rescue
    exception ->
      {:error, {:dialog_turn_failed, Exception.format(:error, exception, __STACKTRACE__)}}
  catch
    kind, reason ->
      {:error, {:dialog_turn_failed, Exception.format(kind, reason, __STACKTRACE__)}}
  end

  defp dialog_repo_status_snapshot(workspace) when is_binary(workspace) do
    dialog_git_snapshot_command(workspace, [
      "status",
      "--porcelain=v1",
      "--untracked-files=normal",
      "-z"
    ])
  end

  defp ensure_dialog_repo_unchanged(workspace, before_repo_status) when is_binary(workspace) do
    with {:ok, after_repo_status} <- dialog_repo_status_snapshot(workspace) do
      if after_repo_status == "" do
        :ok
      else
        {:error, {:dialog_repo_modified, before_repo_status, after_repo_status}}
      end
    end
  end

  defp dialog_git_snapshot_command(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.cmd("git", args,
           cd: workspace,
           env: RuntimePaths.cleaned_builtin_system_env(),
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, {:dialog_git_snapshot_failed, args, status, output}}
    end
  end

  defp continue_run_codex_turns(:continue, turn_context, issue) when is_map(turn_context) do
    workspace = turn_context.workspace
    worker_host = turn_context.worker_host

    case AppServer.start_session(workspace, worker_host: worker_host, issue: issue) do
      {:ok, session} ->
        run_context = %{
          app_session: session,
          workspace: workspace,
          codex_update_recipient: turn_context.codex_update_recipient,
          opts: turn_context.opts,
          issue_state_fetcher: turn_context.issue_state_fetcher,
          worker_host: worker_host,
          max_turns: turn_context.max_turns
        }

        try do
          do_run_codex_turns(run_context, issue, 1, :initial)
        after
          AppServer.stop_session(session)
        end

      {:error, reason} ->
        handle_run_error(reason, issue, turn_context)
    end
  end

  defp do_run_codex_turns(turn_context, issue, turn_number, previous_turn_outcome)
       when is_map(turn_context) do
    opts = turn_context.opts
    max_turns = turn_context.max_turns

    prompt =
      build_turn_prompt(
        issue,
        turn_context.workspace,
        opts,
        turn_number,
        max_turns,
        previous_turn_outcome
      )

    turn_context.app_session
    |> AppServer.run_turn(
      prompt,
      issue,
      on_message: codex_message_handler(turn_context.codex_update_recipient, issue)
    )
    |> handle_turn_result(turn_context, issue, turn_number)
  end

  defp handle_turn_result({:ok, turn_session}, turn_context, issue, turn_number) do
    Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}")

    issue
    |> continue_with_issue?(
      turn_context.issue_state_fetcher,
      turn_context.workspace,
      turn_context.worker_host
    )
    |> continue_turn(
      turn_context,
      turn_number,
      :completed,
      "after normal turn completion",
      "with issue still active"
    )
  end

  defp handle_turn_result({:error, {:turn_cancelled, reason}}, turn_context, issue, turn_number) do
    Logger.warning("Codex turn cancelled for #{issue_context(issue)} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}: #{inspect(reason)}")

    issue
    |> continue_after_cancelled_turn?(
      turn_context.issue_state_fetcher,
      turn_context.workspace,
      turn_context.worker_host
    )
    |> continue_turn(
      turn_context,
      turn_number,
      :cancelled,
      "after interrupted turn",
      "after interrupted turn"
    )
  end

  defp handle_turn_result({:error, reason}, turn_context, issue, _turn_number) do
    handle_run_error(reason, issue, turn_context)
  end

  defp continue_turn(
         {:continue, refreshed_issue, {:incomplete_phase, reason} = previous_turn_outcome},
         turn_context,
         turn_number,
         _previous_turn_outcome,
         _continuation_message,
         _max_turns_message
       )
       when turn_number < turn_context.max_turns do
    reason_label = incomplete_phase_reason_label(reason)

    Logger.warning("Continuing agent run for #{issue_context(refreshed_issue)} after incomplete phase completion contract reason=#{reason_label} turn=#{turn_number}/#{turn_context.max_turns}")

    do_run_codex_turns(turn_context, refreshed_issue, turn_number + 1, previous_turn_outcome)
  end

  defp continue_turn(
         {:continue, refreshed_issue, {:incomplete_phase, reason}},
         turn_context,
         turn_number,
         _previous_turn_outcome,
         _continuation_message,
         _max_turns_message
       ) do
    reason_label = incomplete_phase_reason_label(reason)

    Logger.warning(
      "Reached agent.max_turns for #{issue_context(refreshed_issue)} with incomplete phase completion contract reason=#{reason_label}; returning control to orchestrator turn=#{turn_number}/#{turn_context.max_turns}"
    )

    send_completion_contract_update(
      turn_context.codex_update_recipient,
      refreshed_issue,
      {:incomplete_phase_max_turns, reason}
    )

    :ok
  end

  defp continue_turn(
         {:continue, refreshed_issue},
         turn_context,
         turn_number,
         previous_turn_outcome,
         continuation_message,
         _max_turns_message
       )
       when turn_number < turn_context.max_turns do
    Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} #{continuation_message} turn=#{turn_number}/#{turn_context.max_turns}")

    do_run_codex_turns(turn_context, refreshed_issue, turn_number + 1, previous_turn_outcome)
  end

  defp continue_turn(
         {:continue, refreshed_issue},
         turn_context,
         turn_number,
         _previous_turn_outcome,
         _continuation_message,
         max_turns_message
       ) do
    Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} #{max_turns_message}; returning control to orchestrator turn=#{turn_number}/#{turn_context.max_turns}")

    :ok
  end

  defp continue_turn(
         {:done, _refreshed_issue},
         _turn_context,
         _turn_number,
         _previous_turn_outcome,
         _continuation_message,
         _max_turns_message
       ),
       do: :ok

  defp continue_turn(
         {:error, reason},
         _turn_context,
         _turn_number,
         _previous_turn_outcome,
         _continuation_message,
         _max_turns_message
       ),
       do: {:error, reason}

  defp build_turn_prompt(issue, workspace, opts, 1, _max_turns, _previous_turn_outcome) do
    prompt_opts =
      opts
      |> Keyword.put_new(:session_mode, :orchestrated)
      |> Keyword.put(:active_repo_root, workspace)

    PromptBuilder.build_prompt(issue, prompt_opts)
  end

  defp build_turn_prompt(
         %Issue{} = issue,
         _workspace,
         _opts,
         turn_number,
         max_turns,
         previous_turn_outcome
       ) do
    Workflow.prompt_snippet("continuation_guidance", %{
      continuation_intro: continuation_intro(previous_turn_outcome),
      turn_number: turn_number,
      max_turns: max_turns,
      issue_state: issue.state
    })
  end

  defp continuation_intro(:cancelled) do
    Workflow.prompt_snippet("continuation_intro_cancelled")
  end

  defp continuation_intro({:incomplete_phase, reason}) do
    Workflow.prompt_snippet("continuation_intro_incomplete_phase", %{
      reason: incomplete_phase_reason_text(reason)
    })
  end

  defp continuation_intro(_previous_turn_outcome) do
    Workflow.prompt_snippet("continuation_intro_completed")
  end

  defp incomplete_phase_reason_label(reason) do
    reason
    |> incomplete_phase_reason_text()
    |> String.replace(~r/\s+/, "_")
  end

  defp incomplete_phase_reason_text({:open_workpad_checklist, section_title}) when is_binary(section_title) do
    "offene Workpad-Checkliste #{section_title}"
  end

  defp incomplete_phase_reason_text({:missing_workpad_checklist, section_title}) when is_binary(section_title) do
    "fehlende oder unvollständige Workpad-Checkliste #{section_title}"
  end

  defp incomplete_phase_reason_text({:workpad_checklist_inspection_failed, section_titles}) when is_list(section_titles) do
    "Workpad-Checklistenprüfung fehlgeschlagen für #{format_section_titles(section_titles)}"
  end

  defp incomplete_phase_reason_text(:merge_evidence_missing) do
    "fehlende oder unvollständige Merge-Evidenz"
  end

  defp incomplete_phase_reason_text(:merge_evidence_inspection_failed) do
    "Merge-Evidenzprüfung fehlgeschlagen"
  end

  defp incomplete_phase_reason_text(:merge_workspace_inspection_failed) do
    "Merge-Workspace-Statusprüfung fehlgeschlagen"
  end

  defp incomplete_phase_reason_text(:review_checklist_inspection_failed) do
    "Review-Checklistenprüfung fehlgeschlagen"
  end

  defp incomplete_phase_reason_text(reason) do
    inspect(reason)
  end

  defp continue_with_issue?(
         %Issue{id: issue_id} = started_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        resolve_issue_continuation(
          started_issue,
          refreshed_issue,
          issue_state_fetcher,
          workspace,
          worker_host
        )

      {:ok, []} ->
        {:done, started_issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(
         started_issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host
       ),
       do: {:done, started_issue}

  defp continue_after_cancelled_turn?(
         %Issue{id: issue_id} = started_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       )
       when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        with :ok <-
               maybe_clear_review_autocommit_marker_after_review_departure(
                 started_issue,
                 refreshed_issue,
                 workspace,
                 worker_host
               ) do
          cancelled_turn_continuation_status(
            started_issue,
            refreshed_issue,
            issue_state_fetcher,
            workspace,
            worker_host
          )
        end

      {:ok, []} ->
        {:done, started_issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_after_cancelled_turn?(
         started_issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host
       ),
       do: {:done, started_issue}

  defp cancelled_turn_continuation_status(
         %Issue{} = started_issue,
         %Issue{} = refreshed_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    if state_changed_during_turn?(started_issue, refreshed_issue) do
      Logger.info(
        "Stopping interrupted agent run after tracker status changed: #{issue_context(refreshed_issue)} previous_state=#{inspect(started_issue.state)} current_state=#{inspect(refreshed_issue.state)}"
      )

      with {:ok, %Issue{} = current_issue, continuation_mode} <-
             maybe_redirect_dirty_merge_handoff(
               started_issue,
               refreshed_issue,
               issue_state_fetcher,
               workspace,
               worker_host
             ) do
        continuation_status(current_issue, continuation_mode)
      end
    else
      maybe_redirect_dirty_cancelled_merge_turn(
        started_issue,
        refreshed_issue,
        issue_state_fetcher,
        workspace,
        worker_host
      )
    end
  end

  defp resolve_issue_continuation(
         %Issue{} = started_issue,
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    with {:ok, %Issue{} = current_issue, continuation_mode} <-
           maybe_finalize_active_codex_issue(
             started_issue,
             issue,
             issue_state_fetcher,
             workspace,
             worker_host
           ) do
      continuation_status(current_issue, continuation_mode)
    end
  end

  defp continuation_status(%Issue{} = issue, :stop) do
    {:done, issue}
  end

  defp continuation_status(%Issue{} = issue, {:incomplete_phase, _reason} = continuation_mode) do
    if active_issue_state?(issue.state) do
      {:continue, issue, continuation_mode}
    else
      {:done, issue}
    end
  end

  defp continuation_status(%Issue{} = issue, _continuation_mode) do
    if active_issue_state?(issue.state) do
      {:continue, issue}
    else
      {:done, issue}
    end
  end

  defp maybe_finalize_active_codex_issue(
         %Issue{} = started_issue,
         %Issue{id: issue_id} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       )
       when is_binary(issue_id) do
    result =
      if state_changed_during_turn?(started_issue, issue) do
        Logger.info("Stopping agent run after tracker status changed: #{issue_context(issue)} previous_state=#{inspect(started_issue.state)} current_state=#{inspect(issue.state)}")

        maybe_redirect_dirty_merge_handoff(
          started_issue,
          issue,
          issue_state_fetcher,
          workspace,
          worker_host
        )
      else
        case codex_issue_finalize_mode(started_issue.state) do
          {:transition, error_event, log_label} ->
            maybe_transition_completed_codex_issue(
              issue,
              issue_state_fetcher,
              error_event,
              log_label
            )

          :review ->
            maybe_finalize_review_codex_issue(
              issue,
              issue_state_fetcher,
              workspace,
              worker_host
            )

          :test ->
            maybe_finalize_test_codex_issue(
              issue,
              issue_state_fetcher,
              workspace,
              worker_host
            )

          :merge ->
            maybe_finalize_merge_codex_issue(
              issue,
              issue_state_fetcher,
              workspace,
              worker_host
            )

          :normal ->
            {:ok, issue, :normal}
        end
      end

    with {:ok, %Issue{} = current_issue, continuation_mode} <- result,
         :ok <-
           maybe_clear_review_autocommit_marker_after_review_departure(
             started_issue,
             current_issue,
             workspace,
             worker_host
           ) do
      {:ok, current_issue, continuation_mode}
    end
  end

  defp maybe_finalize_active_codex_issue(
         _started_issue,
         %Issue{} = issue,
         _issue_state_fetcher,
         _workspace,
         _worker_host
       ),
       do: {:ok, issue, :normal}

  defp maybe_redirect_dirty_merge_handoff(
         %Issue{} = started_issue,
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    if merge_codex_state?(started_issue.state) and
         normalize_issue_state(issue.state) == normalize_issue_state(@merge_handoff_state_name) do
      case merge_workspace_rerun_status(workspace, worker_host) do
        :rerun ->
          Logger.warning("Redirecting dirty merge handoff to test rerun: #{issue_context(issue)} previous_state=#{inspect(started_issue.state)} current_state=#{inspect(issue.state)}")

          transition_issue_state(
            issue,
            issue_state_fetcher,
            @merge_rerun_state_name,
            :merge_rerun_state_update_failed,
            "changed merge issue with workspace changes",
            :stop
          )

        _clean_or_error ->
          {:ok, issue, :stop}
      end
    else
      {:ok, issue, :stop}
    end
  end

  defp maybe_redirect_dirty_cancelled_merge_turn(
         %Issue{} = started_issue,
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    if merge_codex_state?(started_issue.state) and merge_codex_state?(issue.state) do
      maybe_redirect_dirty_cancelled_merge_workspace(issue, issue_state_fetcher, workspace, worker_host)
    else
      continuation_status(issue, :normal)
    end
  end

  defp maybe_redirect_dirty_cancelled_merge_workspace(issue, issue_state_fetcher, workspace, worker_host) do
    case merge_workspace_rerun_status(workspace, worker_host) do
      :rerun ->
        redirect_dirty_cancelled_merge_workspace(issue, issue_state_fetcher)

      _clean_or_error ->
        continuation_status(issue, :normal)
    end
  end

  defp redirect_dirty_cancelled_merge_workspace(%Issue{} = issue, issue_state_fetcher) do
    Logger.warning("Redirecting dirty interrupted merge turn to test rerun: #{issue_context(issue)} state=#{inspect(issue.state)}")

    case transition_issue_state(
           issue,
           issue_state_fetcher,
           @merge_rerun_state_name,
           :merge_rerun_state_update_failed,
           "interrupted merge issue with workspace changes",
           :stop
         ) do
      {:ok, %Issue{} = current_issue, continuation_mode} ->
        continuation_status(current_issue, continuation_mode)

      {:error, _reason} = error ->
        error
    end
  end

  defp codex_issue_finalize_mode(state) do
    cond do
      prereview_codex_state?(state) ->
        {:transition, :prereview_handoff_state_update_failed, "completed prereview issue"}

      review_codex_state?(state) ->
        :review

      test_codex_state?(state) ->
        :test

      merge_codex_state?(state) ->
        :merge

      true ->
        :normal
    end
  end

  defp refetch_issue(%Issue{id: issue_id} = issue, issue_state_fetcher, fallback_state)
       when is_binary(issue_id) and is_binary(fallback_state) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        {:ok, coerce_stale_issue_state(refreshed_issue, issue.state, fallback_state)}

      {:ok, []} ->
        {:ok, %{issue | state: fallback_state}}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp coerce_stale_issue_state(%Issue{} = refreshed_issue, previous_state, fallback_state)
       when is_binary(previous_state) and is_binary(fallback_state) do
    refreshed_state = normalize_issue_state(refreshed_issue.state)
    previous_state = normalize_issue_state(previous_state)
    normalized_fallback_state = normalize_issue_state(fallback_state)

    if refreshed_state == previous_state and normalized_fallback_state != previous_state do
      %{refreshed_issue | state: fallback_state}
    else
      refreshed_issue
    end
  end

  defp handle_run_error(reason, %Issue{} = issue, turn_context) when is_map(turn_context) do
    case maybe_clear_review_autocommit_marker_after_review_error(
           issue,
           turn_context.issue_state_fetcher,
           turn_context.workspace,
           turn_context.worker_host
         ) do
      :ok ->
        {:error, reason}

      {:error, cleanup_reason} ->
        {:error, {:review_error_cleanup_failed, reason, cleanup_reason}}
    end
  end

  defp maybe_finalize_test_codex_issue(
         %Issue{} = issue,
         issue_state_fetcher,
         _workspace,
         _worker_host
       ) do
    maybe_transition_after_closed_workpad_sections(
      issue,
      issue_state_fetcher,
      ["Test", "Validierung"],
      :test_handoff_state_update_failed,
      "completed test issue"
    )
  end

  defp maybe_finalize_merge_codex_issue(
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    case merge_workspace_rerun_status(workspace, worker_host) do
      :rerun ->
        transition_issue_state(
          issue,
          issue_state_fetcher,
          @merge_rerun_state_name,
          :merge_rerun_state_update_failed,
          "completed merge issue with workspace changes",
          :stop
        )

      :clean ->
        case merge_workpad_handoff_status(issue) do
          :ready ->
            transition_issue_state(
              issue,
              issue_state_fetcher,
              resolve_next_handoff_state(issue),
              :merge_handoff_state_update_failed,
              "completed merge issue",
              :stop
            )

          :blocked ->
            Logger.info("Keeping merge issue active because PR merge evidence is missing or incomplete before completed merge issue: #{issue_context(issue)}")
            {:ok, issue, {:incomplete_phase, :merge_evidence_missing}}

          {:error, reason} ->
            Logger.warning("Failed to inspect workpad merge evidence before completed merge issue; keeping issue active: #{issue_context(issue)} reason=#{inspect(reason)}")
            {:ok, issue, {:incomplete_phase, :merge_evidence_inspection_failed}}
        end

      {:error, reason} ->
        Logger.warning("Failed to inspect merge workspace status before completed merge issue; keeping issue active: #{issue_context(issue)} reason=#{inspect(reason)}")
        {:ok, issue, {:incomplete_phase, :merge_workspace_inspection_failed}}
    end
  end

  defp merge_workspace_rerun_status(workspace, worker_host) do
    case Workspace.git_status_snapshot(workspace, worker_host) do
      {:ok, ""} -> :clean
      {:ok, _status} -> :rerun
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_transition_completed_codex_issue(
         %Issue{} = issue,
         issue_state_fetcher,
         error_tag,
         reason_label
       ) do
    case required_handoff_workpad_sections(issue.state) do
      [_ | _] = section_titles ->
        maybe_transition_after_closed_workpad_sections(
          issue,
          issue_state_fetcher,
          section_titles,
          error_tag,
          reason_label
        )

      [] ->
        transition_issue_state(
          issue,
          issue_state_fetcher,
          resolve_next_handoff_state(issue),
          error_tag,
          reason_label,
          :stop
        )
    end
  end

  defp maybe_transition_after_closed_workpad_sections(
         %Issue{} = issue,
         issue_state_fetcher,
         section_titles,
         error_tag,
         reason_label
       ) do
    case workpad_sections_handoff_status(issue, section_titles) do
      :ready ->
        transition_issue_state(
          issue,
          issue_state_fetcher,
          resolve_next_handoff_state(issue),
          error_tag,
          reason_label,
          :stop
        )

      {:open, section_title} ->
        Logger.info("Keeping issue active because the workpad #{section_title} checklist still has open items before #{reason_label}: #{issue_context(issue)}")
        {:ok, issue, {:incomplete_phase, {:open_workpad_checklist, section_title}}}

      {:blocked, section_title} ->
        Logger.info("Keeping issue active because the workpad #{section_title} checklist evidence is missing or incomplete before #{reason_label}: #{issue_context(issue)}")
        {:ok, issue, {:incomplete_phase, {:missing_workpad_checklist, section_title}}}

      {:error, reason} ->
        Logger.warning("Failed to inspect workpad #{format_section_titles(section_titles)} checklist before #{reason_label}; keeping issue active: #{issue_context(issue)} reason=#{inspect(reason)}")
        {:ok, issue, {:incomplete_phase, {:workpad_checklist_inspection_failed, section_titles}}}
    end
  end

  defp maybe_finalize_review_codex_issue(
         %Issue{} = issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    case review_workpad_handoff_status(issue) do
      {:ready, review_result} ->
        transition_issue_state(
          issue,
          issue_state_fetcher,
          resolve_review_handoff_state(issue, review_result, workspace, worker_host),
          :review_handoff_state_update_failed,
          "completed review issue",
          :stop
        )

      :open ->
        Logger.info("Keeping review issue active because the workpad review checklist still has open items: #{issue_context(issue)}")
        {:ok, issue, {:incomplete_phase, {:open_workpad_checklist, "Review"}}}

      :blocked ->
        Logger.info("Keeping review issue active because the workpad review checklist evidence is missing or incomplete: #{issue_context(issue)}")
        {:ok, issue, {:incomplete_phase, {:missing_workpad_checklist, "Review"}}}

      {:error, reason} ->
        Logger.warning("Failed to inspect workpad review checklist before review handoff; keeping review issue active: #{issue_context(issue)} reason=#{inspect(reason)}")
        {:ok, issue, {:incomplete_phase, :review_checklist_inspection_failed}}
    end
  end

  defp transition_issue_state(
         %Issue{} = issue,
         issue_state_fetcher,
         next_state,
         error_tag,
         reason_label,
         continuation_mode
       )
       when is_binary(next_state) and is_atom(error_tag) do
    case Tracker.update_issue_state(issue.id, next_state) do
      :ok ->
        Logger.info("Auto-transitioned #{reason_label}: #{issue_context(issue)} next_state=#{next_state}")

        with {:ok, %Issue{} = refreshed_issue} <- refetch_issue(issue, issue_state_fetcher, next_state) do
          {:ok, refreshed_issue, continuation_mode}
        end

      {:error, reason} ->
        Logger.warning("Failed auto-transition for #{reason_label}: #{issue_context(issue)} next_state=#{next_state} reason=#{inspect(reason)}")

        {:error, {error_tag, next_state, reason}}
    end
  end

  defp maybe_sync_issue_branch_name(%Issue{id: issue_id}, _workspace, _worker_host)
       when not is_binary(issue_id),
       do: :ok

  defp maybe_sync_issue_branch_name(%Issue{} = issue, workspace, worker_host)
       when is_binary(workspace) do
    with {:ok, branch_name} <- Workspace.current_branch(workspace, worker_host),
         :ok <- Tracker.update_issue_branch_name(issue.id, branch_name) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to sync Linear branch name for #{issue_context(issue)}: #{inspect(reason)}")

        :ok
    end
  end

  defp maybe_prepare_workspace_for_issue_run(%Issue{state: state} = issue, workspace, worker_host, _opts)
       when is_binary(state) and is_binary(workspace) do
    if review_codex_state?(state) do
      maybe_create_review_autocommit(issue, workspace, worker_host)
    else
      maybe_clear_review_autocommit_marker(issue, workspace, worker_host)
    end
  end

  defp maybe_prepare_workspace_for_issue_run(_issue, _workspace, _worker_host, _opts), do: :ok

  defp maybe_create_review_autocommit(%Issue{} = issue, workspace, worker_host) do
    case Workspace.prepare_review_autocommit(workspace, AutocommitMessage.build(issue, "Review (AI)"), worker_host) do
      {:ok, :already_recorded} ->
        Logger.info("Skipped review autocommit because this review stay was already prepared #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:ok, :clean} ->
        Logger.info("Recorded review autocommit marker for clean workspace #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:ok, :not_git_repo} ->
        Logger.info("Skipped review autocommit because the workspace is not a git repository #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:ok, :committed} ->
        Logger.info("Created review autocommit before first review turn #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)}")
        :ok

      {:error, reason} ->
        Logger.warning("Failed review autocommit before first review turn #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")
        {:error, {:review_autocommit_failed, reason}}
    end
  end

  defp maybe_clear_review_autocommit_marker(%Issue{} = issue, workspace, worker_host) do
    case Workspace.clear_review_autocommit_marker(workspace, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to clear stale review autocommit marker before non-review run #{issue_context(issue)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}"
        )

        {:error, {:review_autocommit_marker_clear_failed, reason}}
    end
  end

  defp maybe_clear_review_autocommit_marker_for_existing_workspace(%Issue{} = issue, worker_host) do
    case Workspace.clear_review_autocommit_marker_for_existing_issue_workspace(issue, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to clear stale review autocommit marker for manual issue #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")

        {:error, {:review_autocommit_marker_clear_failed, reason}}
    end
  end

  defp maybe_clear_review_autocommit_marker_after_review_error(
         %Issue{} = started_issue,
         issue_state_fetcher,
         workspace,
         worker_host
       ) do
    if review_codex_state?(started_issue.state) do
      case refetch_issue(started_issue, issue_state_fetcher, started_issue.state) do
        {:ok, %Issue{} = refreshed_issue} ->
          maybe_clear_review_autocommit_marker_after_review_departure(
            started_issue,
            refreshed_issue,
            workspace,
            worker_host
          )

        {:error, reason} ->
          {:error, reason}
      end
    else
      :ok
    end
  end

  defp maybe_clear_review_autocommit_marker_after_review_departure(
         %Issue{} = started_issue,
         %Issue{} = current_issue,
         workspace,
         worker_host
       ) do
    if review_codex_state?(started_issue.state) and not review_codex_state?(current_issue.state) do
      maybe_clear_review_autocommit_marker(current_issue, workspace, worker_host)
    else
      :ok
    end
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp prereview_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @prereview_codex_state_name
  end

  defp prereview_codex_state?(_state_name), do: false

  defp review_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @review_codex_state_name
  end

  defp review_codex_state?(_state_name), do: false

  defp test_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @test_codex_state_name
  end

  defp test_codex_state?(_state_name), do: false

  defp merge_codex_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @merge_codex_state_name
  end

  defp merge_codex_state?(_state_name), do: false

  defp manual_in_progress_issue_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == @manual_in_progress_state_name
  end

  defp manual_in_progress_issue_state?(_state_name), do: false

  defp ignored_manual_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)
    Enum.any?(@ignored_manual_state_names, &(&1 == normalized_state))
  end

  defp ignored_manual_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp state_changed_during_turn?(%Issue{state: started_state}, %Issue{state: current_state})
       when is_binary(started_state) and is_binary(current_state) do
    normalize_issue_state(started_state) != normalize_issue_state(current_state)
  end

  defp state_changed_during_turn?(_started_issue, _current_issue), do: false

  defp resolve_next_handoff_state(%Issue{} = issue) do
    Workflow.resolve_next_status(issue.state, Issue.label_names(issue)) ||
      default_next_handoff_state(issue.state)
  end

  defp resolve_review_handoff_state(%Issue{} = issue, :no_findings, workspace, worker_host) do
    cond do
      review_handoff_skipped?(issue) ->
        @review_no_findings_handoff_state_name

      review_workspace_clean?(issue, workspace, worker_host) ->
        @review_no_findings_handoff_state_name

      true ->
        @review_handoff_state_name
    end
  end

  defp resolve_review_handoff_state(%Issue{} = issue, _review_result, _workspace, _worker_host) do
    if review_handoff_skipped?(issue) do
      @review_no_findings_handoff_state_name
    else
      @review_handoff_state_name
    end
  end

  defp review_handoff_skipped?(%Issue{} = issue) do
    Config.yolo?() or
      issue
      |> Issue.label_names()
      |> Enum.map(&normalize_issue_state/1)
      |> Enum.any?(fn label ->
        label == ~s(skip "#{normalize_issue_state(@review_handoff_state_name)}") or
          label == "skip #{normalize_issue_state(@review_handoff_state_name)}"
      end)
  end

  defp review_workspace_clean?(%Issue{} = issue, workspace, worker_host) when is_binary(workspace) do
    case Workspace.git_status_snapshot(workspace, worker_host) do
      {:ok, ""} ->
        true

      {:ok, _status} ->
        false

      {:error, reason} ->
        Logger.warning("Failed to inspect review workspace status before no-findings handoff; using regular review handoff: #{issue_context(issue)} reason=#{inspect(reason)}")

        false
    end
  end

  defp review_workpad_handoff_status(%Issue{id: issue_id}) when is_binary(issue_id) do
    with {:ok, comments} <- Tracker.fetch_issue_comment_bodies(issue_id) do
      Workpad.review_handoff_status(comments)
    end
  end

  defp review_workpad_handoff_status(_issue), do: {:ready, :unknown}

  defp merge_workpad_handoff_status(%Issue{id: issue_id}) when is_binary(issue_id) do
    with {:ok, comments} <- Tracker.fetch_issue_comment_bodies(issue_id) do
      Workpad.merge_handoff_status(comments)
    end
  end

  defp merge_workpad_handoff_status(_issue), do: :blocked

  defp required_handoff_workpad_sections(state_name) when is_binary(state_name) do
    cond do
      prereview_codex_state?(state_name) -> ["Review"]
      test_codex_state?(state_name) -> ["Test", "Validierung"]
      true -> []
    end
  end

  defp required_handoff_workpad_sections(_state_name), do: []

  defp workpad_sections_handoff_status(%Issue{id: issue_id}, section_titles)
       when is_binary(issue_id) and is_list(section_titles) do
    with {:ok, comments} <- Tracker.fetch_issue_comment_bodies(issue_id) do
      comments
      |> Workpad.find_comment_body()
      |> workpad_body_sections_handoff_status(section_titles)
    end
  end

  defp workpad_sections_handoff_status(_issue, section_titles), do: {:blocked, format_section_titles(section_titles)}

  defp workpad_body_sections_handoff_status(body, section_titles)
       when is_binary(body) and is_list(section_titles) do
    Enum.reduce_while(section_titles, :ready, fn section_title, :ready ->
      case Workpad.section_checklist_status(body, section_title) do
        :closed -> {:cont, :ready}
        :open -> {:halt, {:open, section_title}}
        :missing -> {:halt, {:blocked, section_title}}
        :no_checklist -> {:halt, {:blocked, section_title}}
      end
    end)
  end

  defp workpad_body_sections_handoff_status(_body, section_titles), do: {:blocked, format_section_titles(section_titles)}

  defp format_section_titles(section_titles) when is_list(section_titles) do
    Enum.join(section_titles, "/")
  end

  defp default_next_handoff_state(state_name) when is_binary(state_name) do
    cond do
      prereview_codex_state?(state_name) -> @implementation_handoff_state_name
      review_codex_state?(state_name) -> @review_handoff_state_name
      test_codex_state?(state_name) -> @test_handoff_state_name
      merge_codex_state?(state_name) -> @merge_handoff_state_name
      true -> state_name
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
