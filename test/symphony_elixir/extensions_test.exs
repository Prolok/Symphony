defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.{Tracker.Memory, Workpad}

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def fetch_issue_by_identifier(identifier) do
      send(self(), {:fetch_issue_by_identifier_called, identifier})
      {:ok, identifier}
    end

    def fetch_issue_comment_bodies(issue_id) do
      send(self(), {:fetch_issue_comment_bodies_called, issue_id})
      Process.get({__MODULE__, :issue_comment_bodies_result})
    end

    def fetch_issue_comments(issue_id) do
      send(self(), {:fetch_issue_comments_called, issue_id})

      case Process.get({__MODULE__, :issue_comments_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :issue_comments_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :issue_comments_result})
      end
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      Process.delete({Adapter, :branch_name_update_supported})
      Process.delete({FakeLinearClient, :graphql_result})
      Process.delete({FakeLinearClient, :graphql_results})
      Process.delete({FakeLinearClient, :issue_comment_bodies_result})
      Process.delete({FakeLinearClient, :issue_comments_result})
      Process.delete({FakeLinearClient, :issue_comments_results})

      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "linear adapter fetches an issue by identifier through the configured client module" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, "PRO-49"} = Adapter.fetch_issue_by_identifier("PRO-49")
    assert_receive {:fetch_issue_by_identifier_called, "PRO-49"}
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "Du arbeitest an einem Ticket dieses Repositorys."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 2_000

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 2_000

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 2_000

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert {:ok, false} = SymphonyElixir.Tracker.workpad_exists?("issue-1")
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "## Symphony Workpad\n\nbody")
    assert {:ok, true} = SymphonyElixir.Tracker.workpad_exists?("issue-1")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Fertig")
    assert :ok = SymphonyElixir.Tracker.update_issue_branch_name("issue-1", "symphony/MT-1")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_comment, "issue-1", "## Symphony Workpad\n\nbody"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Fertig"}
    assert_receive {:memory_tracker_branch_update, "issue-1", "symphony/MT-1"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")
    assert :ok = Memory.update_issue_branch_name("issue-1", "symphony/quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "memory tracker updates addressable comments" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-1" => [
        %{id: "comment-1", body: "old body", created_at: "2026-06-08T08:00:00Z"},
        %{id: "comment-2", body: "other"}
      ]
    })

    assert :ok = Memory.update_comment("comment-1", "updated body")
    assert_receive {:memory_tracker_comment_update, "issue-1", "comment-1", "updated body"}

    assert {:ok, comments} = Memory.fetch_issue_comments("issue-1")
    assert Enum.find(comments, &(&1.id == "comment-1")).body == "updated body"
    assert Enum.find(comments, &(&1.id == "comment-2")).body == "other"

    assert {:error, :comment_not_found} = Memory.update_comment("missing", "new body")

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"issue-1" => "not a comment list"})
    assert {:error, :comment_not_found} = Memory.update_comment("comment-1", "updated body")

    assert :ok = Memory.create_comment("issue-1", "restored body")
    assert {:ok, [created_comment]} = Memory.fetch_issue_comments("issue-1")
    assert is_binary(created_comment.id)
    assert created_comment.body == "restored body"
  end

  test "workpad helper safely updates one existing tracker workpad and verifies it" do
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "issue-1" => [
        %{id: "comment-other", body: "ordinary comment"},
        %{id: "comment-workpad", body: "## Symphony Workpad\n\nold"}
      ]
    })

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    updated_body = """
    ## Symphony Workpad

    ### Plan

    - [x] updated
    """

    assert :ok = Workpad.update_tracker_workpad("issue-1", updated_body)

    assert_receive {:memory_tracker_fetch_issue_comments, "issue-1"}
    assert_receive {:memory_tracker_comment_update, "issue-1", "comment-workpad", ^updated_body}
    assert_receive {:memory_tracker_fetch_issue_comments, "issue-1"}

    assert {:ok, comments} = Memory.fetch_issue_comments("issue-1")
    assert Enum.find(comments, &(&1.id == "comment-workpad")).body == updated_body
    assert Enum.find(comments, &(&1.id == "comment-other")).body == "ordinary comment"
  end

  test "workpad helper updates a workpad comment created through memory tracker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    body = """
    ## Symphony Workpad

    ### Plan

    - [ ] created
    """

    assert :ok = Memory.create_comment("issue-1", body)
    assert {:ok, [comment]} = Memory.fetch_issue_comments("issue-1")
    assert is_binary(comment.id)
    assert comment.id != ""
    assert comment.body == body

    updated_body = """
    ## Symphony Workpad

    ### Plan

    - [x] updated
    """

    assert :ok = Workpad.update_tracker_workpad("issue-1", updated_body)
    assert {:ok, [updated_comment]} = Memory.fetch_issue_comments("issue-1")
    assert updated_comment.id == comment.id
    assert updated_comment.body == updated_body
  end

  test "workpad helper rejects missing, multiple, empty, placeholder, and markerless updates" do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "missing-workpad" => [%{id: "comment-1", body: "ordinary comment"}],
      "missing-id" => ["## Symphony Workpad\n\nold"],
      "multiple-workpads" => [
        %{id: "comment-1", body: "## Symphony Workpad\n\nfirst"},
        %{id: "comment-2", body: "## Symphony Workpad\n\nsecond"}
      ]
    })

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    valid_body = "## Symphony Workpad\n\n### Plan\n\n- [x] done\n"

    assert {:error, :workpad_comment_not_found} = Workpad.update_tracker_workpad("missing-workpad", valid_body)

    assert {:error, {:multiple_workpad_comments, 2}} =
             Workpad.update_tracker_workpad("multiple-workpads", valid_body)

    assert {:error, :workpad_comment_missing_id} = Workpad.update_tracker_workpad("missing-id", valid_body)
    assert {:error, :workpad_comment_not_found} = Workpad.find_comment(nil)
    assert {:error, :empty_workpad_body} = Workpad.validate_update_body(" \n ")
    assert {:error, :workpad_marker_missing} = Workpad.validate_update_body("### Plan\n\n- [x] done")
    assert {:error, :placeholder_workpad_body} = Workpad.validate_update_body("## Symphony Workpad\n\nprobe")
    assert {:error, :placeholder_workpad_body} = Workpad.validate_update_body("## Symphony Workpad\n")
    assert {:error, :invalid_workpad_body} = Workpad.validate_update_body(nil)
  end

  test "workpad helper reports verification mismatches after tracker update" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")

    updated_body = """
    ## Symphony Workpad

    ### Plan

    - [x] updated
    """

    Process.put(
      {FakeLinearClient, :issue_comments_results},
      [
        {:ok, [%{id: "comment-workpad", body: "## Symphony Workpad\n\nold"}]},
        {:ok, [%{id: "comment-other", body: updated_body}]}
      ]
    )

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    )

    assert {:error, :workpad_comment_id_changed} = Workpad.update_tracker_workpad("issue-1", updated_body)

    Process.put(
      {FakeLinearClient, :issue_comments_results},
      [
        {:ok, [%{id: "comment-workpad", body: "## Symphony Workpad\n\nold"}]},
        {:ok, [%{id: "comment-workpad", body: "## Symphony Workpad\n\nstale"}]}
      ]
    )

    assert {:error, :workpad_update_verification_failed} = Workpad.update_tracker_workpad("issue-1", updated_body)
  end

  test "workpad helper matches only the exact marker header" do
    assert Workpad.marker() == "## Symphony Workpad"
    assert Workpad.comment_matches?("## Symphony Workpad\n\nbody")
    assert Workpad.comment_matches?("prefix\n## Symphony Workpad\nsuffix")
    refute Workpad.comment_matches?("## Symphony Workpad extra")
    refute Workpad.comment_matches?(nil)
  end

  test "workpad helper finds the workpad comment and detects open checklist items in a section" do
    workpad_body = """
    ## Symphony Workpad

    ### Review

    - [x] completed
    - [ ] pending

    ### Test

    - [x] not relevant here
    """

    assert Workpad.find_comment_body(["other", workpad_body]) == workpad_body
    assert {:ok, %{body: ^workpad_body}} = Workpad.find_comment([workpad_body])
    assert Workpad.find_comment_body(nil) == nil
    assert Workpad.section_has_open_checklist_items?(workpad_body, "Review")
    refute Workpad.section_has_open_checklist_items?(workpad_body, "Test")
    refute Workpad.section_has_open_checklist_items?(workpad_body, "Plan")
    refute Workpad.section_has_open_checklist_items?(nil, "Review")
    assert Workpad.section_checklist_status(workpad_body, "Review") == :open
    assert Workpad.section_checklist_status(workpad_body, "Test") == :closed
    assert Workpad.section_checklist_status(workpad_body, "Plan") == :missing
    assert Workpad.section_checklist_status(nil, "Review") == :missing
  end

  test "workpad helper marks prose-only sections as missing an explicit checklist" do
    workpad_body = """
    ## Symphony Workpad

    ### Review

    Review wurde lokal abgeschlossen.

    ### Test

    - [x] abgehakt
    """

    assert Workpad.section_checklist_status(workpad_body, "Review") == :no_checklist
    assert Workpad.section_checklist_status(workpad_body, "Test") == :closed
    refute Workpad.section_has_open_checklist_items?(workpad_body, "Review")
  end

  test "workpad helper classifies review handoff evidence" do
    no_findings_workpad = """
    ## Symphony Workpad

    ### Review

    - [x] Review gate completed without findings
    """

    findings_marker_workpad = """
    ## Symphony Workpad

    ### Review

    - [x] Review subagent: Keine Findings.
    - [x] Findings:
    """

    unknown_result_workpad = """
    ## Symphony Workpad

    ### Review

    - [x] Review abgeschlossen
    """

    open_workpad = """
    ## Symphony Workpad

    ### Review

    - [ ] Review subagent läuft
    """

    assert Workpad.review_handoff_status(no_findings_workpad) == {:ready, :no_findings}
    assert Workpad.review_handoff_status(findings_marker_workpad) == {:ready, :unknown}
    assert Workpad.review_handoff_status(unknown_result_workpad) == {:ready, :unknown}

    assert Workpad.review_handoff_status([
             no_findings_workpad,
             """
             Kombinierter Review-Finding-Fix-Kommentar für MT-123:

             - Finding: P1 `lib/example.ex`: Beispiel.
             - Relevanz: Das Problem war reviewer-relevant.
             - Änderung: Der Fix wurde umgesetzt.
             """
           ]) == {:ready, :unknown}

    assert Workpad.review_handoff_status([
             nil,
             %{body: no_findings_workpad},
             %{"body" => "Kombinierter Nach-Fix-Kommentar zu einem behandelten Finding"}
           ]) == {:ready, :unknown}

    assert Workpad.review_handoff_status([
             """
             ## Symphony Workpad

             ### Review

             - [x] Review subagent: Keine Findings.

             ### Verlauf

             - 2026-05-26 15:49:16 CEST - Fixrunde 3 abgeschlossen; kombinierter Nach-Fix-Kommentar wurde gepostet.
             """
           ]) == {:ready, :unknown}

    assert Workpad.review_handoff_status("""
           ## Symphony Workpad

           ### Review

           - [x] Review subagent: Keine Findings.

           ### Verlauf

           - 2026-05-26 16:08:12 CEST - Review-Fixes entstanden.
           """) == {:ready, :unknown}

    assert Workpad.review_handoff_status([
             no_findings_workpad,
             """
             ## Symphony Workpad

             ### Verlauf

             - 2026-05-26 16:09:04 CEST - Fixes entstanden.
             """
           ]) == {:ready, :unknown}

    assert Workpad.review_handoff_status([no_findings_workpad]) == {:ready, :no_findings}
    assert Workpad.find_comment_body([nil, %{body: no_findings_workpad}]) == no_findings_workpad
    assert Workpad.find_comment_body([%{"body" => no_findings_workpad}]) == no_findings_workpad
    assert Workpad.review_handoff_status(open_workpad) == :open
    assert Workpad.review_handoff_status("## Symphony Workpad\n\n### Review\n\nReview fertig.") == :blocked
    assert Workpad.review_handoff_status("## Symphony Workpad\n\n### Test\n\n- [x] fertig") == :blocked
    assert Workpad.review_handoff_status(nil) == :blocked
  end

  test "workpad helper classifies merge handoff evidence" do
    merge_evidence_workpad = """
    ## Symphony Workpad

    ### Verlauf

    - 2026-05-29 18:12:00 CEST - Merge-Evidenz: PR #42 gemergt, Merge-Commit `abc1234`.
    """

    merge_evidence_with_url_workpad = """
    ## Symphony Workpad

    ### Verlauf

    - 2026-05-29 18:13:00 CEST - Merge evidence: https://github.com/owner/repo/pull/42 merged, merge commit deadbee.
    """

    reversed_url_merge_evidence_workpad = """
    ## Symphony Workpad

    ### Verlauf

    - 2026-05-29 18:13:30 CEST - Merge evidence: merged https://github.com/owner/repo/pull/43, merge commit cafebabe.
    """

    incomplete_workpad = """
    ## Symphony Workpad

    ### Verlauf

    - 2026-05-29 18:14:00 CEST - PR #42 gemergt.
    """

    assert Workpad.merge_handoff_status(merge_evidence_workpad) == :ready
    assert Workpad.merge_handoff_status([%{body: merge_evidence_with_url_workpad}]) == :ready
    assert Workpad.merge_handoff_status(reversed_url_merge_evidence_workpad) == :ready
    assert Workpad.merge_handoff_status(incomplete_workpad) == :blocked
    assert Workpad.merge_handoff_status("Merge-Evidenz: PR #42 gemergt, Merge-Commit `abc1234`.") == :blocked
    assert Workpad.merge_handoff_status(nil) == :blocked
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :issue_comment_bodies_result},
      {:ok, ["not it", "## Symphony Workpad\n\npresent"]}
    )

    assert {:ok, ["not it", "## Symphony Workpad\n\npresent"]} = Adapter.fetch_issue_comment_bodies("issue-1")

    assert_receive {:fetch_issue_comment_bodies_called, "issue-1"}

    assert {:ok, true} = Adapter.workpad_exists?("issue-1")
    assert_receive {:fetch_issue_comment_bodies_called, "issue-1"}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.update_comment("comment-1", "updated")
    assert_receive {:graphql_called, update_comment_query, %{body: "updated", commentId: "comment-1"}}
    assert update_comment_query =~ "commentUpdate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentUpdate" => %{"success" => false}}}}
    )

    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.update_comment("comment-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_update_failed} = Adapter.update_comment("comment-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Fertig")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Fertig"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
    flush_graphql_calls()

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "__type" => %{
               "inputFields" => [%{"name" => "branchName"}]
             }
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_branch_name("issue-1", "symphony/MT-1")

    assert_receive {:graphql_called, support_query, %{}}
    assert_receive {:graphql_called, update_branch_query, %{issueId: "issue-1", branchName: "symphony/MT-1"}}

    assert support_query =~ "__type"
    assert support_query =~ "IssueUpdateInput"
    assert update_branch_query =~ "issueUpdate"
    assert update_branch_query =~ "branchName"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
    )

    assert {:error, :issue_branch_name_update_failed} = Adapter.update_issue_branch_name("issue-1", "symphony/Broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.update_issue_branch_name("issue-1", "symphony/Boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})

    assert {:error, :issue_branch_name_update_failed} = Adapter.update_issue_branch_name("issue-1", "symphony/Weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)

    assert {:error, :issue_branch_name_update_failed} = Adapter.update_issue_branch_name("issue-1", "symphony/Odd")

    flush_graphql_calls()
    Process.delete({Adapter, :branch_name_update_supported})

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"__type" => %{"inputFields" => [%{"name" => "stateId"}]}}}}
    )

    assert :ok = Adapter.update_issue_branch_name("issue-1", "symphony/Unsupported")

    assert_receive {:graphql_called, unsupported_query, %{}}
    assert unsupported_query =~ "IssueUpdateInput"
    refute_receive {:graphql_called, _, %{issueId: "issue-1", branchName: "symphony/Unsupported"}}

    flush_graphql_calls()
    Process.delete({Adapter, :branch_name_update_supported})
    Process.put({FakeLinearClient, :graphql_result}, {:error, :schema_unavailable})

    assert :ok = Adapter.update_issue_branch_name("issue-1", "symphony/Fallback")

    assert_receive {:graphql_called, fallback_query, %{}}
    assert fallback_query =~ "IssueUpdateInput"
    refute_receive {:graphql_called, _, %{issueId: "issue-1", branchName: "symphony/Fallback"}}
  end

  defp flush_graphql_calls do
    receive do
      {:graphql_called, _, _} -> flush_graphql_calls()
    after
      0 -> :ok
    end
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "projects" => [],
             "generated_at" => state_payload["generated_at"],
             "counts" => %{"running" => 1, "retrying" => 1},
             "running" => [
               %{
                 "project" => nil,
                 "issue_reference" => "MT-HTTP",
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
               }
             ],
             "retrying" => [
               %{
                 "project" => nil,
                 "issue_reference" => "MT-RETRY",
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12}
             },
             "retry" => nil,
             "logs" => %{
               "codex_session_logs" => [
                 %{
                   "at" => issue_payload["recent_events"] |> List.first() |> Map.fetch!("at"),
                   "event" => "notification",
                   "session_id" => "thread-http",
                   "message" => "rendered"
                 }
               ]
             },
             "recent_events" => [
               %{
                 "at" => issue_payload["recent_events"] |> List.first() |> Map.fetch!("at"),
                 "event" => "notification",
                 "session_id" => "thread-http",
                 "message" => "rendered"
               }
             ],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} = json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} = json_response(conn, 202)
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js = response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  test "http server falls back to the next free port when the configured port is occupied" do
    {occupied_socket, occupied_port} = listen_with_free_successor!()
    on_exit(fn -> :gen_tcp.close(occupied_socket) end)

    orchestrator_name = Module.concat(__MODULE__, :FallbackPortOrchestrator)
    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot()})

    start_supervised!(
      {HttpServer,
       [
         host: "127.0.0.1",
         port: occupied_port,
         orchestrator: orchestrator_name,
         snapshot_timeout_ms: 50
       ]}
    )

    assert HttpServer.bound_port() == occupied_port + 1

    response = Req.get!("http://127.0.0.1:#{occupied_port + 1}/api/v1/state")
    assert response.status == 200
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    event_at = DateTime.utc_now()

    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          recent_codex_events: [
            %{event: :notification, message: "rendered", session_id: "thread-http", timestamp: event_at}
          ],
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp listen_with_free_successor! do
    case :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        use_test_socket_or_retry(socket)

      {:error, reason} ->
        flunk("failed to reserve a test port: #{inspect(reason)}")
    end
  end

  defp use_test_socket_or_retry(socket) do
    with {:ok, {_ip, port}} when port < 65_535 <- :inet.sockname(socket),
         true <- port_available?(port + 1) do
      {socket, port}
    else
      _ ->
        :ok = :gen_tcp.close(socket)
        listen_with_free_successor!()
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        true

      {:error, _reason} ->
        false
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
