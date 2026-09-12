defmodule SymphonyElixir.CoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AutocommitMessage
  alias SymphonyElixir.Codex.ScriptSupport

  setup_all do
    # The application also schedules polls when its initial poll is disabled.
    # Keep it away from this module's global Memory fixtures until all per-test
    # cleanup has finished; individual tests start their own orchestrators.
    application_orchestrator = Process.whereis(Orchestrator)

    if is_pid(application_orchestrator) do
      stop_orchestrator_and_workers(application_orchestrator, fn _pid ->
        Supervisor.terminate_child(SymphonyElixir.Supervisor, Orchestrator)
      end)

      on_exit(fn ->
        assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, Orchestrator)
      end)
    end

    {:ok, application_orchestrator: application_orchestrator}
  end

  setup do
    isolate_git_discovery!(System.tmp_dir!())
    :ok
  end

  test "config defaults and validation checks" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: nil,
      poll_interval_ms: nil,
      tracker_active_states: nil,
      tracker_terminal_states: nil,
      codex_command: nil
    )

    config = Config.settings!()
    assert config.polling.interval_ms == 30_000
    assert config.polling.idle_shutdown_ms == 3_600_000

    assert config.tracker.active_states == [
             "Todo (AI)",
             "Planung (AI)",
             "In Arbeit (AI)",
             "PreReview (AI)",
             "Review (AI)",
             "Test (AI)",
             "Abbruch (AI)",
             "Merge (AI)"
           ]

    assert config.tracker.terminal_states == ["Review", "Fertig", "Abgebrochen"]
    assert config.tracker.assignee == "dev@example.com"
    assert config.agent.max_turns == 20

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: "invalid")

    assert_raise ArgumentError, ~r/interval_ms/, fn ->
      Config.settings!().polling.interval_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.interval_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_idle_shutdown_ms: "invalid")

    assert_raise ArgumentError, ~r/idle_shutdown_ms/, fn ->
      Config.settings!().polling.idle_shutdown_ms
    end

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "polling.idle_shutdown_ms"

    write_workflow_file!(Workflow.workflow_file_path(), poll_interval_ms: 45_000)
    assert Config.settings!().polling.interval_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), poll_idle_shutdown_ms: 45_000)
    assert Config.settings!().polling.idle_shutdown_ms == 45_000

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_turns"

    write_workflow_file!(Workflow.workflow_file_path(), max_turns: 5)
    assert Config.settings!().agent.max_turns == 5

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: "Todo,  Planung,")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    assert {:error, :missing_linear_scope} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "project",
      codex_command: ""
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.command"
    assert message =~ "can't be blank"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "   ")
    assert :ok = Config.validate!()
    assert Config.settings!().codex.command == "   "

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "/bin/sh app-server")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "definitely-not-valid")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "unsafe-ish")
    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
    )

    assert :ok = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: 123)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "123")
    assert {:error, {:unsupported_tracker_kind, "123"}} = Config.validate!()
  end

  describe "maximum review iterations" do
    setup do
      previous = System.get_env("SYM_MAXIMUM_REVIEW_ITERATIONS")
      System.delete_env("SYM_MAXIMUM_REVIEW_ITERATIONS")
      on_exit(fn -> restore_env("SYM_MAXIMUM_REVIEW_ITERATIONS", previous) end)
      root = Path.dirname(Workflow.workflow_file_path())
      File.write!(Path.join(root, "mix.exs"), "defmodule SymphonyElixir.MixProject\napp: :symphony_elixir\n")
      {:ok, symphony_root: root}
    end

    test "resolves built-in, root file, local and process precedence without exporting values", %{symphony_root: root} do
      before_env = System.get_env()
      assert Config.maximum_review_iterations!(root) == 3
      File.write!(Path.join(root, ".env"), "UNRELATED_SETTING=unchanged\n")
      assert Config.maximum_review_iterations!(root) == 3

      File.write!(Path.join(root, ".env"), "SYM_MAXIMUM_REVIEW_ITERATIONS=4\n")
      assert Config.maximum_review_iterations!(root) == 4

      for {assignment, expected} <- [{"1", 1}, {"' 5 '", 5}, {~s(" 3 "), 3}] do
        File.write!(Path.join(root, ".env.local"), "export SYM_MAXIMUM_REVIEW_ITERATIONS = #{assignment} # override\n")
        assert Config.maximum_review_iterations!(root) == expected
      end

      assert System.get_env() == before_env
      System.put_env("SYM_MAXIMUM_REVIEW_ITERATIONS", " 7 ")
      assert Config.maximum_review_iterations!(root) == 7
    end

    test "rejects explicit empty and invalid values from every source with a named error", %{symphony_root: root} do
      for value <- ["", "0", "-1", "1.5", "text"] do
        for filename <- [".env", ".env.local"] do
          path = Path.join(root, filename)
          File.write!(path, "SYM_MAXIMUM_REVIEW_ITERATIONS=#{value}\n")

          assert_raise ArgumentError, ~r/SYM_MAXIMUM_REVIEW_ITERATIONS.*positive integer/, fn ->
            Config.maximum_review_iterations!(root)
          end

          File.rm!(path)
        end

        System.put_env("SYM_MAXIMUM_REVIEW_ITERATIONS", value)

        assert_raise ArgumentError, ~r/SYM_MAXIMUM_REVIEW_ITERATIONS.*positive integer/, fn ->
          PromptBuilder.build_prompt(%Issue{state: "Review (AI)"}, prompt_template: "review")
        end

        System.delete_env("SYM_MAXIMUM_REVIEW_ITERATIONS")
      end

      File.write!(Path.join(root, ".env.local"), "MALFORMED\n")

      assert_raise ArgumentError, ~r/SYM_MAXIMUM_REVIEW_ITERATIONS config.*invalid_env_file/, fn ->
        Config.maximum_review_iterations!(root)
      end
    end

    test "keeps Symphony configuration isolated from target repo, worktree and previous resolutions", %{symphony_root: root} do
      target = Path.join(root, "target-project")
      worktree = Path.join(root, "target-worktrees/ISSUE-1")
      other_symphony = Path.join(root, "other-symphony")

      for {directory, value} <- [{root, 1}, {target, 8}, {worktree, 9}, {other_symphony, 5}] do
        File.mkdir_p!(Path.join(directory, ".symphony"))
        File.write!(Path.join(directory, ".env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=#{value}\nLINEAR_API_KEY=ignored\nSYM_CODEX_MODEL=ignored\n")
        File.write!(Path.join(directory, ".symphony/.env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=99\n")
      end

      System.put_env("SYMPHONY_SOURCE_REPO", target)
      System.put_env("SYMPHONY_ACTIVE_REPO_ROOT", worktree)
      System.put_env("SYMPHONY_WORKFLOW_FILE", Path.join(root, "WORKFLOW.md"))
      before_env = System.get_env()
      issue = %Issue{state: "Review (AI)"}
      opts = [prompt_template: "{{ runtime.maximum_review_iterations | plus: 1 }}"]

      File.cd!(worktree, fn ->
        assert PromptBuilder.build_prompt(issue, opts) == "2"
        assert PromptBuilder.build_prompt(issue, Keyword.put(opts, :workflow_file, Path.join(other_symphony, "WORKFLOW.md"))) == "2"
        assert PromptBuilder.build_prompt(issue, opts) == "2"
      end)

      assert Config.maximum_review_iterations!(other_symphony) == 5
      assert System.get_env() == before_env
    end

    test "external workflow files do not replace the Symphony checkout as budget source", %{symphony_root: root} do
      external = Path.join(root, "external-config")
      File.mkdir_p!(external)
      File.write!(Path.join(root, ".env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=1\n")
      File.write!(Path.join(external, ".env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=99\n")
      workflow_file = Path.join(external, "CUSTOM.md")
      write_workflow_file!(workflow_file)
      Workflow.set_workflow_file_path(workflow_file)

      File.cd!(root, fn ->
        for mode <- [:orchestrated, :manual] do
          assert PromptBuilder.build_prompt(%Issue{state: "Review (AI)"},
                   prompt_template: "{{ runtime.maximum_review_iterations }}",
                   session_mode: mode,
                   workflow_file: workflow_file
                 ) == "1"
        end
      end)
    end

    test "renders the real automated and manual review prompts with the same budget", %{symphony_root: root} do
      {:ok, %{prompt_template: automated}} = Workflow.load(Path.expand("../../WORKFLOW.md", __DIR__))
      {:ok, %{prompt_template: manual}} = Workflow.load(Path.expand("../../WORKFLOW_INTERACTIVE.md", __DIR__))
      issue = %Issue{id: "review-budget", identifier: "MT-696", title: "Review", state: "Review (AI)", labels: []}

      for limit <- [3, 1, 5] do
        if limit != 3, do: File.write!(Path.join(root, ".env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=#{limit}\n")

        for {mode, template} <- [orchestrated: automated, manual: manual] do
          prompt = File.cd!(root, fn -> PromptBuilder.build_prompt(issue, session_mode: mode, prompt_template: template) end)
          assert prompt =~ "runtime.maximum_review_iterations=#{limit}"
          assert prompt =~ "gemäß Skill"
        end
      end

      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      interactive_path = Path.join(root, "WORKFLOW_INTERACTIVE.md")
      File.cp!(Path.expand("../../WORKFLOW_INTERACTIVE.md", __DIR__), interactive_path)
      workflow_path = Workflow.workflow_file_path()

      File.mkdir_p!(Path.join(root, ".symphony"))
      File.write!(Path.join(root, ".symphony/.env.local"), "SYM_MAXIMUM_REVIEW_ITERATIONS=99\n")

      for {shell_value, expected} <- [{nil, 5}, {"7", 7}] do
        restore_env("SYM_MAXIMUM_REVIEW_ITERATIONS", shell_value)

        assert {:ok, %{prompt: prompt, workflow_step: "Review (AI)"}} =
                 File.cd!(root, fn ->
                   ScriptSupport.manual_prompt_context(workflow_path, interactive_path, issue.identifier, root)
                 end)

        assert prompt =~ "runtime.maximum_review_iterations=#{expected}"
      end
    end
  end

  test "current WORKFLOW.md file is valid and complete" do
    original_workflow_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.clear_workflow_file_path()
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load()
    assert is_map(config)
    review_authorization = get_in(config, ["prompt_snippets", "review_subagent_authorization"])

    tracker = Map.get(config, "tracker", %{})
    assert is_map(tracker)
    assert Map.get(tracker, "kind") == "linear"
    assert is_binary(Map.get(tracker, "project_slug"))
    assert is_list(Map.get(tracker, "active_states"))
    assert is_list(Map.get(tracker, "terminal_states"))

    hooks = Map.get(config, "hooks", %{})
    assert is_map(hooks)
    assert Map.get(hooks, "timeout_ms") == 180_000
    assert Map.get(hooks, "after_create") =~ "set -eu"
    assert Map.get(hooks, "after_create") =~ "branch=\"symphony/$issue_key\""
    assert Map.get(hooks, "after_create") =~ "source_repo=\"$SYMPHONY_PROJECT_ROOT\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$workspace\" rev-parse --is-inside-work-tree"
    assert Map.get(hooks, "after_create") =~ "rm -rf \"$workspace\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" fetch origin"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" worktree add \"$workspace\" \"$branch\""
    assert Map.get(hooks, "after_create") =~ "refs/remotes/origin/$branch"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" worktree add --track -b \"$branch\" \"$workspace\" \"origin/$branch\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$workspace\" pull --ff-only origin \"$branch\""
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" worktree add -b \"$branch\" \"$workspace\" origin/main"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" config \"branch.$branch.remote\" origin"
    assert Map.get(hooks, "after_create") =~ "git -C \"$source_repo\" config \"branch.$branch.merge\" \"refs/heads/$branch\""

    assert Map.get(hooks, "after_create") =~
             "python3 \"$source_repo/.symphony/on_create_worktree.py\" \"$source_repo\" \"$workspace\""

    refute Map.has_key?(hooks, "on_worktree_commit")
    assert Map.get(hooks, "before_remove") =~ "workspace=\"$PWD\""

    assert Map.get(hooks, "before_remove") =~
             "python3 \"$SYMPHONY_PROJECT_ROOT/.symphony/on_remove_worktree.py\" \"$SYMPHONY_PROJECT_ROOT\" \"$workspace\""

    assert Map.get(hooks, "before_remove") =~ "cd \"$SYMPHONY_WORKFLOW_DIR\" && mise exec -- mix workspace.before_remove --workspace \"$workspace\" --source-repo \"$SYMPHONY_PROJECT_ROOT\""
    codex = Map.get(config, "codex", %{})
    assert is_map(codex)
    assert Map.get(codex, "command") == "sym-codex --observer"

    assert String.trim(prompt) != ""
    assert is_binary(Config.workflow_prompt())
    assert Config.workflow_prompt() == prompt
    assert prompt =~ "Der kanonische Arbeitsbranch für dieses Issue heißt immer `symphony/{{ issue.identifier }}`."
    assert prompt =~ "Wenn ein frischer Branch benötigt wird, erstelle oder verwende genau `symphony/{{ issue.identifier }}` von `origin/main`."
    assert prompt =~ "Im App-Modus nutze ausschließlich das injizierte `linear_graphql` bzw. das gebundene `symphony_linear`-MCP"
    assert prompt =~ "Das geschützte Betreiberwerkzeug `scripts/linear-app` ist kein Modell-Shell-Ersatz."
    assert prompt =~ "kein Shell-/Mix-/Update-Skript-Fallback"
    assert prompt =~ "features.memories=false"
    assert prompt =~ "SYM_PROJECT_ROOT"
    assert prompt =~ "verwende für die erste Anfrage einen bereits abgesicherten schema-konformen Bootstrap"
    assert prompt =~ "query BootstrapIssue($key: String!)"
    assert prompt =~ "query BootstrapIssueByTeamAndNumber($teamKey: String!, $number: Float!)"
    assert prompt =~ "Wenn in der aktuellen Session bereits bestätigt ist, dass `issue(id: $key)` Issue-Keys akzeptiert"
    assert prompt =~ "Nutze die dabei zurückgegebene interne `id` anschließend für eng begrenzte Folgeabfragen über `issue(id: $id)`."
    assert prompt =~ "Verwende in dieser ersten Anfrage keine spekulativen Felder oder Filter wie `links` oder `issues(filter: { identifier: ... })`"
    assert prompt =~ "führe zuerst gezielte Introspection über den in der Session verfügbaren Linear-Zugriff aus."
    assert prompt =~ "einen dedizierten Blocker-Kommentar außerhalb des Workpads"
    assert prompt =~ "falls vor dem ersten Workpad-Bootstrap noch kein Workpad existiert"
    assert prompt =~ "Wenn die aktuelle Linear-API `branchName` in `IssueUpdateInput` unterstützt"
    assert prompt =~ "der lokale Branchname und die dazugehörige PR bleiben maßgeblich."
    assert prompt =~ "Wenn der Pull/Rebase einen Konflikt nicht autonom auflösen kann"
    assert prompt =~ "verschiebe nach `BLOCKER`"
    assert prompt =~ "produktverhaltensrelevanten Klärungsbedarf nach `Planung` zurückgeben"
    assert prompt =~ "Wenn mehrere plausible Varianten die Funktionalität, das Verhalten oder eine Produktausgabe verändern würden"
    assert prompt =~ "gib das Issue mit empfohlenem Lösungsvorschlag nach `Planung` zurück"
    assert prompt =~ "Wenn Symphony mit `--yolo` gestartet wird"
    assert prompt =~ "die Hauptmaske zeigt"
    assert prompt =~ "`--yolo`"
    assert prompt =~ "des Assignees."
    assert prompt =~ "Pfadkontext für Skills in diesem Turn:"
    assert prompt =~ "Aktiv bearbeitetes Repository/Worktree: `{{ runtime.active_repo_root }}`"
    assert prompt =~ "Repo-lokaler Skill-Pfad: `{{ runtime.active_repo_skill_root }}`"
    assert prompt =~ "Globale Skill-Wurzeln: `{{ runtime.global_skill_roots_text }}`"
    assert prompt =~ "den globalen Skill `symphony-review` explizit öffnen"
    assert prompt =~ "Den Skill `symphony-review` vollständig ausführen."
    assert prompt =~ "Ein normal beendeter Hauptturn alleine belegt keinen abgeschlossenen Merge."
    assert prompt =~ "Guardrail-Fallback"
    assert prompt =~ "Workpad-`Merge-Evidenz`"
    assert prompt =~ "Von aufgerufenen Skills ausdrücklich geforderte separate Nachvollziehbarkeitskommentare"
    refute prompt =~ "Review-Subagent `Findings:` liefert"

    workflow_source = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))

    assert workflow_source =~
             "sobald der aktive Workflow oder ein aufgerufener Skill einen Review-Subagenten verlangt"

    assert prompt =~
             "Davon ausgenommen sind ausdrücklich von aufgerufenen Skills geforderte Nachvollziehbarkeitskommentare"

    assert prompt =~
             "separate Nachvollziehbarkeitskommentare sind neben dem Workpad zulässig"

    assert prompt =~ "keine getrennten Vorab-Finding-Kommentare plus spätere Fix-Kommentare"
    assert review_authorization =~ "vollständigen relevanten Review-Scope"
    assert review_authorization =~ "keine Issue-Beschreibung"
    assert review_authorization =~ "keinen Issue-Titel"
    assert review_authorization =~ "keine Issue-URL"
    assert review_authorization =~ "keine Ticketabsicht"
    assert review_authorization =~ "keine Akzeptanzkriterien"
    assert review_authorization =~ "keine Workpad-/Workflow-Zusammenfassung"
    assert review_authorization =~ "Repository-Stand gegen `origin/main`"
    assert review_authorization =~ "kein Abgleich gegen Linear-Issue, Workpad, Ticketabsicht oder Akzeptanzkriterien"
    assert review_authorization =~ "nicht nach den ersten ein oder zwei Findings abbrechen"
    assert review_authorization =~ "alle klar belegbaren, reviewer-relevanten Findings"
    assert review_authorization =~ "genau einen kombinierten Nach-Fix-Kommentar"
    assert prompt =~ "den globalen Skill `symphony-workpad`"
  end

  test "regular follow-up issue rule requires the generated label at creation and aborts on lookup failure" do
    workflow_source = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))

    assert [[_, global_rules]] =
             Regex.scan(~r/^### Globale Arbeitsregeln\n(.*?)(?=^#|\z)/msu, workflow_source)

    assert [[follow_up_rule]] =
             Regex.scan(
               ~r/^- Wenn während der Ausführung sinnvolle Verbesserungen außerhalb des Scopes entdeckt werden,.*?(?=^- |\z)/msu,
               global_rules
             )

    follow_up_rule = String.replace(follow_up_rule, ~r/\s+/u, " ")

    assert follow_up_rule =~
             "Das Folge-Issue muss einen klaren Titel, eine Beschreibung und Validierungspunkte enthalten, in `Backlog` eingeordnet sein, demselben Projekt wie das aktuelle Issue zugewiesen werden"

    assert follow_up_rule =~
             "das aktuelle Issue als `related` verknüpfen und `blockedBy` verwenden, wenn das Folge-Issue vom aktuellen Issue abhängt."

    assert follow_up_rule =~
             "Löse vor der Anlage das Label `symphony-generated` im Ziel-Team sicher auf: Verwende ein vorhandenes gleichnamiges Label wieder"

    assert follow_up_rule =~ "oder lege ein fehlendes Label einmalig im Ziel-Team an."

    assert follow_up_rule =~
             "Übergib die sicher bestimmte Label-ID bereits bei `issueCreate` über `labelIds`."

    assert follow_up_rule =~
             "Kann die Label-ID nicht sicher bestimmt werden, erstelle kein Folge-Issue, melde den Fehler sichtbar und behandle den Vorgang nicht als erfolgreich."
  end

  test "review skills keep complete review scope and combined finding fix comments in symphony-review" do
    global_review_skill = File.read!(Path.expand("../../.codex/skills/symphony-review/SKILL.md", __DIR__))
    local_review_skill = File.read!(Path.expand("../../.codex/skills/sym-review/SKILL.md", __DIR__))
    workpad_skill = File.read!(Path.expand("../../.codex/skills/symphony-workpad/SKILL.md", __DIR__))

    assert global_review_skill =~ "Findings:"
    assert global_review_skill =~ "vollständigen relevanten"
    assert global_review_skill =~ "keine Issue-Beschreibung"
    assert global_review_skill =~ "keinen Issue-Titel"
    assert global_review_skill =~ "keine Issue-URL"
    assert global_review_skill =~ "keine Ticketabsicht"
    assert global_review_skill =~ "Akzeptanzkriterien und keine Workpad-/Workflow-Zusammenfassung"
    assert global_review_skill =~ "keine Workpad-/Workflow-Zusammenfassung"
    assert global_review_skill =~ "untracked Änderungen gegen `origin/main`"
    assert global_review_skill =~ "nicht gegen Linear-Issue, Workpad, Ticketabsicht oder"
    assert global_review_skill =~ "Spezifikationsabweichungen gegen repo-lokale Specs"
    assert global_review_skill =~ "Abweichungen von Linear-Issue-Anforderungen"
    assert global_review_skill =~ "nicht nach den ersten ein oder zwei Findings"
    assert global_review_skill =~ "alle klar belegbaren Findings"
    assert global_review_skill =~ "Vor den Fixes keinen separaten Findings-Kommentar"
    assert global_review_skill =~ ~r/genau einen kombinierten\s+Linear-Issue-Kommentar pro behandeltem Finding/
    assert global_review_skill =~ "Bei einem behandelten Finding entsteht genau ein kombinierter"
    assert global_review_skill =~ "Bei zwei behandelten Findings entstehen genau zwei"
    assert global_review_skill =~ "Review-/Fix-Schleife"
    refute global_review_skill =~ "vor den Fixes als"
    refute global_review_skill =~ "nach den Änderungen aus Subagent-Findings"
    refute global_review_skill =~ "Finding-zu-Änderung"
    refute global_review_skill =~ "`make all`"

    assert local_review_skill =~ "Zusätzliche Review-Hinweise"
    assert local_review_skill =~ "Keine zusätzlichen repositoryspezifischen Hinweise"
    refute local_review_skill =~ "`make all`"
    refute local_review_skill =~ "Findings:"
    refute local_review_skill =~ "## Subagent-Auftrag"

    assert workpad_skill =~ "kombinierte"
    assert workpad_skill =~ "Review-Finding-Fix-Kommentare"
    assert workpad_skill =~ "Zulässige Ausnahmen"
    assert workpad_skill =~ "ersetzen das Workpad nicht"
  end

  test "review budget contract counts starts across recovery and treats final-round findings before handoff" do
    skill = File.read!(Path.expand("../../.codex/skills/symphony-review/SKILL.md", __DIR__))
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))
    defaults = File.read!(Path.expand("../../.env", __DIR__))

    assert defaults =~ "SYM_MAXIMUM_REVIEW_ITERATIONS=3"
    assert skill =~ "`runtime.maximum_review_iterations`"
    assert skill =~ "N=1 erlaubt einen Start, N=3 drei"
    assert skill =~ "Vor jedem `spawn_agent` prüfen: gestartete Runden < N"
    assert skill =~ "Rundennummer vor dem Start im Workpad reservieren"
    assert skill =~ "die Subagent-ID ergänzen"
    assert skill =~ "Fortsetzungen, Retries und Recovery übernehmen Limit, Zähler, Subagent-IDs"
    assert skill =~ "Kein Reset wegen neuer Session"
    assert skill =~ "neuer Eintritt nach Verlassen der Phase beginnt bei 0"
    assert skill =~ ~r/Warten auf denselben Subagenten und Wiederverwendung seines Ergebnisses\s+zählen nicht erneut/
    assert skill =~ "keinen Doppelstart auslösen"
    assert skill =~ "Bei eindeutigem `Keine Findings.` darf die Schleife vor N enden"
    assert skill =~ "Ein Timeout bleibt ein offener Pflichtschritt, auch am Rundenlimit"
    assert skill =~ "Auch Findings aus Runde N vollständig bewerten"
    assert skill =~ "gezielt validieren und wie oben kommentieren"
    assert skill =~ "keine Runde N+1 starten"
    assert skill =~ "erst nach vollständig behandelter Evidenz"
    assert skill =~ "nicht erneut reviewte Fixes ausdrücklich dokumentieren"
    assert skill =~ "Das Limit ist kein `Keine Findings.`-Signal"
    assert skill =~ ~r/Freigabe-\/Skip-Regel im Abschluss gilt auch hier/
    assert skill =~ "Solange die Review-Checkliste im Workpad offen, fehlend"
    assert skill =~ "nach `Freigabe Review` verschieben; mit `--yolo` oder `Skip \"Freigabe Review\"`"
    refute skill =~ "die Checkliste wieder bei Schritt 1 starten"
    assert workflow =~ "das Rundenbudget aus `symphony-review` es erlaubt"
    assert workflow =~ "die Review-Schleife gemäß Rundenbudget fortsetzen oder abschließen"
  end

  test "AI phase completion contracts require closed checklists and merge evidence" do
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))
    prereview_skill = File.read!(Path.expand("../../.codex/skills/symphony-prereview/SKILL.md", __DIR__))
    review_skill = File.read!(Path.expand("../../.codex/skills/symphony-review/SKILL.md", __DIR__))
    test_skill = File.read!(Path.expand("../../.codex/skills/symphony-test/SKILL.md", __DIR__))
    land_skill = File.read!(Path.expand("../../.codex/skills/symphony-land/SKILL.md", __DIR__))

    assert workflow =~ "Guardrail-Fallback"
    assert workflow =~ "Turn-Abschlussvertrag für aktive AI-Status"
    assert workflow =~ "phasenspezifischen Abschlussbedingungen"
    assert workflow =~ "Runtime-Fallbacks, die ein Issue nach normalem Turn-Ende weiter aktiv halten"
    assert workflow =~ "Wenn der vorherige Turn normal endete, der Tracker-Status aber weiterhin ein aktiver AI-Status ist"
    assert workflow =~ "continuation_intro_incomplete_phase"
    assert workflow =~ "Findings-Erhalt allein erfüllt den Abschlussvertrag nicht"
    assert workflow =~ "Beende den Turn nicht zwischen Findings-Erhalt und dieser Verarbeitung."
    assert workflow =~ "Workpad-`Merge-Evidenz`"
    assert workflow =~ "Ein normal beendeter Hauptturn alleine belegt keinen abgeschlossenen Merge."
    assert workflow =~ "`agent.max_turns` ist kein normaler Phasenabschluss."

    assert prereview_skill =~
             "offener, fehlender oder nicht explizit abgehakter `### Review`-Checkliste"

    assert prereview_skill =~ "im selben Turn weiterarbeiten"

    assert review_skill =~ "Solange die Review-Checkliste im Workpad offen, fehlend"
    assert review_skill =~ "den Hauptturn nicht final"
    assert review_skill =~ "im selben Turn in der Review-/Fix-Schleife weiter"
    assert review_skill =~ "Findings sofort im Hauptturn behandeln"
    assert review_skill =~ ~r/`agent.max_turns` ist kein\s+normaler Phasenabschluss\./

    assert test_skill =~
             ~r/offener, fehlender oder nicht explizit abgehakter `### Test`-\s*oder `### Validierung`-Checkliste/

    assert test_skill =~ "im selben Turn weiterarbeiten"

    assert land_skill =~ "Merge-Evidenz: PR #<nummer> gemergt"
    assert land_skill =~ "Ohne diese Evidenz keinen normalen Abschluss behaupten und den Hauptturn nicht"
    assert land_skill =~ "den Hauptturn nicht"
    assert land_skill =~ "im selben Turn die Merge-/Watch-Schleife fortsetzen"
    assert land_skill =~ "`agent.max_turns` ist"
  end

  test "merge phase contracts skip local full gate and keep PR checks plus rerun guarantees" do
    workflow = File.read!(Path.expand("../../WORKFLOW.md", __DIR__))
    test_skill = File.read!(Path.expand("../../.codex/skills/symphony-test/SKILL.md", __DIR__))
    local_test_skill = File.read!(Path.expand("../../.codex/skills/sym-test/SKILL.md", __DIR__))
    land_skill = File.read!(Path.expand("../../.codex/skills/symphony-land/SKILL.md", __DIR__))
    push_skill = File.read!(Path.expand("../../.codex/skills/symphony-push/SKILL.md", __DIR__))

    assert test_skill =~ "Nur im Status `Test (AI)` verwenden"
    assert test_skill =~ "repo-lokalen Testschritt"
    assert test_skill =~ "nach `Merge (AI)` verschieben"
    assert local_test_skill =~ "`make all`"

    assert workflow =~ "Lokale Volltests werden in `Merge (AI)` nicht pauschal ausgeführt"
    assert workflow =~ "das vollständige lokale Gate bleibt Aufgabe von `Test (AI)`"
    assert workflow =~ "GitHub-Checks mit `skipped` ersetzen keine bestandene CI"
    assert workflow =~ "lokale Test-Evidenz aus `Test (AI)` bleibt dann das maßgebliche Gate"
    assert workflow =~ "aktueller Branch `symphony/<Issue>`"
    assert workflow =~ "PR-Head-SHA gleich"
    assert workflow =~ "Duplicate-URL"
    assert workflow =~ "PR-Nummer oder PR-URL"
    assert workflow =~ "andere Merge-Dateiänderungen neue Änderungen erzeugen oder übernehmen"
    assert workflow =~ "der normale Merge-Pfad wird nur fortgesetzt"
    assert workflow =~ "Review-Feedback, ein CI-Fix oder eine andere Handlung"

    assert land_skill =~ "Lokale Volltests nicht pauschal wiederholen"
    assert land_skill =~ "GitHub-Checks nach Policy bewerten"
    assert land_skill =~ "Keine pauschalen lokalen Volltests in `Merge (AI)` ausführen"
    assert land_skill =~ "Test-Evidenz aus `Test (AI)` ist das maßgebliche lokale Gate"
    assert land_skill =~ "PR-/Remote-Preflight"
    assert land_skill =~ "PR-Head-SHA muss dem"
    assert land_skill =~ "skipped by policy"
    assert land_skill =~ "neutral akzeptiert"
    assert land_skill =~ ~r/im\s+Merge-Schritt übernommene Dateiänderungen/
    assert land_skill =~ "Review-Kommentare und Codex-Review-Issue-Kommentare prüfen"
    assert land_skill =~ "Feedback Dateiänderungen erfordert"
    assert land_skill =~ "File-changing Review-Fixes in `Merge (AI)`"
    assert land_skill =~ "Checks beobachten"
    assert land_skill =~ "Bei Fehlschlag Logs holen"
    assert land_skill =~ "fehlende oder inkonsistente"
    assert land_skill =~ ~r/Pull\/Rebase oder Konfliktlösung\s+Dateien ändert, committen, pushen/
    assert land_skill =~ "Commit/Push veröffentlichen"
    assert land_skill =~ ~r/nach\s+`Test \(AI\)` zurückverschieben und stoppen/
    refute land_skill =~ "neuen CI-Lauf auslösen"
    refute land_skill =~ "Vor jedem Push das vollständige lokale Qualitäts-Gate ausführen"

    assert push_skill =~ "`Merge (AI)`-Autocommit-Ausnahme"
    assert push_skill =~ "keine lokale"
    assert push_skill =~ "kein lokales Voll-Gate"
    assert push_skill =~ "nach `Test (AI)` zurückspringen und"
    assert push_skill =~ "PR-Head-SHA"
    assert push_skill =~ "Duplicate-/Already-exists"
    assert push_skill =~ "idempotent"
  end

  test "land watch helper classifies check policy and merge preflight blockers" do
    helper_path = Path.expand("../../.codex/skills/symphony-land/land_watch.py", __DIR__)

    script = """
    import importlib.util
    import sys

    spec = importlib.util.spec_from_file_location("land_watch", #{inspect(helper_path)})
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    def completed(name, conclusion):
        return {
            "name": name,
            "status": "completed",
            "conclusion": conclusion,
            "completed_at": "2026-06-11T19:00:00Z",
        }

    skipped = module.summarize_checks([completed("ci", "skipped")])
    assert not skipped.pending
    assert not skipped.failed
    assert module.check_summary_message(skipped) == "GitHub checks acceptable: 1 skipped by policy"

    neutral = module.summarize_checks([completed("lint", "neutral")])
    assert not neutral.pending
    assert not neutral.failed
    assert module.check_summary_message(neutral) == "GitHub checks acceptable: 1 neutral accepted"

    mixed = module.summarize_checks([
        completed("unit", "success"),
        completed("ci", "skipped"),
        completed("docs", "neutral"),
    ])
    assert not mixed.pending
    assert not mixed.failed
    assert module.check_summary_message(mixed) == (
        "GitHub checks acceptable: 1 success, 1 skipped by policy, 1 neutral accepted"
    )

    failed = module.summarize_checks([completed("ci", "failure")])
    assert not failed.pending
    assert failed.failed
    assert failed.failures == ["ci: failure"]

    ok_pr = module.PrInfo(
        number=42,
        url="https://github.com/owner/repo/pull/42",
        head_sha="abc123456789",
        mergeable="MERGEABLE",
        merge_state="CLEAN",
    )
    ok_evidence = module.MergePreflightEvidence(
        branch="symphony/PRO-524",
        local_head="abc123456789",
        remote_branch_exists=True,
        pr=ok_pr,
    )
    assert module.merge_preflight_failures(ok_evidence) == []

    missing_remote = module.MergePreflightEvidence(
        branch="symphony/PRO-524",
        local_head="abc123456789",
        remote_branch_exists=False,
        pr=ok_pr,
    )
    assert any("origin/symphony/PRO-524 is missing" in failure for failure in module.merge_preflight_failures(missing_remote))

    missing_pr = module.MergePreflightEvidence(
        branch="symphony/PRO-524",
        local_head="abc123456789",
        remote_branch_exists=True,
        pr=None,
    )
    assert any("No open GitHub PR" in failure for failure in module.merge_preflight_failures(missing_pr))

    assert module.is_pr_not_found_error("no open pull requests found for branch")
    assert not module.is_pr_not_found_error("HTTP 403: authentication required")

    async def current_branch():
        return "symphony/PRO-524"

    async def local_head_sha():
        return "abc123456789"

    async def remote_branch_exists(_branch):
        return True

    async def pr_not_found(_branch):
        raise module.PrNotFoundError("no open pull requests found for branch")

    async def pr_lookup_failed(_branch):
        raise RuntimeError("HTTP 403: authentication required")

    module.current_branch = current_branch
    module.local_head_sha = local_head_sha
    module.remote_branch_exists = remote_branch_exists
    module.get_pr_info = pr_not_found

    no_pr_evidence = __import__("asyncio").run(module.collect_merge_preflight_evidence())
    assert no_pr_evidence.pr is None

    module.get_pr_info = pr_lookup_failed
    try:
        __import__("asyncio").run(module.collect_merge_preflight_evidence())
    except RuntimeError as error:
        assert "authentication required" in str(error)
    else:
        raise AssertionError("expected PR lookup errors to propagate")

    stale_pr = module.PrInfo(
        number=42,
        url="https://github.com/owner/repo/pull/42",
        head_sha="def987654321",
        mergeable="MERGEABLE",
        merge_state="CLEAN",
    )
    stale_evidence = module.MergePreflightEvidence(
        branch="symphony/PRO-524",
        local_head="abc123456789",
        remote_branch_exists=True,
        pr=stale_pr,
    )
    assert any("PR head mismatch" in failure for failure in module.merge_preflight_failures(stale_evidence))
    assert module.merge_preflight_failures(
        module.MergePreflightEvidence(
            branch="main",
            local_head="abc123456789",
            remote_branch_exists=True,
            pr=ok_pr,
        )
    )[0].startswith("Current branch must be symphony/<Issue>")
    """

    {output, status} = System.cmd("python3", ["-B", "-c", script], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "land watch helper enforces manual review label approval rules" do
    helper_path = Path.expand("../../.codex/skills/symphony-land/land_watch.py", __DIR__)

    script = """
    import importlib.util
    import os
    import sys

    spec = importlib.util.spec_from_file_location("land_watch", #{inspect(helper_path)})
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    def user(login, kind="User"):
        return {"login": login, "type": kind}

    def review(login, state, commit_id="head-sha", submitted_at="2026-07-08T10:00:00Z", kind="User", body=""):
        return {
            "user": user(login, kind),
            "state": state,
            "commit_id": commit_id,
            "submitted_at": submitted_at,
            "body": body,
        }

    assert module.issue_labels_from_env('[\" requires manual review \", \"backend\"]') == [
        " requires manual review ",
        "backend",
    ]
    assert module.issue_labels_from_env("not-json") == []
    assert module.requires_manual_review([" requires manual review "])
    assert module.requires_manual_review(["REQUIRES MANUAL REVIEW"])
    assert not module.requires_manual_review(['Require \"Freigabe Review\"'])
    assert not module.requires_manual_review(["Benötigt Freigabe Review"])
    assert not module.requires_manual_review(["Skip \\"Freigabe Review\\""])

    os.environ.pop(module.ISSUE_IDENTIFIER_ENV, None)
    try:
        __import__("asyncio").run(module.current_issue_labels(["backend"]))
    except module.LabelRefreshError as error:
        assert "Missing issue identity" in str(error)
    else:
        raise AssertionError("missing identity must block")
    os.environ[module.ISSUE_IDENTIFIER_ENV] = "PRO-580"
    try:
        __import__("asyncio").run(module.current_issue_labels(["backend"]))
    except module.AppLabelLookupRequired:
        pass
    else:
        raise AssertionError("snapshot must never replace bound live label lookup")

    assert module.has_valid_manual_approval(
        [review("reviewer", "APPROVED")],
        "head-sha",
        "author",
    )
    assert module.has_valid_manual_approval(
        [
            review("reviewer", "CHANGES_REQUESTED", submitted_at="2026-07-08T10:00:00Z"),
            review("reviewer", "APPROVED", submitted_at="2026-07-08T10:05:00Z"),
        ],
        "head-sha",
        "author",
    )
    assert not module.has_valid_manual_approval(
        [
            review("reviewer", "APPROVED", submitted_at="2026-07-08T10:00:00Z"),
            review("reviewer", "CHANGES_REQUESTED", submitted_at="2026-07-08T10:05:00Z"),
        ],
        "head-sha",
        "author",
    )
    assert not module.has_valid_manual_approval(
        [review("reviewer", "APPROVED", commit_id="old-sha")],
        "head-sha",
        "author",
    )
    assert not module.has_valid_manual_approval(
        [review("author", "APPROVED")],
        "head-sha",
        "author",
    )
    assert not module.has_valid_manual_approval(
        [review("github-actions[bot]", "APPROVED", kind="Bot")],
        "head-sha",
        "author",
    )

    pr = module.PrInfo(
        number=42,
        url="https://github.com/owner/repo/pull/42",
        head_sha="head-sha",
        mergeable="MERGEABLE",
        merge_state="CLEAN",
        author_login="author",
    )
    module.raise_on_missing_manual_review_approval(
        ["Requires Manual Review"],
        pr,
        [review("reviewer", "APPROVED")],
    )

    missing_approval_labels = ["Skip \\"Freigabe Review\\"", "Requires Manual Review"]
    os.environ["SYMPHONY_YOLO"] = "true"
    try:
        module.raise_on_missing_manual_review_approval(missing_approval_labels, pr, [])
    except SystemExit as error:
        assert error.code == module.MANUAL_REVIEW_BLOCKER_EXIT
    else:
        raise AssertionError("expected missing approval to block")
    finally:
        os.environ.pop("SYMPHONY_YOLO", None)

    blocker = module.manual_review_blocker_message(pr)
    assert "PR #42" in blocker
    assert "head-sha" in blocker
    assert "`Requires Manual Review`" in blocker
    assert "`Merge (AI)`" in blocker

    blocking_reviews = module.filter_blocking_reviews(
        [review("reviewer", "CHANGES_REQUESTED")],
        None,
    )
    assert len(blocking_reviews) == 1
    try:
        module.raise_on_human_feedback([], [], blocking_reviews, None)
    except SystemExit as error:
        assert error.code == 2
    else:
        raise AssertionError("expected CHANGES_REQUESTED to stay review feedback")
    """

    {output, status} = System.cmd("python3", ["-B", "-c", script], stderr_to_stdout: true)
    assert status == 0, output
  end

  test "repo-local symphony-linear skill documents schema-valid issue lookup patterns and fallback" do
    skill_path = Path.expand("../../.codex/skills/symphony-linear/SKILL.md", __DIR__)
    skill = File.read!(skill_path)

    assert skill =~ "### Ein Issue per Key, Team/Nummer oder id abfragen"
    assert skill =~ "query BootstrapIssue($key: String!)"
    assert skill =~ "query BootstrapIssueByTeamAndNumber($teamKey: String!, $number: Float!)"
    assert skill =~ "query IssueById($id: String!)"
    assert skill =~ "orientieren willst, splitte den Identifier in"
    assert skill =~ "Nutze keinen Fallback `issues(filter: { identifier: ... })`"
    assert skill =~ "wie `links` in die erste Anfrage aufzunehmen."
    assert skill =~ "Keine Shell-/Mix-/Update-Skript-Fallbacks"
    refute skill =~ "query IssueByIdentifier($identifier: String!)"
    refute skill =~ "links {\n"
  end

  test "repo-local symphony-pull skill rebases main and keeps branch pulls fast-forward only" do
    skill_path = Path.expand("../../.codex/skills/symphony-pull/SKILL.md", __DIR__)
    skill = File.read!(skill_path)

    assert skill =~ "git pull --ff-only origin $(git branch --show-current)"
    assert skill =~ "git -c merge.conflictStyle=zdiff3 rebase origin/main"
    assert skill =~ "git rebase --continue"
    assert skill =~ "git stash push --include-untracked"
    assert skill =~ "git stash apply --index <stash-ref>"
    assert skill =~ "git stash drop <stash-ref>"
    assert skill =~ "Rebase-Quelle(n)"
    refute skill =~ "git -c " <> "merge.conflictstyle=zdiff3 merge " <> "origin/main"
    refute skill =~ "git " <> "merge --continue"
    refute skill =~ "Autocommit vor " <> "Pull"
    refute skill =~ "Autocommit vor " <> "Rebase"
  end

  test "workflow derives ordered states from the current WORKFLOW.md status overview" do
    original_workflow_path = Workflow.workflow_file_path()
    repo_workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.set_workflow_file_path(repo_workflow_path)
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert {:ok, status_overview} = Workflow.status_overview()

    expected_statuses = [
      "Backlog",
      "Todo",
      "Todo (Dialog-AI)",
      "Umsetzungsticket erstellt",
      "Todo (AI)",
      "Planung (AI)",
      "Planung",
      "In Arbeit",
      "In Arbeit (AI)",
      "PreReview (AI)",
      "Freigabe Implementierung",
      "Review (AI)",
      "Freigabe Review",
      "Test (AI)",
      "Merge (AI)",
      "BLOCKER",
      "Abbruch (AI)",
      "Review",
      "Fertig",
      "Abgebrochen"
    ]

    actual_statuses = Enum.map(status_overview, & &1.status)

    assert actual_statuses == expected_statuses

    in_arbeit_status = Enum.find(status_overview, &(&1.status == "In Arbeit (AI)"))
    dialog_done_status = Enum.find(status_overview, &(&1.status == "Umsetzungsticket erstellt"))

    assert in_arbeit_status.next_regular_status == "PreReview (AI)"
    assert dialog_done_status.next_regular_status == nil
  end

  test "workflow resolves chained skip labels from the status overview order" do
    original_workflow_path = Workflow.workflow_file_path()
    repo_workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)

    on_exit(fn -> Workflow.set_workflow_file_path(original_workflow_path) end)
    Workflow.set_workflow_file_path(repo_workflow_path)

    next_status =
      Workflow.resolve_next_status("In Arbeit (AI)", [
        ~s|skip "prereview (ai)"|,
        ~s(skip "freigabe implementierung")
      ])

    plan_next_status = Workflow.resolve_next_status("Planung (AI)", [~s(skip "planung")])

    manual_planning_skip_status = Workflow.resolve_next_status("Planung", [~s(skip "planung")])

    implementation_handoff_skip_status = Workflow.resolve_next_status("Freigabe Implementierung", [~s(skip "freigabe implementierung")])

    review_skip_status = Workflow.resolve_next_status("Review (AI)", [~s(skip "freigabe review")])

    review_handoff_skip_status = Workflow.resolve_next_status("Freigabe Review", [~s(skip "freigabe review")])

    assert next_status == "Review (AI)"
    assert plan_next_status == "In Arbeit (AI)"
    assert manual_planning_skip_status == nil
    assert implementation_handoff_skip_status == "Review (AI)"
    assert review_skip_status == "Test (AI)"
    assert review_handoff_skip_status == "Test (AI)"
  end

  test "workflow treats yolo mode like approval skip labels without skipping manual planning" do
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)
    original_workflow_path = Workflow.workflow_file_path()
    repo_workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)

    on_exit(fn ->
      restore_app_env(:yolo, previous_yolo)
      Workflow.set_workflow_file_path(original_workflow_path)
    end)

    Workflow.set_workflow_file_path(repo_workflow_path)
    Application.put_env(:symphony_elixir, :yolo, true)

    assert Workflow.resolve_next_status("Planung (AI)", []) == "In Arbeit (AI)"
    assert Workflow.resolve_next_status("Planung", []) == nil
    assert Workflow.resolve_next_status("PreReview (AI)", []) == "Review (AI)"
    assert Workflow.resolve_next_status("Freigabe Implementierung", []) == "Review (AI)"
    assert Workflow.resolve_next_status("Review (AI)", []) == "Test (AI)"
    assert Workflow.resolve_next_status("Freigabe Review", []) == "Test (AI)"
  end

  test "workflow falls back to built-in transitions when the prompt has no status overview" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Prompt without status table")

    assert Workflow.ordered_statuses() == [
             "Backlog",
             "Todo",
             "Todo (AI)",
             "Planung (AI)",
             "Planung",
             "In Arbeit (AI)",
             "PreReview (AI)",
             "Freigabe Implementierung",
             "Review (AI)",
             "Freigabe Review",
             "Test (AI)",
             "Merge (AI)",
             "BLOCKER",
             "Abbruch (AI)",
             "Review",
             "Fertig",
             "Abgebrochen"
           ]

    assert Workflow.resolve_next_status("Merge (AI)", []) == "Review"
    assert Workflow.resolve_next_status("Planung", []) == nil
    assert Workflow.resolve_target_status("Review", [nil, "skip review"]) == "Fertig"
    assert Workflow.resolve_next_status(nil, []) == nil
    assert Workflow.resolve_target_status(nil, []) == nil
  end

  test "workflow returns nil for unknown current statuses" do
    assert Workflow.resolve_next_status("Unbekannt", []) == nil
  end

  test "workflow returns nil for manual planning even when a skip label is present" do
    prompt = """
    ## Statusübersicht

    | Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
    | --- | --- | --- | --- |
    | `Planung` | Nein | Manueller Klärungspunkt | Warten auf menschliches Verschieben |
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: prompt)

    assert Workflow.resolve_next_status("Planung", [~s(skip "planung")]) == nil
  end

  test "workflow returns nil when a skipped direct handoff has no following table status" do
    prompt = """
    ## Statusübersicht

    | Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
    | --- | --- | --- | --- |
    | `Freigabe Review` | Nein | Manueller Freigabepunkt | Warten auf menschliches Verschieben |
    """

    write_workflow_file!(Workflow.workflow_file_path(), prompt: prompt)

    assert Workflow.resolve_next_status("Freigabe Review", [~s(skip "freigabe review")]) == nil
  end

  test "workflow status overview parser returns an error when no status table exists" do
    assert {:error, :status_overview_not_found} = Workflow.status_overview_from_prompt("Prompt without status table")
  end

  test "workflow status overview parser accepts direct rows without a header and ignores malformed rows" do
    prompt = """
    ## Statusübersicht

    | `Direkt` | Ja |  |  |
    | kaputt |
    """

    assert {:ok,
            [
              %{
                status: "Direkt",
                in_scope: true,
                description: nil,
                next_regular_status: nil
              }
            ]} = Workflow.status_overview_from_prompt(prompt)
  end

  test "workflow status overview parser rejects header-only tables" do
    prompt = """
    ## Statusübersicht

    | Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
    """

    assert {:error, :status_overview_not_found} = Workflow.status_overview_from_prompt(prompt)
  end

  test "workflow status overview parser rejects tables without any parseable rows" do
    prompt = """
    ## Statusübersicht

    | --- | --- | --- | --- |
    """

    assert {:error, :status_overview_not_found} = Workflow.status_overview_from_prompt(prompt)
  end

  test "personal LINEAR_API_KEY does not enter the app configuration" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    env_api_key = "test-linear-api-key"

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.put_env("LINEAR_API_KEY", env_api_key)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    refute Map.has_key?(Config.settings!().tracker, :api_key)
    assert Config.settings!().tracker.project_slug == "project"
    assert :ok = Config.validate!()
  end

  test "linear assignee resolves from LINEAR_ASSIGNEE env var" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    env_assignee = "dev@example.com"

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.put_env("LINEAR_ASSIGNEE", env_assignee)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert Config.settings!().tracker.assignee == env_assignee
  end

  test "startup validation requires LINEAR_ASSIGNEE in the environment" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn -> restore_env("LINEAR_ASSIGNEE", previous_linear_assignee) end)
    System.delete_env("LINEAR_ASSIGNEE")

    assert {:error, :missing_linear_assignee_env} = Config.validate_startup_requirements()

    System.put_env("LINEAR_ASSIGNEE", "dev@example.com")

    assert :ok = Config.validate_startup_requirements()
  end

  test "startup validation does not require LINEAR_ASSIGNEE in yolo mode" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
      restore_app_env(:yolo, previous_yolo)
    end)

    System.delete_env("LINEAR_ASSIGNEE")
    Application.put_env(:symphony_elixir, :yolo, true)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    assert :ok = Config.validate_startup_requirements()
    assert Config.yolo?()
  end

  test "application startup preflight loads env files from .symphony before validating assignee" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    previous_workflow_path = Workflow.workflow_file_path()
    original_cwd = File.cwd!()

    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-preflight-#{System.unique_integer([:positive])}"
      )

    invocation_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-invocation-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
      Workflow.set_workflow_file_path(previous_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(workflow_root)
      File.rm_rf(invocation_root)
    end)

    System.delete_env("LINEAR_ASSIGNEE")
    File.mkdir_p!(workflow_root)
    File.mkdir_p!(Path.join(invocation_root, ".symphony"))

    workflow_path = Path.join(workflow_root, "WORKFLOW.md")

    write_workflow_file!(workflow_path,
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    File.write!(Path.join([invocation_root, ".symphony", ".env.local"]), "LINEAR_ASSIGNEE=dev@example.com\n")
    Workflow.set_workflow_file_path(workflow_path)
    File.cd!(invocation_root)

    assert :ok = SymphonyElixir.Application.startup_preflight()
    assert System.get_env("LINEAR_ASSIGNEE") == "dev@example.com"
  end

  test "application startup preflight returns env file errors from .symphony under the invocation directory" do
    previous_linear_assignee = System.get_env("LINEAR_ASSIGNEE")
    previous_workflow_path = Workflow.workflow_file_path()
    original_cwd = File.cwd!()

    workflow_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-preflight-invalid-workflow-#{System.unique_integer([:positive])}"
      )

    invocation_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-preflight-invalid-invocation-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      restore_env("LINEAR_ASSIGNEE", previous_linear_assignee)
      Workflow.set_workflow_file_path(previous_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(workflow_root)
      File.rm_rf(invocation_root)
    end)

    System.delete_env("LINEAR_ASSIGNEE")
    File.mkdir_p!(workflow_root)
    File.mkdir_p!(Path.join(invocation_root, ".symphony"))

    workflow_path = Path.join(workflow_root, "WORKFLOW.md")

    write_workflow_file!(workflow_path,
      tracker_assignee: nil,
      tracker_project_slug: "project",
      codex_command: "/bin/sh app-server"
    )

    File.write!(Path.join([invocation_root, ".symphony", ".env"]), "LINEAR_ASSIGNEE\n")
    Workflow.set_workflow_file_path(workflow_path)
    File.cd!(invocation_root)

    assert {:error, {:invalid_env_file, path, 1, :missing_assignment}} = SymphonyElixir.Application.startup_preflight()

    assert path == Path.join([invocation_root, ".symphony", ".env"])
  end

  test "test config disables startup preflight, terminal cleanup and initial poll during automatic boot" do
    refute Application.get_env(:symphony_elixir, :run_startup_preflight_on_boot, true)
    refute Application.get_env(:symphony_elixir, :run_terminal_workspace_cleanup_on_start, true)
    refute Application.get_env(:symphony_elixir, :run_initial_orchestrator_poll_on_start, true)
  end

  test "workflow file path defaults to WORKFLOW.md in the current working directory outside escript mode" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = workflow_directory_outside_repo!("symphony-workflow-no-escript")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, [])

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path defaults relative to the launched symphony binary" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = workflow_directory_outside_repo!("symphony-workflow-default")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == "/opt/symphony/WORKFLOW.md"
  end

  test "workflow file path ignores non-Symphony projects even when they contain a workflow file" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = workflow_directory_outside_repo!("symphony-workflow-generic-project")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.write!(Path.join(temp_root, "WORKFLOW.md"), "---\n---\n")

    File.write!(
      Path.join(temp_root, "mix.exs"),
      """
      defmodule GenericProject.MixProject do
        use Mix.Project

        def project do
          [app: :generic_project]
        end
      end
      """
    )

    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == "/opt/symphony/WORKFLOW.md"
  end

  test "workflow file path ignores plain workflow files without a Symphony mix project" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = workflow_directory_outside_repo!("symphony-workflow-no-mix")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.write!(Path.join(temp_root, "WORKFLOW.md"), "---\n---\n")

    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == "/opt/symphony/WORKFLOW.md"
  end

  test "workflow file path prefers the current Symphony worktree when launched from a Symphony checkout" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path prefers the Symphony workflow when launched from the repo root" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    repo_root = File.cwd!()

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.cd!(repo_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    assert Workflow.workflow_file_path() == Path.join(repo_root, "WORKFLOW.md")
  end

  test "workflow file path falls back to cwd for non-symphony executables" do
    original_workflow_path = Workflow.workflow_file_path()
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_cwd = File.cwd!()
    temp_root = workflow_directory_outside_repo!("symphony-workflow-cwd")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)
      File.cd!(original_cwd)
      File.rm_rf(temp_root)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    File.mkdir_p!(temp_root)
    File.cd!(temp_root)
    Workflow.clear_workflow_file_path()
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/usr/bin/elixir")

    assert Workflow.workflow_file_path() == Path.join(File.cwd!(), "WORKFLOW.md")
  end

  test "workflow file path resolves from app env when set" do
    app_workflow_path = "/tmp/app/WORKFLOW.md"

    on_exit(fn ->
      Workflow.clear_workflow_file_path()
    end)

    Workflow.set_workflow_file_path(app_workflow_path)

    assert Workflow.workflow_file_path() == app_workflow_path
  end

  test "workflow load accepts prompt-only files without front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "PROMPT_ONLY_WORKFLOW.md")
    File.write!(workflow_path, "Prompt only\n")

    assert {:ok, %{config: %{}, prompt: "Prompt only", prompt_template: "Prompt only"}} = Workflow.load(workflow_path)
  end

  test "workflow load accepts unterminated front matter with an empty prompt" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "UNTERMINATED_WORKFLOW.md")
    File.write!(workflow_path, "---\ntracker:\n  kind: linear\n")

    assert {:ok, %{config: %{"tracker" => %{"kind" => "linear"}}, prompt: "", prompt_template: ""}} = Workflow.load(workflow_path)
  end

  test "workflow load rejects non-map front matter" do
    workflow_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "INVALID_FRONT_MATTER_WORKFLOW.md")
    File.write!(workflow_path, "---\n- not-a-map\n---\nPrompt body\n")

    assert {:error, :workflow_front_matter_not_a_map} = Workflow.load(workflow_path)
  end

  test "SymphonyElixir.start_link delegates to the orchestrator" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    on_exit(fn ->
      if is_pid(orchestrator_pid) and is_pid(Process.whereis(SymphonyElixir.Supervisor)) and
           is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
        case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end
      end
    end)

    if is_pid(orchestrator_pid) and is_pid(Process.whereis(SymphonyElixir.Supervisor)) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
    end

    assert {:ok, pid} = SymphonyElixir.start_link()
    assert Process.whereis(SymphonyElixir.Orchestrator) == pid

    GenServer.stop(pid)
  end

  test "linear issue state reconciliation fetch with no running issues is a no-op" do
    assert {:ok, []} = Client.fetch_issue_states_by_ids([])
  end

  test "non-active issue state stops running agent without cleaning workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-nonactive-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-1"
    issue_identifier = "MT-555"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "Todo (AI)", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Backlog",
        title: "Queued",
        description: "Not started",
        labels: [~s(skip "freigabe review")]
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal issue state stops running agent and cleans workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-terminal-reconcile-#{System.unique_integer([:positive])}"
      )

    issue_id = "issue-2"
    issue_identifier = "MT-556"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"]
      )

      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Arbeit (AI)", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Closed",
        title: "Fertig",
        description: "Completed",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "cancel issue state stops running agent, cleans workspace, and moves issue to Abgebrochen" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-cancel"
    issue_identifier = "MT-556-C"
    workspace = Path.join(test_root, issue_identifier)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: [
          "Todo (AI)",
          "In Arbeit (AI)",
          "Review (AI)",
          "Abbruch (AI)"
        ],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Fertig", "Abgebrochen"]
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      File.mkdir_p!(test_root)
      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      agent_ref = Process.monitor(agent_pid)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: issue_identifier,
            issue: %Issue{id: issue_id, state: "In Arbeit (AI)", identifier: issue_identifier},
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Abbruch (AI)",
        title: "Abort work",
        description: "User canceled the workflow",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      assert_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _reason}
      refute Process.alive?(agent_pid)
      refute File.exists?(workspace)
      assert_receive {:memory_tracker_state_update, ^issue_id, "Abgebrochen"}
    after
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "cancel issue from polling cleans workspace and moves issue to Abgebrochen without dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-poll-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    issue_id = "issue-cancel-poll"
    issue_identifier = "MT-556-P"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: [
          "Todo (AI)",
          "In Arbeit (AI)",
          "Review (AI)",
          "Abbruch (AI)"
        ],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Fertig", "Abgebrochen"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        state: "Abbruch (AI)",
        title: "Abort idle work",
        description: "Workspace should be cleaned without dispatch",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])

      orchestrator_name = Module.concat(__MODULE__, :CancelPollingOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)
        restore_app_env(:memory_tracker_recipient, previous_recipient)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      File.mkdir_p!(Path.join(test_root, issue_identifier))

      send(pid, :tick)
      assert_receive {:memory_tracker_state_update, ^issue_id, "Abgebrochen"}, 1_000
      Process.sleep(100)

      refute File.exists?(Path.join(test_root, issue_identifier))
      state = :sys.get_state(pid)
      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_recipient)
      File.rm_rf(test_root)
    end
  end

  test "missing running issues stop active agents without cleaning the workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-running-reconcile-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    issue_id = "issue-missing"
    issue_identifier = "MT-557"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: test_root,
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate"],
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      orchestrator_name = Module.concat(__MODULE__, :MissingRunningIssueOrchestrator)
      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        restore_app_env(:memory_tracker_issues, previous_memory_issues)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      Process.sleep(50)

      assert {:ok, workspace} = SymphonyElixir.PathSafety.canonicalize(Path.join(test_root, issue_identifier))

      File.mkdir_p!(workspace)

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      initial_state = :sys.get_state(pid)

      running_entry = %{
        pid: agent_pid,
        ref: nil,
        identifier: issue_identifier,
        issue: %Issue{id: issue_id, state: "In Arbeit (AI)", identifier: issue_identifier},
        started_at: DateTime.utc_now()
      }

      :sys.replace_state(pid, fn _ ->
        initial_state
        |> Map.put(:running, %{issue_id => running_entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))
        |> Map.put(:retry_attempts, %{})
      end)

      send(pid, :tick)
      Process.sleep(100)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Process.alive?(agent_pid)
      assert File.exists?(workspace)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(test_root)
    end
  end

  test "reconcile updates running issue state for active issues" do
    issue_id = "issue-3"

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: self(),
          ref: nil,
          identifier: "MT-557",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-557",
            state: "Todo (AI)"
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-557",
      state: "In Arbeit (AI)",
      title: "Active state refresh",
      description: "State should be refreshed",
      labels: []
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)
    updated_entry = updated_state.running[issue_id]

    assert Map.has_key?(updated_state.running, issue_id)
    assert MapSet.member?(updated_state.claimed, issue_id)
    assert updated_entry.issue.state == "In Arbeit (AI)"
  end

  test "reconcile stops running issue when active state needs a different runner" do
    for {new_state, issue_id} <- [
          {"In Arbeit", "issue-active-mode-manual"},
          {"Todo (Dialog-AI)", "issue-active-mode-dialog"}
        ] do
      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      agent_ref = Process.monitor(agent_pid)

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: agent_pid,
            ref: nil,
            identifier: "MT-MODE",
            issue: %Issue{
              id: issue_id,
              identifier: "MT-MODE",
              state: "In Arbeit (AI)"
            },
            run_mode: :regular,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      issue = %Issue{
        id: issue_id,
        identifier: "MT-MODE",
        state: new_state,
        title: "Active mode switch",
        description: "Runner should switch immediately",
        labels: []
      }

      updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

      refute Map.has_key?(updated_state.running, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
      refute Map.has_key?(updated_state.completed_states, issue_id)
      assert_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _reason}
    end
  end

  test "reconcile enforces dialog and regular run mode origin invariants" do
    scenarios = [
      %{
        suffix: "dialog-to-regular",
        from_run_mode: :dialog,
        from_state: "Todo (Dialog-AI)",
        to_state: "In Arbeit (AI)",
        assigned_to_worker: true,
        expected: :stop
      },
      %{
        suffix: "dialog-routed-away",
        from_run_mode: :dialog,
        from_state: "Todo (Dialog-AI)",
        to_state: "Todo (Dialog-AI)",
        assigned_to_worker: false,
        expected: :stop
      },
      %{
        suffix: "regular-to-dialog",
        from_run_mode: :regular,
        from_state: "In Arbeit (AI)",
        to_state: "Todo (Dialog-AI)",
        assigned_to_worker: true,
        expected: :stop
      },
      %{
        suffix: "dialog-stays-dialog",
        from_run_mode: :dialog,
        from_state: "Todo (Dialog-AI)",
        to_state: "Todo (Dialog-AI)",
        assigned_to_worker: true,
        expected: :keep
      }
    ]

    for %{
          suffix: suffix,
          from_run_mode: from_run_mode,
          from_state: from_state,
          to_state: to_state,
          assigned_to_worker: assigned_to_worker,
          expected: expected
        } <- scenarios do
      issue_id = "issue-run-mode-origin-#{suffix}"
      identifier = "MT-ORIGIN-#{suffix}"

      agent_pid =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      agent_ref = Process.monitor(agent_pid)

      try do
        state = %Orchestrator.State{
          running: %{
            issue_id => %{
              pid: agent_pid,
              ref: nil,
              identifier: identifier,
              issue: %Issue{
                id: issue_id,
                identifier: identifier,
                state: from_state,
                assigned_to_worker: true
              },
              run_mode: from_run_mode,
              started_at: DateTime.utc_now()
            }
          },
          claimed: MapSet.new([issue_id]),
          completed_states: %{},
          codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
          retry_attempts: %{}
        }

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          state: to_state,
          title: "Run mode origin #{suffix}",
          description: "Reconciliation should enforce the expected runner",
          labels: [],
          assigned_to_worker: assigned_to_worker
        }

        updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

        case expected do
          :stop ->
            refute Map.has_key?(updated_state.running, issue_id)
            refute MapSet.member?(updated_state.claimed, issue_id)
            refute Map.has_key?(updated_state.completed_states, issue_id)
            refute Map.has_key?(updated_state.retry_attempts, issue_id)
            assert_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _reason}

          :keep ->
            assert %{
                     run_mode: ^from_run_mode,
                     issue: %Issue{
                       state: ^to_state,
                       assigned_to_worker: ^assigned_to_worker
                     }
                   } = updated_state.running[issue_id]

            assert MapSet.member?(updated_state.claimed, issue_id)
            refute Map.has_key?(updated_state.completed_states, issue_id)
            refute Map.has_key?(updated_state.retry_attempts, issue_id)
            assert Process.alive?(agent_pid)
            refute_receive {:DOWN, ^agent_ref, :process, ^agent_pid, _reason}, 50
        end
      after
        if Process.alive?(agent_pid) do
          Process.exit(agent_pid, :kill)
        end

        Process.demonitor(agent_ref, [:flush])
      end
    end
  end

  test "reconcile stops running issue when it is reassigned away from this worker" do
    issue_id = "issue-reassigned"

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    state = %Orchestrator.State{
      running: %{
        issue_id => %{
          pid: agent_pid,
          ref: nil,
          identifier: "MT-561",
          issue: %Issue{
            id: issue_id,
            identifier: "MT-561",
            state: "In Arbeit (AI)",
            assigned_to_worker: true
          },
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue_id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: issue_id,
      identifier: "MT-561",
      state: "In Arbeit (AI)",
      title: "Reassigned active issue",
      description: "Worker should stop",
      labels: [],
      assigned_to_worker: false
    }

    updated_state = Orchestrator.reconcile_issue_states_for_test([issue], state)

    refute Map.has_key?(updated_state.running, issue_id)
    refute MapSet.member?(updated_state.claimed, issue_id)
    refute Process.alive?(agent_pid)
  end

  test "normal worker exit schedules active-state continuation retry" do
    issue_id = "issue-resume"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ContinuationOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = orchestrator_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558",
      issue: %Issue{id: issue_id, identifier: "MT-558", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(350)
    state = orchestrator_state(pid)
    observed_ms = System.monotonic_time(:millisecond)

    refute Map.has_key?(state.running, issue_id)
    assert MapSet.member?(state.completed, issue_id)
    assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
    assert is_integer(due_at_ms)
    assert_due_after_observation(due_at_ms, trigger_ms, observed_ms, 1_000, 1_500)
  end

  test "normal worker exit records the original dispatch state after running state refreshes" do
    issue_id = "issue-refreshed-state-completion"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RefreshedStateCompletionOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = orchestrator_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-558B",
      dispatch_issue: %Issue{id: issue_id, identifier: "MT-558B", state: "Todo (AI)"},
      issue: %Issue{id: issue_id, identifier: "MT-558B", state: "Planung (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(350)
    state = orchestrator_state(pid)

    assert Map.get(state.completed_states, issue_id) == "todo (ai)"
    assert %{attempt: 1} = state.retry_attempts[issue_id]
  end

  test "incomplete phase max-turn completion schedules guardrail retry without completion marker" do
    issue_id = "issue-incomplete-max-turns"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :IncompleteMaxTurnsOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = orchestrator_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560MAX",
      issue: %Issue{id: issue_id, identifier: "MT-560MAX", state: "Review (AI)"},
      recovered_turn_context: "Findings:\n- High: Example finding.",
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)

    send(
      pid,
      {:agent_completion_contract, issue_id, {:incomplete_phase_max_turns, {:open_workpad_checklist, "Review"}}}
    )

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(350)
    state = orchestrator_state(pid)
    observed_ms = System.monotonic_time(:millisecond)

    refute MapSet.member?(state.completed, issue_id)
    refute Map.has_key?(state.completed_states, issue_id)
    assert MapSet.member?(state.claimed, issue_id)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-560MAX",
             recovered_turn_context: "Findings:\n- High: Example finding."
           } = state.retry_attempts[issue_id]

    assert_due_after_observation(due_at_ms, trigger_ms, observed_ms, 1_000, 1_500)
  end

  test "abnormal worker exit increments retry attempt progressively" do
    issue_id = "issue-crash"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-559",
      retry_attempt: 2,
      issue: %Issue{id: issue_id, identifier: "MT-559", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = orchestrator_state(pid)

    assert %{attempt: 3, due_at_ms: due_at_ms, identifier: "MT-559", error: "agent exited: :boom"} = state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, trigger_ms, 39_000, 40_500)
  end

  test "normal worker completion preserves recovered subagent findings for the continuation retry" do
    issue_id = "issue-normal-recovered-subagent-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NormalRecoveredSubagentRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560C",
      issue: %Issue{id: issue_id, identifier: "MT-560C", state: "Review (AI)"},
      recovered_turn_context: "Findings:\n- High: Example finding.",
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(350)
    state = :sys.get_state(pid)
    observed_ms = System.monotonic_time(:millisecond)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-560C",
             recovered_turn_context: "Findings:\n- High: Example finding."
           } = state.retry_attempts[issue_id]

    assert_due_after_observation(due_at_ms, trigger_ms, observed_ms, 1_000, 1_500)
  end

  test "normal worker completion keeps late subagent findings from tagged user messages until continuation retry is scheduled" do
    issue_id = "issue-normal-late-recovered-subagent-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LateRecoveredSubagentRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560D",
      issue: %Issue{id: issue_id, identifier: "MT-560D", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "<subagent_notification>\n{\"agent_path\":\"agent-1\",\"status\":{\"completed\":\"Findings:\\n- High: Late example finding.\"}}\n</subagent_notification>"
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)
    observed_ms = System.monotonic_time(:millisecond)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-560D",
             recovered_turn_context: "Findings:\n- High: Late example finding."
           } = state.retry_attempts[issue_id]

    assert_due_after_observation(due_at_ms, trigger_ms, observed_ms, 1_000, 1_500)
  end

  test "normal worker completion ignores tagged subagent findings from unknown agents" do
    issue_id = "issue-review-tagged-notification-unknown-agent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TaggedNotificationUnknownAgentRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560Q",
      issue: %Issue{id: issue_id, identifier: "MT-560Q", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-2"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "<subagent_notification>\n{\"agent_path\":\"agent-1\",\"status\":{\"completed\":\"Findings:\\n- High: Should be ignored.\"}}\n</subagent_notification>"
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560Q", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion recovers tagged subagent no-findings with a trusted review spawn call even before the agent id is known" do
    issue_id = "issue-review-tagged-notification-trusted-spawn-call"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TaggedNotificationTrustedSpawnCallRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560Q1",
      issue: %Issue{id: issue_id, identifier: "MT-560Q1", state: "Review (AI)"},
      review_subagent_call_ids: MapSet.new(["call-review-q1"]),
      review_subagent_ids: MapSet.new(),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "<subagent_notification>\n{\"agent_path\":\"agent-review-q1\",\"status\":{\"completed\":\"No findings.\\nResidual risk: none.\"}}\n</subagent_notification>"
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{
             identifier: "MT-560Q1",
             recovered_turn_context: "Keine Findings.\nResidual risk: none."
           } = state.retry_attempts[issue_id]
  end

  test "review subagent tracking resets when a new Codex turn starts" do
    issue_id = "issue-review-subagent-reset-on-new-turn"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ReviewSubagentResetOnNewTurnOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560S",
      issue: %Issue{id: issue_id, identifier: "MT-560S", state: "Review (AI)"},
      session_id: "thread-review-old-turn",
      review_subagent_call_ids: MapSet.new(["call-review-old"]),
      review_subagent_ids: MapSet.new(["agent-review-old"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-review-new-turn",
         timestamp: DateTime.utc_now()
       }}
    )

    Process.sleep(50)

    assert %{
             session_id: "thread-review-new-turn",
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = orchestrator_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_call_ids, MapSet.new())
    assert MapSet.equal?(review_subagent_ids, MapSet.new())

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "<subagent_notification>\n{\"agent_path\":\"agent-review-old\",\"status\":{\"completed\":\"Findings:\\n- High: Stale finding.\"}}\n</subagent_notification>"
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{recovered_turn_context: nil} = :sys.get_state(pid).running[issue_id]
  end

  test "recovered review subagent ids survive a new Codex turn and can complete later" do
    issue_id = "issue-recovered-review-subagent-new-turn"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RecoveredReviewSubagentNewTurnOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560S2",
      issue: %Issue{id: issue_id, identifier: "MT-560S2", state: "Review (AI)"},
      recovered_review_subagent_ids: MapSet.new(["agent-review-recovered"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :session_started,
         session_id: "thread-review-resumed",
         timestamp: DateTime.utc_now()
       }}
    )

    Process.sleep(50)

    assert %{
             session_id: "thread-review-resumed",
             review_subagent_ids: review_subagent_ids,
             recovered_review_subagent_ids: recovered_review_subagent_ids
           } = orchestrator_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_ids, MapSet.new())
    assert MapSet.equal?(recovered_review_subagent_ids, MapSet.new(["agent-review-recovered"]))

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-review-recovered":{"completed":"No findings.\\nResidual risk: none."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{
             recovered_turn_context: "Keine Findings.\nResidual risk: none.",
             recovered_review_subagent_ids: recovered_review_subagent_ids
           } = :sys.get_state(pid).running[issue_id]

    assert MapSet.equal?(recovered_review_subagent_ids, MapSet.new())
  end

  test "review subagent tracking trusts only the mandatory review spawn request" do
    issue_id = "issue-review-trusted-spawn-agent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TrustedReviewSpawnAgentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560T",
      issue: %Issue{id: issue_id, identifier: "MT-560T", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :tool_call_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/tool/call",
           "params" => %{
             "tool" => "spawn_agent",
             "callId" => "call-review-1",
             "arguments" => %{
               "fork_context" => false,
               "message" => """
               Start a read-only review of the current worktree against origin/main.
               Only report review findings and return exactly one of:
               Findings:
               - High: Example finding.
               Keine Findings.
               """
             }
           }
         }
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "id" => "call-review-1",
               "type" => "function_call_output",
               "tool" => "spawn_agent",
               "output" => ~s({"id":"agent-review-1"})
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = :sys.get_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_call_ids, MapSet.new(["call-review-1"]))
    assert MapSet.equal?(review_subagent_ids, MapSet.new(["agent-review-1"]))
  end

  test "review subagent tracking accepts review-state spawn_agent requests with noncanonical review wording" do
    issue_id = "issue-review-explorer-spawn-agent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ExplorerReviewSpawnAgentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560T2",
      issue: %Issue{id: issue_id, identifier: "MT-560T2", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :tool_call_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/tool/call",
           "params" => %{
             "tool" => "spawn_agent",
             "callId" => "call-review-explorer-1",
             "arguments" => %{
               "fork_context" => false,
               "agent_type" => "explorer",
               "message" => """
               Führe einen isolierten read-only Code-Review des aktuellen Diffs gegen `origin/main`
               im Repository `/tmp/example` durch. Scope ist nur der Diff in
               `lib/example.ex` und `test/example_test.exs`. Liefere nur konkrete Findings mit
               Schweregrad, Datei/Zeile und kurzer Begründung; wenn du nichts findest, sage das
               explizit. Keine Dateien editieren, keine Tests starten, keine Workpad-/Linear-/
               Statusänderungen, keine weiteren Subagenten.
               """
             }
           }
         }
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "id" => "call-review-explorer-1",
               "type" => "function_call_output",
               "tool" => "spawn_agent",
               "output" => ~s({"id":"agent-review-explorer-1"})
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = :sys.get_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_call_ids, MapSet.new(["call-review-explorer-1"]))
    assert MapSet.equal?(review_subagent_ids, MapSet.new(["agent-review-explorer-1"]))
  end

  test "review subagent tracking derives agent ids from tool call completion output" do
    issue_id = "issue-review-tool-result-spawn-agent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :ToolResultReviewSpawnAgentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560T3",
      issue: %Issue{id: issue_id, identifier: "MT-560T3", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :tool_call_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/tool/call",
           "params" => %{
             "tool" => "spawn_agent",
             "callId" => "call-review-tool-result-1",
             "arguments" => %{
               "fork_context" => false,
               "agent_type" => "explorer",
               "message" => """
               Read-only review task for the current worktree against origin/main.
               Stay read-only, keep the review narrow, and report only findings.
               If there are no findings, say that explicitly.
               """
             }
           }
         },
         tool_result: %{
           "success" => true,
           "output" => ~s({"agent_id":"agent-review-tool-result-1","nickname":"Scout"})
         }
       }}
    )

    Process.sleep(50)

    assert %{
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = :sys.get_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_call_ids, MapSet.new(["call-review-tool-result-1"]))
    assert MapSet.equal?(review_subagent_ids, MapSet.new(["agent-review-tool-result-1"]))
  end

  test "review subagent tracking in Review (AI) forwards arbitrary spawn_agent completions" do
    issue_id = "issue-review-unrelated-spawn-agent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :UnrelatedReviewSpawnAgentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560U",
      issue: %Issue{id: issue_id, identifier: "MT-560U", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :tool_call_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/tool/call",
           "params" => %{
             "tool" => "spawn_agent",
             "callId" => "call-helper-1",
             "arguments" => %{
               "fork_context" => false,
               "message" => "Inspect this helper and summarize the result."
             }
           }
         }
       }}
    )

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "id" => "call-helper-1",
               "type" => "function_call_output",
               "tool" => "spawn_agent",
               "output" => ~s({"id":"agent-helper-1"})
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = :sys.get_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_call_ids, MapSet.new(["call-helper-1"]))
    assert MapSet.equal?(review_subagent_ids, MapSet.new(["agent-helper-1"]))

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "<subagent_notification>\n{\"agent_path\":\"agent-helper-1\",\"status\":{\"completed\":\"Findings:\\n- High: Helper finding.\"}}\n</subagent_notification>"
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{recovered_turn_context: "Findings:\n- High: Helper finding."} =
             :sys.get_state(pid).running[issue_id]
  end

  test "review subagent tracking captures collabAgentToolCall spawnAgent completions" do
    issue_id = "issue-review-collab-spawn-agent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :CollabReviewSpawnAgentOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560U1",
      issue: %Issue{id: issue_id, identifier: "MT-560U1", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "collabAgentToolCall",
               "id" => "call-collab-review-1",
               "tool" => "spawnAgent",
               "status" => "completed",
               "prompt" => "Inspect this helper and summarize the result.",
               "receiverThreadIds" => ["agent-collab-review-1"],
               "agentsStates" => %{
                 "agent-collab-review-1" => %{"status" => "pendingInit", "message" => nil}
               }
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = :sys.get_state(pid).running[issue_id]

    assert MapSet.equal?(review_subagent_call_ids, MapSet.new(["call-collab-review-1"]))
    assert MapSet.equal?(review_subagent_ids, MapSet.new(["agent-collab-review-1"]))
  end

  test "normal worker completion recovers late collab wait results from collabAgentToolCall items" do
    issue_id = "issue-normal-late-collab-wait-agent-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LateCollabWaitAgentRecoveredRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560U2",
      issue: %Issue{id: issue_id, identifier: "MT-560U2", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "collabAgentToolCall",
               "id" => "call-collab-review-2",
               "tool" => "spawnAgent",
               "status" => "completed",
               "prompt" => "Inspect this helper and summarize the result.",
               "receiverThreadIds" => ["agent-collab-review-2"],
               "agentsStates" => %{
                 "agent-collab-review-2" => %{"status" => "pendingInit", "message" => nil}
               }
             }
           }
         }
       }}
    )

    Process.sleep(50)
    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "collabAgentToolCall",
               "id" => "call-collab-wait-1",
               "tool" => "wait",
               "status" => "completed",
               "receiverThreadIds" => ["agent-collab-review-2"],
               "agentsStates" => %{
                 "agent-collab-review-2" => %{
                   "status" => "completed",
                   "message" => "Keine Findings.\nResidual risk: none."
                 }
               }
             }
           }
         }
       }}
    )

    retry_entry =
      Enum.find_value(1..20, fn _attempt ->
        Process.sleep(50)
        :sys.get_state(pid).retry_attempts[issue_id]
      end)

    assert %{
             identifier: "MT-560U2",
             recovered_turn_context: "Keine Findings.\nResidual risk: none."
           } = retry_entry
  end

  test "normal worker completion recovers late wait_agent findings from item completion output" do
    issue_id = "issue-normal-late-wait-agent-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LateWaitAgentRecoveredRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560E",
      issue: %Issue{id: issue_id, identifier: "MT-560E", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-1":{"completed":"Findings:\\n- High: Late wait_agent finding."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)
    observed_ms = System.monotonic_time(:millisecond)

    assert %{
             attempt: 1,
             due_at_ms: due_at_ms,
             identifier: "MT-560E",
             recovered_turn_context: "Findings:\n- High: Late wait_agent finding."
           } = state.retry_attempts[issue_id]

    assert_due_after_observation(due_at_ms, trigger_ms, observed_ms, 1_000, 1_500)
  end

  test "normal worker completion recovers late wait_agent findings from tool call completion output" do
    issue_id = "issue-normal-late-wait-agent-tool-result-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LateWaitAgentToolResultRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560E1",
      issue: %Issue{id: issue_id, identifier: "MT-560E1", state: "Review (AI)"},
      review_subagent_call_ids: MapSet.new(["call-review-e1"]),
      review_subagent_ids: MapSet.new(),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :tool_call_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/tool/call",
           "params" => %{
             "tool" => "wait_agent",
             "callId" => "call-wait-e1",
             "arguments" => %{"targets" => ["agent-review-e1"], "timeout_ms" => 600_000}
           }
         },
         tool_result: %{
           "success" => true,
           "output" => ~s({"status":{"agent-review-e1":{"completed":"No findings.\\nResidual risk: none."}},"timed_out":false})
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{
             identifier: "MT-560E1",
             recovered_turn_context: "Keine Findings.\nResidual risk: none."
           } = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores timed out wait_agent findings from item completion output" do
    issue_id = "issue-normal-late-wait-agent-timeout"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LateWaitAgentTimedOutRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560F",
      issue: %Issue{id: issue_id, identifier: "MT-560F", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-1":{"completed":"Findings:\\n- High: Timed out finding."}},"timed_out":true})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560F", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores late wait_agent findings when no review subagent id was verified" do
    issue_id = "issue-review-wait-agent-without-verified-subagent"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :WaitAgentWithoutVerifiedSubagentRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560R",
      issue: %Issue{id: issue_id, identifier: "MT-560R", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-1":{"completed":"Findings:\\n- High: Should be ignored without a verified subagent id."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560R", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion recovers late wait_agent no-concrete-findings output from a verified review subagent" do
    issue_id = "issue-review-wait-agent-no-concrete-findings"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :WaitAgentNoConcreteFindingsRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560R1",
      issue: %Issue{id: issue_id, identifier: "MT-560R1", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-review-r1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" =>
                 ~s|{"status":{"agent-review-r1":{"completed":"No concrete findings in the scoped diff. I also ran `mix test test/mix/tasks/workspace_before_remove_test.exs test/symphony_elixir/extensions_test.exs`, and it passed (`53 tests, 0 failures`)."}},"timed_out":false}|
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{
             identifier: "MT-560R1",
             recovered_turn_context:
               "Keine Findings.\nin the scoped diff. I also ran `mix test test/mix/tasks/workspace_before_remove_test.exs test/symphony_elixir/extensions_test.exs`, and it passed (`53 tests, 0 failures`)."
           } = state.retry_attempts[issue_id]
  end

  test "normal worker completion recovers late wait_agent bullet-list findings from a verified review subagent" do
    issue_id = "issue-review-wait-agent-bullet-list-findings"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :WaitAgentBulletListFindingsRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560R1B",
      issue: %Issue{id: issue_id, identifier: "MT-560R1B", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-review-r1b"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" =>
                 ~s|{"status":{"agent-review-r1b":{"completed":"- Medium `lib/symphony_elixir/agent_runner.ex:218-247` Cancelled Codex turns now bubble out as hard errors.\\n\\n- Medium `lib/symphony_elixir/agent_runner.ex:576-593` Review handoff now keys only off `git status`."}},"timed_out":false}|
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{
             identifier: "MT-560R1B",
             recovered_turn_context:
               "Findings:\n- Medium `lib/symphony_elixir/agent_runner.ex:218-247` Cancelled Codex turns now bubble out as hard errors.\n\n- Medium `lib/symphony_elixir/agent_runner.ex:576-593` Review handoff now keys only off `git status`."
           } = state.retry_attempts[issue_id]
  end

  test "normal worker completion recovers late wait_agent findings with a trusted review spawn call even before the agent id is known" do
    issue_id = "issue-review-wait-agent-with-trusted-spawn-call"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :WaitAgentWithTrustedSpawnCallRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560R2",
      issue: %Issue{id: issue_id, identifier: "MT-560R2", state: "Review (AI)"},
      review_subagent_call_ids: MapSet.new(["call-review-r2"]),
      review_subagent_ids: MapSet.new(),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-review-r2":{"completed":"No findings.\\nResidual risk: none."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{
             identifier: "MT-560R2",
             recovered_turn_context: "Keine Findings.\nResidual risk: none."
           } = state.retry_attempts[issue_id]
  end

  test "late wait_agent findings can still enrich retry metadata after normal completion finalization" do
    issue_id = "issue-review-late-retry-metadata-update"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :LateRetryMetadataUpdateOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560R3",
      issue: %Issue{id: issue_id, identifier: "MT-560R3", state: "Review (AI)"},
      review_subagent_call_ids: MapSet.new(["call-review-r3"]),
      review_subagent_ids: MapSet.new(),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})
    Process.sleep(350)

    assert %{identifier: "MT-560R3", recovered_turn_context: nil} = orchestrator_state(pid).retry_attempts[issue_id]
    refute Map.has_key?(orchestrator_state(pid).running, issue_id)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-review-r3":{"completed":"Findings:\\n- High: Late retry finding."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(50)

    assert %{
             identifier: "MT-560R3",
             recovered_turn_context: "Findings:\n- High: Late retry finding."
           } = orchestrator_state(pid).retry_attempts[issue_id]
  end

  test "normal worker completion ignores tagged subagent notifications outside user message events" do
    issue_id = "issue-review-tagged-notification-non-user-message"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TaggedNotificationNonUserMessageRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560K",
      issue: %Issue{id: issue_id, identifier: "MT-560K", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "content" => [
                 %{
                   "type" => "input_text",
                   "text" => "<subagent_notification>\n{\"agent_path\":\"agent-1\",\"status\":{\"completed\":\"Findings:\\n- High: Should be ignored.\"}}\n</subagent_notification>"
                 }
               ]
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560K", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores late subagent findings outside Review (AI)" do
    issue_id = "issue-non-review-late-subagent-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NonReviewLateRecoveredSubagentRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560G",
      issue: %Issue{id: issue_id, identifier: "MT-560G", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "content" => [
                 %{
                   "type" => "input_text",
                   "text" => "<subagent_notification>\n{\"agent_path\":\"agent-1\",\"status\":{\"completed\":\"Findings:\\n- High: Non-review finding.\"}}\n</subagent_notification>"
                 }
               ]
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560G", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores wait_agent-like output from other tools" do
    issue_id = "issue-review-non-wait-agent-output"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NonWaitAgentRecoveredRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560H",
      issue: %Issue{id: issue_id, identifier: "MT-560H", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "exec_command",
               "output" => ~s({"status":{"agent-1":{"completed":"Findings:\\n- High: Should be ignored."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560H", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores plain wait_agent output without structured status" do
    issue_id = "issue-review-wait-agent-plain-output"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :PlainWaitAgentOutputRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560L",
      issue: %Issue{id: issue_id, identifier: "MT-560L", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => "Findings:\n- High: Should be ignored."
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560L", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores nested wait_agent findings outside completed status entries" do
    issue_id = "issue-review-wait-agent-nested-output"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :NestedWaitAgentOutputRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560M",
      issue: %Issue{id: issue_id, identifier: "MT-560M", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"agent-1":{"details":["Findings:\\n- High: Should be ignored."]}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560M", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores top-level wait_agent completed fields outside agent status entries" do
    issue_id = "issue-review-wait-agent-top-level-completed"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TopLevelWaitAgentCompletedRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560N",
      issue: %Issue{id: issue_id, identifier: "MT-560N", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"completed":"Keine Findings.","timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560N", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores wait_agent completed fields from unknown status entries" do
    issue_id = "issue-review-wait-agent-unknown-status-entry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :UnknownWaitAgentStatusEntryRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560O",
      issue: %Issue{id: issue_id, identifier: "MT-560O", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "item/completed",
           "params" => %{
             "item" => %{
               "type" => "function_call_output",
               "tool" => "wait_agent",
               "output" => ~s({"status":{"summary":{"completed":"Keine Findings."}},"timed_out":false})
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560O", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores tagged subagent notifications wrapped in surrounding prose" do
    issue_id = "issue-review-tagged-notification-surrounding-prose"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :TaggedNotificationSurroundingProseRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560P",
      issue: %Issue{id: issue_id, identifier: "MT-560P", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "Vorheriger Kontext\n<subagent_notification>\n{\"agent_path\":\"agent-1\",\"status\":{\"completed\":\"Keine Findings.\"}}\n</subagent_notification>\nNachtrag"
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560P", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "normal worker completion ignores plain findings text without wait_agent or subagent tag" do
    issue_id = "issue-review-plain-findings-text"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :PlainFindingsRecoveredRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560I",
      issue: %Issue{id: issue_id, identifier: "MT-560I", state: "Review (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :normal})

    Process.sleep(50)

    send(
      pid,
      {:codex_worker_update, issue_id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "codex/event/user_message",
           "params" => %{
             "msg" => %{
               "payload" => %{
                 "content" => [
                   %{
                     "type" => "input_text",
                     "text" => "Findings:\n- High: Untagged plain text."
                   }
                 ]
               }
             }
           }
         }
       }}
    )

    Process.sleep(350)
    state = :sys.get_state(pid)

    assert %{identifier: "MT-560I", recovered_turn_context: nil} = state.retry_attempts[issue_id]
  end

  test "first abnormal worker exit waits before retrying" do
    issue_id = "issue-crash-initial"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :InitialCrashRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560",
      issue: %Issue{id: issue_id, identifier: "MT-560", state: "In Arbeit (AI)"},
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    trigger_ms = System.monotonic_time(:millisecond)
    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{attempt: 1, due_at_ms: due_at_ms, identifier: "MT-560", error: "agent exited: :boom"} = state.retry_attempts[issue_id]

    assert_due_in_range(due_at_ms, trigger_ms, 9_000, 10_500)
  end

  test "abnormal worker exit preserves recovered subagent findings for the retry prompt" do
    issue_id = "issue-recovered-subagent-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RecoveredSubagentRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560B",
      issue: %Issue{id: issue_id, identifier: "MT-560B", state: "Review (AI)"},
      review_subagent_ids: MapSet.new(["agent-1"]),
      session_id: nil,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {
      :codex_worker_update,
      issue_id,
      %{
        event: :notification,
        timestamp: DateTime.utc_now(),
        payload: %{
          "method" => "codex/event/user_message",
          "params" => %{
            "msg" => %{
              "payload" => %{
                "content" => [
                  %{
                    "type" => "input_text",
                    "text" => "<subagent_notification>\n{\"agent_path\":\"agent-1\",\"status\":{\"completed\":\"Findings:\\n- High: Example finding.\"}}\n</subagent_notification>"
                  }
                ]
              }
            }
          }
        }
      }
    })

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{
             attempt: 1,
             identifier: "MT-560B",
             error: "agent exited: :boom",
             recovered_turn_context: "Findings:\n- High: Example finding."
           } = state.retry_attempts[issue_id]
  end

  test "abnormal worker exit preserves running review subagent ids for the retry prompt" do
    issue_id = "issue-recovered-review-subagent-ids-retry"
    ref = make_ref()
    orchestrator_name = Module.concat(__MODULE__, :RecoveredReviewSubagentIdsRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: "MT-560B2",
      issue: %Issue{id: issue_id, identifier: "MT-560B2", state: "Review (AI)"},
      recovered_review_subagent_call_ids: MapSet.new(["call-review-recovered-1"]),
      recovered_review_subagent_ids: MapSet.new(["agent-review-recovered-1"]),
      review_subagent_call_ids: MapSet.new(["call-review-current-1"]),
      review_subagent_ids: MapSet.new(["agent-review-current-1"]),
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, ref, :process, self(), :boom})
    Process.sleep(50)
    state = :sys.get_state(pid)

    assert %{
             identifier: "MT-560B2",
             error: "agent exited: :boom",
             review_subagent_call_ids: review_subagent_call_ids,
             review_subagent_ids: review_subagent_ids
           } = state.retry_attempts[issue_id]

    assert MapSet.equal?(
             review_subagent_call_ids,
             MapSet.new(["call-review-recovered-1", "call-review-current-1"])
           )

    assert MapSet.equal?(
             review_subagent_ids,
             MapSet.new(["agent-review-recovered-1", "agent-review-current-1"])
           )
  end

  test "stale retry timer messages do not consume newer retry entries" do
    issue_id = "issue-stale-retry"
    orchestrator_name = Module.concat(__MODULE__, :StaleRetryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    current_retry_token = make_ref()
    stale_retry_token = make_ref()

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:retry_attempts, %{
        issue_id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: current_retry_token,
          due_at_ms: System.monotonic_time(:millisecond) + 30_000,
          identifier: "MT-561",
          error: "agent exited: :boom"
        }
      })
    end)

    send(pid, {:retry_issue, issue_id, stale_retry_token})
    Process.sleep(50)

    assert %{
             attempt: 2,
             retry_token: ^current_retry_token,
             identifier: "MT-561",
             error: "agent exited: :boom"
           } = :sys.get_state(pid).retry_attempts[issue_id]
  end

  test "retry-dispatched recovered review context is consumed after one continuation turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-recovered-review-context-consumed-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      issue_id = "issue-recovered-review-context-consumed"
      issue_identifier = "MT-560J"
      retry_token = make_ref()
      existing_task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# recovered context\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        set -eu
        workspace="$PWD"
        source_repo="$SYMPHONY_PROJECT_ROOT"
        issue_key="$(basename "$workspace")"
        branch="symphony/$issue_key"
        rm -rf "$workspace"
        git -C "$source_repo" worktree add -b "$branch" "$workspace" HEAD
        """,
        codex_command: "sh -lc 'sleep 60'",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Recovered review continuation context",
        description: "Retry prompt context should only be reused once",
        state: "Review (AI)",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      started_task_supervisor =
        case existing_task_supervisor do
          pid when is_pid(pid) ->
            nil

          nil ->
            {:ok, pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor)
            pid
        end

      File.cd!(source_repo, fn ->
        orchestrator_name = Module.concat(__MODULE__, :ConsumedRecoveredContextRetryOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end

          if is_pid(started_task_supervisor) and Process.alive?(started_task_supervisor) do
            Process.exit(started_task_supervisor, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn _ ->
          %{
            initial_state
            | retry_attempts: %{
                issue_id => %{
                  attempt: 1,
                  timer_ref: nil,
                  retry_token: retry_token,
                  due_at_ms: System.monotonic_time(:millisecond) + 30_000,
                  identifier: issue_identifier,
                  recovered_turn_context: "Findings:\n- High: Example finding."
                }
              }
          }
        end)

        send(pid, {:retry_issue, issue_id, retry_token})

        running_entry =
          Enum.find_value(1..20, fn _attempt ->
            Process.sleep(50)
            :sys.get_state(pid).running[issue_id]
          end)

        assert %{recovered_turn_context: nil} = running_entry

        send(pid, {:DOWN, running_entry.ref, :process, running_entry.pid, :normal})
        Process.sleep(400)
        retry_entry = :sys.get_state(pid).retry_attempts[issue_id]

        assert %{identifier: ^issue_identifier, recovered_turn_context: nil} = retry_entry
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "retry short-circuits a clean recovered review handoff without starting a new session" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-clean-review-retry-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      issue_id = "issue-clean-review-retry-handoff"
      issue_identifier = "MT-560J1"
      workspace = Path.join(workspace_root, issue_identifier)
      retry_token = make_ref()

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# clean review handoff\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# clean review workspace\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'sleep 60'",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Clean recovered review handoff",
        description: "Recovered no-findings review results should not dispatch another session",
        state: "Review (AI)",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [no_findings_review_workpad()]
      })

      File.cd!(source_repo, fn ->
        orchestrator_name = Module.concat(__MODULE__, :CleanRecoveredReviewRetryHandoffOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn _ ->
          %{
            initial_state
            | retry_attempts: %{
                issue_id => %{
                  attempt: 1,
                  timer_ref: nil,
                  retry_token: retry_token,
                  due_at_ms: System.monotonic_time(:millisecond) + 30_000,
                  identifier: issue_identifier,
                  workspace_path: workspace,
                  recovered_turn_context: "Keine Findings."
                }
              }
          }
        end)

        send(pid, {:retry_issue, issue_id, retry_token})

        assert_receive {:memory_tracker_state_update, ^issue_id, "Test (AI)"}, 1_000
        Process.sleep(500)

        state = orchestrator_state(pid)
        refute Map.has_key?(state.running, issue_id)
        refute Map.has_key?(state.retry_attempts, issue_id)
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "retry dispatches recovered no-findings without handoff when workpad review evidence is open" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-open-workpad-review-retry-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      issue_id = "issue-open-workpad-review-retry-handoff"
      issue_identifier = "MT-560J1B"
      workspace = Path.join(workspace_root, issue_identifier)
      codex_binary = Path.join(test_root, "fake-codex")
      codex_stamp = Path.join(test_root, "codex-dispatched")
      retry_token = make_ref()

      File.mkdir_p!(source_repo)
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# open workpad review workspace\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      write_successful_fake_codex!(codex_binary, codex_stamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1,
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Open workpad recovered review handoff",
        description: "Recovered no-findings review results need closed workpad evidence",
        state: "Review (AI)",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review (AI) Einstieg: Pull und Snapshot geprüft
          - [ ] Review (AI) read-only Subagent: läuft
          """
        ]
      })

      File.cd!(source_repo, fn ->
        orchestrator_name = Module.concat(__MODULE__, :OpenWorkpadRecoveredReviewRetryHandoffOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn _ ->
          %{
            initial_state
            | retry_attempts: %{
                issue_id => %{
                  attempt: 1,
                  timer_ref: nil,
                  retry_token: retry_token,
                  due_at_ms: System.monotonic_time(:millisecond) + 30_000,
                  identifier: issue_identifier,
                  workspace_path: workspace,
                  recovered_turn_context: "Keine Findings."
                }
              }
          }
        end)

        send(pid, {:retry_issue, issue_id, retry_token})

        assert_receive {:memory_tracker_branch_update, ^issue_id, "main"}, 1_000
        assert_file_exists_eventually!(codex_stamp)
        refute_receive {:memory_tracker_state_update, ^issue_id, _state}, 100
        stop_orchestrator_and_workers(pid)
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "retry dispatches recovered no-findings when workspace is dirty" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dirty-review-retry-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      issue_id = "issue-dirty-review-retry-handoff"
      issue_identifier = "MT-560J2"
      workspace = Path.join(workspace_root, issue_identifier)
      codex_binary = Path.join(test_root, "fake-codex")
      codex_stamp = Path.join(test_root, "codex-dispatched")
      retry_token = make_ref()

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# dirty review handoff\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# dirty review workspace\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty review workspace\nreview change\n")
      File.write!(review_autocommit_marker_path!(workspace), "true\n")
      write_successful_fake_codex!(codex_binary, codex_stamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Dirty recovered review handoff",
        description: "Recovered no-findings review results must keep manual review when changes exist",
        state: "Review (AI)",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [no_findings_review_workpad()]
      })

      File.cd!(source_repo, fn ->
        orchestrator_name = Module.concat(__MODULE__, :DirtyRecoveredReviewRetryHandoffOrchestrator)
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end
        end)

        initial_state = :sys.get_state(pid)

        :sys.replace_state(pid, fn _ ->
          %{
            initial_state
            | retry_attempts: %{
                issue_id => %{
                  attempt: 1,
                  timer_ref: nil,
                  retry_token: retry_token,
                  due_at_ms: System.monotonic_time(:millisecond) + 30_000,
                  identifier: issue_identifier,
                  workspace_path: workspace,
                  recovered_turn_context: "Keine Findings."
                }
              }
          }
        end)

        send(pid, {:retry_issue, issue_id, retry_token})

        # Recovery performs real Git checks and starts an app-server process.
        assert_receive {:memory_tracker_state_update, ^issue_id, "Freigabe Review"}, 10_000
        assert_file_exists_eventually!(codex_stamp)
        stop_orchestrator_and_workers(pid)
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "retry dispatches recovered no-findings when workspace path is missing" do
    caller_repo =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspace-review-retry-handoff-#{System.unique_integer([:positive])}"
      )

    test_root = Path.join(caller_repo, "tmp")
    previous_tmpdir = System.get_env("TMPDIR")
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      File.mkdir_p!(test_root)
      caller_git!(caller_repo, ["init", "--template=", "-b", "main"])
      caller_git!(caller_repo, ["config", "user.name", "Test User"])
      caller_git!(caller_repo, ["config", "user.email", "test@example.com"])
      caller_git!(caller_repo, ["config", "core.hooksPath", "/dev/null"])
      caller_git!(caller_repo, ["config", "commit.gpgsign", "false"])
      File.write!(Path.join(caller_repo, ".gitignore"), "/tmp/\n")
      sentinel = Path.join(caller_repo, "sentinel.txt")
      File.write!(sentinel, "initial\n")
      caller_git!(caller_repo, ["add", ".gitignore", "sentinel.txt"])
      caller_git!(caller_repo, ["commit", "-m", "initial"])
      File.write!(sentinel, "initial\nstaged\n")
      caller_git!(caller_repo, ["add", "sentinel.txt"])
      File.write!(sentinel, "initial\nstaged\nunstaged\n")
      caller_before = caller_repository_snapshot(caller_repo)

      System.put_env("TMPDIR", test_root)
      isolate_git_discovery!(System.tmp_dir!())

      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      issue_id = "issue-missing-workspace-review-retry-handoff"
      issue_identifier = "MT-560J3"
      codex_binary = Path.join(test_root, "fake-codex")
      codex_stamp = Path.join(test_root, "codex-dispatched")
      retry_token = make_ref()

      File.mkdir_p!(source_repo)
      write_successful_fake_codex!(codex_binary, codex_stamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Missing workspace recovered review handoff",
        description: "Recovered no-findings review results must keep manual review without workspace evidence",
        state: "Review (AI)",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [no_findings_review_workpad()]
      })

      File.cd!(source_repo, fn ->
        orchestrator_name =
          Module.concat(__MODULE__, :MissingWorkspaceRecoveredReviewRetryHandoffOrchestrator)

        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        target_state =
          try do
            initial_state = :sys.get_state(pid)

            :sys.replace_state(pid, fn _ ->
              %{
                initial_state
                | retry_attempts: %{
                    issue_id => %{
                      attempt: 1,
                      timer_ref: nil,
                      retry_token: retry_token,
                      due_at_ms: System.monotonic_time(:millisecond) + 30_000,
                      identifier: issue_identifier,
                      recovered_turn_context: "Keine Findings."
                    }
                  }
              }
            end)

            send(pid, {:retry_issue, issue_id, retry_token})

            assert_receive {:memory_tracker_state_update, ^issue_id, target_state}, 10_000
            assert_file_exists_eventually!(codex_stamp)
            target_state
          after
            stop_orchestrator_and_workers(pid)
            assert caller_repository_snapshot(caller_repo) == caller_before
          end

        assert target_state == "Freigabe Review"
      end)
    after
      restore_env("TMPDIR", previous_tmpdir)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(caller_repo)
    end
  end

  test "manual refresh coalesces repeated requests and ignores superseded ticks" do
    now_ms = System.monotonic_time(:millisecond)
    stale_tick_token = make_ref()

    state = %Orchestrator.State{
      poll_interval_ms: 30_000,
      max_concurrent_agents: 1,
      next_poll_due_at_ms: now_ms + 30_000,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: stale_tick_token,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil
    }

    refresh_result = Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, state)
    assert {:reply, %{queued: true, coalesced: false}, refreshed_state} = refresh_result

    assert is_reference(refreshed_state.tick_timer_ref)
    assert is_reference(refreshed_state.tick_token)
    refute refreshed_state.tick_token == stale_tick_token
    assert refreshed_state.next_poll_due_at_ms <= System.monotonic_time(:millisecond)

    coalesced_result = Orchestrator.handle_call(:request_refresh, {self(), make_ref()}, refreshed_state)

    assert {:reply, %{queued: true, coalesced: true}, coalesced_state} = coalesced_result

    assert coalesced_state.tick_token == refreshed_state.tick_token
    assert {:noreply, ^coalesced_state} = Orchestrator.handle_info({:tick, stale_tick_token}, coalesced_state)
  end

  test "select_worker_host_for_test skips full ssh hosts under the shared per-host cap" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == "worker-b"
  end

  test "select_worker_host_for_test returns no_worker_capacity when every ssh host is full" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, nil) == :no_worker_capacity
  end

  test "select_worker_host_for_test keeps the preferred ssh host when it still has capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 2
    )

    state = %Orchestrator.State{
      running: %{
        "issue-1" => %{worker_host: "worker-a"},
        "issue-2" => %{worker_host: "worker-b"}
      }
    }

    assert Orchestrator.select_worker_host_for_test(state, "worker-a") == "worker-a"
  end

  test "dialog issues bypass ssh worker capacity" do
    write_workflow_file!(Workflow.workflow_file_path(),
      worker_ssh_hosts: ["worker-a", "worker-b"],
      worker_max_concurrent_agents_per_host: 1
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{
        "issue-1" => %{worker_host: "worker-a", issue: %Issue{id: "issue-1", state: "In Arbeit (AI)"}},
        "issue-2" => %{worker_host: "worker-b", issue: %Issue{id: "issue-2", state: "Review (AI)"}}
      },
      claimed: MapSet.new(),
      completed_states: %{}
    }

    dialog_issue = %Issue{
      id: "issue-dialog-capacity",
      identifier: "MT-DIALOG-CAPACITY",
      title: "Dialog capacity",
      state: "Todo (Dialog-AI)"
    }

    regular_issue = %Issue{
      id: "issue-regular-capacity",
      identifier: "MT-REGULAR-CAPACITY",
      title: "Regular capacity",
      state: "In Arbeit (AI)"
    }

    assert Orchestrator.select_worker_host_for_issue_for_test(dialog_issue, state, nil) == nil
    assert Orchestrator.should_dispatch_issue_for_test(dialog_issue, state)

    assert Orchestrator.select_worker_host_for_issue_for_test(regular_issue, state, nil) ==
             :no_worker_capacity

    refute Orchestrator.should_dispatch_issue_for_test(regular_issue, state)
  end

  test "unchanged answered dialog issue stays idle without comment refresh or activity touch", %{
    application_orchestrator: application_orchestrator
  } do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dialog-idle-poll-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      issue_id = "issue-dialog-idle-poll"
      completed_at = ~U[2026-05-21 09:50:44Z]

      answer_signal = %{
        id: "comment-answer",
        created_at: ~U[2026-05-21 09:55:00Z],
        updated_at: ~U[2026-05-21 09:55:00Z]
      }

      issue = %Issue{
        id: issue_id,
        identifier: "MT-DIALOG-IDLE",
        title: "Idle dialog",
        description: "Already answered dialog issue",
        state: "Todo (Dialog-AI)",
        url: "https://example.org/issues/MT-DIALOG-IDLE",
        updated_at: completed_at,
        last_comment_signal: answer_signal,
        labels: []
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(test_root, "worktrees"),
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [
          %{id: "comment-user", body: "Question", created_at: ~U[2026-05-21 09:54:00Z]},
          %{
            id: "comment-answer",
            body: "### Antwort Symphony\n\n[Session thread-idle]\n\nDone",
            created_at: ~U[2026-05-21 09:55:00Z],
            updated_at: ~U[2026-05-21 09:55:00Z]
          }
        ]
      })

      parent = self()
      orchestrator_name = Module.concat(__MODULE__, :DialogIdlePollOrchestrator)

      with_orchestrator(
        [
          name: orchestrator_name,
          initial_poll?: false,
          idle_shutdown_ms: 1,
          output_fun: fn message -> send(parent, {:orchestrator_output, message}) end,
          shutdown_fun: fn -> send(parent, :shutdown_called) end
        ],
        fn pid ->
          now_ms = System.monotonic_time(:millisecond)

          :sys.replace_state(pid, fn state ->
            issue
            |> Orchestrator.observe_dialog_full_check_for_test(state, now_ms)
            |> Map.put(:last_activity_at_ms, now_ms - 10_000)
            |> Map.put(:completed_states, %{issue_id => {"todo (dialog-ai)", DateTime.to_iso8601(completed_at)}})
          end)

          send(pid, :tick)

          assert_receive {:orchestrator_output, "Symphony nach Inaktivität beendet"}, 1_000
          assert_receive :shutdown_called, 1_000

          refute Process.whereis(Orchestrator)

          if is_pid(application_orchestrator) do
            refute Process.alive?(application_orchestrator)
            # A late poll from the application must not reach the current fixture.
            send(application_orchestrator, :run_poll_cycle)
          end

          refute_receive {:memory_tracker_fetch_issue_comments, ^issue_id}, 100

          state = orchestrator_state(pid)
          refute Map.has_key?(state.running, issue_id)
          refute MapSet.member?(state.claimed, issue_id)
          assert state.last_activity_at_ms == now_ms - 10_000
          assert state.shutdown_requested
        end
      )
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  for outcome <- [:return, :raise] do
    test "dialog fixture stops its orchestrator and worker before data restoration on #{outcome}" do
      write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
      parent = self()

      run_fixture = fn ->
        with_orchestrator([name: nil, initial_poll?: false], fn pid ->
          {:ok, worker} =
            Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
              receive do
                :stop -> :ok
              end
            end)

          # Ensure a broken cleanup cannot leak the regression's worker itself.
          on_exit(fn ->
            Process.exit(worker, :kill)
            if Process.alive?(pid), do: GenServer.stop(pid)
          end)

          :sys.replace_state(pid, fn state ->
            %{state | running: %{"fixture-worker" => %{pid: worker, ref: Process.monitor(worker)}}}
          end)

          send(parent, {:fixture_processes, pid, Process.monitor(pid), worker, Process.monitor(worker)})

          case unquote(outcome) do
            :return -> :ok
            :raise -> flunk("fixture assertion")
          end
        end)
      end

      case unquote(outcome) do
        :return -> assert :ok = run_fixture.()
        :raise -> assert_raise ExUnit.AssertionError, ~r/fixture assertion/, run_fixture
      end

      assert_receive {:fixture_processes, pid, ref, worker, worker_ref}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
      refute Process.alive?(pid)
      refute Process.alive?(worker)

      # Publish the next fixture only after both monitored processes are down.
      issue_id = "issue-dialog-after-cleanup"
      issue = %Issue{id: issue_id, identifier: "MT-AFTER-CLEANUP", state: "Todo (Dialog-AI)"}
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      send(pid, :run_poll_cycle)
      refute_receive {:memory_tracker_fetch_issue_comments, ^issue_id}, 100
    end
  end

  test "changed dialog comment signal dispatches despite unchanged issue timestamp" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dialog-comment-signal-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      issue_id = "issue-dialog-comment-signal"
      completed_at = ~U[2026-05-21 09:50:44Z]

      answer_signal = %{
        id: "comment-answer",
        created_at: ~U[2026-05-21 09:55:00Z],
        updated_at: ~U[2026-05-21 09:55:00Z]
      }

      issue = %Issue{
        id: issue_id,
        identifier: "MT-DIALOG-SIGNAL",
        title: "Dialog with new comment",
        description: "A new comment should dispatch",
        state: "Todo (Dialog-AI)",
        url: "https://example.org/issues/MT-DIALOG-SIGNAL",
        updated_at: completed_at,
        labels: []
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(test_root, "worktrees"),
        codex_command: "sh -lc 'sleep 60'",
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [
          %{id: "comment-user-old", body: "Old question", created_at: ~U[2026-05-21 09:54:00Z]},
          %{
            id: "comment-answer",
            body: "### Antwort Symphony\n\n[Session thread-existing]\n\nDone",
            created_at: ~U[2026-05-21 09:55:00Z],
            updated_at: ~U[2026-05-21 09:55:00Z]
          },
          %{
            id: "comment-user-new",
            body: "Follow-up without issue updatedAt changing",
            created_at: ~U[2026-05-21 10:00:00Z],
            updated_at: ~U[2026-05-21 10:00:00Z]
          }
        ]
      })

      orchestrator_name = Module.concat(__MODULE__, :DialogChangedSignalOrchestrator)

      with_orchestrator([name: orchestrator_name, initial_poll?: false], fn pid ->
        observed_issue = %{issue | last_comment_signal: answer_signal}
        now_ms = System.monotonic_time(:millisecond)

        :sys.replace_state(pid, fn state ->
          observed_issue
          |> Orchestrator.observe_dialog_full_check_for_test(state, now_ms)
          |> Map.put(:completed_states, %{issue_id => {"todo (dialog-ai)", DateTime.to_iso8601(completed_at)}})
        end)

        send(pid, :tick)

        assert_receive {:memory_tracker_fetch_issue_comments, ^issue_id}, 1_000

        running_entry =
          Enum.find_value(1..20, fn _attempt ->
            Process.sleep(50)
            orchestrator_state(pid).running[issue_id]
          end)

        assert %{run_mode: :dialog, issue: %Issue{updated_at: ^completed_at}} = running_entry
        assert running_entry.issue.last_comment_signal.id == "comment-user-new"
        refute_receive {:memory_tracker_fetch_issue_comments, ^issue_id}, 100
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "dialog safety fallback dispatches when lightweight signal is missing and unchanged" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dialog-safety-fallback-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      issue_id = "issue-dialog-safety-fallback"

      issue = %Issue{
        id: issue_id,
        identifier: "MT-DIALOG-SAFETY",
        title: "Dialog with missing comment signal",
        description: "Safety fallback should find a request",
        state: "Todo (Dialog-AI)",
        url: "https://example.org/issues/MT-DIALOG-SAFETY",
        last_comment_signal: %{},
        labels: []
      }

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(test_root, "worktrees"),
        codex_command: "sh -lc 'sleep 60'",
        poll_interval_ms: 30_000
      )

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue_id => [
          %{
            id: "comment-safety-answer",
            body: "### Antwort Symphony\n\n[Session thread-safety]\n\nPrevious answer",
            created_at: ~U[2026-05-21 09:55:00Z],
            updated_at: ~U[2026-05-21 09:55:00Z]
          },
          %{
            id: "comment-safety-user",
            body: "Safety-discovered request",
            created_at: ~U[2026-05-21 10:00:00Z],
            updated_at: ~U[2026-05-21 10:00:00Z]
          }
        ]
      })

      orchestrator_name = Module.concat(__MODULE__, :DialogSafetyFallbackOrchestrator)

      with_orchestrator(
        [name: orchestrator_name, initial_poll?: false, active_instance_count_fun: fn -> 1 end],
        fn pid ->
          now_ms = System.monotonic_time(:millisecond)

          :sys.replace_state(pid, fn state ->
            Orchestrator.observe_dialog_full_check_for_test(issue, state, now_ms - 31_000)
          end)

          send(pid, :tick)

          assert_receive {:memory_tracker_fetch_issue_comments, ^issue_id}, 1_000

          running_entry =
            Enum.find_value(1..20, fn _attempt ->
              Process.sleep(50)
              orchestrator_state(pid).running[issue_id]
            end)

          assert %{run_mode: :dialog} = running_entry
          refute_receive {:memory_tracker_fetch_issue_comments, ^issue_id}, 100
        end
      )
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      File.rm_rf(test_root)
    end
  end

  test "dialog safety interval scales by open dialog issues and active instances" do
    state = %Orchestrator.State{
      active_instance_count_fun: fn -> 3 end
    }

    assert Orchestrator.dialog_safety_full_check_interval_ms_for_test(state, 3) == 270_000
    assert Orchestrator.dialog_safety_full_check_interval_ms_for_test(state, 0) == 90_000
  end

  test "failed dialog safety full check is throttled only for unchanged or missing signals" do
    now_ms = System.monotonic_time(:millisecond)
    issue_id = "issue-dialog-failed-safety"
    checked_at_ms = now_ms - 31_000
    old_key = {"comment-old", "2026-05-21T09:55:00Z", "2026-05-21T09:55:00Z"}

    unchanged_issue = %Issue{
      id: issue_id,
      identifier: "MT-DIALOG-FAILED-SAFETY",
      title: "Dialog failed safety",
      state: "Todo (Dialog-AI)",
      last_comment_signal: %{
        id: "comment-old",
        created_at: ~U[2026-05-21 09:55:00Z],
        updated_at: ~U[2026-05-21 09:55:00Z]
      }
    }

    state = %Orchestrator.State{
      dialog_observations: %{
        issue_id => %{
          comment_key: old_key,
          last_full_check_at_ms: checked_at_ms
        }
      }
    }

    throttled_state =
      Orchestrator.observe_dialog_failed_full_check_for_test(unchanged_issue, state, now_ms)

    assert %{
             comment_key: ^old_key,
             last_full_check_at_ms: ^now_ms
           } = throttled_state.dialog_observations[issue_id]

    refute Orchestrator.should_dispatch_issue_for_test(unchanged_issue, throttled_state)

    changed_issue = %{
      unchanged_issue
      | last_comment_signal: %{
          id: "comment-new",
          created_at: ~U[2026-05-21 10:00:00Z],
          updated_at: ~U[2026-05-21 10:00:00Z]
        }
    }

    unchanged_failed_state =
      Orchestrator.observe_dialog_failed_full_check_for_test(changed_issue, state, now_ms)

    assert %{
             comment_key: ^old_key,
             last_full_check_at_ms: ^checked_at_ms
           } = unchanged_failed_state.dialog_observations[issue_id]

    assert Orchestrator.should_dispatch_issue_for_test(changed_issue, unchanged_failed_state)

    missing_signal_issue = %{unchanged_issue | id: "issue-dialog-missing-signal", last_comment_signal: nil}

    missing_signal_state =
      Orchestrator.observe_dialog_failed_full_check_for_test(
        missing_signal_issue,
        %Orchestrator.State{},
        now_ms
      )

    assert %{
             comment_key: :missing,
             last_full_check_at_ms: ^now_ms
           } = missing_signal_state.dialog_observations[missing_signal_issue.id]

    refute Orchestrator.should_dispatch_issue_for_test(missing_signal_issue, missing_signal_state)
  end

  test "dialog prompt full check observes signal only after accepted dispatch" do
    now_ms = System.monotonic_time(:millisecond)
    issue_id = "issue-dialog-observe-dispatch"

    issue = %Issue{
      id: issue_id,
      identifier: "MT-DIALOG-OBSERVE",
      title: "Dialog observation",
      state: "Todo (Dialog-AI)",
      last_comment_signal: %{
        id: "comment-user",
        created_at: ~U[2026-05-21 10:00:00Z],
        updated_at: ~U[2026-05-21 10:00:00Z]
      }
    }

    state_before_dispatch = %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      retry_attempts: %{},
      dialog_observations: %{}
    }

    skipped_state =
      Orchestrator.observe_dialog_dispatch_result_for_test(
        issue,
        state_before_dispatch,
        state_before_dispatch,
        now_ms
      )

    refute Map.has_key?(skipped_state.dialog_observations, issue_id)

    running_state = %{
      state_before_dispatch
      | running: %{issue_id => %{run_mode: :dialog}}
    }

    observed_running_state =
      Orchestrator.observe_dialog_dispatch_result_for_test(
        issue,
        state_before_dispatch,
        running_state,
        now_ms
      )

    assert %{
             comment_key: {"comment-user", "2026-05-21T10:00:00Z", "2026-05-21T10:00:00Z"},
             last_full_check_at_ms: ^now_ms
           } = observed_running_state.dialog_observations[issue_id]

    retry_state = %{
      state_before_dispatch
      | retry_attempts: %{issue_id => %{attempt: 1, identifier: "MT-DIALOG-OBSERVE"}}
    }

    observed_retry_state =
      Orchestrator.observe_dialog_dispatch_result_for_test(
        issue,
        state_before_dispatch,
        retry_state,
        now_ms
      )

    assert %{
             comment_key: {"comment-user", "2026-05-21T10:00:00Z", "2026-05-21T10:00:00Z"},
             last_full_check_at_ms: ^now_ms
           } = observed_retry_state.dialog_observations[issue_id]
  end

  test "orchestrator ignores manual Todo without recording bootstrap completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-todo-noop-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      issue_id = "issue-todo-orchestrator"

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: Path.join(test_root, "worktrees"),
        tracker_active_states: ["Todo (AI)", "In Arbeit (AI)", "Review (AI)"],
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: "MT-TODO-ORCH",
        title: "Manual Todo",
        description: "Wait for a human move into Todo (AI)",
        state: "Todo",
        url: "https://example.org/issues/MT-TODO-ORCH",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :TodoNoopOrchestrator)

      {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end
      end)

      send(pid, :tick)
      Process.sleep(150)

      state = :sys.get_state(pid)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
      refute Map.has_key?(state.running, issue_id)
      refute MapSet.member?(state.claimed, issue_id)
      refute Map.has_key?(state.completed_states, issue_id)
      refute_receive {:memory_tracker_branch_update, ^issue_id, _branch}, 100
      refute_receive {:memory_tracker_comment, ^issue_id, _body}, 100
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "candidate dispatch skips issues while a retry timer is pending" do
    issue = %Issue{
      id: "issue-pending-retry",
      identifier: "MT-PENDING-RETRY",
      title: "Pending retry",
      state: "In Arbeit (AI)"
    }

    state = %Orchestrator.State{
      max_concurrent_agents: 1,
      running: %{},
      claimed: MapSet.new(),
      completed_states: %{},
      retry_attempts: %{}
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)

    state_with_pending_retry = %{
      state
      | retry_attempts: %{
          issue.id => %{
            attempt: 2,
            due_at_ms: System.monotonic_time(:millisecond) + 20_000,
            identifier: issue.identifier
          }
        }
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state_with_pending_retry)
  end

  defp assert_due_in_range(due_at_ms, trigger_ms, min_delay_ms, max_delay_ms) do
    scheduled_delay_ms = due_at_ms - trigger_ms

    assert scheduled_delay_ms >= min_delay_ms
    assert scheduled_delay_ms <= max_delay_ms
  end

  defp assert_due_after_observation(
         due_at_ms,
         trigger_ms,
         observed_ms,
         min_total_delay_ms,
         max_remaining_delay_ms
       ) do
    total_delay_ms = due_at_ms - trigger_ms
    remaining_delay_ms = due_at_ms - observed_ms

    assert total_delay_ms >= min_total_delay_ms
    assert remaining_delay_ms >= 0
    assert remaining_delay_ms <= max_remaining_delay_ms
  end

  defp orchestrator_state(pid) when is_pid(pid) do
    :sys.get_state(pid, 15_000)
  end

  defp with_orchestrator(opts, fun) do
    {:ok, pid} = Orchestrator.start_link(opts)

    try do
      fun.(pid)
    after
      stop_orchestrator_and_workers(pid)
    end
  end

  defp stop_orchestrator_and_workers(pid, stop_fun \\ &GenServer.stop(&1, :normal, 1_000)) when is_pid(pid) do
    if Process.alive?(pid) do
      # Freeze dispatch before taking the worker snapshot. Stop the orchestrator
      # first so worker exits cannot schedule retries or launch replacement work.
      :ok = :sys.suspend(pid)
      running = orchestrator_state(pid).running
      :ok = stop_fun.(pid)

      Enum.each(running, fn
        {_issue_id, %{pid: worker_pid}} when is_pid(worker_pid) ->
          ref = Process.monitor(worker_pid)
          Process.exit(worker_pid, :kill)
          assert_receive {:DOWN, ^ref, :process, ^worker_pid, _reason}, 1_000

        _entry ->
          :ok
      end)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)

  defp assert_file_exists_eventually!(path, attempts \\ 100)

  defp assert_file_exists_eventually!(path, attempts) when attempts > 0 do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(50)
      assert_file_exists_eventually!(path, attempts - 1)
    end
  end

  defp assert_file_exists_eventually!(path, 0), do: flunk("expected file to exist: #{path}")

  defp no_findings_review_workpad do
    """
    ## Symphony Workpad

    ### Review

    - [x] Review (AI) Einstieg: Pull und Snapshot geprüft
    - [x] Review (AI) read-only Subagent: Keine Findings.
    """
  end

  defp write_successful_fake_codex!(codex_binary, stamp_path)
       when is_binary(codex_binary) and is_binary(stamp_path) do
    File.mkdir_p!(Path.dirname(codex_binary))

    File.write!(codex_binary, """
    #!/bin/sh
    touch #{stamp_path}
    count=0

    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-success"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-success"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)
  end

  defp review_handoff_test_recipient(parent, state_agent)
       when is_pid(parent) and is_pid(state_agent) do
    receive do
      {:memory_tracker_state_update, _issue_id, state_name} = message ->
        Agent.update(state_agent, fn _ -> state_name end)
        send(parent, message)
        review_handoff_test_recipient(parent, state_agent)

      {:agent_completion_contract, _issue_id, _contract} = message ->
        send(parent, message)
        review_handoff_test_recipient(parent, state_agent)

      _other ->
        review_handoff_test_recipient(parent, state_agent)
    end
  end

  test "fetch issues by states with empty state set is a no-op" do
    assert {:ok, []} = Client.fetch_issues_by_states([])
  end

  test "linear candidate polling includes manual approval states for skip labels outside yolo" do
    previous_request_fun = Application.get_env(:symphony_elixir, :linear_client_request_fun)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)
    parent = self()

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_active_states: ["Todo (AI)", "Review (AI)"],
        tracker_assignee: "dev@example.com"
      )

      Application.put_env(:symphony_elixir, :yolo, false)

      SymphonyElixir.TestSupport.stub_linear_client(fn payload, headers ->
        send(parent, {:linear_request, payload, headers})

        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "issues" => %{
                 "nodes" => [],
                 "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
               }
             }
           }
         }}
      end)

      assert {:ok, []} = Client.fetch_candidate_issues()
      assert_receive {:linear_request, %{"variables" => %{stateNames: state_names}}, headers}
      assert {"Authorization", "Bearer synthetic-app-token"} in headers

      assert MapSet.subset?(
               MapSet.new(["Todo (AI)", "Review (AI)", "In Arbeit", "Freigabe Implementierung", "Freigabe Review"]),
               MapSet.new(state_names)
             )
    after
      restore_app_env(:linear_client_request_fun, previous_request_fun)
      restore_app_env(:yolo, previous_yolo)
    end
  end

  test "prompt builder renders issue and attempt values from workflow template" do
    workflow_prompt = "Ticket {{ issue.identifier }} {{ issue.title }} labels={{ issue.labels }} attempt={{ attempt }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "S-1",
      title: "Refactor backend request path",
      description: "Replace transport layer",
      state: "Todo",
      url: "https://example.org/issues/S-1",
      labels: ["backend"]
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 3)

    assert prompt =~ "Ticket S-1 Refactor backend request path"
    assert prompt =~ "labels=backend"
    assert prompt =~ "attempt=3"
  end

  test "prompt builder appends recovered continuation context when present" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        Bitte starte den Review-Subagenten nicht sofort erneut.
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701B",
      title: "Recovered review continuation",
      description: "Prompt should include recovered subagent context",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701B",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "Findings:\n- High: Example finding."
      )

    assert prompt =~ "Ticket MT-701B"
    assert prompt =~ "Wiederverwendeter Kontext aus dem Workflow:"
    assert prompt =~ "Bitte starte den Review-Subagenten nicht sofort erneut."
    assert prompt =~ "Findings:\n- High: Example finding."
  end

  test "prompt builder appends recovered no-findings continuation context in Review (AI)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701E",
      title: "Recovered review no-findings continuation",
      description: "Prompt should include explicit no-findings recovery context",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701E",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "Keine Findings.\nRestrisiko: keine."
      )

    assert prompt =~ "Ticket MT-701E"
    assert prompt =~ "Wiederverwendeter Kontext aus dem Workflow:"
    assert prompt =~ "Keine Findings.\nRestrisiko: keine."
  end

  test "prompt builder normalizes markdown findings and english no-findings review context" do
    assert PromptBuilder.normalize_recovered_review_context("**Findings**\n- High: Example finding.") ==
             "Findings:\n- High: Example finding."

    assert PromptBuilder.normalize_recovered_review_context(
             "- Medium `lib/symphony_elixir/agent_runner.ex:218-247` Example finding.\n\n- Low `lib/symphony_elixir/agent_runner.ex:576-593` Another finding."
           ) ==
             "Findings:\n- Medium `lib/symphony_elixir/agent_runner.ex:218-247` Example finding.\n\n- Low `lib/symphony_elixir/agent_runner.ex:576-593` Another finding."

    assert PromptBuilder.normalize_recovered_review_context("No findings.\nResidual risk: none.") == "Keine Findings.\nResidual risk: none."

    assert PromptBuilder.normalize_recovered_review_context("No concrete findings in the scoped diff. I also ran `mix test`, and it passed.") ==
             "Keine Findings.\nin the scoped diff. I also ran `mix test`, and it passed."
  end

  test "prompt builder normalizes exact findings and no-findings variants and rejects invalid values" do
    assert PromptBuilder.normalize_recovered_review_context("Findings:") == "Findings:"
    assert PromptBuilder.normalize_recovered_review_context("No findings.") == "Keine Findings."
    assert PromptBuilder.normalize_recovered_review_context("   \n") == nil
    assert PromptBuilder.normalize_recovered_review_context("Subagent still running") == nil
    assert PromptBuilder.normalize_recovered_review_context(123) == nil
  end

  test "prompt builder appends recovered running review subagent ids in Review (AI)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        """,
        "recovered_review_subagent_wait" => """
        Wiederhergestellter Review-Subagent-Status:
        {{ agent_ids_text }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701E2",
      title: "Recovered running review subagent",
      description: "Prompt should include known running review subagent ids",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701E2",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_review_subagent_ids: ["agent-review-2", "agent-review-1"]
      )

    assert prompt =~ "Ticket MT-701E2"
    assert prompt =~ "Wiederhergestellter Review-Subagent-Status:"
    assert prompt =~ "agent-review-1"
    assert prompt =~ "agent-review-2"
  end

  test "prompt builder appends recovered running review subagent ids from a MapSet" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => "{{ context }}",
        "recovered_review_subagent_wait" => """
        Laufende Review-Subagenten:
        {{ agent_ids_text }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701E3",
      title: "Recovered running review subagent mapset",
      description: "Prompt should include known running review subagent ids from a MapSet",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701E3",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_review_subagent_ids: MapSet.new(["agent-review-b", "agent-review-a"])
      )

    assert prompt =~ "Laufende Review-Subagenten:"
    assert prompt =~ "agent-review-a"
    assert prompt =~ "agent-review-b"
  end

  test "prompt builder prefers recovered completion context over running review subagent wait hints" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Abschluss:
        {{ context }}
        """,
        "recovered_review_subagent_wait" => """
        Laufende Review-Subagenten:
        {{ agent_ids_text }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701E4",
      title: "Recovered review completion wins",
      description: "Prompt should not append running subagent wait hints once a completion exists",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701E4",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "Findings:\n- High: Example finding.",
        recovered_review_subagent_ids: ["agent-review-1"]
      )

    assert prompt =~ "Abschluss:"
    assert prompt =~ "Findings:\n- High: Example finding."
    refute prompt =~ "Laufende Review-Subagenten:"
  end

  test "prompt builder ignores invalid recovered running review subagent ids" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => "{{ context }}",
        "recovered_review_subagent_wait" => """
        Laufende Review-Subagenten:
        {{ agent_ids_text }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701E5",
      title: "Recovered running review subagent invalid ids",
      description: "Prompt should ignore blank and non-binary review subagent ids",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701E5",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_review_subagent_ids: ["", "  ", nil]
      )

    assert prompt == "Ticket MT-701E5"
  end

  test "prompt builder ignores recovered running review subagent ids outside Review (AI) and without state" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => "{{ context }}",
        "recovered_review_subagent_wait" => """
        Laufende Review-Subagenten:
        {{ agent_ids_text }}
        """
      }
    )

    non_review_issue = %Issue{
      identifier: "MT-701E6",
      title: "Recovered running review subagent outside review",
      description: "Prompt should ignore running review subagent ids outside review",
      state: "In Arbeit (AI)",
      url: "https://example.org/issues/MT-701E6",
      labels: []
    }

    missing_state_issue = %Issue{
      identifier: "MT-701E7",
      title: "Recovered running review subagent without state",
      description: "Prompt should ignore running review subagent ids without a state",
      state: nil,
      url: "https://example.org/issues/MT-701E7",
      labels: []
    }

    assert PromptBuilder.build_prompt(
             non_review_issue,
             recovered_review_subagent_ids: ["agent-review-1"]
           ) == "Ticket MT-701E6"

    assert PromptBuilder.build_prompt(
             missing_state_issue,
             recovered_review_subagent_ids: ["agent-review-1"]
           ) == "Ticket MT-701E7"
  end

  test "prompt builder ignores recovered continuation context outside Review (AI)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701D",
      title: "Recovered review continuation outside review",
      description: "Prompt should ignore recovered subagent context outside Review (AI)",
      state: "In Arbeit (AI)",
      url: "https://example.org/issues/MT-701D",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "Findings:\n- High: Example finding."
      )

    assert prompt == "Ticket MT-701D"
  end

  test "prompt builder ignores invalid recovered continuation context in Review (AI)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701F",
      title: "Invalid recovered review continuation",
      description: "Prompt should ignore invalid recovered subagent context",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701F",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: 123
      )

    assert prompt == "Ticket MT-701F"
  end

  test "prompt builder preserves raw recovered continuation context in Review (AI)" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701H",
      title: "Raw recovered review continuation text",
      description: "Prompt should keep binary recovered subagent context even without explicit review prefixes",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701H",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "Subagent timed out without final result"
      )

    assert prompt =~ "Ticket MT-701H"
    assert prompt =~ "Subagent timed out without final result"
  end

  test "prompt builder ignores recovered continuation context when issue state is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "recovered_turn_context" => """
        Wiederverwendeter Kontext aus dem Workflow:
        {{ context }}
        """
      }
    )

    issue = %Issue{
      identifier: "MT-701G",
      title: "Recovered review continuation without state",
      description: "Prompt should ignore recovered context when state is unavailable",
      state: nil,
      url: "https://example.org/issues/MT-701G",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "Findings:\n- High: Example finding."
      )

    assert prompt == "Ticket MT-701G"
  end

  test "workflow prompt snippets must be defined in WORKFLOW.md" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{}
    )

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippets_missing: snippet="recovered_turn_context"/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings:\n- High: Missing snippet."})
                 end
  end

  test "workflow prompt snippet accepts atom names and renders workflow values" do
    snippet =
      Workflow.prompt_snippet(:continuation_guidance, %{
        continuation_intro: "Fortsetzen",
        turn_number: 2,
        max_turns: 5,
        issue_state: "Review (AI)"
      })

    assert snippet =~ "Fortsetzen"
    assert snippet =~ "Fortsetzungs-Turn #2 von 5"
    assert snippet =~ "Der aktuelle Tracker-Status ist \"Review (AI)\"."

    incomplete_intro =
      Workflow.prompt_snippet(:continuation_intro_incomplete_phase, %{
        reason: "offene Workpad-Checkliste Review"
      })

    assert incomplete_intro =~ "offene Workpad-Checkliste Review"
    assert incomplete_intro =~ "unvollständigen Phasenabschluss"
  end

  test "workflow prompt snippet raises when prompt_snippets has an invalid type" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: "ungueltig"
    )

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippets_invalid: value="ungueltig"/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings"})
                 end
  end

  test "workflow prompt snippet raises when the requested snippet key is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{"anderes_snippet" => "vorhanden"}
    )

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippet_missing: snippet="recovered_turn_context"/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings"})
                 end
  end

  test "workflow prompt snippet raises when the requested snippet is empty" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{"recovered_turn_context" => "   "}
    )

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippet_empty: snippet="recovered_turn_context"/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings"})
                 end
  end

  test "workflow prompt snippet raises when the requested snippet has an invalid value type" do
    File.write!(
      Workflow.workflow_file_path(),
      """
      ---
      prompt_snippets:
        recovered_turn_context: 123
      ---
      Ticket {{ issue.identifier }}
      """
    )

    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    {:ok, _} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert :ok = WorkflowStore.force_reload()

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippet_invalid: snippet="recovered_turn_context" value=123/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings"})
                 end
  end

  test "workflow prompt snippet raises when snippet rendering fails" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{"recovered_turn_context" => "{{ fehlende_variable }}"}
    )

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippet_parse_error:/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings"})
                 end
  end

  test "workflow prompt snippet raises when the workflow file cannot be loaded" do
    original_workflow_path = Workflow.workflow_file_path()
    missing_workflow_path = Path.join(Path.dirname(original_workflow_path), "MISSING_SNIPPET_WORKFLOW.md")

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_nil(Process.whereis(WorkflowStore)) do
        assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
      end
    end)

    if Process.whereis(WorkflowStore) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    end

    Workflow.set_workflow_file_path(missing_workflow_path)

    assert_raise RuntimeError,
                 ~r/workflow_prompt_snippet_unavailable: snippet="recovered_turn_context"/,
                 fn ->
                   Workflow.prompt_snippet("recovered_turn_context", %{context: "Findings"})
                 end
  end

  test "workflow prompt snippet serializes supported assign value types" do
    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "Ticket {{ issue.identifier }}",
      prompt_snippets: %{
        "typed_snippet" => "{{ dt }}|{{ ndt }}|{{ date }}|{{ time }}|{{ issue_value.identifier }}|{{ nested.inner }}"
      }
    )

    dt = DateTime.from_naive!(~N[2026-04-14 15:30:45], "Etc/UTC")
    ndt = ~N[2026-04-14 15:31:00]
    date = ~D[2026-04-14]
    time = ~T[15:32:10]

    issue_value = %Issue{
      identifier: "MT-TYPES",
      title: "Typed snippet",
      description: "Exercise workflow assign serialization",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-TYPES",
      labels: []
    }

    snippet =
      Workflow.prompt_snippet("typed_snippet", %{
        dt: dt,
        ndt: ndt,
        date: date,
        time: time,
        issue_value: issue_value,
        nested: %{inner: "OK"},
        values: ["eins", "zwei"]
      })

    assert snippet =~ DateTime.to_iso8601(dt)
    assert snippet =~ NaiveDateTime.to_iso8601(ndt)
    assert snippet =~ Date.to_iso8601(date)
    assert snippet =~ Time.to_iso8601(time)
    assert snippet =~ "MT-TYPES"
    assert snippet =~ "OK"
  end

  test "prompt builder ignores blank recovered continuation context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701C",
      title: "Blank recovered review continuation",
      description: "Prompt should ignore blank recovered subagent context",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-701C",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(
        issue,
        recovered_turn_context: "   \n"
      )

    assert prompt == "Ticket MT-701C"
  end

  test "prompt builder renders issue datetime fields without crashing" do
    workflow_prompt = "Ticket {{ issue.identifier }} created={{ issue.created_at }} updated={{ issue.updated_at }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    created_at = DateTime.from_naive!(~N[2026-02-26 18:06:48], "Etc/UTC")
    updated_at = DateTime.from_naive!(~N[2026-02-26 18:07:03], "Etc/UTC")

    issue = %Issue{
      identifier: "MT-697",
      title: "Live smoke",
      description: "Prompt should serialize datetimes",
      state: "Todo",
      url: "https://example.org/issues/MT-697",
      labels: [],
      created_at: created_at,
      updated_at: updated_at
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Ticket MT-697"
    assert prompt =~ "created=2026-02-26T18:06:48Z"
    assert prompt =~ "updated=2026-02-26T18:07:03Z"
  end

  test "prompt builder renders runtime local time context for workflow prompts" do
    workflow_prompt = "local={{ runtime.local_time }} tz={{ runtime.timezone }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698",
      title: "Local timestamps in workpad history",
      description: "Prompt should expose local runtime time",
      state: "Todo",
      url: "https://example.org/issues/MT-698",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert [_, local_time] = Regex.run(~r/local=([^ ]+)/, prompt)
    assert local_time =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$/
    assert prompt =~ "tz="
  end

  test "prompt builder exposes session and workflow modes" do
    workflow_prompt = "session={{ runtime.session_mode }} workflow={{ runtime.workflow_mode }} automated={{ runtime.automated }} interactive={{ runtime.interactive }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698C",
      title: "Session mode",
      description: "Expose manual and automated modes",
      state: "Planung",
      url: "https://example.org/issues/MT-698C",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) ==
             "session=orchestrated workflow=interactive automated=false interactive=true"

    assert PromptBuilder.build_prompt(issue, session_mode: :manual) ==
             "session=manual workflow=interactive automated=false interactive=true"
  end

  test "prompt builder exposes active repo and global skill roots" do
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)

    on_exit(fn ->
      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")

    workflow_prompt = "active={{ runtime.active_repo_root }} repo_skill={{ runtime.active_repo_skill_root }} source={{ runtime.source_repo_root }} globals={{ runtime.global_skill_roots_text }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698CC",
      title: "Skill roots",
      description: "Expose path guidance for skills",
      state: "In Arbeit (AI)",
      url: "https://example.org/issues/MT-698CC",
      labels: []
    }

    prompt =
      PromptBuilder.build_prompt(issue,
        active_repo_root: "/tmp/symphony-worktrees/MT-698CC",
        source_repo_root: "/tmp/symphony-source",
        workflow_file: "/tmp/symphony-source/WORKFLOW.md"
      )

    assert prompt =~ "active=/tmp/symphony-worktrees/MT-698CC"
    assert prompt =~ "repo_skill=/tmp/symphony-worktrees/MT-698CC/.codex/skills"
    assert prompt =~ "source=/tmp/symphony-source"
    assert prompt =~ "globals="
    assert prompt =~ "#{System.user_home()}/.codex/skills"

    if executable = System.find_executable("symphony") do
      assert prompt =~ Path.dirname(executable)
    else
      assert prompt =~ "/opt/symphony/bin"
    end
  end

  test "prompt builder resolves skill roots from the environment when prompt opts omit them" do
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    previous_active_repo_root = System.get_env("SYMPHONY_ACTIVE_REPO_ROOT")
    previous_source_repo = System.get_env("SYMPHONY_SOURCE_REPO")
    previous_workflow_file = System.get_env("SYMPHONY_WORKFLOW_FILE")
    previous_codex_home = System.get_env("CODEX_HOME")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("SYMPHONY_ACTIVE_REPO_ROOT", previous_active_repo_root)
      restore_env("SYMPHONY_SOURCE_REPO", previous_source_repo)
      restore_env("SYMPHONY_WORKFLOW_FILE", previous_workflow_file)
      restore_env("CODEX_HOME", previous_codex_home)
      restore_env("PATH", previous_path)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    System.put_env("SYMPHONY_ACTIVE_REPO_ROOT", "/tmp/env-active")
    System.put_env("SYMPHONY_SOURCE_REPO", "/tmp/env-source")
    System.put_env("SYMPHONY_WORKFLOW_FILE", "/tmp/env-source/WORKFLOW.md")
    System.put_env("CODEX_HOME", "/tmp/env-codex")
    System.put_env("PATH", "/tmp/no-symphony-here")
    Application.put_env(:symphony_elixir, :escript_script_name, "/opt/symphony/bin/symphony")

    workflow_prompt =
      "active={{ runtime.active_repo_root }} source={{ runtime.source_repo_root }} workflow={{ runtime.workflow_file }} exec={{ runtime.symphony_executable_dir }} codex={{ runtime.codex_home }} globals={{ runtime.global_skill_roots_text }}"

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698CD",
      title: "Skill roots from env",
      description: "Prompt should honor environment-based path hints",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-698CD",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "active=/tmp/env-active"
    assert prompt =~ "source=/tmp/env-source"
    assert prompt =~ "workflow=/tmp/env-source/WORKFLOW.md"
    assert prompt =~ "exec=/opt/symphony/bin"
    assert prompt =~ "codex=/tmp/env-codex"
    assert prompt =~ "globals=/tmp/env-codex/skills, /opt/symphony/bin"
  end

  test "prompt builder leaves the executable dir blank when Symphony is not detectable" do
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    System.put_env("PATH", "/tmp/no-symphony-here")
    Application.delete_env(:symphony_elixir, :escript_script_name)

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "exec={{ runtime.symphony_executable_dir }}")

    issue = %Issue{
      identifier: "MT-698CE",
      title: "Missing symphony executable",
      description: "Prompt should keep the field blank when unavailable",
      state: "Review",
      url: "https://example.org/issues/MT-698CE",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "exec="
  end

  test "prompt builder prefers the detected symphony executable from PATH" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-prompt-builder-exec-#{System.unique_integer([:positive])}"
      )

    bin_dir = Path.join(test_root, "bin")
    fake_symphony = Path.join(bin_dir, "symphony")
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end

      File.rm_rf(test_root)
    end)

    File.mkdir_p!(bin_dir)
    File.write!(fake_symphony, "#!/bin/sh\n")
    File.chmod!(fake_symphony, 0o755)
    System.put_env("PATH", bin_dir)
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/fallback/symphony")

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "exec={{ runtime.symphony_executable_dir }}")

    issue = %Issue{
      identifier: "MT-698CE1",
      title: "Detected symphony executable",
      description: "Prompt should use the executable found on PATH",
      state: "Review",
      url: "https://example.org/issues/MT-698CE1",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "exec=#{bin_dir}"
  end

  test "prompt builder trims blank env paths and falls back from missing HOME to the escript path" do
    original_script_name = Application.get_env(:symphony_elixir, :escript_script_name)
    original_prompt_builder_user_home = Application.get_env(:symphony_elixir, :prompt_builder_user_home)
    previous_active_repo_root = System.get_env("SYMPHONY_ACTIVE_REPO_ROOT")
    previous_codex_home = System.get_env("CODEX_HOME")
    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("SYMPHONY_ACTIVE_REPO_ROOT", previous_active_repo_root)
      restore_env("CODEX_HOME", previous_codex_home)
      restore_env("PATH", previous_path)

      if is_nil(original_prompt_builder_user_home) do
        Application.delete_env(:symphony_elixir, :prompt_builder_user_home)
      else
        Application.put_env(:symphony_elixir, :prompt_builder_user_home, original_prompt_builder_user_home)
      end

      if is_nil(original_script_name) do
        Application.delete_env(:symphony_elixir, :escript_script_name)
      else
        Application.put_env(:symphony_elixir, :escript_script_name, original_script_name)
      end
    end)

    System.put_env("SYMPHONY_ACTIVE_REPO_ROOT", "   ")
    System.delete_env("CODEX_HOME")
    System.put_env("PATH", "/tmp/no-symphony-here")
    Application.put_env(:symphony_elixir, :escript_script_name, ~c"/opt/symphony/bin/symphony")
    Application.put_env(:symphony_elixir, :prompt_builder_user_home, nil)

    write_workflow_file!(Workflow.workflow_file_path(),
      prompt: "active={{ runtime.active_repo_root }} exec={{ runtime.symphony_executable_dir }} globals={{ runtime.global_skill_roots_text }}"
    )

    issue = %Issue{
      identifier: "MT-698CF",
      title: "Blank path envs",
      description: "Fallback path handling should stay deterministic",
      state: "Planung (AI)",
      url: "https://example.org/issues/MT-698CF",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, source_repo_root: "/tmp/fallback-source")

    assert prompt =~ "active=/tmp/fallback-source"
    assert prompt =~ "exec=/opt/symphony/bin"
    assert prompt =~ "globals=/opt/symphony/bin"
  end

  test "prompt builder treats Planung as interactive in orchestrated and manual sessions" do
    workflow_prompt = "{% if runtime.automated %}AUTO{% else %}INTERACTIVE{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-698D",
      title: "Planung bootstrap",
      description: "Session mode changes behavior",
      state: "Planung",
      url: "https://example.org/issues/MT-698D",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "INTERACTIVE"
    assert PromptBuilder.build_prompt(issue, session_mode: :manual) == "INTERACTIVE"
  end

  test "prompt builder keeps AI states automated in manual sessions and falls back to orchestrated for unknown session modes" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{{ runtime.session_mode }} {{ runtime.workflow_mode }}")

    issue = %Issue{
      identifier: "MT-698DA",
      title: "AI state automation",
      description: "AI statuses stay automated",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-698DA",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue, session_mode: :manual) == "manual automated"
    assert PromptBuilder.build_prompt(issue, session_mode: :unexpected) == "orchestrated automated"
  end

  test "prompt builder treats missing issue states as interactive" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{{ runtime.workflow_mode }}")

    issue = %Issue{
      identifier: "MT-698DB",
      title: "Missing state",
      description: "Nil state should not force automation",
      state: nil,
      url: "https://example.org/issues/MT-698DB",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "interactive"
  end

  test "prompt builder can resolve an issue by identifier for manual sessions" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      prompt: "{{ issue.identifier }} {{ runtime.session_mode }} {{ runtime.workflow_mode }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698e",
        identifier: "MT-698E",
        title: "Resolve by identifier",
        description: "Manual prompt lookup",
        state: "Planung",
        url: "https://example.org/issues/MT-698E",
        labels: []
      }
    ])

    assert {:ok, "MT-698E orchestrated interactive"} = PromptBuilder.build_prompt_for_issue_identifier("MT-698E")

    assert {:ok, "MT-698E manual interactive"} = PromptBuilder.build_prompt_for_issue_identifier("MT-698E", session_mode: :manual)

    assert {:error, {:issue_not_found, "MISSING-1"}} = PromptBuilder.build_prompt_for_issue_identifier("MISSING-1", session_mode: :manual)
  end

  test "script support loads env files from .symphony under the project root for manual prompts" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    project_root = Path.join(System.tmp_dir!(), "sym-codex-project-root-#{System.unique_integer([:positive])}")
    interactive_workflow_path = Path.join(project_root, "WORKFLOW_INTERACTIVE.md")

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(project_root)
    File.mkdir_p!(Path.join(project_root, ".symphony"))
    File.write!(Path.join(project_root, ".symphony/.env"), "LINEAR_API_KEY=project-root-key\n")
    File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")
    System.put_env("LINEAR_API_KEY", "inherited-shell-key")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: "$LINEAR_API_KEY",
      prompt: "{{ issue.identifier }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698f",
        identifier: "MT-698F",
        title: "External env directory",
        description: "Manual prompt should load env files from .symphony",
        state: "Planung",
        url: "https://example.org/issues/MT-698F",
        labels: []
      }
    ])

    assert {:ok, "interactive=MT-698F"} =
             ScriptSupport.manual_prompt(
               Workflow.workflow_file_path(),
               interactive_workflow_path,
               "MT-698F",
               project_root
             )

    refute Map.has_key?(Config.settings!().tracker, :api_key)
  end

  test "script support exposes the workflow step alongside the manual prompt context" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    project_root = Path.join(System.tmp_dir!(), "sym-codex-prompt-context-#{System.unique_integer([:positive])}")
    interactive_workflow_path = Path.join(project_root, "WORKFLOW_INTERACTIVE.md")

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(Path.join(project_root, ".symphony"))
    File.write!(interactive_workflow_path, "---\n---\ninteractive={{ issue.identifier }}\n")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      prompt: "{{ issue.identifier }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698fa",
        identifier: "MT-698FA",
        title: "Manual prompt context",
        description: "Workflow step should be exposed",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-698FA",
        labels: []
      }
    ])

    assert {:ok, %{prompt: "interactive=MT-698FA", workflow_step: "Review (AI)"}} =
             ScriptSupport.manual_prompt_context(
               Workflow.workflow_file_path(),
               interactive_workflow_path,
               "MT-698FA",
               project_root
             )
  end

  test "script support resolves workspace root after loading project .symphony env files" do
    previous_custom_root = System.get_env("SYMP_SCRIPT_WORKSPACE_ROOT")

    project_root = Path.join(System.tmp_dir!(), "sym-codex-workspace-root-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_env("SYMP_SCRIPT_WORKSPACE_ROOT", previous_custom_root)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(Path.join(project_root, ".symphony"))
    File.write!(Path.join(project_root, ".symphony/.env"), "SYMP_SCRIPT_WORKSPACE_ROOT=external-worktrees\n")
    System.delete_env("SYMP_SCRIPT_WORKSPACE_ROOT")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: "$SYMP_SCRIPT_WORKSPACE_ROOT"
    )

    assert {:ok, "external-worktrees"} = ScriptSupport.workspace_root(Workflow.workflow_file_path(), project_root)
  end

  test "prompt builder uses trimmed TZ environment values in runtime context" do
    previous_tz = System.get_env("TZ")
    on_exit(fn -> restore_env("TZ", previous_tz) end)

    System.put_env("TZ", "  Europe/Paris  ")
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "tz={{ runtime.timezone }}")

    issue = %Issue{
      identifier: "MT-698A",
      title: "Trim timezone",
      description: "Prompt should trim TZ",
      state: "Todo",
      url: "https://example.org/issues/MT-698A",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "tz=Europe/Paris"
  end

  test "prompt builder falls back to system-local when TZ is blank" do
    previous_tz = System.get_env("TZ")
    on_exit(fn -> restore_env("TZ", previous_tz) end)

    System.put_env("TZ", "   ")
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "tz={{ runtime.timezone }}")

    issue = %Issue{
      identifier: "MT-698B",
      title: "Blank timezone",
      description: "Prompt should handle blank TZ",
      state: "Todo",
      url: "https://example.org/issues/MT-698B",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "tz=system-local"
  end

  test "prompt builder falls back to system-local when TZ is unset" do
    previous_tz = System.get_env("TZ")
    on_exit(fn -> restore_env("TZ", previous_tz) end)

    System.delete_env("TZ")
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "tz={{ runtime.timezone }}")

    issue = %Issue{
      identifier: "MT-698BB",
      title: "Unset timezone",
      description: "Prompt should handle missing TZ",
      state: "Todo",
      url: "https://example.org/issues/MT-698BB",
      labels: []
    }

    assert PromptBuilder.build_prompt(issue) == "tz=system-local"
  end

  test "prompt builder normalizes nested date-like values, maps, and structs in issue fields" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Ticket {{ issue.identifier }}")

    issue = %Issue{
      identifier: "MT-701",
      title: "Serialize nested values",
      description: "Prompt builder should normalize nested terms",
      state: "Todo",
      url: "https://example.org/issues/MT-701",
      labels: [
        ~N[2026-02-27 12:34:56],
        ~D[2026-02-28],
        ~T[12:34:56],
        %{phase: "test"},
        URI.parse("https://example.org/issues/MT-701")
      ]
    }

    assert PromptBuilder.build_prompt(issue) == "Ticket MT-701"
  end

  test "prompt builder uses strict variable rendering" do
    workflow_prompt = "Work on ticket {{ missing.ticket_id }} and follow these steps."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-123",
      title: "Investigate broken sync",
      description: "Reproduce and fix",
      state: "In Progress",
      url: "https://example.org/issues/MT-123",
      labels: ["bug"]
    }

    assert_raise Solid.RenderError, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder surfaces invalid template content with prompt context" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "{% if issue.identifier %}")

    issue = %Issue{
      identifier: "MT-999",
      title: "Broken prompt",
      description: "Invalid template syntax",
      state: "Todo",
      url: "https://example.org/issues/MT-999",
      labels: []
    }

    assert_raise RuntimeError, ~r/template_parse_error:.*template="/s, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "prompt builder uses a sensible default template when workflow prompt is blank" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "   \n")

    issue = %Issue{
      identifier: "MT-777",
      title: "Make fallback prompt useful",
      description: "Include enough issue context to start working.",
      state: "In Progress",
      url: "https://example.org/issues/MT-777",
      labels: ["prompt"]
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Du arbeitest an einem Linear-Ticket."
    assert prompt =~ "Identifier: MT-777"
    assert prompt =~ "Titel: Make fallback prompt useful"
    assert prompt =~ "Beschreibung:"
    assert prompt =~ "Include enough issue context to start working."
    assert Config.workflow_prompt() =~ "{{ issue.identifier }}"
    assert Config.workflow_prompt() =~ "{{ issue.title }}"
    assert Config.workflow_prompt() =~ "{{ issue.description }}"
  end

  test "prompt builder default template handles missing issue body" do
    write_workflow_file!(Workflow.workflow_file_path(), prompt: "")

    issue = %Issue{
      identifier: "MT-778",
      title: "Handle empty body",
      description: nil,
      state: "Todo",
      url: "https://example.org/issues/MT-778",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "Identifier: MT-778"
    assert prompt =~ "Titel: Handle empty body"
    assert prompt =~ "Keine Beschreibung vorhanden."
  end

  test "prompt builder reports workflow load failures separately from template parse errors" do
    original_workflow_path = Workflow.workflow_file_path()
    workflow_store_pid = Process.whereis(SymphonyElixir.WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(original_workflow_path)

      if is_pid(workflow_store_pid) and
           is_pid(Process.whereis(SymphonyElixir.Supervisor)) and
           is_nil(Process.whereis(SymphonyElixir.WorkflowStore)) do
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
      end
    end)

    if is_pid(Process.whereis(SymphonyElixir.Supervisor)) do
      assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
    end

    Workflow.set_workflow_file_path(Path.join(System.tmp_dir!(), "missing-workflow-#{System.unique_integer([:positive])}.md"))

    issue = %Issue{
      identifier: "MT-780",
      title: "Workflow unavailable",
      description: "Missing workflow file",
      state: "Todo",
      url: "https://example.org/issues/MT-780",
      labels: []
    }

    assert_raise RuntimeError, ~r/workflow_unavailable:/, fn ->
      PromptBuilder.build_prompt(issue)
    end
  end

  test "in-repo WORKFLOW.md renders correctly" do
    workflow_path = Workflow.workflow_file_path()
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md", File.cwd!()))
    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    issue = %Issue{
      identifier: "MT-616",
      title: "Use rich templates for WORKFLOW.md",
      description: "Render with rich template variables",
      state: "In Arbeit (AI)",
      url: "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd",
      labels: ["templating", "workflow"]
    }

    on_exit(fn -> Workflow.set_workflow_file_path(workflow_path) end)

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt =~
             ~r/(You are working on a Linear (ticket|issue)|Du arbeitest an einem Linear-Ticket) `MT-616`/

    assert prompt =~ ~r/(Issue context|Ticket-Kontext):/
    assert prompt =~ "Identifier: MT-616"
    assert prompt =~ ~r/(Title|Titel): Use rich templates for WORKFLOW.md/
    assert prompt =~ ~r/(Current status|Aktueller Status): In Arbeit \(AI\)/
    assert prompt =~ "https://example.org/issues/MT-616/use-rich-templates-for-workflowmd"

    assert prompt =~
             ~r/(This is an unattended orchestration session\.|Dies ist eine unbeaufsichtigte Orchestrierungssitzung\.)/

    assert prompt =~
             ~r/(Only stop early for a true blocker|Stoppe nur bei einem echten Blocker frühzeitig)/

    assert prompt =~ ~r/(Local system time for this turn|Lokale Systemzeit für diesen Turn):/
    assert prompt =~ ~r/(local system time|lokale Systemzeit)/
    assert prompt =~ ~r/(keine UTC- oder `Z`-Zeitstempel|do not use UTC or `Z` timestamps)/

    assert prompt =~ ~s("next steps for user")
    assert prompt =~ "Pfadkontext für Skills in diesem Turn:"
    assert prompt =~ "Repo-lokaler Skill-Pfad:"
    assert prompt =~ "Globale Skill-Wurzeln:"
    assert prompt =~ "globalen Skill `symphony-planning`"
    assert prompt =~ "globalen Skill `symphony-review`"
    assert prompt =~ "globalen Skill `symphony-workpad`"
    assert prompt =~ "globalen Skill `symphony-land`"
    assert prompt =~ "Freigabe Review"
    assert prompt =~ "`<Issue-Key> Review (AI) Autocommit`"
    assert prompt =~ "Den Skill `symphony-review` vollständig ausführen."
    refute prompt =~ "Review-Subagent `Findings:` liefert"
    assert prompt =~ "`gh pr merge`"
    assert prompt =~ "`<Issue-Key> Test (AI) Autocommit`"
    assert prompt =~ "`<Issue-Key> Merge (AI) Autocommit`"
    assert prompt =~ "produktverhaltensrelevanten Klärungsbedarf nach `Planung` zurückgeben"
    assert prompt =~ "Nutze das Workpad in diesem Status nur als Quelle für Fortschritts- und Review-Protokollierung."

    assert prompt =~
             "Nutze das Workpad in diesem Status für `### Test`, `### Verlauf`, Pull-Nachweise und die bereits aus früheren Phasen übernommene `### Validierung`."

    assert prompt =~ "Die dort festgehaltenen ticketseitigen Validierungsvorgaben bleiben bindend."
    assert prompt =~ "Das Workpad dient in diesem Status primär der Fortschritts- und Merge-Dokumentation."

    assert prompt =~
             "Es bleibt zulässig, dort festgehaltenen Ticketkontext, Plan-Entscheidungen und Übergabenotizen als Hintergrund für Merge- und Review-Entscheidungen zu lesen."

    assert prompt =~ "Erzeuge keine Implementierungsänderungen und nimm kein Zurückrollen bestehender Implementierung allein vor, um Details des Workpads zu erfüllen."
    assert prompt =~ ~r/(Continuation context|Fortsetzungskontext):/
    assert prompt =~ ~r/(retry attempt #2|Wiederholungsversuch Nr\. 2)/
  end

  test "in-repo WORKFLOW.md adds docs review hints only for Review (AI) when docs exist" do
    workflow_path = Workflow.workflow_file_path()
    repo_root = File.cwd!()
    no_docs_root = Path.join(System.tmp_dir!(), "prompt-builder-no-docs-#{System.unique_integer([:positive])}")
    workflow_file = Path.join(repo_root, "WORKFLOW.md")

    Workflow.set_workflow_file_path(workflow_file)

    Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    on_exit(fn ->
      Workflow.set_workflow_file_path(workflow_path)
      File.rm_rf(no_docs_root)
    end)

    File.mkdir_p!(no_docs_root)

    review_issue = %Issue{
      identifier: "MT-616R",
      title: "Review with docs hint",
      description: "Prompt should include docs-specific review guidance",
      state: "Review (AI)",
      url: "https://example.org/issues/MT-616R/review-with-docs-hint",
      labels: []
    }

    review_prompt =
      PromptBuilder.build_prompt(review_issue,
        active_repo_root: repo_root,
        source_repo_root: repo_root,
        workflow_file: workflow_file
      )

    assert review_prompt =~ "Zusätzliche Review-Hinweise:"
    assert review_prompt =~ "Das aktive Repository enthält ein `docs/`-Verzeichnis."
    assert review_prompt =~ "Dokumentationskonsistenz und mögliche Dokumentationsdrift"
    assert review_prompt =~ "Code, Workflow-/Skill-Texten und Inhalten unter `docs/`"

    in_arbeit_prompt =
      PromptBuilder.build_prompt(%{review_issue | state: "In Arbeit (AI)"},
        active_repo_root: repo_root,
        source_repo_root: repo_root,
        workflow_file: workflow_file
      )

    refute in_arbeit_prompt =~ "Zusätzliche Review-Hinweise:"

    review_prompt_without_docs =
      PromptBuilder.build_prompt(review_issue,
        active_repo_root: no_docs_root,
        source_repo_root: repo_root,
        workflow_file: workflow_file
      )

    refute review_prompt_without_docs =~ "Zusätzliche Review-Hinweise:"
  end

  test "in-repo WORKFLOW_INTERACTIVE.md renders planning and workpad skill guidance" do
    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    original_workflow_path = Workflow.workflow_file_path()
    interactive_workflow_path = Path.expand("../../WORKFLOW_INTERACTIVE.md", __DIR__)
    project_root = Path.join(System.tmp_dir!(), "interactive-workflow-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(project_root)
    end)

    File.mkdir_p!(project_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      prompt: "{{ issue.identifier }}"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [
      %Issue{
        id: "issue-698g",
        identifier: "MT-698G",
        title: "Interactive workpad skill",
        description: "Manual prompt should mention workpad handling",
        state: "Planung",
        url: "https://example.org/issues/MT-698G",
        labels: []
      }
    ])

    assert {:ok, prompt} =
             ScriptSupport.manual_prompt(
               Workflow.workflow_file_path(),
               interactive_workflow_path,
               "MT-698G",
               project_root
             )

    assert prompt =~ "symphony-linear"
    assert prompt =~ "symphony-planning"
    assert prompt =~ "symphony-workpad"
    assert prompt =~ "Aktiv bearbeitetes Repository/Worktree"
    assert prompt =~ "Repo-lokale `sym-*`-Skills"
    assert prompt =~ "Globale `symphony-*`-Skill-Wurzeln"
    assert prompt =~ "Das Ticket befindet sich im manuellen Status `Planung`"
    assert prompt =~ "an welchen Punkten die Planung noch Klärungsbedarf hat"
    assert prompt =~ "Nach Freigabe durch den Benutzer aktualisiere den finalen Plan"
    assert prompt =~ "Statuslogik"
  end

  test "prompt builder adds continuation guidance for retries" do
    workflow_prompt = "{% if attempt %}Retry #" <> "{{ attempt }}" <> "{% endif %}"
    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)

    issue = %Issue{
      identifier: "MT-201",
      title: "Continue autonomous ticket",
      description: "Retry flow",
      state: "In Progress",
      url: "https://example.org/issues/MT-201",
      labels: []
    }

    prompt = PromptBuilder.build_prompt(issue, attempt: 2)

    assert prompt == "Retry #2"
  end

  test "agent runner keeps workspace after successful codex run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-retain-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(workspace_root)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        identifier: "S-99",
        title: "Smoke test",
        description: "Run and keep workspace",
        state: "In Progress",
        url: "https://example.org/issues/S-99",
        labels: ["backend"]
      }

      before = MapSet.new(File.ls!(workspace_root))
      assert :ok = AgentRunner.run(issue)
      entries_after = MapSet.new(File.ls!(workspace_root))

      created = MapSet.difference(entries_after, before) |> Enum.filter(&(&1 == "S-99"))

      created = MapSet.new(created)

      assert MapSet.size(created) == 1
      workspace_name = created |> Enum.to_list() |> List.first()
      assert workspace_name == "S-99"

      workspace = Path.join(workspace_root, workspace_name)
      assert File.exists?(workspace)
      assert File.exists?(Path.join(workspace, "README.md"))
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner forwards timestamped codex updates to recipient" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-updates-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          case "$count" in
            1)
              printf '%s\\n' '{\"id\":1,\"result\":{}}'
              ;;
            2)
              printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-live\"}}}'
              ;;
            3)
              printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-live\"}}}'
              ;;
            4)
              printf '%s\\n' '{\"method\":\"turn/completed\"}'
              ;;
            *)
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-live-updates",
        identifier: "MT-99",
        title: "Smoke test",
        description: "Capture codex updates",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      test_pid = self()

      assert :ok =
               AgentRunner.run(
                 issue,
                 test_pid,
                 issue_state_fetcher: fn [_issue_id] -> {:ok, [%{issue | state: "Fertig"}]} end
               )

      assert_receive {:codex_worker_update, "issue-live-updates",
                      %{
                        event: :session_started,
                        timestamp: %DateTime{},
                        session_id: session_id
                      }},
                     500

      assert session_id == "thread-live-turn-live"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner ignores Planung without creating a workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      remote_repo = Path.join(test_root, "remote.git")
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["clone", remote_repo, source_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "checkout", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      File.write!(Path.join(source_repo, "README.md"), "bootstrap\n")
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      previous_yolo = Application.get_env(:symphony_elixir, :yolo)

      on_exit(fn ->
        restore_app_env(:yolo, previous_yolo)
      end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'touch #{codex_stamp}'"
      )

      Application.put_env(:symphony_elixir, :yolo, true)
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-bootstrap-1",
        identifier: "MT-BOOT",
        title: "Bootstrap only",
        description: "Prepare worktree and workpad",
        state: "Planung",
        url: "https://example.org/issues/MT-BOOT",
        labels: ["backend"]
      }

      assert :ok =
               File.cd!(source_repo, fn ->
                 AgentRunner.run(issue)
               end)

      workspace = Path.join(workspace_root, "MT-BOOT")

      refute File.dir?(workspace)

      assert {worktree_list, 0} = System.cmd("git", ["-C", source_repo, "worktree", "list", "--porcelain"], stderr_to_stdout: true)

      refute worktree_list =~ workspace
      refute_receive {:memory_tracker_branch_update, "issue-bootstrap-1", _branch}, 100
      refute_receive {:memory_tracker_comment, "issue-bootstrap-1", _body}, 100
      refute File.exists?(codex_stamp)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips direct manual approval states with matching labels without starting the next AI state" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-manual-skip-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    try do
      remote_repo = Path.join(test_root, "remote.git")
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_log = Path.join(test_root, "codex.log")
      codex_binary = Path.join(test_root, "fake-codex")

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["clone", remote_repo, source_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "checkout", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      File.write!(Path.join(source_repo, "README.md"), "manual-skip\n")
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      File.write!(codex_binary, """
      #!/bin/sh
      pwd >> #{codex_log}
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-manual-skip"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-manual-skip"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      no_findings_workpad = """
      ## Symphony Workpad

      ### Review

      - [x] Review step one
      - [x] Review subagent completed without findings
      """

      prepare_clean_workspace = fn identifier ->
        workspace = Path.join(workspace_root, identifier)

        File.mkdir_p!(workspace)
        File.write!(Path.join(workspace, "README.md"), "# review approval clean\n")
        System.cmd("git", ["-C", workspace, "init", "-b", "main"])
        System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
        System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
        System.cmd("git", ["-C", workspace, "add", "README.md"])
        System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      end

      run_case = fn issue_id, start_state, labels, expected_state ->
        File.rm(codex_log)
        identifier = String.upcase(issue_id)
        Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

        if start_state == "Freigabe Review" do
          Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
            issue_id => [no_findings_workpad]
          })

          prepare_clean_workspace.(identifier)
        end

        {:ok, state_agent} = Agent.start_link(fn -> start_state end)
        parent = self()

        recipient =
          spawn(fn ->
            review_handoff_test_recipient(parent, state_agent)
          end)

        Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

        state_fetcher = fn [_requested_issue_id] ->
          current_state = Agent.get(state_agent, & &1)

          {:ok,
           [
             %Issue{
               id: issue_id,
               identifier: identifier,
               title: "Manual skip handoff",
               description: "Skip a manual approval state immediately",
               state: current_state,
               labels: labels
             }
           ]}
        end

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          title: "Manual skip handoff",
          description: "Skip a manual approval state immediately",
          state: start_state,
          url: "https://example.org/issues/#{issue_id}",
          labels: labels
        }

        assert :ok =
                 File.cd!(source_repo, fn ->
                   AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
                 end)

        assert_receive {:memory_tracker_state_update, ^issue_id, ^expected_state}
        refute File.exists?(codex_log)

        Agent.stop(state_agent)
      end

      run_case.(
        "issue-skip-implementation",
        "Freigabe Implementierung",
        [~s(skip "freigabe implementierung")],
        "Review (AI)"
      )

      run_case.(
        "issue-skip-review",
        "Freigabe Review",
        [~s(skip "freigabe review")],
        "Test (AI)"
      )

      Application.put_env(:symphony_elixir, :yolo, true)

      run_case.(
        "issue-yolo-skip-implementation",
        "Freigabe Implementierung",
        [],
        "Review (AI)"
      )
    after
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner transitions Freigabe Review with skip label or yolo without starting Test AI" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-approval-guard-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      codex_stamp = Path.join(test_root, "codex-invoked")
      codex_binary = Path.join(test_root, "fake-codex")
      write_successful_fake_codex!(codex_binary, codex_stamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      findings_workpad = """
      ## Symphony Workpad

      ### Review

      - [x] Review step one
      - [x] Review subagent completed with findings

      Findings:
      - High: Example finding.
      """

      no_findings_workpad = """
      ## Symphony Workpad

      ### Review

      - [x] Review step one
      - [x] Review subagent completed without findings
      """

      prepare_clean_workspace = fn identifier ->
        workspace = Path.join(workspace_root, identifier)

        File.mkdir_p!(workspace)
        File.write!(Path.join(workspace, "README.md"), "# review approval clean\n")
        System.cmd("git", ["-C", workspace, "init", "-b", "main"])
        System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
        System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
        System.cmd("git", ["-C", workspace, "add", "README.md"])
        System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      end

      run_case = fn issue_id, identifier, labels, yolo?, workpad_body, prepare_workspace ->
        File.rm(codex_stamp)
        Application.put_env(:symphony_elixir, :yolo, yolo?)

        comments =
          if is_binary(workpad_body) do
            %{issue_id => [workpad_body]}
          else
            %{}
          end

        Application.put_env(:symphony_elixir, :memory_tracker_comments, comments)
        prepare_workspace.(identifier)
        {:ok, state_agent} = Agent.start_link(fn -> "Freigabe Review" end)
        parent = self()

        recipient =
          spawn(fn ->
            review_handoff_test_recipient(parent, state_agent)
          end)

        Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

        state_fetcher = fn [_requested_issue_id] ->
          current_state = Agent.get(state_agent, & &1)

          {:ok,
           [
             %Issue{
               id: issue_id,
               identifier: identifier,
               title: "Review approval skip",
               description: "Skip manual review approval when explicitly requested",
               state: current_state,
               labels: labels
             }
           ]}
        end

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          title: "Review approval skip",
          description: "Skip manual review approval when explicitly requested",
          state: "Freigabe Review",
          url: "https://example.org/issues/#{identifier}",
          labels: labels
        }

        assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
        assert_receive {:memory_tracker_state_update, ^issue_id, "Test (AI)"}
        refute File.exists?(codex_stamp)

        Agent.stop(state_agent)
      end

      run_case.(
        "issue-review-approval-findings",
        "MT-REVIEW-APPROVAL-FINDINGS",
        [~s(skip "freigabe review")],
        false,
        findings_workpad,
        fn _identifier -> :ok end
      )

      run_case.(
        "issue-review-approval-missing-workpad",
        "MT-REVIEW-APPROVAL-MISSING-WORKPAD",
        [~s(skip "freigabe review")],
        false,
        nil,
        prepare_clean_workspace
      )

      run_case.(
        "issue-review-approval-missing-workspace",
        "MT-REVIEW-APPROVAL-MISSING-WORKSPACE",
        [~s(skip "freigabe review")],
        false,
        no_findings_workpad,
        fn _identifier -> :ok end
      )

      run_case.(
        "issue-review-approval-dirty",
        "MT-REVIEW-APPROVAL-DIRTY",
        [],
        true,
        no_findings_workpad,
        fn identifier ->
          workspace = Path.join(workspace_root, identifier)

          File.mkdir_p!(workspace)
          File.write!(Path.join(workspace, "README.md"), "# review approval dirty\n")
          System.cmd("git", ["-C", workspace, "init", "-b", "main"])
          System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
          System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
          System.cmd("git", ["-C", workspace, "add", "README.md"])
          System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
          File.write!(Path.join(workspace, "README.md"), "# review approval dirty\nreview fix\n")
        end
      )
    after
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner ignores Todo without creating a workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-todo-#{System.unique_integer([:positive])}"
      )

    try do
      remote_repo = Path.join(test_root, "remote.git")
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")

      assert {_, 0} = System.cmd("git", ["init", "--bare", remote_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["clone", remote_repo, source_repo], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "checkout", "-b", "main"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"], stderr_to_stdout: true)
      File.write!(Path.join(source_repo, "README.md"), "todo\n")
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "add", "README.md"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"], stderr_to_stdout: true)
      assert {_, 0} = System.cmd("git", ["-C", source_repo, "push", "-u", "origin", "main"], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'touch #{codex_stamp}'"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-todo-1",
        identifier: "MT-TODO",
        title: "Todo only",
        description: "Wait for a human move into Todo (AI)",
        state: "Todo",
        url: "https://example.org/issues/MT-TODO",
        labels: ["backend"]
      }

      assert :ok =
               File.cd!(source_repo, fn ->
                 AgentRunner.run(issue)
               end)

      workspace = Path.join(workspace_root, "MT-TODO")

      refute File.dir?(workspace)

      assert {worktree_list, 0} = System.cmd("git", ["-C", source_repo, "worktree", "list", "--porcelain"], stderr_to_stdout: true)

      refute worktree_list =~ workspace
      refute_receive {:memory_tracker_branch_update, "issue-todo-1", _branch}, 100
      refute_receive {:memory_tracker_comment, "issue-todo-1", _body}, 100
      refute File.exists?(codex_stamp)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace status preserves remote existence check failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-remote-presence-failure-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"
      printf '%s\\n' 'remote presence check failed'
      exit 75
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a"]
      )

      issue = %Issue{
        id: "issue-remote-presence-failure",
        identifier: "MT-REMOTE-PRESENCE",
        title: "Remote presence failure",
        description: "Preserve remote workspace presence failures",
        state: "Freigabe Review"
      }

      assert {:error, {:workspace_presence_failed, "worker-a", 75, output}} =
               SymphonyElixir.Workspace.git_status_snapshot_for_existing_issue_workspace(
                 issue,
                 "worker-a"
               )

      assert output =~ "remote presence check failed"
      assert File.read!(trace_file) =~ "worker-a bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner surfaces ssh startup failures instead of silently hopping hosts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-single-host-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *worker-a*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\n' 'worker-a prepare failed' >&2
          exit 75
          ;;
        *worker-b*"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '/remote/home/.symphony-remote-workspaces/MT-SSH-FAILOVER'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-a", "worker-b"]
      )

      issue = %Issue{
        id: "issue-ssh-failover",
        identifier: "MT-SSH-FAILOVER",
        title: "Do not fail over within a single worker run",
        description: "Surface the startup failure to the orchestrator",
        state: "In Progress"
      }

      assert_raise RuntimeError, ~r/workspace_prepare_failed/, fn ->
        AgentRunner.run(issue, nil, worker_host: "worker-a")
      end

      trace = File.read!(trace_file)
      assert trace =~ "worker-a bash -lc"
      refute trace =~ "worker-b bash -lc"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn while the issue remains active" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cont-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        prompt_snippets: %{
          "continuation_guidance" => """
          Workflow-Fortsetzung aus WORKFLOW.md:
          - {{ continuation_intro }}
          - Turn {{ turn_number }}/{{ max_turns }}
          - Status {{ issue_state }}
          """,
          "continuation_intro_completed" => "Der vorherige Codex-Turn ist abgeschlossen; arbeite im bestehenden Kontext weiter."
        }
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_turn_fetch_count, 0) + 1
        Process.put(:agent_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch, attempt})

        state =
          if attempt == 1 do
            "In Arbeit (AI)"
          else
            "Fertig"
          end

        {:ok,
         [
           %Issue{
             id: "issue-continue",
             identifier: "MT-247",
             title: "Continue until done",
             description: "Still active after first turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-continue",
        identifier: "MT-247",
        title: "Continue until done",
        description: "Still active after first turn",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-247",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch, 1}
      assert_receive {:issue_state_fetch, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 0) =~ "Du arbeitest an einem Ticket dieses Repositorys."
      refute Enum.at(turn_texts, 1) =~ "Du arbeitest an einem Ticket dieses Repositorys."
      assert Enum.at(turn_texts, 1) =~ "Workflow-Fortsetzung aus WORKFLOW.md:"
      assert Enum.at(turn_texts, 1) =~ "Turn 2/3"
      assert Enum.at(turn_texts, 1) =~ "Status In Arbeit (AI)"

      assert Enum.at(turn_texts, 1) =~
               "Der vorherige Codex-Turn ist abgeschlossen; arbeite im bestehenden Kontext weiter."
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after a turn changes to another active status" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-status-change-stop-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN:%s\\n' "$$" >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-status-change"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-status-change-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-status-change-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        prompt_snippets: %{
          "continuation_guidance" => "Status {{ issue_state }} Turn {{ turn_number }}/{{ max_turns }}",
          "continuation_intro_completed" => "completed"
        }
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_status_change_fetch_count, 0) + 1
        Process.put(:agent_status_change_fetch_count, attempt)
        send(parent, {:issue_state_fetch_after_status_change, attempt})

        state =
          if attempt == 1 do
            "Planung (AI)"
          else
            "Fertig"
          end

        {:ok,
         [
           %Issue{
             id: "issue-status-change-stop",
             identifier: "MT-STATUS-CHANGE",
             title: "Stop on status change",
             description: "A status handoff should start a fresh agent run",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-status-change-stop",
        identifier: "MT-STATUS-CHANGE",
        title: "Stop on status change",
        description: "A status handoff should start a fresh agent run",
        state: "Todo (AI)",
        url: "https://example.org/issues/MT-STATUS-CHANGE",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch_after_status_change, 1}
      refute_receive {:issue_state_fetch_after_status_change, 2}, 100

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      turn_start_count =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.count(&(&1["method"] == "turn/start"))

      assert turn_start_count == 1
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner continues with a follow-up turn after an interrupted Codex turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-cancelled-continuation-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      run_id="$(date +%s%N)-$$"
      printf 'RUN:%s\\n' "$run_id" >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cancel-cont"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cancel-1"}}}'
            printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cancel-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3,
        prompt_snippets: %{
          "continuation_guidance" => """
          Workflow-Fortsetzung nach Unterbrechung:
          - {{ continuation_intro }}
          - Turn {{ turn_number }}/{{ max_turns }}
          - Status {{ issue_state }}
          - Thread-Kontext beibehalten.
          """,
          "continuation_intro_cancelled" => "Der vorherige Codex-Turn wurde unterbrochen; setze die Arbeit im vorhandenen Thread fort."
        }
      )

      parent = self()

      state_fetcher = fn [_issue_id] ->
        attempt = Process.get(:agent_cancelled_turn_fetch_count, 0) + 1
        Process.put(:agent_cancelled_turn_fetch_count, attempt)
        send(parent, {:issue_state_fetch_after_cancelled_turn, attempt})

        state =
          if attempt == 1 do
            "In Arbeit (AI)"
          else
            "Fertig"
          end

        {:ok,
         [
           %Issue{
             id: "issue-cancelled-continue",
             identifier: "MT-248",
             title: "Continue after interrupted turn",
             description: "Still active after a cancelled turn",
             state: state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-cancelled-continue",
        identifier: "MT-248",
        title: "Continue after interrupted turn",
        description: "Still active after a cancelled turn",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:issue_state_fetch_after_cancelled_turn, 1}
      assert_receive {:issue_state_fetch_after_cancelled_turn, 2}

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert length(Enum.filter(lines, &String.starts_with?(&1, "RUN:"))) == 1
      assert length(Enum.filter(lines, &String.contains?(&1, "\"method\":\"thread/start\""))) == 1

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2
      assert Enum.at(turn_texts, 1) =~ "Workflow-Fortsetzung nach Unterbrechung:"
      assert Enum.at(turn_texts, 1) =~ "Turn 2/3"
      assert Enum.at(turn_texts, 1) =~ "Status In Arbeit (AI)"

      assert Enum.at(turn_texts, 1) =~
               "Der vorherige Codex-Turn wurde unterbrochen; setze die Arbeit im vorhandenen Thread fort."

      assert Enum.at(turn_texts, 1) =~ "Thread-Kontext beibehalten."
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "agent runner syncs the current workspace branch name to the tracker before running Codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-branch-sync-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-branch-sync"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-branch-sync"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        workspace="$PWD"
        cd "$(dirname "$workspace")"
        rm -rf "$workspace"
        git -C "#{template_repo}" worktree add -b "symphony/MT-BRANCH-SYNC" "$workspace" main
        """,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-branch-sync",
             identifier: "MT-BRANCH-SYNC",
             title: "Branch sync",
             description: "Sync tracker branch name from workspace",
             state: "Freigabe Implementierung"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-branch-sync",
        identifier: "MT-BRANCH-SYNC",
        title: "Branch sync",
        description: "Sync tracker branch name from workspace",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-BRANCH-SYNC",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_branch_update, "issue-branch-sync", "symphony/MT-BRANCH-SYNC"}
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  @tag :manual_in_arbeit_bootstrap
  test "agent runner bootstraps a worktree for manual In Arbeit without starting Codex" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-manual-in-arbeit-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# manual bootstrap\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        set -eu
        workspace="$PWD"
        source_repo="$SYMPHONY_PROJECT_ROOT"
        issue_key="$(basename "$workspace")"
        branch="symphony/$issue_key"
        rm -rf "$workspace"
        git -C "$source_repo" worktree add -b "$branch" "$workspace" HEAD
        touch "$workspace/.after_create_ran"
        """,
        codex_command: "sh -lc 'touch #{codex_stamp}'"
      )

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      issue = %Issue{
        id: "issue-manual-in-arbeit",
        identifier: "MT-MANUAL-IN-ARBEIT",
        title: "Manual in-progress bootstrap",
        description: "Prepare a worktree for manual work",
        state: "In Arbeit",
        url: "https://example.org/issues/MT-MANUAL-IN-ARBEIT",
        labels: []
      }

      workspace = Path.join(workspace_root, "MT-MANUAL-IN-ARBEIT")

      assert :ok =
               File.cd!(source_repo, fn ->
                 AgentRunner.run(issue)
               end)

      assert File.dir?(workspace)
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.exists?(Path.join(workspace, ".after_create_ran"))
      refute File.exists?(codex_stamp)

      assert {"symphony/MT-MANUAL-IN-ARBEIT\n", 0} = System.cmd("git", ["-C", workspace, "branch", "--show-current"], stderr_to_stdout: true)

      assert_receive {:memory_tracker_branch_update, "issue-manual-in-arbeit", "symphony/MT-MANUAL-IN-ARBEIT"}
      refute_receive {:memory_tracker_state_update, "issue-manual-in-arbeit", _state_name}, 100
    after
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  @tag :manual_in_arbeit_orchestrator
  test "orchestrator dispatches manual In Arbeit once for bootstrap without scheduling continuation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-manual-in-arbeit-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")
      issue_id = "issue-manual-orchestrator"
      issue_identifier = "MT-MANUAL-ORCH"
      existing_task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# manual orchestrator\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: """
        set -eu
        workspace="$PWD"
        source_repo="$SYMPHONY_PROJECT_ROOT"
        issue_key="$(basename "$workspace")"
        branch="symphony/$issue_key"
        rm -rf "$workspace"
        git -C "$source_repo" worktree add -b "$branch" "$workspace" HEAD
        touch "$workspace/.after_create_ran"
        """,
        codex_command: "sh -lc 'touch #{codex_stamp}'",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Manual in-progress bootstrap",
        description: "Prepare a worktree for manual work",
        state: "In Arbeit",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      workspace = Path.join(workspace_root, issue_identifier)
      expected_branch = "symphony/#{issue_identifier}"
      orchestrator_name = Module.concat(__MODULE__, :ManualInArbeitOrchestrator)

      started_task_supervisor =
        case existing_task_supervisor do
          pid when is_pid(pid) ->
            nil

          nil ->
            {:ok, pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor)
            pid
        end

      File.cd!(source_repo, fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end

          if is_pid(started_task_supervisor) and Process.alive?(started_task_supervisor) do
            Process.exit(started_task_supervisor, :normal)
          end
        end)

        send(pid, :tick)

        # The handshake includes creating a real Git worktree and running its hook.
        assert_receive {:memory_tracker_branch_update, ^issue_id, ^expected_branch}, 10_000
        Process.sleep(350)

        assert File.dir?(workspace)
        assert File.exists?(Path.join(workspace, ".after_create_ran"))
        refute File.exists?(codex_stamp)

        state = :sys.get_state(pid)
        refute Map.has_key?(state.running, issue_id)
        refute MapSet.member?(state.claimed, issue_id)
        assert Map.get(state.completed_states, issue_id) == "in arbeit"
        refute Map.has_key?(state.retry_attempts, issue_id)
      end)
    after
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "orchestrator transitions yolo Freigabe Review without dispatching Test AI" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-review-noop-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")
      codex_binary = Path.join(test_root, "fake-codex")
      issue_id = "issue-review-noop-orchestrator"
      issue_identifier = "MT-REVIEW-NOOP"
      existing_task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# manual review noop\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])
      write_successful_fake_codex!(codex_binary, codex_stamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Blocked review approval",
        description: "Keep Freigabe Review stopped when approval evidence requires a human",
        state: "Freigabe Review",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: []
      }

      workpad = """
      ## Symphony Workpad

      ### Review

      - [x] Review step one
      - [x] Review subagent completed with findings

      Findings:
      - High: Example finding.
      """

      Application.put_env(:symphony_elixir, :yolo, true)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue_id => [workpad]})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :FreigabeReviewNoopOrchestrator)

      started_task_supervisor =
        case existing_task_supervisor do
          pid when is_pid(pid) ->
            nil

          nil ->
            {:ok, pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor)
            pid
        end

      File.cd!(source_repo, fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end

          if is_pid(started_task_supervisor) and Process.alive?(started_task_supervisor) do
            Process.exit(started_task_supervisor, :normal)
          end
        end)

        send(pid, :tick)
        assert_receive {:memory_tracker_state_update, ^issue_id, "Test (AI)"}, 2_000
        Process.sleep(350)

        refute File.exists?(codex_stamp)
      end)
    after
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "orchestrator transitions Freigabe Review with matching skip label without dispatching Test AI" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-orchestrator-review-skip-label-#{System.unique_integer([:positive])}"
      )

    previous_memory_issues = Application.get_env(:symphony_elixir, :memory_tracker_issues)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "worktrees")
      codex_stamp = Path.join(test_root, "codex-invoked")
      codex_binary = Path.join(test_root, "fake-codex")
      issue_id = "issue-review-skip-label-orchestrator"
      issue_identifier = "MT-REVIEW-SKIP-LABEL"
      existing_task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)

      File.mkdir_p!(source_repo)
      File.write!(Path.join(source_repo, "README.md"), "# manual review skip label\n")
      System.cmd("git", ["-C", source_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", source_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", source_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", source_repo, "add", "README.md"])
      System.cmd("git", ["-C", source_repo, "commit", "-m", "initial"])
      write_successful_fake_codex!(codex_binary, codex_stamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        poll_interval_ms: 30_000
      )

      issue = %Issue{
        id: issue_id,
        identifier: issue_identifier,
        title: "Skipped review approval",
        description: "Skip Freigabe Review outside yolo when the skip label is set",
        state: "Freigabe Review",
        url: "https://example.org/issues/#{issue_identifier}",
        labels: [~s(skip "freigabe review")]
      }

      Application.put_env(:symphony_elixir, :yolo, false)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue_id => []})
      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      orchestrator_name = Module.concat(__MODULE__, :FreigabeReviewSkipLabelOrchestrator)

      started_task_supervisor =
        case existing_task_supervisor do
          pid when is_pid(pid) ->
            nil

          nil ->
            {:ok, pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor)
            pid
        end

      File.cd!(source_repo, fn ->
        {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

        on_exit(fn ->
          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end

          if is_pid(started_task_supervisor) and Process.alive?(started_task_supervisor) do
            Process.exit(started_task_supervisor, :normal)
          end
        end)

        send(pid, :tick)
        assert_receive {:memory_tracker_state_update, ^issue_id, "Test (AI)"}, 2_000
        Process.sleep(350)

        refute File.exists?(codex_stamp)
      end)
    after
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_issues, previous_memory_issues)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves PreReview (AI) issues to Freigabe Implementierung after a clean prereview turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-prereview-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-prereview"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-prereview"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "PreReview (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-prereview-handoff" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] PreReview abgeschlossen
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-prereview-handoff",
             identifier: "MT-PREREVIEW",
             title: "PreReview handoff",
             description: "Advance after clean prereview turn",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-prereview-handoff",
        identifier: "MT-PREREVIEW",
        title: "PreReview handoff",
        description: "Advance after clean prereview turn",
        state: "PreReview (AI)",
        url: "https://example.org/issues/MT-PREREVIEW",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-prereview-handoff", "Freigabe Implementierung"}
      assert "Freigabe Implementierung" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips Freigabe Implementierung after a clean prereview turn when the label is set" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-prereview-skip-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-prereview-skip"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-prereview-skip"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "PreReview (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-prereview-skip-handoff" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] PreReview abgeschlossen
          """
        ]
      })

      labels = [~s(skip "freigabe implementierung")]

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-prereview-skip-handoff",
             identifier: "MT-PREREVIEW-SKIP",
             title: "PreReview handoff with skip",
             description: "Skip the manual implementation handoff after prereview",
             state: current_state,
             labels: labels
           }
         ]}
      end

      issue = %Issue{
        id: "issue-prereview-skip-handoff",
        identifier: "MT-PREREVIEW-SKIP",
        title: "PreReview handoff with skip",
        description: "Skip the manual implementation handoff after prereview",
        state: "PreReview (AI)",
        url: "https://example.org/issues/MT-PREREVIEW-SKIP",
        labels: labels
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-prereview-skip-handoff", "Review (AI)"}
      assert "Review (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps PreReview and Test AI active while handoff checklists are open or missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-open-handoff-checklists-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-open-handoff"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-open-handoff"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      run_case = fn issue_id, identifier, state_name, workpad_body ->
        {:ok, state_agent} = Agent.start_link(fn -> state_name end)
        parent = self()

        recipient =
          spawn(fn ->
            review_handoff_test_recipient(parent, state_agent)
          end)

        Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

        comments = if is_binary(workpad_body), do: %{issue_id => [workpad_body]}, else: %{}
        Application.put_env(:symphony_elixir, :memory_tracker_comments, comments)

        state_fetcher = fn [_issue_id] ->
          current_state = Agent.get(state_agent, & &1)

          {:ok,
           [
             %Issue{
               id: issue_id,
               identifier: identifier,
               title: "Open handoff checklist",
               description: "Keep active until the handoff checklist is closed",
               state: current_state
             }
           ]}
        end

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          title: "Open handoff checklist",
          description: "Keep active until the handoff checklist is closed",
          state: state_name,
          url: "https://example.org/issues/#{identifier}",
          labels: []
        }

        assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
        refute_receive {:memory_tracker_state_update, ^issue_id, _state}, 100
        assert state_name == Agent.get(state_agent, & &1)

        Agent.stop(state_agent)
      end

      run_case.(
        "issue-prereview-open-handoff",
        "MT-PREREVIEW-OPEN",
        "PreReview (AI)",
        """
        ## Symphony Workpad

        ### Review

        - [ ] Handoff-Checkliste abschließen
        """
      )

      run_case.(
        "issue-prereview-missing-workpad-handoff",
        "MT-PREREVIEW-MISSING",
        "PreReview (AI)",
        nil
      )

      run_case.(
        "issue-prereview-missing-review-handoff",
        "MT-PREREVIEW-NO-REVIEW",
        "PreReview (AI)",
        """
        ## Symphony Workpad

        ### Test

        - [x] Nicht relevant
        """
      )

      run_case.(
        "issue-test-open-handoff",
        "MT-TEST-OPEN",
        "Test (AI)",
        """
        ## Symphony Workpad

        ### Test

        - [ ] Handoff-Checkliste abschließen
        """
      )

      run_case.(
        "issue-test-missing-workpad-handoff",
        "MT-TEST-MISSING",
        "Test (AI)",
        nil
      )

      run_case.(
        "issue-test-missing-test-handoff",
        "MT-TEST-NO-TEST",
        "Test (AI)",
        """
        ## Symphony Workpad

        ### Validierung

        - [x] Ticketseitige Validierung abgeschlossen
        """
      )

      run_case.(
        "issue-test-open-validation-handoff",
        "MT-TEST-VALIDATION-OPEN",
        "Test (AI)",
        """
        ## Symphony Workpad

        ### Validierung

        - [ ] Ticketseitige Validierung abschließen

        ### Test

        - [x] Testlauf abgeschlossen
        """
      )
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops after a stale manual skip refetch and preserves exact Review AI casing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-manual-stale-review-casing-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

    on_exit(fn ->
      restore_env("SYMP_TEST_CODEx_TRACE", previous_trace)
    end)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-review-casing.trace")

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-review-casing.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-manual-stale-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-manual-stale-review"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        prompt_snippets: %{
          "review_subagent_authorization" => "MANDATORY_REVIEW_SUBAGENT"
        },
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Freigabe Implementierung" end)
      {:ok, fetch_counter} = Agent.start_link(fn -> 0 end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-manual-stale-review-casing" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      labels = [~s(skip "freigabe implementierung")]

      state_fetcher = fn [_issue_id] ->
        fetch_number = Agent.get_and_update(fetch_counter, &{&1, &1 + 1})
        current_state = if fetch_number == 0, do: "Freigabe Implementierung", else: Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-manual-stale-review-casing",
             identifier: "MT-MANUAL-STALE-REVIEW",
             title: "Manual stale review casing",
             description: "Preserve Review casing after a stale manual skip refetch",
             state: current_state,
             labels: labels
           }
         ]}
      end

      issue = %Issue{
        id: "issue-manual-stale-review-casing",
        identifier: "MT-MANUAL-STALE-REVIEW",
        title: "Manual stale review casing",
        description: "Preserve Review casing after a stale manual skip refetch",
        state: "Freigabe Implementierung",
        url: "https://example.org/issues/MT-MANUAL-STALE-REVIEW",
        labels: labels
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-manual-stale-review-casing", "Review (AI)"}
      refute File.exists?(trace_file)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips Freigabe Review after a no-findings clean review turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-handoff" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-handoff",
             identifier: "MT-REVIEW",
             title: "Review handoff",
             description: "Advance after clean review turn",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-handoff",
        identifier: "MT-REVIEW",
        title: "Review handoff",
        description: "Advance after clean review turn",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-handoff", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Freigabe Review when combined review finding fix evidence exists" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-combined-finding-fix-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-comment-findings"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-comment-findings"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-combined-finding-fix" => [
          """
          Kombinierter Review-Finding-Fix-Kommentar für MT-REVIEW-COMMENT:

          - Finding: P1 `lib/example.ex`: Beispiel.
          - Relevanz: Das Problem betrifft den Review-Scope.
          - Änderung: Das Finding wurde behoben.
          """,
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-combined-finding-fix",
             identifier: "MT-REVIEW-COMMENT",
             title: "Review handoff with combined finding fix evidence",
             description: "Use manual review handoff after combined finding fix evidence",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-combined-finding-fix",
        identifier: "MT-REVIEW-COMMENT",
        title: "Review handoff with combined finding fix evidence",
        description: "Use manual review handoff after combined finding fix evidence",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-COMMENT",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-combined-finding-fix", "Freigabe Review"}
      assert "Freigabe Review" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Review AI active when the workpad still has open review checklist items" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-workpad-open-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-open"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-open"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-workpad-open" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Dateiname geprüft
          - [ ] Read-only Review-Subagent gegen `origin/main` ausführen: ausstehend

          ### Test

          - [ ] Noch nicht gestartet
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-workpad-open",
             identifier: "MT-REVIEW-OPEN",
             title: "Review continuation with open workpad items",
             description: "Keep Review (AI) active for open review checklist items",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-workpad-open",
        identifier: "MT-REVIEW-OPEN",
        title: "Review continuation with open workpad items",
        description: "Keep Review (AI) active for open review checklist items",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-OPEN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:memory_tracker_state_update, "issue-review-workpad-open", _state}, 100
      assert "Review (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner labels Review AI continuation as incomplete phase when checklist stays open" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-incomplete-continuation-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-incomplete"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-incomplete-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-incomplete-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 2,
        prompt_snippets: %{
          "continuation_guidance" => """
          Workflow-Fortsetzung:
          - {{ continuation_intro }}
          - Turn {{ turn_number }}/{{ max_turns }}
          - Status {{ issue_state }}
          """,
          "continuation_intro_completed" => "Normal abgeschlossen.",
          "continuation_intro_incomplete_phase" => "Unvollständiger Phasenabschluss: {{ reason }}",
          "review_subagent_authorization" => "Review-Delegation erlaubt."
        }
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-incomplete-continuation" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Dateiname geprüft
          - [ ] Read-only Review-Subagent gegen `origin/main` ausführen: ausstehend
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-incomplete-continuation",
             identifier: "MT-REVIEW-INCOMPLETE",
             title: "Review incomplete continuation",
             description: "Keep Review (AI) active with explicit incomplete continuation",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-incomplete-continuation",
        identifier: "MT-REVIEW-INCOMPLETE",
        title: "Review incomplete continuation",
        description: "Keep Review (AI) active with explicit incomplete continuation",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-INCOMPLETE",
        labels: []
      }

      log =
        capture_log(fn ->
          assert :ok = AgentRunner.run(issue, recipient, issue_state_fetcher: state_fetcher)
        end)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      turn_texts =
        lines
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&String.trim_leading(&1, "JSON:"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["method"] == "turn/start"))
        |> Enum.map(fn payload ->
          get_in(payload, ["params", "input"])
          |> Enum.map_join("\n", &Map.get(&1, "text", ""))
        end)

      assert length(turn_texts) == 2

      assert Enum.at(turn_texts, 1) =~
               "Unvollständiger Phasenabschluss: offene Workpad-Checkliste Review"

      refute Enum.at(turn_texts, 1) =~ "Normal abgeschlossen."
      assert log =~ "after incomplete phase completion contract"
      assert log =~ "reason=offene_Workpad-Checkliste_Review"
      assert_receive {:agent_completion_contract, "issue-review-incomplete-continuation", {:incomplete_phase_max_turns, {:open_workpad_checklist, "Review"}}}

      refute_receive {:memory_tracker_state_update, "issue-review-incomplete-continuation", _state}, 100
      assert "Review (AI)" == Agent.get(state_agent, & &1)
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Review AI active when the workpad comment is missing" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-workpad-missing-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-missing-workpad"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-missing-workpad"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-workpad-missing",
             identifier: "MT-REVIEW-MISSING",
             title: "Review continuation with missing workpad",
             description: "Keep Review (AI) active without a workpad",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-workpad-missing",
        identifier: "MT-REVIEW-MISSING",
        title: "Review continuation with missing workpad",
        description: "Keep Review (AI) active without a workpad",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-MISSING",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:memory_tracker_state_update, "issue-review-workpad-missing", _state}, 100
      assert "Review (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Review AI active when the workpad lacks a Review section" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-workpad-no-section-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-no-section"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-no-section"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-workpad-no-section" => [
          """
          ## Symphony Workpad

          ### Test

          - [ ] Noch nicht gestartet
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-workpad-no-section",
             identifier: "MT-REVIEW-NO-SECTION",
             title: "Review continuation with missing review section",
             description: "Keep Review (AI) active without a Review checklist section",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-workpad-no-section",
        identifier: "MT-REVIEW-NO-SECTION",
        title: "Review continuation with missing review section",
        description: "Keep Review (AI) active without a Review checklist section",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-NO-SECTION",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:memory_tracker_state_update, "issue-review-workpad-no-section", _state}, 100
      assert "Review (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Review AI active when the workpad Review section has no checklist items" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-workpad-no-checklist-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-no-checklist"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-no-checklist"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-workpad-no-checklist" => [
          """
          ## Symphony Workpad

          ### Review

          Review lokal abgeschlossen.
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-workpad-no-checklist",
             identifier: "MT-REVIEW-NO-CHECKLIST",
             title: "Review continuation with prose-only review section",
             description: "Keep Review (AI) active without an explicit completed Review checklist",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-workpad-no-checklist",
        identifier: "MT-REVIEW-NO-CHECKLIST",
        title: "Review continuation with prose-only review section",
        description: "Keep Review (AI) active without an explicit completed Review checklist",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-NO-CHECKLIST",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:memory_tracker_state_update, "issue-review-workpad-no-checklist", _state}, 100
      assert "Review (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Freigabe Review after a no-findings review with open workspace changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-dirty-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-dirty"}}}'
            ;;
          4)
            printf 'review change\\n' >> README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-dirty"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-dirty-handoff" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-dirty-handoff",
             identifier: "MT-REVIEW-DIRTY",
             title: "Review handoff with dirty workspace",
             description: "Keep manual review approval when review leaves changes behind",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-dirty-handoff",
        identifier: "MT-REVIEW-DIRTY",
        title: "Review handoff with dirty workspace",
        description: "Keep manual review approval when review leaves changes behind",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-DIRTY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-dirty-handoff", "Freigabe Review"}
      assert "Freigabe Review" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Freigabe Review when review workspace status cannot be inspected" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-status-error-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-status-error"}}}'
            ;;
          4)
            rm -rf .git
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-status-error"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-status-error-handoff" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-status-error-handoff",
             identifier: "MT-REVIEW-STATUS-ERROR",
             title: "Review handoff with status error",
             description: "Keep manual review approval when workspace cleanliness is unknown",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-status-error-handoff",
        identifier: "MT-REVIEW-STATUS-ERROR",
        title: "Review handoff with status error",
        description: "Keep manual review approval when workspace cleanliness is unknown",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-STATUS-ERROR",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-status-error-handoff", "Freigabe Review"}
      assert "Freigabe Review" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner creates a review autocommit before the first Review (AI) dispatch when the workspace is dirty" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-dirty-preflight-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-PREFLIGHT")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty before review\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'HEAD:%s\\n' "$(git log -1 --pretty=%s)" >> "$trace_file"

      if git status --porcelain=v1 --untracked-files=all | grep -q .; then
        printf 'DIRTY:yes\\n' >> "$trace_file"
      else
        printf 'DIRTY:no\\n' >> "$trace_file"
      fi

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-preflight"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-preflight"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-dirty-preflight" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-dirty-preflight",
             identifier: "MT-REVIEW-PREFLIGHT",
             title: "Review preflight dirty workspace",
             description: "Create a one-time review snapshot commit before the first review run",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-dirty-preflight",
        identifier: "MT-REVIEW-PREFLIGHT",
        title: "Review preflight dirty workspace",
        description: "Create a one-time review snapshot commit before the first review run",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-PREFLIGHT",
        labels: []
      }

      expected_subject = review_autocommit_subject(issue.identifier)

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-dirty-preflight", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)
      assert File.read!(trace_file) =~ "HEAD:#{expected_subject}\nDIRTY:no\n"
      assert {subject_output, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      assert subject_output == "#{expected_subject}\n"
      assert {commit_body, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%b"])
      assert commit_body =~ "sichert den bis dahin offenen Arbeitsstand für MT-REVIEW-PREFLIGHT"
      assert commit_body =~ "kein Nachweis, dass Review (AI) bereits abgeschlossen ist"
      assert {"", 0} = System.cmd("git", ["-C", workspace, "status", "--short"])
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips a second review autocommit on fresh Review (AI) dispatches within the same stay" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-dirty-restart-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-RETRY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# still dirty after prior review work\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'HEAD:%s\\n' "$(git log -1 --pretty=%s)" >> "$trace_file"

      if git status --porcelain=v1 --untracked-files=all | grep -q .; then
        printf 'DIRTY:yes\\n' >> "$trace_file"
      else
        printf 'DIRTY:no\\n' >> "$trace_file"
      fi

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-retry"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-retry"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-dirty-restart" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-dirty-restart",
             identifier: "MT-REVIEW-RETRY",
             title: "Review restart keeps dirty workspace open",
             description: "Do not create a second review snapshot commit on fresh dispatches",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-dirty-restart",
        identifier: "MT-REVIEW-RETRY",
        title: "Review restart keeps dirty workspace open",
        description: "Do not create a second review snapshot commit on fresh dispatches",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-RETRY",
        labels: []
      }

      expected_subject = review_autocommit_subject(issue.identifier)

      assert {:ok, :committed} =
               Workspace.prepare_review_autocommit(
                 workspace,
                 AutocommitMessage.build(issue, "Review (AI)")
               )

      assert {"", 0} = System.cmd("git", ["-C", workspace, "status", "--short"])

      File.write!(Path.join(workspace, "README.md"), "# dirty review follow-up\n")

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-dirty-restart", "Freigabe Review"}

      assert File.read!(trace_file) =~ "HEAD:#{expected_subject}\nDIRTY:yes\n"
      assert {subject_output, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      assert subject_output == "#{expected_subject}\n"
      assert {status_output, 0} = System.cmd("git", ["-C", workspace, "status", "--short"])
      assert status_output =~ "README.md"
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner still creates the first review autocommit after a before_run failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-before-run-failure-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-HOOK")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")
      before_run_counter = Path.join(test_root, "before-run.count")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty before hook succeeds\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'HEAD:%s\\n' "$(git log -1 --pretty=%s)" >> "$trace_file"

      if git status --porcelain=v1 --untracked-files=all | grep -q .; then
        printf 'DIRTY:yes\\n' >> "$trace_file"
      else
        printf 'DIRTY:no\\n' >> "$trace_file"
      fi

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-hook"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-hook"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_before_run: """
        count=0
        if [ -f "#{before_run_counter}" ]; then
          count=$(cat "#{before_run_counter}")
        fi
        count=$((count + 1))
        printf '%s' "$count" > "#{before_run_counter}"
        if [ "$count" -eq 1 ]; then
          echo before-run failed once
          exit 17
        fi
        """,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-before-run-failure" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-before-run-failure",
             identifier: "MT-REVIEW-HOOK",
             title: "Review hook failure retry",
             description: "Create the first review snapshot after a failed before_run hook",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-before-run-failure",
        identifier: "MT-REVIEW-HOOK",
        title: "Review hook failure retry",
        description: "Create the first review snapshot after a failed before_run hook",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-HOOK",
        labels: []
      }

      assert_raise RuntimeError, ~r/review-before-run-failure/, fn ->
        AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      end

      marker_path = review_autocommit_marker_path!(workspace)

      assert {"initial\n", 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      refute File.exists?(marker_path)

      expected_subject = review_autocommit_subject(issue.identifier)

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-before-run-failure", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)
      assert File.read!(trace_file) =~ "HEAD:#{expected_subject}\nDIRTY:no\n"
      assert {subject_output, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      assert subject_output == "#{expected_subject}\n"
      assert {"", 0} = System.cmd("git", ["-C", workspace, "status", "--short"])
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner clears the review autocommit marker after a startup failure leaves Review (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-startup-failure-marker-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-STARTUP-FAIL")
      success_codex = Path.join(test_root, "fake-codex-success")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty before startup failure\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'exit 23'",
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-review-startup-failure-marker",
        identifier: "MT-REVIEW-STARTUP-FAIL",
        title: "Review startup failure clears marker",
        description: "Clear the review marker when startup fails after Review has already been left",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-STARTUP-FAIL",
        labels: []
      }

      marker_path = review_autocommit_marker_path!(workspace)
      expected_subject = review_autocommit_subject(issue.identifier)

      assert_raise RuntimeError, ~r/review-startup-failure-marker/, fn ->
        AgentRunner.run(
          issue,
          nil,
          issue_state_fetcher: fn [_issue_id] ->
            {:ok, [%{issue | state: "Freigabe Review"}]}
          end
        )
      end

      refute File.exists?(marker_path)
      assert {subject_output, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      assert subject_output == "#{expected_subject}\n"

      File.write!(Path.join(workspace, "README.md"), "# dirty before second review\n")

      File.write!(success_codex, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-startup-failure"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-startup-failure"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(success_codex, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{success_codex} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-startup-failure-marker" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-startup-failure-marker",
             identifier: "MT-REVIEW-STARTUP-FAIL",
             title: "Review startup failure clears marker",
             description: "Clear the review marker when startup fails after Review has already been left",
             state: current_state
           }
         ]}
      end

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-startup-failure-marker", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)

      assert {log_output, 0} =
               System.cmd("git", ["-C", workspace, "log", "--pretty=%s", "--max-count=3"])

      assert log_output =~ "#{expected_subject}\n#{expected_subject}\ninitial\n"
      refute File.exists?(marker_path)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner clears the review autocommit marker after a failed review turn leaves Review (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-turn-failure-marker-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-TURN-FAIL")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty before failed review turn\n")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-turn-failure"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-turn-failure"}}}'
            printf '%s\\n' '{"method":"turn/failed","params":{"reason":"boom"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-review-turn-failure-marker",
        identifier: "MT-REVIEW-TURN-FAIL",
        title: "Review turn failure clears marker",
        description: "Clear the review marker when a failed review turn has already left Review (AI)",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-TURN-FAIL",
        labels: []
      }

      marker_path = review_autocommit_marker_path!(workspace)
      expected_subject = review_autocommit_subject(issue.identifier)

      assert_raise RuntimeError, ~r/review-turn-failure-marker/, fn ->
        AgentRunner.run(
          issue,
          nil,
          issue_state_fetcher: fn [_issue_id] ->
            {:ok, [%{issue | state: "Freigabe Review"}]}
          end
        )
      end

      refute File.exists?(marker_path)
      assert {subject_output, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      assert subject_output == "#{expected_subject}\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner clears the review autocommit marker after leaving Review (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-marker-clear-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-MARKER")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty before first review\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'HEAD:%s\\n' "$(git log -1 --pretty=%s)" >> "$trace_file"

      if git status --porcelain=v1 --untracked-files=all | grep -q .; then
        printf 'DIRTY:yes\\n' >> "$trace_file"
      else
        printf 'DIRTY:no\\n' >> "$trace_file"
      fi

      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-marker"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-marker"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-review-marker-clear" => [
          """
          ## Symphony Workpad

          ### Review

          - [x] Review step one
          - [x] Review subagent completed without findings
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-review-marker-clear",
             identifier: "MT-REVIEW-MARKER",
             title: "Review marker cleared on handoff",
             description: "Clear the review marker after leaving Review (AI)",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-review-marker-clear",
        identifier: "MT-REVIEW-MARKER",
        title: "Review marker cleared on handoff",
        description: "Clear the review marker after leaving Review (AI)",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-MARKER",
        labels: []
      }

      marker_path = review_autocommit_marker_path!(workspace)
      expected_subject = review_autocommit_subject(issue.identifier)

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-marker-clear", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)
      refute File.exists?(marker_path)

      File.write!(Path.join(workspace, "README.md"), "# dirty before second review\n")
      Agent.update(state_agent, fn _state -> "Review (AI)" end)

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-review-marker-clear", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)

      assert File.read!(trace_file) =~
               "HEAD:#{expected_subject}\nDIRTY:no\nHEAD:#{expected_subject}\nDIRTY:no\n"

      assert {log_output, 0} =
               System.cmd("git", ["-C", workspace, "log", "--pretty=%s", "--max-count=3"])

      assert log_output =~ "#{expected_subject}\n#{expected_subject}\ninitial\n"
      refute File.exists?(marker_path)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner clears the review autocommit marker while bootstrapping manual In Arbeit" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-marker-clear-manual-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-MANUAL")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      marker_path = review_autocommit_marker_path!(workspace)
      File.write!(marker_path, "true\n")
      assert File.exists?(marker_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-review-marker-clear-manual",
        identifier: "MT-REVIEW-MANUAL",
        title: "Manual In Arbeit clears review marker",
        description: "Clear the review marker when bootstrapping manual in-progress work",
        state: "In Arbeit",
        url: "https://example.org/issues/MT-REVIEW-MANUAL",
        labels: []
      }

      assert :ok = AgentRunner.run(issue)
      refute File.exists?(marker_path)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner clears the review autocommit marker after a cancelled review turn leaves Review (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-marker-clear-cancelled-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-CANCELLED")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty before cancelled review\n")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-cancelled"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-cancelled"}}}'
            printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-review-marker-clear-cancelled",
        identifier: "MT-REVIEW-CANCELLED",
        title: "Cancelled review clears marker",
        description: "Clear the review marker when a cancelled turn leaves Review (AI)",
        state: "Review (AI)",
        url: "https://example.org/issues/MT-REVIEW-CANCELLED",
        labels: []
      }

      marker_path = review_autocommit_marker_path!(workspace)
      expected_subject = review_autocommit_subject(issue.identifier)

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 issue_state_fetcher: fn [_issue_id] ->
                   {:ok, [%{issue | state: "Freigabe Review"}]}
                 end
               )

      refute File.exists?(marker_path)
      assert {subject_output, 0} = System.cmd("git", ["-C", workspace, "log", "-1", "--pretty=%s"])
      assert subject_output == "#{expected_subject}\n"
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner clears the review autocommit marker for manual no-op states without creating a workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-marker-clear-manual-noop-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REVIEW-MANUAL-NOOP")
      codex_stamp = Path.join(test_root, "codex-invoked")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      marker_path = review_autocommit_marker_path!(workspace)
      File.write!(marker_path, "true\n")
      assert File.exists?(marker_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'touch #{codex_stamp}'",
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-review-marker-clear-manual-noop",
        identifier: "MT-REVIEW-MANUAL-NOOP",
        title: "Freigabe Review clears review marker",
        description: "Clear the review marker when Review (AI) has already been left",
        state: "Freigabe Review",
        url: "https://example.org/issues/MT-REVIEW-MANUAL-NOOP",
        labels: []
      }

      assert :ok = AgentRunner.run(issue)
      refute File.exists?(marker_path)
      refute File.exists?(codex_stamp)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner leaves existing workspace state untouched for manual Todo" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-todo-noop-existing-workspace-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TODO-NOOP")
      codex_stamp = Path.join(test_root, "codex-invoked")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      marker_path = review_autocommit_marker_path!(workspace)
      File.write!(marker_path, "true\n")
      assert File.exists?(marker_path)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "sh -lc 'touch #{codex_stamp}'",
        max_turns: 3
      )

      issue = %Issue{
        id: "issue-todo-noop-existing-workspace",
        identifier: "MT-TODO-NOOP",
        title: "Todo leaves workspace alone",
        description: "Manual Todo must not touch existing workspace state",
        state: "Todo",
        url: "https://example.org/issues/MT-TODO-NOOP",
        labels: []
      }

      assert :ok = AgentRunner.run(issue)
      assert File.exists?(marker_path)
      refute File.exists?(codex_stamp)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner skips Freigabe Review after handled review findings when review approval is skipped" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-skip-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-skip"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-skip"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      run_case = fn issue_id, identifier, labels, yolo? ->
        Application.put_env(:symphony_elixir, :yolo, yolo?)

        {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
        parent = self()

        recipient =
          spawn(fn ->
            review_handoff_test_recipient(parent, state_agent)
          end)

        Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

        Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
          issue_id => [
            """
            ## Symphony Workpad

            ### Review

            - [x] Review step one
            - [x] Review subagent completed with findings

            Findings:
            - High: Example finding.
            """
          ]
        })

        state_fetcher = fn [_issue_id] ->
          current_state = Agent.get(state_agent, & &1)

          {:ok,
           [
             %Issue{
               id: issue_id,
               identifier: identifier,
               title: "Review handoff with skip",
               description: "Keep manual review approval when review findings exist",
               state: current_state,
               labels: labels
             }
           ]}
        end

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          title: "Review handoff with skip",
          description: "Advance directly to test when review approval is skipped",
          state: "Review (AI)",
          url: "https://example.org/issues/#{identifier}",
          labels: labels
        }

        assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
        assert_receive {:memory_tracker_state_update, ^issue_id, "Test (AI)"}
        assert "Test (AI)" == Agent.get(state_agent, & &1)

        Agent.stop(state_agent)
      end

      run_case.("issue-review-skip-handoff", "MT-REVIEW-SKIP", [~s(skip "freigabe review")], false)
      run_case.("issue-review-yolo-handoff", "MT-REVIEW-YOLO", [], true)
      run_case.("issue-review-skip-manual-label-handoff", "MT-REVIEW-SKIP-MANUAL", [~s(skip "freigabe review"), "Requires Manual Review"], false)
      run_case.("issue-review-yolo-manual-label-handoff", "MT-REVIEW-YOLO-MANUAL", ["Requires Manual Review"], true)
    after
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Review AI active after blocked review evidence when approval is skipped" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-review-blocked-skip-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)
    previous_yolo = Application.get_env(:symphony_elixir, :yolo)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-review-blocked-skip"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-review-blocked-skip"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      run_case = fn issue_id, identifier, labels, yolo? ->
        Application.put_env(:symphony_elixir, :yolo, yolo?)
        {:ok, state_agent} = Agent.start_link(fn -> "Review (AI)" end)
        parent = self()

        recipient =
          spawn(fn ->
            review_handoff_test_recipient(parent, state_agent)
          end)

        Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
        Application.put_env(:symphony_elixir, :memory_tracker_comments, %{issue_id => []})

        state_fetcher = fn [_issue_id] ->
          current_state = Agent.get(state_agent, & &1)

          {:ok,
           [
             %Issue{
               id: issue_id,
               identifier: identifier,
               title: "Review continuation with blocked evidence and skip",
               description: "Keep Review (AI) active when workpad review evidence is blocked",
               state: current_state,
               labels: labels
             }
           ]}
        end

        issue = %Issue{
          id: issue_id,
          identifier: identifier,
          title: "Review continuation with blocked evidence and skip",
          description: "Keep Review (AI) active when workpad review evidence is blocked",
          state: "Review (AI)",
          url: "https://example.org/issues/#{identifier}",
          labels: labels
        }

        assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
        refute_receive {:memory_tracker_state_update, ^issue_id, _state}, 100
        assert "Review (AI)" == Agent.get(state_agent, & &1)

        Agent.stop(state_agent)
      end

      run_case.(
        "issue-review-blocked-skip-handoff",
        "MT-REVIEW-BLOCKED-SKIP",
        [~s(skip "freigabe review")],
        false
      )

      run_case.("issue-review-blocked-yolo-handoff", "MT-REVIEW-BLOCKED-YOLO", [], true)
    after
      restore_app_env(:yolo, previous_yolo)
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner keeps Merge (AI) active after a clean merge turn without merge evidence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-review-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-clean"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-clean"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-clean-handoff",
             identifier: "MT-MERGE-CLEAN",
             title: "Merge handoff clean",
             description: "Advance to review after a clean merge turn",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-clean-handoff",
        identifier: "MT-MERGE-CLEAN",
        title: "Merge handoff clean",
        description: "Advance to review after a clean merge turn",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-CLEAN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      refute_receive {:memory_tracker_state_update, "issue-merge-clean-handoff", _state_name}, 100
      assert "Merge (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Merge (AI) issues to Review after a clean merge turn with merge evidence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-evidence-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-evidence"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-evidence"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-merge-evidence-handoff" => [
          """
          ## Symphony Workpad

          ### Verlauf

          - 2026-05-29 18:18:00 CEST - Merge-Evidenz: PR #42 gemergt, Merge-Commit `abc1234`.
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-evidence-handoff",
             identifier: "MT-MERGE-EVIDENCE",
             title: "Merge handoff with evidence",
             description: "Advance to review after explicit PR merge evidence",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-evidence-handoff",
        identifier: "MT-MERGE-EVIDENCE",
        title: "Merge handoff with evidence",
        description: "Advance to review after explicit PR merge evidence",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-EVIDENCE",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-evidence-handoff", "Review"}
      assert "Review" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Test (AI) issues to Merge (AI) after a clean test turn without code changes" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-test-merge-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test-clean"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test-clean"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Test (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-test-clean-handoff" => [
          """
          ## Symphony Workpad

          ### Validierung

          - [x] Ticketseitige Validierung abgeschlossen

          ### Test

          - [x] Testlauf abgeschlossen
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-test-clean-handoff",
             identifier: "MT-TEST-CLEAN",
             title: "Test handoff clean",
             description: "Advance to merge when tests need no fixes",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-test-clean-handoff",
        identifier: "MT-TEST-CLEAN",
        title: "Test handoff clean",
        description: "Advance to merge when tests need no fixes",
        state: "Test (AI)",
        url: "https://example.org/issues/MT-TEST-CLEAN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-test-clean-handoff", "Merge (AI)"}
      assert "Merge (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Test (AI) issues to Merge (AI) after a test turn that leaves a dirty workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-test-review-handoff-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test-fix"}}}'
            ;;
          4)
            printf '# fixed during test\\n' > README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test-fix"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Test (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-test-fix-handoff" => [
          """
          ## Symphony Workpad

          ### Validierung

          - [x] Ticketseitige Validierung abgeschlossen

          ### Test

          - [x] Testlauf abgeschlossen
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-test-fix-handoff",
             identifier: "MT-TEST-FIX",
             title: "Test handoff with fix",
             description: "Advance to final handoff when tests leave open changes",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-test-fix-handoff",
        identifier: "MT-TEST-FIX",
        title: "Test handoff with fix",
        description: "Advance to final handoff when tests leave open changes",
        state: "Test (AI)",
        url: "https://example.org/issues/MT-TEST-FIX",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-test-fix-handoff", "Merge (AI)"}
      assert "Merge (AI)" == Agent.get(state_agent, & &1)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner still runs Codex for dirty Test (AI) workspaces and hands off to Merge (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-test-dirty-preflight-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TEST-DIRTY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RAN\\n' >> "$trace_file"
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-test-dirty"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-test-dirty"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Test (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-test-dirty-preflight" => [
          """
          ## Symphony Workpad

          ### Validierung

          - [x] Ticketseitige Validierung abgeschlossen

          ### Test

          - [x] Testlauf abgeschlossen
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-test-dirty-preflight",
             identifier: "MT-TEST-DIRTY",
             title: "Test preflight dirty workspace",
             description: "Allow testing to proceed with open changes",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-test-dirty-preflight",
        identifier: "MT-TEST-DIRTY",
        title: "Test preflight dirty workspace",
        description: "Allow testing to proceed with open changes",
        state: "Test (AI)",
        url: "https://example.org/issues/MT-TEST-DIRTY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-test-dirty-preflight", "Merge (AI)"}
      assert "Merge (AI)" == Agent.get(state_agent, & &1)
      assert File.exists?(trace_file)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner moves Merge (AI) turns that leave file changes back to Test (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-to-test-rerun-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-rerun"}}}'
            ;;
          4)
            printf '# changed by merge pull/rebase\\n' > README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-rerun"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create:
          ~s(git init -b main . && git config user.name "Test User" && git config user.email "test@example.com" && cp #{Path.join(template_repo, "README.md")} README.md && git add README.md && git commit -m initial),
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-rerun-handoff",
             identifier: "MT-MERGE-RERUN",
             title: "Merge rerun handoff",
             description: "Respect the explicit rerun to test after merge changes",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-rerun-handoff",
        identifier: "MT-MERGE-RERUN",
        title: "Merge rerun handoff",
        description: "Respect the explicit rerun to test after merge changes",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-RERUN",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-rerun-handoff", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)

      assert File.read!(Path.join([workspace_root, "MT-MERGE-RERUN", "README.md"])) =~
               "changed by merge pull/rebase"
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner redirects dirty Merge (AI) handoffs to Review back to Test (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-dirty-review-redirect-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MERGE-DIRTY-REVIEW")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-dirty-review"}}}'
            ;;
          4)
            printf '# changed before wrong review handoff\\n' > README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-dirty-review"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-dirty-review-redirect",
             identifier: "MT-MERGE-DIRTY-REVIEW",
             title: "Merge dirty review redirect",
             description: "Redirect wrong dirty merge handoff to test",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-dirty-review-redirect",
        identifier: "MT-MERGE-DIRTY-REVIEW",
        title: "Merge dirty review redirect",
        description: "Redirect wrong dirty merge handoff to test",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-DIRTY-REVIEW",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-dirty-review-redirect", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)

      assert File.read!(Path.join(workspace, "README.md")) =~
               "changed before wrong review handoff"
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner redirects cancelled dirty Merge (AI) handoffs to Review back to Test (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-cancelled-merge-dirty-review-redirect-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MERGE-CANCEL-DIRTY")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-cancel-dirty"}}}'
            ;;
          4)
            printf '# changed before cancelled review handoff\\n' > README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-cancel-dirty"}}}'
            printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Review" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-cancel-dirty-review-redirect",
             identifier: "MT-MERGE-CANCEL-DIRTY",
             title: "Merge cancelled dirty review redirect",
             description: "Redirect cancelled dirty merge handoff to test",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-cancel-dirty-review-redirect",
        identifier: "MT-MERGE-CANCEL-DIRTY",
        title: "Merge cancelled dirty review redirect",
        description: "Redirect cancelled dirty merge handoff to test",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-CANCEL-DIRTY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-cancel-dirty-review-redirect", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)

      assert File.read!(Path.join(workspace, "README.md")) =~
               "changed before cancelled review handoff"
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner redirects cancelled dirty Merge (AI) turns that stay in Merge (AI) back to Test (AI)" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-cancelled-merge-dirty-active-redirect-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MERGE-CANCEL-ACTIVE")
      codex_binary = Path.join(test_root, "fake-codex")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-cancel-active"}}}'
            ;;
          4)
            printf '# changed before cancelled active handoff\\n' > README.md
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-cancel-active"}}}'
            printf '%s\\n' '{"method":"turn/cancelled","params":{"reason":"interrupted"}}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 1
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-cancel-dirty-active-redirect",
             identifier: "MT-MERGE-CANCEL-ACTIVE",
             title: "Merge cancelled dirty active redirect",
             description: "Redirect cancelled dirty active merge to test",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-cancel-dirty-active-redirect",
        identifier: "MT-MERGE-CANCEL-ACTIVE",
        title: "Merge cancelled dirty active redirect",
        description: "Redirect cancelled dirty active merge to test",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-CANCEL-ACTIVE",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-cancel-dirty-active-redirect", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)

      assert File.read!(Path.join(workspace, "README.md")) =~
               "changed before cancelled active handoff"
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner still runs Codex for dirty Merge (AI) workspaces and hands off to Test (AI) even with merge evidence" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-merge-dirty-preflight-#{System.unique_integer([:positive])}"
      )

    previous_memory_recipient = Application.get_env(:symphony_elixir, :memory_tracker_recipient)
    previous_memory_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-MERGE-DIRTY")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "README.md"), "# test\n")
      System.cmd("git", ["-C", workspace, "init", "-b", "main"])
      System.cmd("git", ["-C", workspace, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", workspace, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", workspace, "add", "README.md"])
      System.cmd("git", ["-C", workspace, "commit", "-m", "initial"])
      File.write!(Path.join(workspace, "README.md"), "# dirty\n")

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="#{trace_file}"
      printf 'RAN\\n' >> "$trace_file"
      count=0

      while IFS= read -r _line; do
        count=$((count + 1))
        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-merge-dirty"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-merge-dirty"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        max_turns: 3
      )

      {:ok, state_agent} = Agent.start_link(fn -> "Merge (AI)" end)
      parent = self()

      recipient =
        spawn(fn ->
          review_handoff_test_recipient(parent, state_agent)
        end)

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, recipient)

      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-merge-dirty-preflight" => [
          """
          ## Symphony Workpad

          ### Verlauf

          - 2026-05-29 18:19:00 CEST - Merge-Evidenz: PR #77 gemergt, Merge-Commit `def4567`.
          """
        ]
      })

      state_fetcher = fn [_issue_id] ->
        current_state = Agent.get(state_agent, & &1)

        {:ok,
         [
           %Issue{
             id: "issue-merge-dirty-preflight",
             identifier: "MT-MERGE-DIRTY",
             title: "Merge preflight dirty workspace",
             description: "Allow merge phase to autocommit open changes",
             state: current_state
           }
         ]}
      end

      issue = %Issue{
        id: "issue-merge-dirty-preflight",
        identifier: "MT-MERGE-DIRTY",
        title: "Merge preflight dirty workspace",
        description: "Allow merge phase to autocommit open changes",
        state: "Merge (AI)",
        url: "https://example.org/issues/MT-MERGE-DIRTY",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)
      assert_receive {:memory_tracker_state_update, "issue-merge-dirty-preflight", "Test (AI)"}
      assert "Test (AI)" == Agent.get(state_agent, & &1)
      assert File.exists?(trace_file)
    after
      restore_app_env(:memory_tracker_comments, previous_memory_comments)
      restore_app_env(:memory_tracker_recipient, previous_memory_recipient)
      File.rm_rf(test_root)
    end
  end

  test "agent runner stops continuing once agent.max_turns is reached" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-runner-max-turns-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex.trace")

      File.mkdir_p!(template_repo)
      File.write!(Path.join(template_repo, "README.md"), "# test")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex.trace}"
      printf 'RUN\\n' >> "$trace_file"
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
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-max"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-1"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
          5)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-max-2"}}}'
            printf '%s\\n' '{"method":"turn/completed"}'
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)
      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)

      on_exit(fn -> System.delete_env("SYMP_TEST_CODEx_TRACE") end)

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: workspace_root,
        hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md",
        codex_command: "#{codex_binary} app-server",
        max_turns: 2
      )

      state_fetcher = fn [_issue_id] ->
        {:ok,
         [
           %Issue{
             id: "issue-max-turns",
             identifier: "MT-248",
             title: "Stop at max turns",
             description: "Still active",
             state: "In Arbeit (AI)"
           }
         ]}
      end

      issue = %Issue{
        id: "issue-max-turns",
        identifier: "MT-248",
        title: "Stop at max turns",
        description: "Still active",
        state: "In Arbeit (AI)",
        url: "https://example.org/issues/MT-248",
        labels: []
      }

      assert :ok = AgentRunner.run(issue, nil, issue_state_fetcher: state_fetcher)

      trace = File.read!(trace_file)
      assert length(String.split(trace, "RUN", trim: true)) == 1
      assert length(Regex.scan(~r/"method":"turn\/start"/, trace)) == 2
    after
      System.delete_env("SYMP_TEST_CODEx_TRACE")
      File.rm_rf(test_root)
    end
  end

  test "app server starts with workspace cwd and expected startup command" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-77")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"
      printf 'CWD:%s\\n' \"$PWD\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-77\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-77\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-args",
        identifier: "MT-77",
        title: "Validate codex args",
        description: "Check startup args and cwd",
        state: "In Progress",
        url: "https://example.org/issues/MT-77",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "app-server")
      refute Enum.any?(lines, &String.contains?(&1, "--yolo"))
      assert cwd_line = Enum.find(lines, fn line -> String.starts_with?(line, "CWD:") end)
      assert String.ends_with?(cwd_line, Path.basename(workspace))

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace
                 end)
               else
                 false
               end
             end)

      expected_turn_sandbox_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [canonical_workspace],
        "readOnlyAccess" => %{"type" => "fullAccess"},
        "networkAccess" => false,
        "excludeTmpdirEnvVar" => false,
        "excludeSlashTmp" => false
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   expected_approval_policy = %{
                     "reject" => %{
                       "sandbox_approval" => true,
                       "rules" => true,
                       "mcp_elicitations" => true
                     }
                   }

                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "cwd"]) == canonical_workspace &&
                     get_in(payload, ["params", "approvalPolicy"]) == expected_approval_policy &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_sandbox_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup command supports codex args override from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-custom-args-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-custom-args.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-custom-args.trace}"
      count=0
      printf 'ARGV:%s\\n' \"$*\" >> \"$trace_file\"

      while IFS= read -r line; do
        count=$((count + 1))
        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          3)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"method\":\"turn/completed\"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} --model gpt-5.3-codex app-server"
      )

      issue = %Issue{
        id: "issue-custom-args",
        identifier: "MT-88",
        title: "Validate custom codex args",
        description: "Check startup args override",
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert argv_line = Enum.find(lines, fn line -> String.starts_with?(line, "ARGV:") end)
      assert String.contains?(argv_line, "--model gpt-5.3-codex app-server")
      refute String.contains?(argv_line, "--ask-for-approval never")
      refute String.contains?(argv_line, "--sandbox danger-full-access")
    after
      File.rm_rf(test_root)
    end
  end

  test "app server startup payload uses configurable approval and sandbox settings from workflow config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-policy-overrides-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-99")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-policy-overrides.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-policy-overrides.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-99"}}}'
            ;;
          3)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-99"}}}'
            ;;
          4)
            printf '%s\\n' '{"method":"turn/completed"}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      workspace_cache = Path.join(Path.expand(workspace), ".cache")
      File.mkdir_p!(workspace_cache)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "on-request",
        codex_thread_sandbox: "workspace-write",
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [Path.expand(workspace), workspace_cache]
        }
      )

      issue = %Issue{
        id: "issue-policy-overrides",
        identifier: "MT-99",
        title: "Validate codex policy overrides",
        description: "Check startup policy payload overrides",
        state: "In Progress",
        url: "https://example.org/issues/MT-99",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Fix workspace start args", issue)

      lines = File.read!(trace_file) |> String.split("\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "thread/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandbox"]) == "workspace-write"
                 end)
               else
                 false
               end
             end)

      expected_turn_policy = %{
        "type" => "workspaceWrite",
        "writableRoots" => [Path.expand(workspace), workspace_cache]
      }

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 line
                 |> String.trim_leading("JSON:")
                 |> Jason.decode!()
                 |> then(fn payload ->
                   payload["method"] == "turn/start" &&
                     get_in(payload, ["params", "approvalPolicy"]) == "on-request" &&
                     get_in(payload, ["params", "sandboxPolicy"]) == expected_turn_policy
                 end)
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  defp isolate_git_discovery!(directory) do
    # Non-Git fixtures must not discover the repository containing TMPDIR.
    {:ok, ceiling} = SymphonyElixir.PathSafety.canonicalize(directory)
    previous = System.get_env("GIT_CEILING_DIRECTORIES")
    on_exit(fn -> restore_env("GIT_CEILING_DIRECTORIES", previous) end)
    ceilings = Enum.reject([ceiling, previous], &(&1 in [nil, ""]))
    System.put_env("GIT_CEILING_DIRECTORIES", Enum.join(ceilings, ":"))
  end

  defp workflow_directory_outside_repo!(prefix) do
    # Workflow discovery walks all ancestors independently of Git and TMPDIR.
    {directory, 0} = System.cmd("mktemp", ["-d", "/tmp/#{prefix}-XXXXXX"])
    {:ok, canonical_directory} = SymphonyElixir.PathSafety.canonicalize(String.trim(directory))
    canonical_directory
  end

  defp caller_git!(directory, args) do
    {output, 0} = System.cmd("git", ["-C", directory | args], env: [{"GIT_OPTIONAL_LOCKS", "0"}])
    output
  end

  defp caller_repository_snapshot(directory) do
    %{
      head: caller_git!(directory, ["rev-parse", "HEAD"]),
      index: caller_git!(directory, ["ls-files", "--stage", "-z"]),
      staged: caller_git!(directory, ["diff", "--cached", "--binary"]),
      unstaged: caller_git!(directory, ["diff", "--binary"]),
      sentinel: File.read!(Path.join(directory, "sentinel.txt")),
      review_marker: File.read(Path.join(directory, ".git/symphony.review-ai-autocommit.done"))
    }
  end

  defp review_autocommit_marker_path!(workspace) do
    {output, 0} =
      System.cmd("git", [
        "-C",
        workspace,
        "rev-parse",
        "--path-format=absolute",
        "--git-path",
        "symphony.review-ai-autocommit.done"
      ])

    String.trim(output)
  end

  defp review_autocommit_subject(identifier) do
    identifier
    |> AutocommitMessage.build("Review (AI)")
    |> String.split("\n", parts: 2)
    |> hd()
  end
end
