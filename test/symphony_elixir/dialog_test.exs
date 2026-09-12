defmodule SymphonyElixir.DialogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ScriptSupport
  alias SymphonyElixir.Dialog

  test "dialog helper builds first prompts, resumes user comments, and ignores completed answers" do
    dialog_workflow_path = write_dialog_workflow!("dialog={{ issue.identifier }} active={{ runtime.active_repo_root }} workflow={{ runtime.workflow_file }}")

    issue = dialog_issue("issue-dialog-helper", "MT-D1")
    workspace = Path.join(System.tmp_dir!(), "dialog-helper-workspace")

    refute Dialog.state?(nil)

    assert {:ok, %{prompt: first_prompt, session_id: nil, include_session?: true} = first_request} =
             Dialog.next_request(issue, [], workspace)

    assert first_prompt =~ "dialog=MT-D1"
    assert first_prompt =~ "active=#{workspace}"
    assert first_prompt =~ "workflow=#{dialog_workflow_path}"
    assert Dialog.request_current?(first_request, [])

    first_turn_nonblocking_answer =
      Dialog.format_nonblocking_answer_comment("Repository changed before first turn", nil, false, "first-turn")

    refute Dialog.request_current?(
             first_request,
             [%{body: first_turn_nonblocking_answer, created_at: ~U[2026-05-19 10:00:00Z]}]
           )

    assert String.starts_with?(Dialog.request_source_key(%{source_comment_body: "Body-only request"}), "sha256:")

    refute Dialog.request_current?(
             first_request,
             [%{id: "comment-after-description", body: "New user comment", created_at: ~U[2026-05-19 10:00:30Z]}]
           )

    initial_comment = %{id: "comment-initial", body: "Initial comment request", created_at: ~U[2026-05-19 10:00:00Z]}

    assert {:ok, %{prompt: comment_prompt, session_id: nil, include_session?: true} = comment_request} =
             Dialog.next_request(
               issue,
               [initial_comment],
               workspace
             )

    assert comment_prompt =~ "dialog=MT-D1"
    assert comment_prompt =~ "active=#{workspace}"
    assert comment_prompt =~ "workflow=#{dialog_workflow_path}"
    assert comment_prompt =~ "## Aktuelle Benutzeranfrage aus Linear-Kommentar"
    assert comment_prompt =~ "Initial comment request"
    refute comment_prompt == "Initial comment request"
    assert Dialog.request_current?(comment_request, [initial_comment])
    refute Dialog.request_current?(comment_request, [])

    refute Dialog.request_current?(
             comment_request,
             [
               initial_comment,
               %{id: "comment-newer", body: "Newer user comment", created_at: ~U[2026-05-19 10:01:00Z]}
             ]
           )

    comments = [
      %{body: "Follow-up question", created_at: ~U[2026-05-19 10:01:00Z]},
      %{
        body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
        created_at: ~U[2026-05-19 10:00:00Z]
      }
    ]

    assert {:ok, %{prompt: "Follow-up question", session_id: "thread-existing", include_session?: false}} =
             Dialog.next_request(issue, comments, workspace)

    completed_comments = [
      %{body: "Already handled question", created_at: ~U[2026-05-19 10:00:00Z]},
      %{
        body: "### Antwort Symphony\n\n[Session thread-existing]\n\nFinal answer",
        created_at: ~U[2026-05-19 10:01:00Z]
      }
    ]

    assert {:ok, :noop} = Dialog.next_request(issue, completed_comments, workspace)

    edited_completed_comment = %{
      id: "comment-edited",
      body: "Edited handled question",
      created_at: ~U[2026-05-19 10:00:00Z],
      updated_at: ~U[2026-05-19 10:02:00Z]
    }

    comments_after_edit = [
      edited_completed_comment,
      %{
        body: "### Antwort Symphony\n\n[Session thread-existing]\n\nEarlier answer",
        created_at: ~U[2026-05-19 10:01:00Z],
        updated_at: ~U[2026-05-19 10:01:00Z]
      }
    ]

    assert {:ok, %{prompt: "Edited handled question", session_id: "thread-existing"} = edited_request} =
             Dialog.next_request(issue, comments_after_edit, workspace)

    assert Dialog.request_current?(edited_request, comments_after_edit)

    refute Dialog.request_current?(
             edited_request,
             [
               %{edited_completed_comment | body: "Edited handled question with more detail", updated_at: ~U[2026-05-19 10:03:00Z]},
               %{
                 body: "### Antwort Symphony\n\n[Session thread-existing]\n\nEarlier answer",
                 created_at: ~U[2026-05-19 10:01:00Z],
                 updated_at: ~U[2026-05-19 10:01:00Z]
               }
             ]
           )

    assert Dialog.format_answer_comment("### Antwort Symphony\n\nDone", "thread-new", true) ==
             "### Antwort Symphony\n\n[Session thread-new]\n\nDone\n"

    nonblocking_answer = Dialog.format_nonblocking_answer_comment("Repository changed", "thread-stale", true)
    assert nonblocking_answer == "### Antwort Symphony\n\n[Antwort nicht abgeschlossen]\n\n[Session thread-stale]\n\nRepository changed\n"
    assert Dialog.nonblocking_answer_comment?(nonblocking_answer)
    refute Dialog.answer_comment?(nonblocking_answer)
    refute Dialog.nonblocking_answer_comment?(nil)

    comments_after_nonblocking_answer = [
      %{body: "New request", created_at: ~U[2026-05-19 10:01:00Z]},
      %{body: nonblocking_answer, created_at: ~U[2026-05-19 10:02:00Z]}
    ]

    assert {:ok, %{prompt: nonblocking_prompt, session_id: nil, include_session?: true}} =
             Dialog.next_request(issue, comments_after_nonblocking_answer, workspace)

    assert nonblocking_prompt =~ "New request"
    refute nonblocking_prompt =~ "Repository changed"

    source_scoped_nonblocking_answer =
      Dialog.format_nonblocking_answer_comment("Repository changed", nil, false, "id:comment-initial")

    assert source_scoped_nonblocking_answer ==
             "### Antwort Symphony\n\n[Antwort nicht abgeschlossen]\n\n[Quelle id:comment-initial]\n\nRepository changed\n"

    refute Dialog.request_current?(
             comment_request,
             [
               initial_comment,
               %{body: source_scoped_nonblocking_answer, created_at: ~U[2026-05-19 10:01:00Z]}
             ]
           )

    assert {:ok, :noop} =
             Dialog.next_request(
               issue,
               [
                 initial_comment,
                 %{body: source_scoped_nonblocking_answer, created_at: ~U[2026-05-19 10:01:00Z]}
               ],
               workspace
             )

    untimed_source_scoped_nonblocking_answer =
      Dialog.format_nonblocking_answer_comment("Repository changed", nil, false, "id:comment-untimed")

    assert {:ok, :noop} =
             Dialog.next_request(
               issue,
               [
                 %{id: "comment-untimed", body: "Untimed request"},
                 %{body: untimed_source_scoped_nonblocking_answer}
               ],
               workspace
             )

    edited_nonblocking_comments = [
      Map.merge(initial_comment, %{body: "Edited after nonblocking answer", updated_at: ~U[2026-05-19 10:03:00Z]}),
      %{body: source_scoped_nonblocking_answer, created_at: ~U[2026-05-19 10:01:00Z], updated_at: ~U[2026-05-19 10:01:00Z]}
    ]

    assert {:ok,
            %{
              prompt: edited_nonblocking_prompt,
              session_id: nil,
              include_session?: true
            } = edited_nonblocking_request} =
             Dialog.next_request(issue, edited_nonblocking_comments, workspace)

    assert edited_nonblocking_prompt =~ "Edited after nonblocking answer"
    assert Dialog.request_current?(edited_nonblocking_request, edited_nonblocking_comments)

    assert Dialog.request_current?(
             edited_nonblocking_request,
             edited_nonblocking_comments ++
               [%{body: Dialog.format_nonblocking_answer_comment("Repository changed without source", nil, false), created_at: ~U[2026-05-19 10:04:00Z]}]
           )

    assert {:ok, %{prompt: source_scoped_prompt, session_id: nil, include_session?: true}} =
             Dialog.next_request(
               issue,
               [
                 initial_comment,
                 %{id: "comment-newer", body: "Newer source request", created_at: ~U[2026-05-19 10:01:00Z]},
                 %{body: source_scoped_nonblocking_answer, created_at: ~U[2026-05-19 10:02:00Z]}
               ],
               workspace
             )

    assert source_scoped_prompt =~ "Newer source request"

    assert Dialog.format_session_reset_answer_comment("Could not resume") ==
             "### Antwort Symphony\n\n[Session zurückgesetzt]\n\nCould not resume\n"

    nonblocking_session_reset = Dialog.format_nonblocking_session_reset_answer_comment("Could not resume")
    assert nonblocking_session_reset == "### Antwort Symphony\n\n[Antwort nicht abgeschlossen]\n\n[Session zurückgesetzt]\n\nCould not resume\n"
    assert Dialog.nonblocking_answer_comment?(nonblocking_session_reset)
    refute Dialog.answer_comment?(nonblocking_session_reset)

    comments_after_nonblocking_reset = [
      %{
        body: "### Antwort Symphony\n\n[Session thread-broken]\n\nPrevious answer",
        created_at: ~U[2026-05-19 10:00:00Z]
      },
      %{body: "Retry with new details", created_at: ~U[2026-05-19 10:01:00Z]},
      %{body: nonblocking_session_reset, created_at: ~U[2026-05-19 10:02:00Z]}
    ]

    assert {:ok, %{prompt: reset_prompt, session_id: nil, include_session?: true}} =
             Dialog.next_request(issue, comments_after_nonblocking_reset, workspace)

    assert reset_prompt =~ "dialog=MT-D1"
    assert reset_prompt =~ "Retry with new details"

    comments_after_reset = [
      %{
        body: "### Antwort Symphony\n\n[Session thread-broken]\n\nPrevious answer",
        created_at: ~U[2026-05-19 10:00:00Z]
      },
      %{
        body: "### Antwort Symphony\n\n[Session zurückgesetzt]\n\nSession error",
        created_at: ~U[2026-05-19 10:01:00Z]
      },
      %{body: "Start a fresh session", created_at: ~U[2026-05-19 10:02:00Z]}
    ]

    assert {:ok, %{prompt: fresh_prompt, session_id: nil, include_session?: true}} =
             Dialog.next_request(issue, comments_after_reset, workspace)

    assert fresh_prompt =~ "dialog=MT-D1"
    assert fresh_prompt =~ "Start a fresh session"

    assert Dialog.answer_comment?(%{"body" => "### Antwort Symphony\n\nString key"})
    assert Dialog.answer_comment?("### Antwort Symphony\n\nRaw body")
    refute Dialog.answer_comment?(%{body: 123})
    refute Dialog.answer_comment?(nil)
  end

  test "dialog helper handles fallback answer messages and mixed comment shapes" do
    issue = dialog_issue("issue-dialog-shapes", "MT-DSHAPES")
    workspace = Path.join(System.tmp_dir!(), "dialog-shapes-workspace")
    write_dialog_workflow!("dialog={{ issue.identifier }}")

    comments = [
      %{"body" => "User after string timestamp", "createdAt" => "2026-05-19T10:02:00Z"},
      %{"body" => "### Antwort Symphony\n\n[Session thread-string]\n\nPrevious", "created_at" => "2026-05-19T10:01:00Z"},
      %{body: "", updated_at: ~U[2026-05-19 10:00:00Z]}
    ]

    assert {:ok, %{prompt: "User after string timestamp", session_id: "thread-string"}} =
             Dialog.next_request(issue, comments, workspace)

    comments_without_timestamps = [
      %{body: "### Antwort Symphony\n\n[Session thread-unsorted]\n\nPrevious"},
      %{body: "User without timestamps"}
    ]

    assert {:ok, %{prompt: "User without timestamps", session_id: "thread-unsorted"} = unsorted_request} =
             Dialog.next_request(issue, comments_without_timestamps, workspace)

    assert Dialog.request_current?(unsorted_request, comments_without_timestamps)

    comments_with_invalid_timestamp = [
      %{body: "### Antwort Symphony\n\n[Session thread-invalid]\n\nPrevious", created_at: "not-a-timestamp"},
      nil,
      %{body: "User after invalid timestamp"}
    ]

    assert {:ok, %{prompt: "User after invalid timestamp", session_id: "thread-invalid"}} =
             Dialog.next_request(issue, comments_with_invalid_timestamp, workspace)

    assert Dialog.final_answer_from_messages([
             %{"payload" => %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => "fallback answer"}}}}
           ]) == "fallback answer"

    assert Dialog.final_answer_from_messages([
             %{payload: %{method: "item/completed", params: %{item: %{type: "agentMessage", text: "atom answer", phase: "final_answer"}}}}
           ]) == "atom answer"

    assert is_nil(
             Dialog.final_answer_from_messages([
               %{payload: %{method: "item/completed", params: %{item: %{type: "agentMessage", text: "   "}}}}
             ])
           )

    assert is_nil(Dialog.final_answer_from_messages([%{payload: %{method: "other"}}]))
    assert is_nil(Dialog.final_answer_from_messages(["not a map"]))
  end

  test "default dialog workflow requires Linear metadata for created implementation tickets" do
    workflow_path = Path.expand("../../WORKFLOW_DIALOG.md", __DIR__)
    assert {:ok, %{prompt_template: prompt_template}} = Workflow.load(workflow_path)

    issue = %{dialog_issue("issue-dialog-relation", "MT-DREL") | assignee_id: "assignee-origin"}

    prompt =
      PromptBuilder.build_prompt(issue,
        prompt_template: prompt_template,
        active_repo_root: "/tmp/project",
        source_repo_root: "/tmp/project",
        workflow_file: workflow_path
      )

    refute prompt =~ "`Backlog`"
    assert prompt =~ "Linear-Issue-ID: issue-dialog-relation"
    assert prompt =~ "Assignee-ID: assignee-origin"
    assert prompt =~ "Status-ID für `Todo`"
    assert prompt =~ "Status-ID\n  für `Umsetzungsticket erstellt`"
    assert prompt =~ "symphony-generated"
    assert prompt =~ ~s(assigneeId: "assignee-origin")
    assert prompt =~ "labelIds"
    assert prompt =~ "issueRelationCreate"
    assert prompt =~ ~s(issueId: "issue-dialog-relation")
    assert prompt =~ "relatedIssueId"
    assert prompt =~ "type: related"
    assert prompt =~ "Related/relatedTo-Verknüpfung"
    assert prompt =~ "issueUpdate"
    assert prompt =~ "stateId:\n  <Umsetzungsticket-erstellt-State-ID>"
    assert prompt =~ "Umsetzungsticket erstellt"
  end

  test "agent runner answers dialog issues without creating a git worktree or running hooks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-runner-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      hook_marker = Path.join(test_root, "hook-ran")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_fake_codex!(codex_binary, trace_file, "thread-dialog", "turn-dialog", "Dialog answer")
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "touch #{hook_marker}",
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-runner", "MT-DIALOG")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())

        assert_receive {:worker_runtime_info, "issue-dialog-runner", %{workspace_path: dialog_workspace}}, 1_000
        assert dialog_workspace == File.cwd!()
        assert File.dir?(dialog_workspace)
        refute File.exists?(Path.join(workspace_root, ".dialog"))
        refute File.exists?(Path.join(workspace_root, "MT-DIALOG"))
        refute File.exists?(hook_marker)

        assert_receive {:memory_tracker_comment, "issue-dialog-runner", body}, 1_000
        assert body =~ "### Antwort Symphony"
        assert body =~ "[Session thread-dialog]"
        assert body =~ "Dialog answer"

        trace = File.read!(trace_file)
        assert trace =~ "PWD:#{File.cwd!()}"
        assert trace =~ ~s("method":"thread/start")
        refute trace =~ ~s("method":"thread/resume")
        assert trace =~ "dialog prompt MT-DIALOG"

        trace_lines = String.split(trace, "\n", trim: true)

        assert %{"params" => thread_start_params} =
                 trace_json_payload(trace_lines, "thread/start")

        assert thread_start_params["approvalPolicy"] == expected_default_approval_policy()
        assert thread_start_params["sandbox"] == "workspace-write"

        assert %{"params" => turn_start_params} =
                 trace_json_payload(trace_lines, "turn/start")

        assert turn_start_params["approvalPolicy"] == expected_default_approval_policy()
        assert turn_start_params["sandboxPolicy"] == expected_workspace_write_policy(File.cwd!())
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes dialog approval errors with an answer comment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-approval-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-approval-error.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_approval_request_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-approval-error", "MT-DAPPROVAL")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())

        assert_receive {:memory_tracker_comment, "issue-dialog-approval-error", body}, 1_000
        assert body =~ "### Antwort Symphony"
        assert body =~ "[Session thread-dialog-approval]"
        assert body =~ "interaktive Genehmigung"
      end)

      assert File.read!(trace_file) =~ ~s("method":"item/commandExecution/requestApproval")
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes dialog input-required errors with an answer comment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-input-required-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input-required.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_turn_input_required_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-input-required", "MT-DINPUT")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())

        assert_receive {:memory_tracker_comment, "issue-dialog-input-required", body}, 1_000
        assert body =~ "### Antwort Symphony"
        assert body =~ "[Session thread-dialog-input-required]"
        assert body =~ "zusätzliche interaktive Eingabe"
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes dialog turn failures with an answer comment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-turn-failed-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-turn-failed.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_turn_failed_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-turn-failed", "MT-DFAILED")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())

        assert_receive {:memory_tracker_comment, "issue-dialog-turn-failed", body}, 1_000
        assert body =~ "### Antwort Symphony"
        assert body =~ "[Session thread-dialog-turn-failed]"
        assert body =~ "Codex-Turn fehlgeschlagen"
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner posts source-scoped turn errors when comment refresh fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-turn-refresh-error-#{System.unique_integer([:positive])}")

    previous_linear_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-turn-refresh-error.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_turn_failed_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: "project",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      original_comment = %{
        id: "comment-original",
        body: "Original turn question",
        created_at: ~U[2026-05-19 10:01:00Z]
      }

      put_linear_comment_refresh_failing_request_fun!([original_comment], self())
      issue = dialog_issue("issue-dialog-turn-refresh-error", "MT-TREFRESH-ERR")

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:linear_comment_body, body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Antwort nicht abgeschlossen]"
      assert body =~ "[Quelle id:comment-original]"
      assert body =~ "[Session thread-dialog-turn-failed]"
      assert body =~ "Codex-Turn fehlgeschlagen"

      assert {:ok, :noop} =
               Dialog.next_request(
                 issue,
                 [original_comment, %{id: "comment-turn-error", body: body, created_at: ~U[2026-05-19 10:02:00Z]}],
                 project_root
               )
    after
      restore_app_env(:linear_client_request_fun, previous_linear_request_fun)
      File.rm_rf(test_root)
    end
  end

  test "agent runner allows Symphony runtime log artifacts during dialog repo checks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-log-artifact-#{System.unique_integer([:positive])}")

    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-log-artifact.trace")
      runtime_log_file = Path.join(project_root, "log/symphony.log")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      File.write!(Path.join(project_root, ".gitignore"), "log/\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md", ".gitignore"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      Application.put_env(:symphony_elixir, :log_file, runtime_log_file)
      write_runtime_log_fake_codex!(codex_binary, trace_file, runtime_log_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-log-artifact", "MT-DLOG")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-log-artifact", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Log-safe answer"
      assert File.read!(runtime_log_file) == "runtime\n"
    after
      restore_app_env(:log_file, previous_log_file)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes tracked source changes with a repository error" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-dirty-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dirty.trace")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-dirty", "MT-DDIRTY")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-dirty", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes untracked non-artifact changes with a repository error" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-untracked-dirty-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-untracked-dirty.trace")
      dirty_file = Path.join(project_root, "dialog-dirty.txt")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-untracked-dirty", "MT-UDIRTY")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-untracked-dirty", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner blocks untracked changes even when git config hides them" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-dialog-untracked-hidden-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-untracked-hidden.trace")
      dirty_file = Path.join(project_root, "dialog-hidden.txt")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["config", "status.showUntrackedFiles", "no"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-untracked-hidden", "MT-UHIDDEN")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-untracked-hidden", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes untracked log files with a repository error" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-untracked-log-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-untracked-log.trace")
      dirty_file = Path.join([project_root, "log", "insight.log"])

      File.mkdir_p!(Path.dirname(dirty_file))
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-untracked-log", "MT-ULOG")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-untracked-log", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes top-level artifact-name files with a repository error" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-root-artifact-name-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-root-artifact-name.trace")
      dirty_file = Path.join(project_root, "log")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-root-artifact-name", "MT-ROOT-ARTIFACT")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-root-artifact-name", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner catches dialog changes to already dirty tracked files" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-tracked-dirty-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tracked-dirty.trace")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(dirty_file, "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      File.write!(dirty_file, "already dirty\n")

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-tracked-dirty", "MT-TDIRTY")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-tracked-dirty", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner allows dialog answers when ignored config changes" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-ignored-dirty-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-ignored-dirty.trace")
      dirty_file = Path.join(project_root, ".env.local")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      File.write!(Path.join(project_root, ".gitignore"), ".env.local\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md", ".gitignore"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-ignored-dirty", "MT-IDIRTY")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-ignored-dirty", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner allows dialog answers when ignored directories change" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-ignored-dir-dirty-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-ignored-dir-dirty.trace")
      dirty_file = Path.join([project_root, "tmp", "dialog-dirty.txt"])

      File.mkdir_p!(Path.dirname(dirty_file))
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      File.write!(Path.join(project_root, ".gitignore"), "tmp/\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md", ".gitignore"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-ignored-dir-dirty", "MT-IDIRTY-DIR")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-ignored-dir-dirty", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner checks the dialog source repo even when the dialog turn fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-dirty-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dirty-error.trace")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_failing_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-dirty-error", "MT-DDIRTY-ERR")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-dirty-error", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner checks the dialog source repo even when session resume fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-dirty-resume-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dirty-resume-error.trace")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_resume_failing_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-dirty-resume-error", "MT-DDIRTY-RESUME-ERR")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-dirty-resume-error" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-dirty-resume-error", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "[Session thread-existing]"
      assert body =~ "[Session zurückgesetzt]"
      assert File.read!(dirty_file) == "dirty\n"
      assert File.read!(trace_file) =~ ~s("method":"thread/resume")

      comments_after_reset = [
        %{
          body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
          created_at: ~U[2026-05-19 10:00:00Z]
        },
        %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
        %{body: body, created_at: ~U[2026-05-19 10:02:00Z]},
        %{body: "Try again after dirty resume", created_at: ~U[2026-05-19 10:03:00Z]}
      ]

      assert {:ok, %{prompt: reset_prompt, session_id: nil, include_session?: true}} =
               Dialog.next_request(issue, comments_after_reset, project_root)

      assert reset_prompt =~ "dialog prompt MT-DDIRTY-RESUME-ERR"
      assert reset_prompt =~ "Try again after dirty resume"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner finalizes clean session resume failures with an answer comment" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-clean-resume-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-clean-resume-error.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_resume_failing_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-clean-resume-error", "MT-CLEAN-RESUME-ERR")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-clean-resume-error" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-clean-resume-error", body}, 1_000
      assert body =~ "### Antwort Symphony"
      refute body =~ "[Session thread-existing]"
      assert body =~ "[Session zurückgesetzt]"
      assert body =~ "Dialogsitzung nicht fortsetzen"
      assert File.read!(trace_file) =~ ~s("method":"thread/resume")

      comments_after_reset = [
        %{
          body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
          created_at: ~U[2026-05-19 10:00:00Z]
        },
        %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
        %{body: body, created_at: ~U[2026-05-19 10:02:00Z]},
        %{body: "Try again from scratch", created_at: ~U[2026-05-19 10:03:00Z]}
      ]

      assert {:ok, %{prompt: reset_prompt, session_id: nil, include_session?: true}} =
               Dialog.next_request(issue, comments_after_reset, project_root)

      assert reset_prompt =~ "dialog prompt MT-CLEAN-RESUME-ERR"
      assert reset_prompt =~ "Try again from scratch"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner posts source-scoped session resets when resume comment refresh fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-resume-refresh-error-#{System.unique_integer([:positive])}")

    previous_linear_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-resume-refresh-error.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_resume_failing_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: "project",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      previous_answer = %{
        body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
        created_at: ~U[2026-05-19 10:00:00Z]
      }

      original_comment = %{
        id: "comment-original",
        body: "Original resume question",
        created_at: ~U[2026-05-19 10:01:00Z]
      }

      put_linear_comment_refresh_failing_request_fun!([previous_answer, original_comment], self())
      issue = dialog_issue("issue-dialog-resume-refresh-error", "MT-RREFRESH-ERR")

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:linear_comment_body, body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Antwort nicht abgeschlossen]"
      assert body =~ "[Quelle id:comment-original]"
      assert body =~ "[Session zurückgesetzt]"
      assert body =~ "Dialogsitzung nicht fortsetzen"
      assert File.read!(trace_file) =~ ~s("method":"thread/resume")

      assert {:ok, :noop} =
               Dialog.next_request(
                 issue,
                 [
                   previous_answer,
                   original_comment,
                   %{id: "comment-reset", body: body, created_at: ~U[2026-05-19 10:02:00Z]}
                 ],
                 project_root
               )
    after
      restore_app_env(:linear_client_request_fun, previous_linear_request_fun)
      File.rm_rf(test_root)
    end
  end

  test "agent runner posts nonblocking session resets when a newer user comment arrives during resume failure" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-stale-resume-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-stale-resume-error.trace")
      release_file = Path.join(test_root, "release-resume")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_waiting_resume_failing_fake_codex!(codex_binary, trace_file, release_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-stale-resume-error", "MT-STALE-RESUME-ERR")

      initial_comments = [
        %{
          body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
          created_at: ~U[2026-05-19 10:00:00Z]
        },
        %{id: "comment-original", body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]}
      ]

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-dialog-stale-resume-error" => initial_comments})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      task =
        Task.async(fn ->
          File.cd!(project_root, fn -> AgentRunner.run(issue, self()) end)
        end)

      wait_until_file_contains!(trace_file, ~s("method":"thread/resume"))

      updated_comments =
        initial_comments ++
          [%{id: "comment-new", body: "New user comment", created_at: ~U[2026-05-19 10:02:00Z]}]

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-stale-resume-error" => updated_comments
      })

      File.write!(release_file, "go\n")

      assert :ok = Task.await(task, 5_000)
      assert_receive {:memory_tracker_comment, "issue-dialog-stale-resume-error", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Antwort nicht abgeschlossen]"
      assert body =~ "[Session zurückgesetzt]"
      assert body =~ "Dialogsitzung nicht fortsetzen"

      comments_after_notice =
        updated_comments ++
          [%{id: "comment-reset", body: body, created_at: ~U[2026-05-19 10:03:00Z]}]

      assert {:ok, %{prompt: reset_prompt, session_id: nil, include_session?: true}} =
               Dialog.next_request(issue, comments_after_notice, project_root)

      assert reset_prompt =~ "dialog prompt MT-STALE-RESUME-ERR"
      assert reset_prompt =~ "New user comment"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps clean dialog startup infrastructure failures hard" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-clean-start-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-clean-start-error.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_initialize_failing_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-clean-start-error", "MT-CLEAN-START-ERR")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-clean-start-error" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert_raise RuntimeError, ~r/forced initialize failure/, fn ->
          AgentRunner.run(issue, self())
        end
      end)

      refute_received {:memory_tracker_comment, "issue-dialog-clean-start-error", _body}
      trace = File.read!(trace_file)
      assert trace =~ ~s("method":"initialize")
      refute trace =~ ~s("method":"thread/resume")
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps dirty dialog startup infrastructure failures hard" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-dirty-start-error-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dirty-start-error.trace")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(dirty_file, "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_initialize_failing_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-dirty-start-error", "MT-DIRTY-START-ERR")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-dirty-start-error" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert_raise RuntimeError, ~r/dialog_session_start_failed_after_repo_modified/, fn ->
          AgentRunner.run(issue, self())
        end
      end)

      refute_received {:memory_tracker_comment, "issue-dialog-dirty-start-error", _body}
      trace = File.read!(trace_file)
      assert trace =~ ~s("method":"initialize")
      refute trace =~ ~s("method":"thread/resume")
      assert File.read!(dirty_file) == "dirty\n"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner resets sessions for malformed resume payloads" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-malformed-resume-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-malformed-resume.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_malformed_resume_fake_codex!(codex_binary, trace_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-malformed-resume", "MT-MALFORMED-RESUME")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-malformed-resume" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:memory_tracker_comment, "issue-dialog-malformed-resume", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Session zurückgesetzt]"
      assert body =~ "Dialogsitzung nicht fortsetzen"
      assert File.read!(trace_file) =~ ~s("method":"thread/resume")
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner resumes the stored dialog session for new user comments" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-resume-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_fake_codex!(codex_binary, trace_file, "thread-existing", "turn-resumed", "Resume answer")
      write_dialog_workflow!("first turn {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-resume", "MT-DRES")

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-resume" => [
          %{body: "What should we do next?", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())

        assert_receive {:memory_tracker_comment, "issue-dialog-resume", body}, 1_000
        assert body =~ "### Antwort Symphony"
        assert body =~ "Resume answer"
        refute body =~ "[Session"

        trace = File.read!(trace_file)
        assert trace =~ ~s("method":"thread/resume")
        assert trace =~ ~s("threadId":"thread-existing")
        assert trace =~ "What should we do next?"
        refute trace =~ ~s("method":"thread/start")
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips stale dialog answers when a newer user comment arrives during the turn" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-comment-race-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      release_file = Path.join(test_root, "release-turn")

      File.mkdir_p!(project_root)
      File.write!(Path.join(project_root, "README.md"), "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])
      write_waiting_fake_codex!(codex_binary, trace_file, release_file, "thread-race", "turn-race", "Stale answer")
      write_dialog_workflow!("first turn {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-comment-race", "MT-DRACE")

      initial_comments = [
        %{id: "comment-original", body: "Original question", created_at: ~U[2026-05-19 10:01:00Z]}
      ]

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-dialog-comment-race" => initial_comments})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      task =
        Task.async(fn ->
          File.cd!(project_root, fn -> AgentRunner.run(issue, self()) end)
        end)

      wait_until_file_contains!(trace_file, "Original question")

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-comment-race" =>
          initial_comments ++
            [%{id: "comment-new", body: "New user comment", created_at: ~U[2026-05-19 10:02:00Z]}]
      })

      File.write!(release_file, "go\n")

      assert :ok = Task.await(task, 5_000)
      refute_received {:memory_tracker_comment, "issue-dialog-comment-race", _body}
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner posts repository errors when a newer user comment arrives during the turn" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-dirty-comment-race-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dirty-race.trace")
      release_file = Path.join(test_root, "release-turn")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(dirty_file, "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_waiting_dirty_fake_codex!(
        codex_binary,
        trace_file,
        release_file,
        dirty_file,
        "thread-dirty-race",
        "turn-dirty-race",
        "Dirty stale answer"
      )

      write_dialog_workflow!("first turn {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-dirty-comment-race", "MT-DDRACE")

      initial_comments = [
        %{id: "comment-original", body: "Original dirty question", created_at: ~U[2026-05-19 10:01:00Z]}
      ]

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-dirty-comment-race" => initial_comments
      })

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      task =
        Task.async(fn ->
          File.cd!(project_root, fn -> AgentRunner.run(issue, self()) end)
        end)

      wait_until_file_contains!(trace_file, "Original dirty question")

      updated_comments =
        initial_comments ++
          [%{id: "comment-new", body: "New user comment", created_at: ~U[2026-05-19 10:02:00Z]}]

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-dirty-comment-race" => updated_comments
      })

      File.write!(release_file, "go\n")

      assert :ok = Task.await(task, 5_000)
      assert_receive {:memory_tracker_comment, "issue-dialog-dirty-comment-race", body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Antwort nicht abgeschlossen]"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty stale answer"
      assert File.read!(dirty_file) == "dirty\n"

      comments_after_notice =
        updated_comments ++
          [%{id: "comment-repo-error", body: body, created_at: ~U[2026-05-19 10:03:00Z]}]

      assert {:ok, %{prompt: prompt, session_id: nil, include_session?: true}} =
               Dialog.next_request(issue, comments_after_notice, project_root)

      assert prompt =~ "New user comment"
      refute prompt =~ "Original dirty question"
      refute prompt =~ "Dirty stale answer"
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner posts nonblocking repository errors when comment refresh fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-dirty-refresh-error-#{System.unique_integer([:positive])}")

    previous_linear_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-dirty-refresh-error.trace")
      dirty_file = Path.join(project_root, "README.md")

      File.mkdir_p!(project_root)
      File.write!(dirty_file, "clean\n")
      git_cmd!(project_root, ["init", "-b", "main"])
      git_cmd!(project_root, ["config", "user.name", "Dialog Test"])
      git_cmd!(project_root, ["config", "user.email", "dialog-test@example.com"])
      git_cmd!(project_root, ["add", "README.md"])
      git_cmd!(project_root, ["commit", "-m", "Initial commit"])

      write_dirty_fake_codex!(codex_binary, trace_file, dirty_file)
      write_dialog_workflow!("dialog prompt {{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "linear",
        tracker_api_token: "token",
        tracker_project_slug: "project",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = dialog_issue("issue-dialog-dirty-refresh-error", "MT-DREFRESH-ERR")

      original_comment = %{
        id: "comment-original",
        body: "Original dirty question",
        created_at: ~U[2026-05-19 10:01:00Z]
      }

      put_linear_comment_refresh_failing_request_fun!([original_comment], self())

      File.cd!(project_root, fn ->
        assert :ok = AgentRunner.run(issue, self())
      end)

      assert_receive {:linear_comment_body, body}, 1_000
      assert body =~ "### Antwort Symphony"
      assert body =~ "[Antwort nicht abgeschlossen]"
      assert body =~ "[Quelle id:comment-original]"
      assert body =~ "Repository"
      assert body =~ "nicht erlaubt"
      refute body =~ "Dirty answer"
      assert File.read!(dirty_file) == "dirty\n"

      assert {:ok, :noop} =
               Dialog.next_request(
                 issue,
                 [original_comment, %{id: "comment-repo-error", body: body, created_at: ~U[2026-05-19 10:02:00Z]}],
                 project_root
               )

      assert {:ok, %{prompt: next_prompt, session_id: nil, include_session?: true}} =
               Dialog.next_request(
                 issue,
                 [
                   original_comment,
                   %{id: "comment-new", body: "New user comment", created_at: ~U[2026-05-19 10:02:00Z]},
                   %{id: "comment-repo-error", body: body, created_at: ~U[2026-05-19 10:03:00Z]}
                 ],
                 project_root
               )

      assert next_prompt =~ "New user comment"
    after
      restore_app_env(:linear_client_request_fun, previous_linear_request_fun)
      File.rm_rf(test_root)
    end
  end

  test "script support exposes dialog prompts and session ids without an implementation worktree" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-script-support-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      interactive_workflow_path = Path.join(test_root, "WORKFLOW_INTERACTIVE.md")

      File.mkdir_p!(Path.join(project_root, ".symphony"))
      File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")

      dialog_workflow_path = write_dialog_workflow!("dialog={{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue = dialog_issue("issue-dialog-script", "MT-DSCRIPT")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-script" => [
          %{body: "Follow-up from Linear", created_at: ~U[2026-05-19 10:01:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-script]\n\nPrevious answer",
            created_at: ~U[2026-05-19 10:00:00Z]
          }
        ]
      })

      assert {:ok, %{prompt: "Follow-up from Linear", workflow_step: "Todo (Dialog-AI)", session_id: "thread-script"}} =
               ScriptSupport.manual_prompt_context(
                 Workflow.workflow_file_path(),
                 interactive_workflow_path,
                 dialog_workflow_path,
                 "MT-DSCRIPT",
                 project_root
               )

      refute File.exists?(Path.join(workspace_root, ".dialog"))
      refute File.exists?(Path.join(workspace_root, "MT-DSCRIPT"))
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "script support exposes dialog workflow step, dialog workspace, and no-op contexts" do
    test_root = Path.join(System.tmp_dir!(), "symphony-dialog-script-noop-#{System.unique_integer([:positive])}")

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_dialog_workflow_path = Application.get_env(:symphony_elixir, :dialog_workflow_file_path)

    try do
      project_root = Path.join(test_root, "project")
      workspace_root = Path.join(test_root, "workspaces")
      interactive_workflow_path = Path.join(test_root, "WORKFLOW_INTERACTIVE.md")
      previous_dialog_path = Path.join(test_root, "previous-dialog.md")

      File.mkdir_p!(Path.join(project_root, ".symphony"))
      File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")
      File.write!(previous_dialog_path, "---\n---\nprevious\n")
      Application.put_env(:symphony_elixir, :dialog_workflow_file_path, previous_dialog_path)

      dialog_workflow_path = write_dialog_workflow!("dialog={{ issue.identifier }}")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root
      )

      issue = dialog_issue("issue-dialog-noop", "MT-DNOOP")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-dialog-noop" => [
          %{body: "Question already handled", created_at: ~U[2026-05-19 10:00:00Z]},
          %{
            body: "### Antwort Symphony\n\n[Session thread-noop]\n\nAlready answered",
            created_at: ~U[2026-05-19 10:01:00Z]
          }
        ]
      })

      assert {:ok, "Todo (Dialog-AI)"} =
               ScriptSupport.workflow_step(Workflow.workflow_file_path(), "MT-DNOOP", project_root)

      assert {:ok, workspace} =
               ScriptSupport.dialog_workspace(Workflow.workflow_file_path(), "MT-DNOOP", project_root)

      assert workspace == Path.expand(project_root)
      refute File.exists?(Path.join(workspace_root, ".dialog"))

      assert {:ok, %{prompt: "", workflow_step: "Todo (Dialog-AI)", session_id: "thread-noop"}} =
               ScriptSupport.manual_prompt_context(
                 Workflow.workflow_file_path(),
                 interactive_workflow_path,
                 dialog_workflow_path,
                 "MT-DNOOP",
                 project_root
               )

      assert Application.get_env(:symphony_elixir, :dialog_workflow_file_path) == previous_dialog_path
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:dialog_workflow_file_path, previous_dialog_workflow_path)
      File.rm_rf(test_root)
    end
  end

  test "memory tracker normalizes comment maps and non-comment values" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        dialog_issue(nil, "MT-NO-ID"),
        dialog_issue("issue-memory-string-signal", "MT-STRING-SIGNAL"),
        dialog_issue("issue-memory-fallback-signal", "MT-FALLBACK-SIGNAL"),
        dialog_issue("issue-memory-invalid-signal", "MT-INVALID-SIGNAL")
      ])

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-memory-comments" => [
          %{"id" => "comment-1", "body" => "string-key body", "createdAt" => "2026-05-19T10:00:00Z"},
          123
        ],
        "issue-memory-string-signal" => [
          %{"id" => " ", "body" => "blank id", "createdAt" => "2026-05-19T10:00:00Z"},
          %{
            "id" => "comment-string-signal",
            "body" => "string timestamp",
            "createdAt" => "2026-05-19T10:01:00Z",
            "updatedAt" => "2026-05-19T10:02:00Z"
          }
        ],
        "issue-memory-fallback-signal" => [
          %{"id" => "comment-fallback-old", "body" => "old without timestamps"},
          %{"id" => "comment-fallback-new", "body" => "new without timestamps"}
        ],
        "issue-memory-invalid-signal" => [
          %{"id" => "comment-invalid", "body" => "invalid timestamp", "createdAt" => "not-a-timestamp"}
        ]
      })

      assert {:ok,
              [
                %{id: "comment-1", body: "string-key body", created_at: "2026-05-19T10:00:00Z", updated_at: nil},
                %{body: ""}
              ]} = Tracker.fetch_issue_comments("issue-memory-comments")

      assert {:ok, ["string-key body", ""]} = Tracker.fetch_issue_comment_bodies("issue-memory-comments")

      assert {:ok, issues} = Tracker.fetch_candidate_issues()

      assert Enum.find(issues, &(&1.identifier == "MT-NO-ID")).last_comment_signal == nil

      assert %{
               id: "comment-string-signal",
               created_at: ~U[2026-05-19 10:01:00Z],
               updated_at: ~U[2026-05-19 10:02:00Z]
             } = Enum.find(issues, &(&1.identifier == "MT-STRING-SIGNAL")).last_comment_signal

      assert %{id: "comment-fallback-new", created_at: nil, updated_at: nil} =
               Enum.find(issues, &(&1.identifier == "MT-FALLBACK-SIGNAL")).last_comment_signal

      assert %{id: "comment-invalid", created_at: nil, updated_at: nil} =
               Enum.find(issues, &(&1.identifier == "MT-INVALID-SIGNAL")).last_comment_signal
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
    end
  end

  test "orchestrator treats dialog issues as active outside the workflow status table" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: ["Todo (AI)"],
      tracker_terminal_states: ["Fertig"]
    )

    issue = dialog_issue("issue-dialog-active", "MT-DACTIVE")

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "orchestrator rechecks completed dialog issues because new comments may not update the issue timestamp" do
    completed_at = ~U[2026-05-21 09:50:44Z]
    issue = %{dialog_issue("issue-dialog-comment", "MT-DCOMMENT") | updated_at: completed_at}

    state = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      completed_states: %{"issue-dialog-comment" => {"todo (dialog-ai)", DateTime.to_iso8601(completed_at)}},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  defp put_linear_comment_refresh_failing_request_fun!(initial_comments, parent)
       when is_list(initial_comments) and is_pid(parent) do
    {:ok, request_counter} = Agent.start_link(fn -> 0 end)

    # These fixtures exercise app writes too: keep the actual lease helper and
    # durable receipts in a temporary project while controlling only HTTP.
    runtime = Path.dirname(Workflow.workflow_file_path())
    File.cp_r!(Path.expand("../../priv", __DIR__), Path.join(runtime, "priv"))
    File.write!(Path.join(runtime, ".symphony-release.json"), "{}")
    System.put_env("SYMPHONY_RELEASE_ROOT", runtime)
    System.put_env("SYMPHONY_LINEAR_ENV_DIR", Path.join(runtime, ".symphony"))
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _headers ->
      case payload["query"] do
        query when is_binary(query) ->
          linear_refresh_failing_response(query, payload, initial_comments, request_counter, parent)

        _query ->
          {:error, :missing_query}
      end
    end)
  end

  defp linear_refresh_failing_response(query, payload, initial_comments, request_counter, parent) do
    cond do
      String.contains?(query, "SymphonyLinearIssueComments") ->
        count = Agent.get_and_update(request_counter, &{&1, &1 + 1})

        if count < 2 do
          {:ok, %{status: 200, body: linear_comments_response(initial_comments)}}
        else
          {:error, :forced_comment_refresh_failure}
        end

      String.contains?(query, "SymphonyCreateComment") ->
        variables = payload["variables"]
        send(parent, {:linear_comment_body, variables["body"] || variables[:body]})

        comment = %{
          "id" => variables["id"] || variables[:id],
          "body" => variables["body"] || variables[:body],
          "updatedAt" => "2026-09-12T08:00:00Z",
          "user" => %{"id" => "synthetic-app"},
          "issue" => %{"id" => variables["issueId"] || variables[:issueId]}
        }

        {:ok, %{status: 200, body: %{"data" => %{"commentCreate" => %{"success" => true, "comment" => comment}}}}}

      true ->
        {:error, {:unexpected_query, query}}
    end
  end

  defp linear_comments_response(comments) when is_list(comments) do
    %{
      "data" => %{
        "issue" => %{
          "comments" => %{
            "nodes" => Enum.map(comments, &linear_comment_node/1),
            "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
          }
        }
      }
    }
  end

  defp linear_comment_node(comment) when is_map(comment) do
    %{
      "id" => Map.get(comment, :id) || Map.get(comment, "id"),
      "body" => Map.get(comment, :body) || Map.get(comment, "body") || "",
      "createdAt" => linear_comment_timestamp(comment, :created_at, "createdAt"),
      "updatedAt" => linear_comment_timestamp(comment, :updated_at, "updatedAt")
    }
  end

  defp linear_comment_timestamp(comment, atom_key, string_key) do
    comment
    |> Map.get(atom_key, Map.get(comment, string_key))
    |> case do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      value when is_binary(value) -> value
      _value -> nil
    end
  end

  defp write_dialog_workflow!(prompt) when is_binary(prompt) do
    path =
      Workflow.workflow_file_path()
      |> Path.dirname()
      |> Path.join("WORKFLOW_DIALOG.md")

    File.write!(path, "---\n---\n#{prompt}\n")
    path
  end

  defp dialog_issue(issue_id, identifier) do
    %Issue{
      id: issue_id,
      identifier: identifier,
      title: "Dialog issue",
      description: "Discuss the idea before implementation.",
      state: Dialog.state_name(),
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  defp write_fake_codex!(codex_binary, trace_file, thread_id, turn_id, answer) do
    escaped_thread_id = Jason.encode!(thread_id)
    escaped_turn_id = Jason.encode!(turn_id)
    escaped_answer = Jason.encode!(answer)

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    printf 'PWD:%s\\n' "$(pwd)" >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":#{escaped_thread_id}}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":#{escaped_turn_id}}}}'
          ;;
        4)
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":#{escaped_answer}}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_waiting_fake_codex!(codex_binary, trace_file, release_file, thread_id, turn_id, answer) do
    escaped_thread_id = Jason.encode!(thread_id)
    escaped_turn_id = Jason.encode!(turn_id)
    escaped_answer = Jason.encode!(answer)

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    release_file=#{inspect(release_file)}
    printf 'PWD:%s\\n' "$(pwd)" >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":#{escaped_thread_id}}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":#{escaped_turn_id}}}}'
          ;;
        4)
          while [ ! -f "$release_file" ]; do
            sleep 0.05
          done
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":#{escaped_answer}}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_waiting_dirty_fake_codex!(codex_binary, trace_file, release_file, dirty_file, thread_id, turn_id, answer) do
    escaped_thread_id = Jason.encode!(thread_id)
    escaped_turn_id = Jason.encode!(turn_id)
    escaped_answer = Jason.encode!(answer)

    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    release_file=#{inspect(release_file)}
    dirty_file=#{inspect(dirty_file)}
    printf 'PWD:%s\\n' "$(pwd)" >> "$trace_file"
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":#{escaped_thread_id}}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":#{escaped_turn_id}}}}'
          ;;
        4)
          while [ ! -f "$release_file" ]; do
            sleep 0.05
          done
          printf 'dirty\\n' > "$dirty_file"
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":#{escaped_answer}}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp wait_until_file_contains!(path, expected, attempts \\ 100)

  defp wait_until_file_contains!(path, expected, attempts) when attempts > 0 do
    if File.exists?(path) and String.contains?(File.read!(path), expected) do
      :ok
    else
      Process.sleep(20)
      wait_until_file_contains!(path, expected, attempts - 1)
    end
  end

  defp wait_until_file_contains!(_path, expected, 0), do: flunk("expected trace to contain #{inspect(expected)}")

  defp write_dirty_fake_codex!(codex_binary, trace_file, dirty_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    dirty_file=#{inspect(dirty_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dirty"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dirty"}}}'
          ;;
        4)
          printf 'dirty\\n' > "$dirty_file"
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"Dirty answer"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_runtime_log_fake_codex!(codex_binary, trace_file, runtime_log_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    runtime_log_file=#{inspect(runtime_log_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-log-safe"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-log-safe"}}}'
          ;;
        4)
          mkdir -p "$(dirname "$runtime_log_file")"
          printf 'runtime\\n' > "$runtime_log_file"
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","phase":"final_answer","text":"Log-safe answer"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_approval_request_fake_codex!(codex_binary, trace_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dialog-approval"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dialog-approval"}}}'
          printf 'EVENT:%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"touch README.md","cwd":"/tmp","reason":"write file"}}' >> "$trace_file"
          printf '%s\\n' '{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"touch README.md","cwd":"/tmp","reason":"write file"}}'
          ;;
        *)
          sleep 1
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_turn_input_required_fake_codex!(codex_binary, trace_file) do
    write_terminal_turn_event_fake_codex!(
      codex_binary,
      trace_file,
      "thread-dialog-input-required",
      "turn-dialog-input-required",
      ~s({"method":"turn/input_required","params":{"requiresInput":true,"reason":"blocked"}})
    )
  end

  defp write_turn_failed_fake_codex!(codex_binary, trace_file) do
    write_terminal_turn_event_fake_codex!(
      codex_binary,
      trace_file,
      "thread-dialog-turn-failed",
      "turn-dialog-turn-failed",
      ~s({"method":"turn/failed","params":{"reason":"forced failure"}})
    )
  end

  defp write_terminal_turn_event_fake_codex!(codex_binary, trace_file, thread_id, turn_id, event_json) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    event_json=#{inspect(event_json)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"#{thread_id}"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"#{turn_id}"}}}'
          ;;
        4)
          printf '%s\\n' "$event_json"
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_dirty_failing_fake_codex!(codex_binary, trace_file, dirty_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    dirty_file=#{inspect(dirty_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-dirty-error"}}}'
          ;;
         3)
           printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-dirty-error"}}}'
           ;;
         4)
           printf 'dirty\\n' > "$dirty_file"
           printf '%s\\n' '{"method":"turn/failed","params":{"reason":"forced failure"}}'
           exit 0
           ;;
         *)
           exit 0
           ;;
       esac
     done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_dirty_resume_failing_fake_codex!(codex_binary, trace_file, dirty_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    dirty_file=#{inspect(dirty_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf 'dirty\\n' > "$dirty_file"
          printf '%s\\n' '{"id":2,"error":{"message":"forced resume failure"}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_resume_failing_fake_codex!(codex_binary, trace_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"error":{"message":"forced resume failure"}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_waiting_resume_failing_fake_codex!(codex_binary, trace_file, release_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    release_file=#{inspect(release_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          while [ ! -f "$release_file" ]; do
            sleep 0.05
          done
          printf '%s\\n' '{"id":2,"error":{"message":"forced resume failure"}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_malformed_resume_fake_codex!(codex_binary, trace_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"title":"missing id"}}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_initialize_failing_fake_codex!(codex_binary, trace_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"error":{"message":"forced initialize failure"}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp write_dirty_initialize_failing_fake_codex!(codex_binary, trace_file, dirty_file) do
    File.write!(codex_binary, """
    #!/bin/sh
    trace_file=#{inspect(trace_file)}
    dirty_file=#{inspect(dirty_file)}
    count=0

    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"

      case "$count" in
        1)
          printf 'dirty\\n' > "$dirty_file"
          printf '%s\\n' '{"id":1,"error":{"message":"forced initialize failure"}}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp trace_json_payload(trace_lines, method) when is_list(trace_lines) and is_binary(method) do
    Enum.find_value(trace_lines, fn
      "JSON:" <> raw ->
        payload = Jason.decode!(raw)
        if payload["method"] == method, do: payload

      _line ->
        nil
    end)
  end

  defp expected_default_approval_policy do
    %{
      "reject" => %{
        "sandbox_approval" => true,
        "rules" => true,
        "mcp_elicitations" => true
      }
    }
  end

  defp expected_workspace_write_policy(workspace) when is_binary(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [Path.expand(workspace)],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp git_cmd!(cwd, args) when is_binary(cwd) and is_list(args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
