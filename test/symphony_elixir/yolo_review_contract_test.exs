defmodule SymphonyElixir.YoloReviewContractTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.CommentActionGuard
  alias SymphonyElixir.ProjectContext
  alias SymphonyElixir.Yolo.{ActionTool, Completion, Group, Handoff, OpenClaw, ReviewContract, Runner, Scope, Store}
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  alias SymphonyElixir.Yolo.{Operations, Recovery}
  alias SymphonyElixir.YoloReviewFixture, as: Fixture

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "human@example.com")
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=human@example.com\n")
    {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    context = %{context | assignee_ids: ["human"], human_handoff_id: "human", yolo_agent_id: "pai"}
    context = put_in(context.settings.tracker.yolo_agent, "Pai")
    context = put_in(context.settings.tracker.app["state_root"], Path.join(root, "state"))
    context = put_in(context.settings.workspace.root, Path.join(root, "workspaces"))
    ProjectContext.bind(context)
    workspace = Fixture.install(root)

    issue = %Issue{
      id: "review",
      identifier: "PRO-1",
      title: "CSV export",
      description: "Stable CSV",
      state: "Yolo Review",
      labels: [~s(skip "freigabe implementierung"), ~s(skip "freigabe review")],
      project_context_id: context.id,
      workspace_id: context.settings.tracker.app["workspace_id"],
      assignee_id: "human",
      delegate_id: "pai",
      assigned_to_worker: true,
      in_project_scope: true,
      project_id: "project",
      team_id: "team"
    }

    {:ok, db} =
      Agent.start_link(fn ->
        %{
          issue: issue,
          body: "## Symphony Workpad\n\nExisting evidence\n\n### Validierung\n\n- [x] Synthetic acceptance\n\n### Verlauf\n\nMerge-Evidenz: PR #1 MERGED, Merge-Commit: #{String.duplicate("a", 40)}",
          updates: 0
        }
      end)

    on_exit(fn -> if Process.alive?(db), do: Agent.stop(db) end)

    opts = [
      dependencies: &{:ok, &1},
      fetch: fn _ -> {:ok, [Agent.get(db, & &1.issue)]} end,
      before_action: fn _ -> :ok end,
      comments: fn _ -> {:ok, [%{id: "workpad", body: Agent.get(db, & &1.body)}]} end,
      workpad: fn _, body -> Agent.update(db, &%{&1 | body: body}) end,
      query: fn
        document, %{id: "team", after: nil} ->
          assert document =~ "query YoloStates"
          {:ok, %{"data" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "review-state", "name" => "Review"}], "pageInfo" => %{"hasNextPage" => false}}}}}}

        document, %{id: id, input: input} ->
          assert document =~ "mutation YoloUpdate"
          assert input in [%{stateId: "review-state", assigneeId: "human", delegateId: nil}, %{assigneeId: "human", delegateId: nil}]
          Agent.update(db, &%{&1 | issue: %{&1.issue | state: if(input[:stateId], do: "Review", else: &1.issue.state), delegate_id: nil}, updates: &1.updates + 1})
          {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => id}}}}}
      end
    ]

    %{root: root, context: context, workspace: workspace, issue: issue, db: db, opts: opts}
  end

  test "only the committed project skill at the bound checkout is accepted", ctx do
    assert %{"binding" => binding, "content" => content} = ReviewContract.load(ctx.workspace, "run")
    assert binding["project_id"] == ctx.context.id
    assert binding["sha"] == ctx.workspace.sha
    assert binding["skill_sha256"] == OpenClaw.digest(content)
    assert content =~ "acceptance.md"

    for workspace <- [%{ctx.workspace | sha: String.duplicate("0", 40)}, %{ctx.workspace | path: Path.join(ctx.root, "missing")}] do
      assert %{"error" => _} = ReviewContract.load(workspace, "run")
    end

    foreign = Path.join(ctx.root, "foreign")
    File.mkdir_p!(foreign)
    other = Fixture.install(foreign)
    assert %{"error" => _} = ReviewContract.load(other, "run")

    path = Path.join(ctx.workspace.path, binding["skill_path"])
    File.write!(path, content <> "\nChanged")
    assert %{"error" => _} = ReviewContract.load(ctx.workspace, "run")
    File.rm!(path)
    assert %{"error" => _} = ReviewContract.load(ctx.workspace, "run")
    File.mkdir!(path)
    assert %{"error" => _} = ReviewContract.load(ctx.workspace, "run")
    File.rmdir!(path)
    File.ln_s!(Path.join(other.path, binding["skill_path"]), path)
    # Even a committed symlink to a foreign skill is invalid.
    Fixture.git(ctx.workspace.path, ["add", "--force", binding["skill_path"]])
    Fixture.git(ctx.workspace.path, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "symlink"])
    sha = Fixture.git(ctx.workspace.path, ["rev-parse", "HEAD"]) |> String.trim()
    assert %{"error" => _} = ReviewContract.load(%{ctx.workspace | sha: sha}, "run")
  end

  test "handoff refuses false bindings, incomplete evidence and completion text before any write", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [ctx.issue.id]}))
        request = %{"issue_id" => ctx.issue.id, "report" => "Checked", "review" => Fixture.evidence()}
        assert {:error, :yolo_review_evidence_required} = Handoff.invoke(Map.delete(request, "review"), ctx.opts)
        assert {:error, :yolo_review_handoff_required} = Completion.invoke(%{"issue_id" => ctx.issue.id, "result" => "Everything checked"}, ctx.opts)

        for key <- ~w(project_id run_id workspace sha skill_path skill_sha256 version) do
          invalid = put_in(request, ["review", "binding", key], "wrong")
          assert {:error, :yolo_review_evidence_invalid} = Handoff.invoke(invalid, ctx.opts)
        end

        for key <- ~w(checks findings limitations decision) do
          assert {:error, :yolo_review_evidence_invalid} = Handoff.invoke(update_in(request["review"], &Map.delete(&1, key)), ctx.opts)
        end

        for checks <- [[], [nil], [%{"name" => "fake", "result" => "not_run", "evidence" => "none"}]] do
          assert {:error, :yolo_review_evidence_invalid} = Handoff.invoke(put_in(request, ["review", "checks"], checks), ctx.opts)
        end

        assert Agent.get(ctx.db, & &1.updates) == 0
        refute Completion.ready?("review", [ctx.issue])
        assert :ok = Handoff.invoke(request, ctx.opts)
        assert Completion.ready?("review", [ctx.issue])
        assert Agent.get(ctx.db, & &1.body) =~ "Prüf- und Lernbeleg (Vertrag 1)"
      end,
      workspace: ctx.workspace
    )
  end

  test "an unavailable project root cannot authorize an otherwise valid checkout", ctx do
    assert %{"binding" => _} = ReviewContract.load(ctx.workspace, "run")
    ProjectContext.bind(%{ctx.context | root: Path.join(ctx.root, "missing-project")})

    try do
      assert %{"error" => "yolo_review_skill_unavailable_or_unbound"} = ReviewContract.load(ctx.workspace, "run")
    after
      ProjectContext.bind(ctx.context)
    end
  end

  test "a checkout without a bound project fails closed instead of crashing", ctx do
    assert %{"binding" => _} = ReviewContract.load(ctx.workspace, "run")

    ProjectContext.with_context(nil, fn ->
      assert %{"error" => "yolo_review_skill_unavailable_or_unbound"} = ReviewContract.load(ctx.workspace, "run")
    end)
  end

  test "a corrupt operation journal remains an error instead of authorizing acceptance", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [ctx.issue.id]}))
        request = %{"issue_id" => ctx.issue.id, "report" => "Checked", "review" => Fixture.evidence()}
        assert :ok = ReviewContract.validate(ctx.issue, request)
        path = Operations.path("interrupted-followup")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "corrupt")

        assert {:error, :yolo_operation_changed_or_corrupt} = ReviewContract.validate(ctx.issue, request)
        # Handoff also checks journal health in its earlier admission gate.
        assert {:error, :yolo_action_scope_changed} = Handoff.invoke(request, ctx.opts)
        assert Agent.get(ctx.db, & &1.updates) == 0
        refute Completion.ready?("review", [ctx.issue])
      end,
      workspace: ctx.workspace
    )
  end

  test "fresh checkout changes invalidate an already captured binding", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        request = %{"issue_id" => ctx.issue.id, "report" => "Checked", "review" => Fixture.evidence()}
        File.write!(Path.join(ctx.workspace.path, ".codex/skills/sym-yolo-review/SKILL.md"), "changed")
        assert {:error, :yolo_review_evidence_invalid} = Handoff.invoke(request, ctx.opts)
        assert Agent.get(ctx.db, & &1.updates) == 0
      end,
      workspace: ctx.workspace
    )
  end

  test "missing durable attempt prevents changing status or delegation", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        request = %{"issue_id" => ctx.issue.id, "report" => "Checked", "review" => Fixture.evidence()}
        assert {:error, :yolo_attempt_unavailable} = Handoff.invoke(request, ctx.opts)
        assert %{issue: %{state: "Yolo Review", delegate_id: "pai"}, updates: 0} = Agent.get(ctx.db, & &1)
      end,
      workspace: ctx.workspace
    )
  end

  test "waiting requires a confirmed dependency and preserves lookup failures", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        request = %{"kind" => "wait", "issue_id" => ctx.issue.id, "report" => "Waiting", "review" => Fixture.evidence()}
        assert {:error, :yolo_wait_requires_dependency} = Handoff.invoke(request, ctx.opts)

        dependencies = fn
          [] -> {:ok, []}
          [_] -> {:error, :offline}
        end

        assert {:error, :offline} = Handoff.invoke(request, Keyword.put(ctx.opts, :dependencies, dependencies))
        assert Agent.get(ctx.db, & &1.updates) == 0
        refute Completion.ready?("review", [ctx.issue])
      end,
      workspace: ctx.workspace
    )
  end

  test "a state change while recording acceptance prevents the terminal update", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [ctx.issue.id]}))
        request = %{"issue_id" => ctx.issue.id, "report" => "Checked", "review" => Fixture.evidence()}
        workpad = fn _, body -> Agent.update(ctx.db, &%{&1 | body: body, issue: %{&1.issue | state: "BLOCKER"}}) end
        assert {:error, :yolo_handoff_not_ready} = Handoff.invoke(request, Keyword.put(ctx.opts, :workpad, workpad))
        assert Agent.get(ctx.db, & &1.updates) == 0
        refute Completion.ready?("review", [ctx.issue])
      end,
      workspace: ctx.workspace
    )
  end

  test "authorized handoff still requires the freshly confirmed status and ownership", ctx do
    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [ctx.issue.id]}))
        request = %{"issue_id" => ctx.issue.id, "report" => "Checked", "review" => Fixture.evidence()}

        for {response, reason} <- [{{:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => ctx.issue.id}}}}}, :yolo_handoff_unconfirmed}, {{:error, :offline}, :offline}] do
          query = fn
            document, %{input: _} ->
              assert document =~ "mutation YoloUpdate"
              mutation = %{"query" => "mutation { issueUpdate(id: \"#{ctx.issue.id}\", input: {stateId: \"target\"}) { success } }"}

              states = fn _, _ ->
                {:ok, %{"data" => %{"issue" => %{"id" => ctx.issue.id, "team" => %{"states" => %{"nodes" => [%{"id" => "target", "name" => "Review"}], "pageInfo" => %{"hasNextPage" => false}}}}}}}
              end

              assert :ok = CommentActionGuard.check(mutation, query: states, fetch_issue: ctx.opts[:fetch], guard: fn _ -> :ok end)
              response

            document, variables ->
              ctx.opts[:query].(document, variables)
          end

          assert {:error, ^reason} = Handoff.invoke(request, Keyword.put(ctx.opts, :query, query))
          refute Handoff.authorized?(ctx.issue.id)
          refute Completion.ready?("review", [ctx.issue])
        end

        assert Agent.get(ctx.db, & &1.issue) == ctx.issue
      end,
      workspace: ctx.workspace
    )
  end

  @tag :review_regression
  test "confirmed terminal acceptance cleans only the regular issue workspace", ctx do
    {:ok, regular} = Workspace.create_for_issue(ctx.issue)
    File.write!(Path.join(regular, "retained.txt"), "regular workspace")
    Fixture.git(regular, ["init", "--quiet"])
    Fixture.git(regular, ["add", "retained.txt"])
    Fixture.git(regular, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "validated"])

    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [ctx.issue.id]}))
        request = %{"issue_id" => ctx.issue.id, "report" => "Accepted", "review" => Fixture.evidence()}
        File.write!(Path.join(regular, "retained.txt"), "unvalidated merge change")
        assert {:error, :merge_workspace_requires_test} = Handoff.invoke(request, ctx.opts)
        assert File.dir?(regular)
        assert Agent.get(ctx.db, & &1.updates) == 0
        Fixture.git(regular, ["checkout", "--", "retained.txt"])
        assert :ok = Handoff.invoke(request, ctx.opts)
        assert Agent.get(ctx.db, & &1.issue.state) == "Review"
        refute File.exists?(regular)
        assert File.dir?(ctx.workspace.path)
      end,
      workspace: ctx.workspace
    )
  end

  test "a missing review contract permits only an explicit escalation without leaving Yolo Review", ctx do
    File.rm!(Path.join(ctx.workspace.path, ".codex/skills/sym-yolo-review/SKILL.md"))

    Scope.with_scope(
      "review",
      [ctx.issue],
      "run",
      fn ->
        {:ok, record} = Store.read("review")
        :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [ctx.issue.id]}))
        request = %{"kind" => "escalate", "issue_id" => ctx.issue.id, "report" => "Prüfanweisung fehlt"}
        assert {:error, :yolo_escalation_incomplete} = Handoff.invoke(request, ctx.opts)

        request =
          Map.put(request, "escalation", %{
            "cause" => "Prüfanweisung fehlt",
            "attempts" => "Gebundenen Checkout geprüft",
            "proposal" => "Versionierte Prüfanweisung bereitstellen",
            "decision" => "Bereitstellung bestätigen"
          })

        assert :ok = Operations.run("unfinished-fix", %{"kind" => "followup", "origin_ids" => [ctx.issue.id]}, fn _ -> :ok end)
        assert :ok = Handoff.invoke(request, ctx.opts)
        assert Completion.ready?("review", [ctx.issue])
        assert %{issue: %{state: "Yolo Review", delegate_id: "pai"}, updates: 0, body: body} = Agent.get(ctx.db, & &1)
        assert body =~ "unfinished-fix"
        assert {:error, _} = Handoff.invoke(Map.put(request, "kind", "handoff"), ctx.opts)
      end,
      workspace: ctx.workspace
    )
  end

  test "an escalated pending creation ends the runner as an evidenced wait without claiming creation success", ctx do
    opts =
      Keyword.merge(ctx.opts,
        project: fn -> {:ok, [ctx.issue]} end,
        workspace: fn _, _ -> {:ok, ctx.workspace} end,
        lease: fn _, fun -> fun.() end,
        scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
        checkpoint: fn _ -> {:ok, %{}} end,
        session: fn _, _, _, _ ->
          assert :ok = Operations.run("pending-creation", %{"kind" => "followup", "origin_ids" => [ctx.issue.id]}, fn _ -> :ok end)

          request = %{
            "kind" => "escalate",
            "issue_id" => ctx.issue.id,
            "report" => "Anlageausgang benötigt Betreiberabgleich",
            "review" => Map.put(Fixture.evidence(), "limitations", ["Anlage und Links unbestätigt"]),
            "escalation" => %{"cause" => "Anlage unbestätigt", "attempts" => "Journal geprüft", "proposal" => "Reservierte ID abgleichen", "decision" => "Abgleich bestätigen"}
          }

          assert :ok = Handoff.invoke(request, ctx.opts)
          {:ok, %{session_id: "escalated-session"}}
        end
      )

    assert :ok = Runner.run("review", [ctx.issue], [ctx.issue], opts)
    assert {:ok, [pending]} = Operations.pending([ctx.issue.id])
    refute pending["done"]
    assert {:ok, record} = Store.read("review")
    assert record["attempt"]["session_id"] == "escalated-session"
    assert record["error"] == nil
    assert record["escalated_operations"][ctx.issue.id] == [pending["key"]]
    assert :ok = Recovery.resume(%Orchestrator.State{}, [ctx.issue], query: fn _, _ -> flunk("an escalated operation must remain reserved") end)
    # A later independent group attempt must not erase the durable operation hold.
    assert :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "independent", "members" => ["another-issue"], "completed" => %{}}))
    assert :ok = Recovery.resume(%Orchestrator.State{}, [ctx.issue], lease: fn _, _ -> flunk("another group attempt must not release an escalated operation") end)
    assert :ok = Store.write("review", record)
    assert %{issue: %{state: "Yolo Review", delegate_id: "pai"}, updates: 0} = Agent.get(ctx.db, & &1)
    assert {:error, :yolo_group_changed} = Runner.run("review", [ctx.issue], [ctx.issue], opts)

    Scope.with_scope("review", [ctx.issue], "stale-run", fn ->
      assert {:error, {:yolo_operations_pending, _}} = Completion.verify_operations([ctx.issue])
    end)

    Scope.with_scope("review", [ctx.issue], record["attempt"]["id"], fn ->
      assert :ok = Completion.verify_operations([ctx.issue])
      assert :ok = Operations.run("later-creation", %{"kind" => "followup", "origin_ids" => [ctx.issue.id]}, fn _ -> :ok end)
      assert {:error, {:yolo_operations_pending, _}} = Completion.verify_operations([ctx.issue])
    end)
  end

  test "a missing skill does not obstruct an honest external BLOCKER handoff", ctx do
    issue = %{ctx.issue | state: "BLOCKER"}
    Agent.update(ctx.db, &%{&1 | issue: issue})

    Scope.with_scope("review", [issue], "run", fn ->
      {:ok, record} = Store.read("review")
      :ok = Store.write("review", Map.put(record, "attempt", %{"id" => "run", "members" => [issue.id]}))
      assert :ok = Handoff.invoke(%{"issue_id" => issue.id, "report" => "Projekt-Skill fehlt; Projektbetreiber muss ihn über PR bereitstellen. Keine Abnahme."}, ctx.opts)
      assert Agent.get(ctx.db, & &1.issue.state) == "BLOCKER"
    end)
  end

  defp selected_executor(executor), do: executor

  for executor <- [:codex, :openclaw] do
    test "#{executor} runs the same versioned fixture and hands off once", ctx do
      executor = selected_executor(unquote(executor))
      context = ctx.context
      if executor == :openclaw, do: ProjectContext.bind(put_in(context.settings.tracker.openclaw_yolo_agent, "po"))
      parent = self()

      session = fn _, prompt, _, _ ->
        assert prompt =~ "Exportprojekt: Schlussabnahme"
        assert prompt =~ "review_contract"
        assert prompt =~ ctx.workspace.sha
        assert prompt =~ "fix_and_regression_test"
        request = %{"kind" => "handoff", "issue_id" => ctx.issue.id, "report" => "CSV fixture checked", "review" => Fixture.evidence()}
        assert ActionTool.execute(request, ctx.opts)["success"]
        send(parent, :accepted)
        {:ok, %{session_id: "codex-session"}}
      end

      transport = fn
        ["--version"] ->
          {:ok, "OpenClaw 2026.9.4\n"}

        ["gateway", "call", "agents.list" | _] ->
          {:ok, Jason.encode!(%{agents: [%{id: "po"}]})}

        ["gateway", "call", "agent", "--params", params | _] ->
          params = Jason.decode!(params)
          assert params["message"] =~ "Exportprojekt: Schlussabnahme"
          assert params["message"] =~ "Memory ersetzt weder sym-yolo-review"
          id = params["idempotencyKey"]
          descriptor = Path.join([ctx.context.settings.workspace.root, "yolo-runs", id, "tools.json"])
          binding = File.read!(descriptor) |> Jason.decode!()
          proof = Map.merge(binding["checkout"], %{"cwd" => ctx.workspace.path, "git_root" => ctx.workspace.path, "clean" => true})
          arguments = %{"kind" => "handoff", "issue_id" => ctx.issue.id, "report" => "CSV fixture checked", "review" => Fixture.evidence()}
          request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => %{"name" => "symphony_yolo_action", "arguments" => arguments}}
          {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, binding["port"], [:binary, packet: :line, active: false], 1000)
          :ok = :gen_tcp.send(socket, Jason.encode!(%{token: binding["token"], checkout: proof, request: request}) <> "\n")
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
          :gen_tcp.close(socket)
          refute Jason.decode!(bytes)["result"]["isError"]
          send(parent, :accepted)
          {:ok, Jason.encode!(%{runId: id, status: "accepted"})}

        ["gateway", "call", "agent.wait", "--params", params | _] ->
          {:ok, Jason.encode!(%{runId: Jason.decode!(params)["runId"], status: "ok", endedAt: 2})}
      end

      opts =
        Keyword.merge(ctx.opts,
          project: fn -> {:ok, [ctx.issue]} end,
          workspace: fn _, _ -> {:ok, ctx.workspace} end,
          lease: fn _, fun -> fun.() end,
          scan: fn _ -> {:ok, %{"versions" => %{}, "last_successful_scan" => "now", "scan_error" => nil}} end,
          checkpoint: fn _ -> {:ok, %{}} end,
          session: session,
          transport: transport,
          tool_opts: ctx.opts
        )

      assert :ok = Runner.run("review", [ctx.issue], [ctx.issue], opts)
      assert_receive :accepted
      result = Agent.get(ctx.db, & &1)
      assert result.updates == 1
      assert result.issue.state == "Review"
      assert result.issue.delegate_id == nil
      assert result.body =~ "Existing evidence"
      assert result.body =~ ctx.workspace.sha
      assert Group.groups([result.issue]) == %{}
      if executor == :openclaw, do: assert({:ok, %{"state" => "completed"}} = Journal.read("review"))
    end
  end
end
