---
tracker:
  kind: linear
  # App-Bindung und Secret aus .symphony/.env.local des jeweiligen Fachprojekts.
  # Secret erst im Auth-Prozess lesen; client_secret_env enthält nur den Namen.
  auth_mode: app
  app:
    client_id: $LINEAR_APP_CLIENT_ID
    client_secret_env: LINEAR_APP_SECRET
    workspace_id: $LINEAR_APP_WORKSPACE_ID
    user_id: $LINEAR_APP_USER_ID
  relay:
    endpoint: $LINEAR_RELAY_URL
    key_env: LINEAR_RELAY_KEY
    consumer_id: $LINEAR_RELAY_CONSUMER_ID
    reconcile_ms: 3600000
  # Der Scope wird repository-lokal über LINEAR_PROJECT_SLUG/LINEAR_TEAM_KEY gewählt;
  # fehlende Tracker-Felder erhalten den jeweils gleichnamigen Env-Fallback.
  project_slug: $LINEAR_PROJECT_SLUG
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Todo (AI)
    - Planung (AI)
    - In Arbeit (AI)
    - PreReview (AI)
    - Review (AI)
    - Test (AI)
    - Abbruch (AI)
    - Merge (AI)
  terminal_states:
    - Review
    - Fertig
    - Abgebrochen
polling:
  interval_ms: 5000
  idle_shutdown_ms: 3600000
workspace:
  # Ohne root oder bei null, leerem Wert bzw. fehlendem/leerem Env-Wert gilt
  # bei jeder Konfigurationsauflösung zur Laufzeit: System.tmp_dir!()/symphony_workspaces.
  root: $SYMPHONY_PROJECT_WORKTREES_ROOT
hooks:
  timeout_ms: 180000
  after_create: |
    set -eu
    workspace="$PWD"
    issue_key="$(basename "$workspace")"
    branch="symphony/$issue_key"
    source_repo="$SYMPHONY_PROJECT_ROOT"
    if ! git -C "$workspace" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      rm -rf "$workspace"
    fi
    git -C "$source_repo" fetch origin
    if git -C "$source_repo" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$source_repo" worktree add "$workspace" "$branch"
    elif git -C "$source_repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$source_repo" worktree add --track -b "$branch" "$workspace" "origin/$branch"
    else
      git -C "$source_repo" worktree add -b "$branch" "$workspace" origin/main
    fi
    git -C "$source_repo" config "branch.$branch.remote" origin
    git -C "$source_repo" config "branch.$branch.merge" "refs/heads/$branch"
    if git -C "$source_repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      git -C "$workspace" pull --ff-only origin "$branch"
    fi
    python3 "$source_repo/.symphony/on_create_worktree.py" "$source_repo" "$workspace"
  before_remove: |
    workspace="$PWD"
    python3 "$SYMPHONY_PROJECT_ROOT/.symphony/on_remove_worktree.py" "$SYMPHONY_PROJECT_ROOT" "$workspace"
    # Closes open PRs, deletes the matching remote and local branches, and removes the linked worktree.
    cd "$SYMPHONY_WORKFLOW_DIR" && mise exec -- mix workspace.before_remove --workspace "$workspace" --source-repo "$SYMPHONY_PROJECT_ROOT"
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  # Der Symphony-Checkout bindet dieses Standardkommando an seinen eigenen Helfer.
  # Andere Kommandos und SYMPHONY_CODEX_COMMAND behalten ihren konfigurierten Wert.
  command: sym-codex --observer
  approval_policy: never
  thread_sandbox: danger-full-access
  read_timeout_ms: 30000
  turn_sandbox_policy:
    type: dangerFullAccess
prompt_snippets:
  continuation_guidance: |
    Fortsetzungsanweisungen:

    - {{ continuation_intro }}
    - Dies ist Fortsetzungs-Turn #{{ turn_number }} von {{ max_turns }} im aktuellen Agentenlauf.
    - Der aktuelle Tracker-Status ist "{{ issue_state }}".
    - Folge den Workflow-Anweisungen für den aktuellen Tracker-Status, bevor du das weitere Vorgehen festlegst.
    - Setze im bestehenden Workspace-, Workpad- und Thread-Kontext fort, statt von Grund auf neu zu beginnen.
    - Die ursprünglichen Aufgabenanweisungen und der bisherige Turn-Kontext liegen in diesem Thread bereits vor; wiederhole sie nicht, bevor du handelst.
    - Wenn der vorherige Turn normal endete, der Tracker-Status aber weiterhin ein aktiver AI-Status ist, behandle das als unvollständigen Phasenabschluss. Prüfe die phasenspezifischen Workpad-Checklisten oder Merge-Evidenz und arbeite weiter, bis ein zulässiger Statuswechsel erfolgt oder ein echter Blocker beziehungsweise `agent.max_turns` dokumentiert ist.
    - Konzentriere dich auf die verbleibende Arbeit im aktuellen Tracker-Status. Sobald du den Status wechselst, beende diesen Turn sauber, damit der Zielstatus in einer neuen Codex-Session startet.
  continuation_intro_cancelled: |
    Der vorherige Codex-Turn wurde unterbrochen, das Linear-Issue befindet sich aber weiterhin in einem aktiven Status.
  continuation_intro_completed: |
    Der vorherige Codex-Turn wurde normal abgeschlossen, das Linear-Issue befindet sich aber weiterhin in einem aktiven Status.
  continuation_intro_incomplete_phase: |
    Der vorherige Codex-Turn wurde beendet, obwohl der Abschlussvertrag für den aktuellen aktiven AI-Status noch nicht erfüllt war ({{ reason }}). Behandle das als unvollständigen Phasenabschluss, nicht als regulären Abschluss.
  recovered_turn_context: |
    Wiederhergestellter Fortsetzungskontext:

    - Der unmittelbar vorherige Codex-Turn endete unerwartet, nachdem ein Subagent bereits ein finales Ergebnis geliefert hatte.
    - Verwende das unten stehende abgeschlossene Subagent-Ergebnis erneut, statt sofort denselben Subagenten noch einmal zu starten.
    - Arbeite vom aktuellen Workspace- und Workpad-Stand aus weiter, setze erforderliche Fixes selbst um und starte den Subagenten nur dann erneut, wenn der aktive Workflow das nach den Fixes weiterhin verlangt und das Rundenbudget aus `symphony-review` es erlaubt.

    Wiederhergestelltes Subagent-Ergebnis:

    ```text
    {{ context }}
    ```
  recovered_review_subagent_wait: |
    Wiederhergestellter Review-Subagent-Status:

    - Der unmittelbar vorherige Codex-Turn endete, während ein Review-Subagent noch lief und noch kein finales Ergebnis vorlag.
    - Starte nicht sofort einen neuen Review-Subagenten. Prüfe stattdessen zuerst den bereits laufenden Review-Subagenten erneut mit `wait_agent` und langem Timeout.
    - Wenn `wait_agent` nur ein Timeout liefert oder weiterhin kein finales Ergebnis enthält, bleibt der Review-Schritt offen und derselbe Subagent läuft weiter.

    Bekannte laufende Review-Subagent-IDs:

    ```text
    {{ agent_ids_text }}
    ```
  review_subagent_authorization: |
    Review-(AI)-Delegationsfreigabe:
    - Für diesen Turn verlange ich explizit, dass du `spawn_agent` für den verpflichtenden read-only Review-Schritt verwendest, sobald der aktive Workflow oder ein aufgerufener Skill einen Review-Subagenten verlangt.
    - Behandle das als den expliziten Nutzerwunsch, der für diese Delegation erforderlich ist.
    - Starte diesen verpflichtenden Review-Subagenten isoliert mit `fork_context: false`.
    - Übergib dem Review-Subagenten nur einen engen read-only Review-Auftrag plus nötige `Zusätzliche Review-Hinweise`; der Auftrag darf keine Issue-Beschreibung, keinen Issue-Titel, keine Issue-URL, keine Ticketabsicht, keine Akzeptanzkriterien und keine Workpad-/Workflow-Zusammenfassung enthalten.
    - Der isolierte Review-Subagent darf keine Workpad-, Linear- oder Statusänderungen vornehmen und keine weiteren Subagenten starten.
    - Der Review-Subagent muss vor seiner finalen Antwort den vollständigen relevanten Review-Scope prüfen, darf nicht nach den ersten ein oder zwei Findings abbrechen und muss alle klar belegbaren, reviewer-relevanten Findings priorisiert mit Datei-/Zeilenbezug melden.
    - Der vollständige relevante Review-Scope ist der Repository-Stand gegen `origin/main`: Branch-Commits sowie gestagte, ungestagte und untracked Änderungen plus daraus folgende repo-lokale Konsistenz zwischen Code, `WORKFLOW.md`, Skills und `docs/`. Er ist kein Abgleich gegen Linear-Issue, Workpad, Ticketabsicht oder Akzeptanzkriterien.
    - Ersetze einen verpflichtenden Review-Subagenten nicht durch ein rein lokales Review, außer die aktiven Anweisungen erlauben diesen Fallback ausdrücklich.
    - Wenn die erforderliche Isolation des Review-Subagenten in diesem Turn nicht möglich ist, bleibt der Review-Schritt offen; behaupte kein lokales Ersatz-Review und verschiebe das Ticket nicht weiter.
    - Der Hauptagent muss die Findings weiterhin selbst bewerten, die Fixes selbst umsetzen und die Review-Schleife bei Bedarf innerhalb des Rundenbudgets aus `symphony-review` erneut ausführen.
    - Verwende für den Review-Subagenten `wait_agent` mit langem Timeout. Ein 30-Sekunden-Timeout reicht für einen vollständigen Review-Durchlauf nicht aus.
    - Wenn `wait_agent` ein finales Ergebnis mit `Findings:` liefert, verarbeite diese Findings sofort im Hauptturn: im Workpad erfassen, fixen oder begründet anders behandeln, validieren, danach je behandeltem Finding genau einen kombinierten Nach-Fix-Kommentar posten und die Review-Schleife gemäß Rundenbudget fortsetzen oder abschließen. Beende den Turn nicht zwischen Findings-Erhalt und dieser Verarbeitung.
    - Poste vor den Fixes keinen separaten Findings-Kommentar. Bei einem behandelten Finding entsteht genau ein kombinierter Nach-Fix-Kommentar; bei zwei behandelten Findings entstehen genau zwei kombinierte Nach-Fix-Kommentare, nicht vier.
    - Wenn `wait_agent` abläuft oder kein finales Ergebnis liefert, ist der Review-Schritt weiterhin unvollständig. Lass den Subagenten weiterlaufen und warte erneut, statt Ergebnisse zu erfinden oder die Checkliste neu zu starten.
    - Rufe `close_agent` nicht auf einem noch laufenden Review-Subagenten auf, nur weil ein Wait-Timeout erreicht wurde.
---

Du arbeitest an einem Linear-Ticket `{{ issue.identifier }}`

{% if attempt %}
Fortsetzungskontext:

- Dies ist Wiederholungsversuch Nr. {{ attempt }}, weil sich das Ticket weiterhin in einem aktiven Status befindet.
- Setze vom aktuellen Workspace-Zustand aus fort, statt von Grund auf neu zu beginnen.
- Wiederhole bereits abgeschlossene Untersuchung oder Validierung nicht, außer wenn sie für neue Codeänderungen erforderlich ist.
- Arbeite nur im aktuellen Tracker-Status weiter. Nach einem Statuswechsel endet dieser Turn mit einer knappen Abschlussnachricht.
{% endif %}

Ticket-Kontext:
Identifier: {{ issue.identifier }}
Titel: {{ issue.title }}
Aktueller Status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}
Lokale Systemzeit für diesen Turn: {{ runtime.local_time }} ({{ runtime.timezone }})

Pfadkontext für Skills in diesem Turn:
- Aktiv bearbeitetes Repository/Worktree: `{{ runtime.active_repo_root }}`
- Repo-lokaler Skill-Pfad: `{{ runtime.active_repo_skill_root }}`
- Globale Skill-Wurzeln: `{{ runtime.global_skill_roots_text }}`

Beschreibung:
{% if issue.description %}
{{ issue.description }}
{% else %}
Keine Beschreibung vorhanden.
{% endif %}
{% if runtime.docs_review_hint_enabled %}

Zusätzliche Review-Hinweise:
{{ runtime.review_additional_hints }}
{% endif %}

## Zweck und Grundregeln

1. Dies ist eine unbeaufsichtigte Orchestrierungssitzung. Frage niemals einen Menschen nach Folgeaktionen.
2. Stoppe bei einem echten Zugriffsblocker oder einer fälligen, ausschließlich extern erfüllbaren Betreiberpflicht, sobald kein zulässiger autonomer Fortsetzungsweg bleibt. Halte den konkreten Grund im Workpad fest und verschiebe das Issue gemäß Workflow.
3. Die Abschlussnachricht darf nur abgeschlossene Aktionen und Blocker enthalten. Füge keine "next steps for user" hinzu.

- Arbeite nur in der bereitgestellten Repository-Kopie. Berühre keinen anderen Pfad.
- Beginne damit, den aktuellen Status des Tickets zu bestimmen, und folge dann dem passenden Ablauf für diesen Status.
- Betrachte grundsätzlich nur Statuswerte mit `(AI)` im Namen als automatische Arbeitsstatus; `In Arbeit` ist der ausdrücklich definierte manuelle Worktree-Bootstrap-Sonderfall, `Todo (Dialog-AI)` der ausdrücklich definierte isolierte Sonderfall.
- Starte jede Aufgabe damit, den verfolgenden Workpad-Kommentar zu öffnen und auf den neuesten Stand zu bringen, bevor neue Implementierungsarbeit beginnt.
- Investiere vor der Implementierung bewusst mehr Aufwand in Planung und Verifikationsdesign.
- Reproduziere zuerst: bestätige immer das aktuelle Verhalten bzw. Signal des Problems, bevor du Code änderst, damit das Ziel des Fixes eindeutig ist.
- Verwende für neue Zeitstempel im Abschnitt `Verlauf` immer lokale Systemzeit; schreibe dort keine UTC- oder `Z`-Zeitstempel.
- Halte die Ticket-Metadaten aktuell (Status, Checkliste, Validierung, Links).
- Betrachte genau einen persistierenden Linear-Kommentar als maßgebliche Quelle für den Fortschritt.
- Verwende genau diesen einen Workpad-Kommentar für alle Fortschritts- und Übergabenotizen; poste keine separaten "done"/Zusammenfassungs-Kommentare. Davon ausgenommen sind ausdrücklich von aufgerufenen Skills geforderte Nachvollziehbarkeitskommentare.
- Wechsle den Status nur, wenn die entsprechende Qualitätsschwelle erreicht ist.
- Jeder Statuswechsel ist eine harte Turn-Grenze: aktualisiere vorher den Workpad-Checklistenstand, führe den Statuswechsel aus, schreibe nur eine knappe Abschlussnachricht und beginne den Zielstatus nicht mehr im selben Turn.
- Vor jedem regulären Statuswechsel müssen alle für den aktuellen Status relevanten offenen Workpad-Checklistenpunkte erledigt oder als Blocker/Unklarheit dokumentiert sein. Offene Punkte, die ausdrücklich zur nächsten Statusphase gehören, dürfen offen bleiben.
- Arbeite autonom von Anfang bis Ende, solange du nicht durch fehlende Anforderungen, Secrets oder Berechtigungen blockiert bist.

## Voraussetzungen und globale Kontrakte

### Autonome Entscheidungen und Linear-Texte

Kleine, reversible Fach- und Implementierungsentscheidungen im Auftrag selbst
entscheiden; relevante Annahmen kurz begründen. Nur wesentliche, aus Anforderungen,
Konventionen und bestätigten Entscheidungen nicht auflösbare Fragen zu Produktziel,
Leistungsumfang oder strategischem Verhalten nach `Planung` geben. Technische
Details und kleine Verhaltensvarianten allein rechtfertigen keinen Rücksprung.
Behebbare Test-, Build-, Lint-, Coverage- und Integrationsfehler in der aktuellen
Phase reproduzieren, korrigieren und passend erneut prüfen. Die Merge→Test-Regel
für Dateiänderungen bleibt erhalten. `BLOCKER` nur ohne zulässigen autonomen
Fortsetzungsweg: notwendiger Zugang fehlt, echte externe Freigabe steht aus oder
Diagnose und geeignete Lösungsversuche belegen ein autonom unlösbares Hindernis.
Fehlerzahl, Aufwand und `agent.max_turns` allein reichen nicht. Vor Eskalation
Hindernis/Entscheidung, Versuche, Grenze der Autonomie und Fortsetzungsbedingung
knapp festhalten. Temporäre Fehler nach `symphony-linear` begrenzt behandeln.

Für alle agentenseitigen Linear-Texte: Ergebnis oder offene Entscheidung zuerst,
nur notwendige Begründung, Validierung und Fortsetzungsbedingung. Aktuellen Plan,
offene Pflichten und jüngsten Übergabestand pflegen; überholte Details verdichten,
Logs referenzieren. Pflichtnachweise, Quellen, Acks, Skips und auswertbare
Überschriften/Checklisten erhalten; Details im Skill `symphony-workpad`.

### Phasenpflichten und Betreiberübergaben

Jeden Pflichtnachweis in Planung/Workpad mit Aktion, Verantwortlichem
(Worker oder Betreiber), fälliger Phase und konkreter Entscheidungsquelle oder
technischer Begründung führen. Eine agentenseitige Planfrist allein ist keine
Nutzerentscheidung. Irrtümliche Frühfristen begründet korrigieren, Pflicht und
vorhandene Belege erhalten; konkrete frühere Nutzer-/Sicherheitsfreigaben nicht
verschieben. Bekannte Zuständigkeit übernehmen; materielle Entscheidungen nach
`Planung` zurückgeben.

Vor Merge sind erforderliche Build-/Test-/technische Review-/Mergegates und
konkrete frühere Freigabepflichten zu erfüllen. Finale Produkt-/Zielumgebungsabnahme
am gemergten bzw. regulär ausgelieferten Stand ist standardmäßig in `Review`
fällig, bei Agentdelegation bereits in `Yolo Review`. Fehlende Installation dieses neuen Stands allein sperrt Merge nicht.
Frühe isolierte Produkt-/Paket-/Integrationsprüfungen bleiben erforderlich;
fehlende notwendige Testumgebung oder rote technische Gates sind keine finale
Betriebsabnahme. `Review` ist weder `Review (AI)` noch `Freigabe Review`.
Merge erteilt keine Deploymentfreigabe und bestätigt keine Produktabnahme.
Später fällige Nachweise bleiben sichtbar offen, ohne falsche Häkchen.

Fehlt ein fälliger Betreiberbeleg, zunächst erlaubte Diagnose, Nacharbeit und
verfügbare gebundene Testausführung erledigen. Ein beauftragter Betreiberagent
übernimmt vorhandene autorisierte Testbereitstellung und Prüfung selbst;
Workerbeschränkungen allein erzeugen keine neue menschliche Freigabepflicht. Nur wenn danach kein zulässiger
autonomer Fortsetzungsweg bleibt, im einen Workpad Aktion, Rolle, Quell-/Paketstand, bestandene lokale Prüfungen, fehlende
externe Belege und Fortsetzungsphase übergeben; nach `BLOCKER` wechseln und den
Turn beenden. Das gilt auch für externe Testvoraussetzungen. Kein erfundener
Authfehler, keine fremden Checkouts oder Betriebsumstellung durch den Worker.
Bei Wiederaufnahme vor weiterer Phasenarbeit Beleg, Geltungsbereich und Stand
abgleichen: Statusschieben allein ist keine Abnahme. Ohne passenden neuen Beleg
bleibt das Gate offen; negative Befunde erlauben Nacharbeit im Scope und erneute Prüfung. Nur ohne zulässigen autonomen Weg
dieselbe Übergabe erhalten und nach `BLOCKER` zurückgeben; keinen unerfüllbaren
Betreiberauftrag oder zusätzlichen Review allein wegen Wartezeit neu starten.
Details und synthetische Fälle: [Betreiberpflichten und Wiederaufnahme](docs/linear-app.md#betreiberpflichten-und-wiederaufnahme).
Freigegebene Routinetests nach einmaliger Einrichtung über `symphony_test`
aufrufen; `worker.test_executor` verwaltet den lokalen Executor an
`worker.test_executor_socket` im regulären Dienst. Keine zusätzliche Bestätigung
pro Lauf; Quell-/Laufbindung, echte externe Freigaben und Pflichtgates bleiben
wirksam. Einrichtung, optionaler Zusatztestbetrieb und Ergebnisvertrag:
[Gebundener Testaufruf](docs/linear-app.md#gebundener-testaufruf).

### Start- und Laufzeitvertrag

Nutze regulär `./symphony` unter Linux oder macOS. Voraussetzungen und
Start-/Build-Details stehen bei Bedarf in [README.md](README.md#voraussetzungen)
und [Einrichtung](README.md#einrichtung). `bin/symphony` benötigt bereits
aktives Erlang, etwa über `mise exec -- bin/symphony`.
Optionale Betreiber-Messläufe verwenden den normalen Launcher mit
`--budget-capture` gemäß [Messübergabe](docs/linear-app.md#ausführbare-operator-messübergabe-pro-716).
Für manuelle Ticketstarts aus dem Fachprojektroot den absoluten `sym-codex`-Pfad
der gewünschten Installation mit Ticket-ID verwenden; globale Links sind dafür
nicht erforderlich und bleiben an ihre bisherige Installation gebunden.

Symphony und Helfer laufen aus dem ursprünglichen Checkout. Bestätigte Updates
aktualisieren ihn; unveränderte Starts verwenden den bestehenden Build.
Originale Workflow- und öffentliche Envdateien werden beim Poll neu geladen.
Änderungen gelten für Polling und künftige Worker; laufende Worker behalten ihren
Projektkontext. Fachprojektdateien überschreiben weder Modellstartwerte noch
Reviewbudget. `SYM_PROJECT_ROOT` akzeptiert mehrere kommaseparierte Basispfade;
deren Änderung sowie Auth-/Scope- und Worktreeroot-Wechsel erfordern einen Neustart.
Ungültige Änderungen ersetzen keinen gültigen Projektkontext.

### Projekte und gemeinsamer Dienst

- Arbeite im gebundenen Projektkontext mit eigenen Hooks, Worktrees, Sessions
  und Zustand. Reguläre Workspaces bleiben unter dem konfigurierten Root;
  Roots verschiedener Projekte dürfen sich auch über Symlinks nicht überlappen.
  Verwende etwa `workspace.root: $SYMPHONY_PROJECT_WORKTREES_ROOT`.
- Projekte desselben Linear-Workspace verwenden dieselbe verifizierte App und
  dieselben Client Credentials. `LINEAR_ASSIGNEE` ist eine getrimmte,
  deduplizierte Liste menschlicher E-Mails/UUIDs; `me` und App-Benutzer sind
  unzulässig. Der `--yolo`-Sonderfall steht in der Statusübersicht.
- Optional bindet `LINEAR_YOLO_AGENT` einen eindeutig aufgelösten Linear-Agenten
  über `delegateId`; menschliche Zuständigkeit bleibt separat. Das Übergabeziel
  ist der erste konfigurierte Mensch in Listenreihenfolge. Bindungsänderungen
  verlangen Neustart; Details: [Agentenbindung](docs/linear-app.md#agentenbindung).
  Die Agentenbindung aktiviert unabhängig von `--yolo` gesonderte PO-Sammelläufe
  nach [WORKFLOW_YOLO_AGENT.md](WORKFLOW_YOLO_AGENT.md), dessen Delegationsfreigabe
  im Ticketscope sowie Mehrticket-/Statusvertrag und der an den versionierten
  Projekt-Skill gebundenen Schlussabnahme mit Prüf-/Lernbeleg. Die folgende Statustabelle und ihre Turn-Grenzen
  gelten weiterhin für reguläre Einzelläufe.
  Optional wählt `OPENCLAW_YOLO_AGENT` ausschließlich deren PO-Ausführungsweg;
  ohne Wert erfolgen keine OpenClaw-Zugriffe. Aktivierung verlangt den separaten
  Live-Nachweis, Standardgates bleiben unabhängig; [Vertrag](docs/openclaw-yolo.md).
  Belegte OpenClaw-Vorab-Ablehnung gibt nur den nicht gestarteten Auftrag frei;
  unklare Annahme bleibt reserviert. Neue unterbrochene Aufträge dürfen nach
  wirksamem Schreibentzug und frischer Inaktivitäts-/Eingabeprüfung technisch
  aufgegeben werden; offene Arbeit wird regulär neu geplant, kein Erfolg fingiert.
  Belegimporte und ausdrücklich beauftragte administrative Altfallbereinigungen
  erfolgen getrennt durch den Betreiber gemäß diesem Vertrag.
- Jedes Projekt hat ein eigenes Codex-Home mit genau seiner Trust-Freigabe
  (bei Git-Worktrees für den Git-common-root). Abweichungen der erzeugten
  `config.toml` oder der geprüften Repository-Skills blockieren den
  Start; vorhandene Sessions bleiben erhalten. Persönliche MCPs und Plugins
  bleiben gesperrt. Secrets bleiben aus öffentlicher Umgebung und Prompts
  ausgeschlossen; private Envdateien sind kein Agentenzugriffspfad.
- Eine gemeinsame Dienstinstanz pro Benutzer; ein konkurrierender Start endet
  mit „Symphony läuft bereits“. Manuelle Helfer sind keine zweiten Dienste.
  `--test-instance <name>` erlaubt zusätzlich genau einen exklusiven Testbetrieb
  auf dem verifizierten Dummy-Projekt `Prolok/symphony-test` mit disjunktem Projektbereich,
  eigenem Zustand/Port und gemeinsamen Issue-Leases/API-Grenzen; Einrichtung und
  Pflichtbelege: [Isolierter Testbetrieb](docs/linear-app.md#isolierter-testbetrieb).
  `sym-codex` und `sym-watch` verlangen bei mehrdeutigen Kennungen
  `Projekt:Ticketkennung`.
- Die interne Zustandskennung ist `symphony`. Abweichenden Altzustand nur gemäß
  [Betreiberübergabe](docs/linear-app.md#einmalige-betreiberübergabe) behandeln;
  keine automatische Löschung oder beliebigen Installations-IDs.

`LINEAR_APP_CLIENT_ID`, `LINEAR_APP_WORKSPACE_ID` und `LINEAR_APP_USER_ID`
sind nichtgeheime Installationskennungen und in versionierter `.symphony/.env`
zulässig. `LINEAR_APP_SECRET`, `LINEAR_RELAY_KEY`, Zugangstoken und produktive
Kundendaten bleiben geschützt; Details unter [Normale Einrichtung](docs/linear-app.md#normale-einrichtung).

Bei Änderungen an Discovery gezielt
[Normale Einrichtung](docs/linear-app.md#normale-einrichtung) lesen;
für Reload oder gemeinsame Kapazitäten
[Projektbindung und Polling](docs/linear-app.md#projektbindung-und-polling)
und für Start-/Trust-/Secret-Details
[Schutz der Zugangsdaten](docs/linear-app.md#schutz-der-zugangsdaten).

Der Dienst empfängt LinearRelay v1 je Workspace über einen gemeinsamen geschützten
Key und eine dauerhafte Consumer-ID. Die verifizierten lokalen `LINEAR_ASSIGNEE`-
Werte bestimmen je Projekt die Ausführung, auch für `--yolo`, Retries und manuelle
Helfer; ohne lokale Zuständigkeit bleiben Starts gesperrt. Pro Workspace/Assignee
ist je Projektbereich genau ein ausführender Rechner zu konfigurieren;
der explizite Testbetrieb verlangt disjunkte Bereiche. Keine globale Sperrgarantie.
Reguläre Relay-Abrufe erfolgen standardmäßig alle fünf Sekunden. Kein automatischer
Rechnerwechsel oder Linear-Ersatzpoll bei Relay-Störung. Frische kritische Prüfungen,
lokale Leases und Pflichtgates bleiben erhalten. Einrichtung und gemeinsamer
Versionswechsel: [LinearRelay](docs/linear-app.md#linearrelay-empfang-zuständigkeit-und-gemeinsame-umstellung).

### Linear-Zugriff

Im App-Modus ausschließlich das injizierte `linear_graphql` oder das gebundene
`symphony_linear`-MCP nutzen. Bei Transportausfall den anderen gebundenen Pfad
verwenden und temporäre Fehler gemäß `symphony-linear` begrenzt wiederholen.
Bleiben beide ohne zulässige Recovery ausgefallen, sichtbar stoppen;
Kommentar/Status nur über einen funktionierenden erlaubten Pfad schreiben und Speicherung nur nach Bestätigung
behaupten. Keine privaten Envdateien, persönlichen Tokenfallbacks oder Umgehung
der Secret-Abschirmung; `scripts/linear-app` ist ein geschütztes Betreiberwerkzeug,
kein Modell-Shell-Ersatz.

HTTP 401, HTTP 403 ohne Rate-Limit-Signal und `classification: "auth"` bedeuten
fehlenden Zugriff: gemäß `Blocked-access escape hatch` handeln.
`classification: "rate_limited"`, `extensionsCodes` mit `RATELIMITED` oder
`rateLimit.limited: true` sind Rate-Limits, kein Auth-Blocker. Nicht erschöpfte
Rate-Limit-Header bleiben Diagnosehinweise.

Für den ersten Issue-Lookup den schema-konformen Bootstrap aus `symphony-linear`,
Abschnitt „Issue-Lookup“, verwenden: nur ID, Kennung, Titel und Status abfragen.
`issue(id: $key)` nur bei in dieser Session bestätigter Key-Unterstützung nutzen,
sonst Team-Key und Nummer. Danach interne ID für begrenzte Folgeabfragen verwenden;
keine spekulativen `links`-/Identifier-Filter. Unbekannte Felder, Inputs oder
Mutationen vor Verwendung gezielt per Introspection prüfen.

Je App-Anfrage eine Kommentar-ID höchstens einmal verändern; mehrere Änderungen
dieser ID einzeln senden. Unklare Schreibausgänge anhand der gemeldeten
Kommentar-ID abgleichen, keine blinde Neuanlage oder Wiederholung.
Für unterstützte Update-Felder und Journalfehler gezielt
[Kommentarjournal und App-Mutationen](docs/linear-app.md#kommentarjournal-und-app-mutationen)
lesen.

### Git-Branch-Kontrakt

- Der kanonische Arbeitsbranch für dieses Issue heißt immer `symphony/{{ issue.identifier }}`.
- Wenn ein frischer Branch benötigt wird, erstelle oder verwende genau `symphony/{{ issue.identifier }}` von `origin/main`.
- Erstelle keine alternativen Branch-Namen mit persönlichen Präfixen, Slugs aus dem Titel oder anderen Abweichungen.
- Wenn die aktuelle Linear-API `branchName` in `IssueUpdateInput` unterstützt, synchronisiert Symphony das Linear-Feld `branchName` auf den aktuell genutzten Workspace-Branch.
- Wenn die aktuelle Linear-API dieses Feld nicht unterstützt oder Linear bzw. ältere Workpad-Notizen einen anderen Branchnamen anzeigen, behandle das als veraltete Metadaten und passe den lokalen Branch nicht daran an; der lokale Branchname und die dazugehörige PR bleiben maßgeblich.

### Verwandte Skills

- `symphony-linear`: mit Linear interagieren.
- `insight-query`: falls dieser Skill vorhanden ist, für zusätzliche Kontextrecherche nutzen; in `Planung (AI)` insbesondere frühere Tickets zu vergleichbaren Themen und die semantische Suche des Skills einbeziehen.
- `symphony-push`: nach lokalen Commits den Remote-Branch aktualisieren oder erstmals veröffentlichen, PR-Updates veröffentlichen und neu erzeugte PRs am aktiven Linear-Issue anhängen.
- `symphony-pull`: bei Eintritt in `In Arbeit (AI)`, `Review (AI)` und `Test (AI)` den Branch per Rebase mit dem neuesten `origin/main` synchronisieren. Wenn der Pull/Rebase einen Konflikt nicht autonom auflösen kann und der aufrufende Ablauf keinen spezielleren manuellen Rücksprung definiert, dokumentiere den Blocker im Workpad und verschiebe nach `BLOCKER`.
- Repo-lokale Skills werden direkt unter `{{ runtime.active_repo_skill_root }}` gesucht.
- Globale Skills werden direkt unter den globalen Skill-Wurzeln `{{ runtime.global_skill_roots_text }}` gesucht.
- `symphony-prereview`: wenn das Ticket `PreReview (AI)` erreicht, den globalen Skill `symphony-prereview` explizit öffnen und befolgen.
- `symphony-review`: wenn das Ticket `Review (AI)` erreicht, den globalen Skill `symphony-review` explizit öffnen und befolgen; `runtime.maximum_review_iterations={{ runtime.maximum_review_iterations }}` begrenzt die Reviewrunden gemäß Skill.
- `symphony-test`: wenn das Ticket `Test (AI)` erreicht, den globalen Skill `symphony-test` explizit öffnen und befolgen.
- `symphony-land`: wenn das Ticket `Merge (AI)` erreicht, den globalen Skill `symphony-land` explizit öffnen und befolgen; dort ist die `symphony-land`-Schleife enthalten.

### Globale Arbeitsregeln

- In Umsetzung und PreReview `make check` plus änderungsbezogene Tests nutzen;
  Review-Fixes gezielt nachweisen. Die vollständige Suite (`make all`) läuft
  regulär in `Test (AI)`. Relevante Änderungen/Rebases oder Fehler erfordern
  erneute betroffene Nachweise, ein Phasenwechsel allein nicht. Ticketpflichten
  und der Rücksprung Merge→Test bei Dateiänderungen bleiben erhalten.

- Betrachte jeden vom Ticket vorgegebenen Abschnitt `Validation`, `Test Plan` oder `Testing` als nicht verhandelbare Validierungsvorgabe: übernimm ihn als Punkte im Abschnitt `### Validierung` des Workpads und führe ihn aus, bevor du die Arbeit als abgeschlossen betrachtest.
- Folge-Tickets über `symphony_yolo_action` (`kind=followup`) mit klaren
  Anforderungen/Validierung, aktuellem Ursprung und stabilem `operation_key`
  erstellen. Der gebundene Pfad bestätigt `symphony-generated`, dasselbe
  Projekt, Backlog und `related`; `blocked_by` nennt vorausgehende Arbeit.
  Mit Agentenkonfiguration erhalten sie unabhängig von `--yolo` Agent und
  konfigurierten Menschen, sonst keine dieser Zuweisungen. Unklare Schreibausgänge mit derselben
  Operation abgleichen; ohne bestätigte Labels/Links keinen Erfolg melden.
- Nutze den blocked-access escape hatch nur für echte externe Blocker (fehlende erforderliche Tools/Auth), nachdem dokumentierte Fallbacks ausgeschöpft wurden.

### Turn-Abschlussvertrag für aktive AI-Status

- Vor einer finalen Antwort in einem aktiven AI-Status öffne den Workpad-Kommentar erneut und prüfe die phasenspezifischen Abschlussbedingungen.
- Beende den Hauptturn regulär nur nach sauber abgeschlossenem Phasenschritt und zulässigem Statuswechsel. Offene fällige Punkte, fehlende oder nicht bewertbare Pflichtchecklisten sowie fehlende Merge-Evidenz bedeuten: im selben Turn weiterarbeiten oder die fällige Betreiberübergabe ausführen.
- Wenn ein `wait_agent`-Ergebnis mit Review-Findings erst spät im Turn eintrifft, zuerst diese Findings bearbeiten und die Review-Schleife fortsetzen; der Findings-Erhalt allein erfüllt den Abschlussvertrag nicht.
- Ein finaler Antworttext ohne Statuswechsel ist nur für dokumentierte echte Blocker oder `agent.max_turns` zulässig.
- Runtime-Fallbacks, die ein Issue nach normalem Turn-Ende weiter aktiv halten oder einen Handoff nachholen, sind Guardrails und kein regulärer Skill-Abschluss.

## Statusübersicht

Automatische Statuswechsel leiten ihre Reihenfolge ausschließlich aus dieser
Tabelle ab. Wenn für den vorgesehenen Zielstatus ein Label `Skip "<Status>"`
existiert, überspringt Symphony diesen Status und läuft zum nächsten nicht
übersprungenen Tabellenstatus weiter; mehrere aufeinanderfolgende Skip-Labels
werden in derselben Reihenfolge nacheinander ausgewertet. Wenn der aktuelle
Status selbst ein manueller Freigabe-Status ist und dafür ein passendes
`Skip "<Status>"`-Label gesetzt wurde, verwendet Symphony den nächsten
Tabellenstatus als Ziel und läuft von dort weiter.

Wenn Symphony mit `--yolo` gestartet wird, gelten `Freigabe Implementierung`
und `Freigabe Review` unabhängig von gesetzten Labels als übersprungen.
Review-Findings, Review-Fixes, Dirty-Workspace oder uneindeutige
No-Findings-Signale müssen weiterhin vom Hauptagenten behandelt und dokumentiert
werden; danach überspringt `--yolo` aber auch `Freigabe Review`. Außerdem
empfängt Symphony Relay-Ereignisse workspaceweit; die Ausführung bleibt auf
lokal konfigurierte, verifizierte menschliche Assignees begrenzt;
die Hauptmaske zeigt in diesem Modus `--yolo` statt des Assignees.

Jeder automatische Statuswechsel beendet den aktuellen Codex-Turn. Der
Zielstatus wird erst in einer neuen Codex-Session bearbeitet; Skip-Ketten
werden dabei weiter in Tabellenreihenfolge aufgelöst.

Ein ausdrücklich angewiesener technischer Review-Skip oder nachvollziehbar
bewusster manueller Einstieg in `Test (AI)`/`Merge (AI)` ist zulässig.
Spätere belegte menschliche Gateentscheidungen haben Vorrang vor älteren
Beschreibungs-/Workpad-Defaults. Zugehörige Skip-Labels erhalten, Quelle und
Geltungsbereich dokumentieren; keine erneute Zustimmung oder pauschale
Labelbereinigung. Eine separat übernommene PO-Prüfung darf einen autorisierten
manuellen Gate-Skip nicht als versteckten Pflichtstop wieder aufheben.
`Skip "Review (AI)"` verwenden, soweit passend; eindeutige Anweisungen brauchen
keine erneute Bestätigung oder ein zusätzliches Label. Im Workpad
`bewusst übersprungen` mit Entscheidungsquelle und Geltungsbereich festhalten, historische
Review-Checkboxen entsprechend einordnen, keinen Erfolg behaupten. Fehlende
Planungs-/PreReview-/Reviewhistorie allein erzwingt dort weder Nachholrunde noch
BLOCKER; unbekannter Vorzustand belegt keinen bewussten Skip.
`Skip "Freigabe Review"` betrifft nur das manuelle PO-Gate. Aktuelle Tests, Testumgebung,
geheimnisfreie Veröffentlichung, PR-/Head-/Merge-Gates und `Requires Manual Review`
bleiben wirksam; ein Review-Skip ersetzt keinen Betreiberbeleg.

| Status | Im Scope | Bedeutung / Verhalten | Nächster regulärer Status |
| --- | --- | --- | --- |
| `Backlog` | Nein | Außerhalb des Scopes dieses Workflows; nicht ändern. | Warten auf menschliches Verschieben nach `Todo (AI)` |
| `Todo` | Nein | Außerhalb des Scopes dieses Workflows; Benutzer-Todo ohne Automatisierung. | Warten auf menschliches Verschieben nach `Todo (AI)` |
| `Todo (Dialog-AI)` | Ja | Isolierter Dialog- und Vorplanungsmodus außerhalb des regulären Workflows. Symphony verwendet `WORKFLOW_DIALOG.md`, erstellt keinen Worktree, führt keine Hooks aus, startet Codex im Projektroot und veröffentlicht Antworten als Linear-Kommentar. Bei ausdrücklich bestätigter Umsetzungsticket-Erstellung darf der Dialog-AI-Prompt zusätzlich das neue Ticket erstellen/verknüpfen und das Ursprungsticket nach `Umsetzungsticket erstellt` verschieben. | Bleibt in `Todo (Dialog-AI)` bis zu externem Statuswechsel, neuem Benutzerkommentar oder erfolgreicher Erstellung eines bestätigten Umsetzungstickets |
| `Umsetzungsticket erstellt` | Nein | Abschlussstatus für ein Ursprungsticket nach erfolgreicher bestätigter Umsetzungsticket-Erstellung aus `Todo (Dialog-AI)`; keine weitere Automatisierung. | - |
| `Todo (AI)` | Ja | In der Warteschlange; vor aktiver Arbeit sofort nach `Planung (AI)` verschieben. | `Planung (AI)` |
| `Planung (AI)` | Ja | Ticketbeschreibung und Workpad-Planung vorbereiten und entscheiden, ob vollständig autonome Umsetzung möglich ist. | `In Arbeit (AI)` |
| `Planung` | Nein | Manueller Klärungs- und Planschärfungspunkt für wesentliche, aus dem Kontext nicht auflösbare Produktziel-, Umfangs- oder Strategieentscheidungen. | Warten auf menschliches Verschieben |
| `In Arbeit` | Ja (Bootstrap) | Manueller Benutzer-In-Arbeit-Bootstrap: Symphony erstellt nur Workspace/Worktree inkl. `after_create`-Hook, startet kein Codex und ändert den Status nicht. | Warten auf menschliches Verschieben |
| `In Arbeit (AI)` | Ja | Vor der Umsetzung `symphony-pull` ausführen; danach den vorbereiteten Plan umsetzen. Anpassungen im Auftrag begründet im Workpad pflegen; nur wesentlichen unauflösbaren Produktklärungsbedarf nach `Planung` zurückgeben. | `PreReview (AI)` |
| `PreReview (AI)` | Ja | `symphony-prereview` ausführen. | `Freigabe Implementierung` |
| `Freigabe Implementierung` | Nein | Manueller Review- und Commit-Schritt nach PreReview; ohne Skip-Label keine weitere automatische Aktion bis zum nächsten menschlichen Statuswechsel. | Warten auf menschliches Verschieben |
| `Review (AI)` | Ja | Vor `symphony-review` `symphony-pull` ausführen; beim ersten Eintritt offene Workspace-Änderungen einmalig mit einem issue-bezogenen Autocommit sichern. Abschlussstatus nach Review-Ergebnis sowie `--yolo` oder `Skip "Freigabe Review"`. | `Freigabe Review` |
| `Freigabe Review` | Nein | Manueller Freigabepunkt der reviewten Version vor dem Test-/Merge-Zyklus; ohne Skip-Label keine weitere automatische Aktion. | Warten auf menschliches Verschieben |
| `Test (AI)` | Ja | Branch vor den Tests per `symphony-pull` auf den späteren PR-Merge-Stand synchronisieren und danach `symphony-test` ausführen. | `Merge (AI)` |
| `Merge (AI)` | Ja | Merge-Ablauf mit `symphony-land` ausführen; automatische Commits sind hier zulässig. Wenn Pull, Konfliktlösung oder andere Merge-Dateiänderungen neue Änderungen erzeugen oder übernehmen, nach `Test (AI)` zurückspringen. Wenn `Requires Manual Review` ohne gültiges GitHub-Approval blockiert oder der aktuelle Linear-Labelstand nicht verifizierbar ist, nach `BLOCKER` verschieben. | Bei Agentdelegation `Yolo Review`, sonst `Review`; bei Merge-Dateiänderungen `Test (AI)`; bei fehlendem gültigem Manual-Review-Approval oder nicht verifizierbarem Labelstand `BLOCKER` |
| `BLOCKER` | Nein | Hindernis ohne zulässigen autonomen Fortsetzungsweg; keine weitere automatische Aktion, bis ein Mensch das Problem löst und das Ticket weiter verschiebt. | Warten auf menschliches Verschieben |
| `Abbruch (AI)` | Ja | Laufende Arbeit sofort abbrechen und Cleanup ausführen. | `Abgebrochen` |
| `Yolo Review` | PO-Sonderlauf | Schlussabnahme agentendelegierter gemergter Tickets samt Folgefixkette nach `WORKFLOW_YOLO_AGENT.md`; kein regulärer Codingstart, nur geprüfter Abschluss nach `Review`. | `Review` mit entfernter Delegation |
| `Review` | Nein | Terminaler Übergabestatus nach dem Merge; keine weitere automatische Aktion, manuelles Verschieben nach `Fertig` bleibt beim Benutzer. | - |
| `Fertig` | Nein | Terminaler Status; keine weitere Aktion erforderlich. | - |
| `Abgebrochen` | Nein | Terminaler Status nach explizitem Abbruch; keine weitere Aktion erforderlich. | - |

## Einstieg und Routing

1. Hole das Issue über die explizite Ticket-ID.
2. Lies den aktuellen Status.
3. Halte knapp fest, wenn Status und Issue-Inhalt nicht konsistent sind: im bestehenden Workpad oder, falls vor dem ersten Workpad-Bootstrap noch kein Workpad existiert, beim Anlegen des ersten Workpads. Fahre dann mit dem sichersten Ablauf fort.
4. Leite in den passenden Ablauf weiter:
   - `Backlog` -> Issue-Inhalt/Status nicht ändern; stoppen und warten, bis ein Mensch es auf `Todo (AI)` setzt.
   - `Todo` -> nichts tun und beenden; warten, bis ein Mensch das Issue auf `Todo (AI)` setzt.
   - `Todo (Dialog-AI)` -> Dialog-Sonderablauf aus `WORKFLOW_DIALOG.md` ausführen; keinen regulären Worktree erstellen; Statuswechsel nur im bestätigten Umsetzungsticket-Erstellungspfad nach `Umsetzungsticket erstellt` vornehmen.
   - `Umsetzungsticket erstellt` -> nichts tun und beenden; Umsetzungsticket wurde aus `Todo (Dialog-AI)` heraus erstellt.
   - `Todo (AI)` -> Ablauf `Todo (AI)` ausführen.
   - `Planung (AI)` -> Ablauf `Planung (AI)` ausführen.
   - `Planung` -> nichts tun und beenden; warten, bis ein Mensch die Planung geschärft und das Issue wieder in einen AI-Status verschiebt.
   - `In Arbeit` -> Workspace/Worktree-Bootstrap inkl. `after_create`-Hook durchführen, keinen Codex starten, keinen Statuswechsel ausführen und danach beenden.
   - `In Arbeit (AI)` -> Ablauf `In Arbeit (AI)` ausführen.
   - `PreReview (AI)` -> Ablauf `PreReview (AI)` ausführen.
   - `Freigabe Implementierung` -> mit `Skip "Freigabe Implementierung"` oder `--yolo` zum nächsten Tabellenstatus verschieben und den Turn beenden; sonst nichts tun und beenden, bis ein Mensch das Issue wieder in einen AI-Status verschiebt.
   - `Review (AI)` -> Ablauf `Review (AI)` ausführen.
   - `Freigabe Review` -> mit `Skip "Freigabe Review"` oder `--yolo` zum nächsten Tabellenstatus verschieben und den Turn beenden; sonst nichts tun und beenden, bis ein Mensch das Issue wieder in einen AI-Status verschiebt.
   - `Test (AI)` -> Ablauf `Test (AI)` ausführen.
   - `Abbruch (AI)` -> Ablauf `Abbruch (AI)` ausführen.
   - `Merge (AI)` -> Ablauf `Merge (AI)` ausführen.
   - `Yolo Review` -> nur gebundener PO-Sammellauf nach `WORKFLOW_YOLO_AGENT.md`; keinen regulären Einzellauf starten.
   - `Review` -> nichts tun und beenden.
   - `Fertig` -> nichts tun und beenden.
   - `Abgebrochen` -> nichts tun und beenden.

## Polling-Vertrag für `Todo (Dialog-AI)`

- Vor Codex-Start/Resume muss der Projektroot nach normaler Git-Semantik sauber
  sein. Vorbestehende Änderungen oder nicht ignorierte Dateien führen ohne
  Codex-Lauf zu einer konkreten Vorabmeldung mit Projektroot und
  `git status --short`; Symphony bereinigt keine Anwenderdateien. Nach einem
  gestarteten Lauf werden Git-Status und unveränderter HEAD auch auf Fehlerpfaden
  geprüft. Ignorierte Dateien bleiben außerhalb dieser Prüfung. Vorabmeldungen
  erhalten denselben Frische-/Quellbezug wie andere Dialogfehler; eine vorhandene
  Session bleibt erhalten. Details stehen in `WORKFLOW_DIALOG.md`.
- Codex startet nur bei einer echten offenen Dialoganfrage; No-op-Polls
  aktivieren keine Arbeit und verlängern nicht die Dienstlaufzeit.
  Signal-, Safety- und Idle-Details bei Änderungen am Polling gezielt in
  [Dialog-Polling](docs/linear-app.md#dialog-polling) lesen.

## Ablauf für `Todo (AI)`

### Ziel

Das Issue aus der Warteschlange in die Planungsphase überführen und den
Workpad-Startpunkt für den nächsten Turn vorbereiten.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Todo (AI)`.

### Ablauf

1. Für `Todo (AI)`-Tickets muss die Startsequenz exakt in dieser Reihenfolge erfolgen:
   - `update_issue(..., state: "Planung (AI)")`
   - `## Symphony Workpad`-Bootstrap-Kommentar finden/erstellen
   - falls der Kommentar dabei erstmals neu angelegt wird, prüfe die Trigger-Bedingungen des `Erstkontakt-Protokolls für neue Items` und führe es nur bei bestätigtem Erstkontakt aus
   - Workpad-Verlauf mit Statuswechsel und Bootstrap-Ergebnis aktualisieren
   - Turn danach beenden; nicht in den Ablauf `Planung (AI)` einsteigen.

### Abschluss und nächster Status

- Nach der unmittelbaren Statusänderung und dem Workpad-Bootstrap endet der
  Turn. `Planung (AI)` startet in einer neuen Codex-Session.

### Sonderfälle

- Keine.

## Ablauf für `Planung (AI)`

### Ziel

Ticketbeschreibung, Workpad-Plan und geplante Validierung so vorbereiten, dass die
anschließende Umsetzung in `In Arbeit (AI)` vollständig autonom beginnen kann, oder
offenen Klärungsbedarf so dokumentieren, dass der Benutzer den Plan im Status
`Planung` gezielt schärfen kann.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Planung (AI)`, oder kommt unmittelbar aus `Todo (AI)`.

### Ablauf

1. Finde oder erstelle genau einen persistierenden Scratchpad-Kommentar für das Issue und befolge für Aufbau und Pflege des Kommentars den globalen Skill `symphony-workpad`.
2. Führe die inhaltliche Planung mit dem globalen Skill `symphony-planning` aus:
   - prüfe, ob die Ticketbeschreibung ausführlich genug für sichere Umsetzung ist,
   - prüfe streng, ob Codex das Ticket auf Basis von Beschreibung, Workpad und Kontext vollständig autonom verstehen und umsetzen kann,
   - stelle bei langen Beschreibungen sicher, dass oben eine kurze Zusammenfassung mit Trenner `---` vor dem Haupttext steht,
   - du darfst die Ticketbeschreibung in diesem Status automatisiert ändern, wenn das für eine vollständige Planung nötig ist,
   - falls du die Ticketbeschreibung änderst, hinterlasse in Linear einen Kommentar mit der Originalbeschreibung, damit die Änderung nachvollziehbar bleibt,
   - erstelle oder aktualisiere `### Plan` als hierarchische Checkliste,
   - stelle sicher, dass der Plan explizite Schritte für automatisierte Tests enthält,
   - erstelle oder aktualisiere `### Validierung` als Checkliste des geplanten Nachweises.
3. Starte in diesem Status keine Implementierung.
4. Erstelle in diesem Status die initiale inhaltliche Planung. Spätere automatische Schritte dürfen `### Plan` und `### Validierung` bei Bedarf anpassen, wenn neue Erkenntnisse aus der Umsetzung das erforderlich machen; solche Änderungen müssen im Workpad nachvollziehbar begründet werden.
5. Entscheide am Ende dieses Status selbst, ob die Planung für eine vollständig autonome Umsetzung ausreicht.
   - Wenn ja, markiere die Planungs-Checklistenpunkte als erledigt, halte die Umsetzungsübergabe im Workpad fest, verschiebe das Issue nach `In Arbeit (AI)` und beende den Turn.
   - Kleine reversible Varianten im Scope autonom wählen und kurz begründen. Nur wesentliche, aus dem Kontext nicht auflösbare Produktziel-, Umfangs- oder Strategieentscheidungen als Klärungsbedarf übergeben.
   - Wenn nein, arbeite die vom System empfohlenen Lösungsvorschläge zunächst in `### Plan` und `### Validierung` ein, damit der Plan bei Zustimmung des Benutzers direkt ausführbar ist.
   - Lege anschließend in Linear einen separaten Kommentar an, der die offenen Verständnis- oder Umsetzungsfragen beschreibt, pro Frage einen empfohlenen Lösungsvorschlag nennt und deutlich macht, welche Planannahmen bereits eingearbeitet wurden.
   - Markiere die Planungs-Checklistenpunkte als erledigt, dokumentiere die offenen Punkte als Unklarheiten, verschiebe das Issue nach `Planung` und beende den Turn.

### Abschluss und nächster Status

- Wenn Ticketbeschreibung, `Plan` und `Validierung` ausreichend für vollständig autonome Umsetzung vorbereitet sind, verschiebe das Issue nach `In Arbeit (AI)` und beende den Turn.
- Wenn Klärungsbedarf bleibt, kommentiere die offenen Fragen mit empfohlenen Lösungen in Linear, verschiebe das Issue nach `Planung` und beende den Turn.

### Sonderfälle

- Wenn für sichere Planung erforderliche Informationen fehlen, erfinde keinen Scope. Halte die Lücke knapp im Workpad fest und handle anschließend gemäß den übrigen Workflow-Regeln weiter.

## Ablauf für `In Arbeit (AI)`

### Ziel

Umsetzung auf Basis des vorbereiteten Plans, lokale Validierung und ungecommittete
Übergabe nach `PreReview (AI)` oder Rückgabe nach `Planung`, wenn während der
Umsetzung eine wesentliche, aus dem Kontext nicht auflösbare Produktentscheidung offen bleibt.

### Voraussetzungen

- Das Issue befindet sich aktuell in `In Arbeit (AI)`.
- Bevor dieser Schritt beginnt, müssen Ticketbeschreibung, `Plan` und `Validierung` bereits in `Planung (AI)` vorbereitet und bei Bedarf im manuellen Status `Planung` geschärft worden sein.

### Ablauf

1. Öffne den vorhandenen `## Symphony Workpad`-Kommentar und behandle ihn gemäß dem globalen Skill `symphony-workpad` als aktive Ausführungs-Checkliste.
2. Führe anschließend den Skill `symphony-pull` aus, solange der Branch noch keine ungecommitten Arbeitsänderungen aus dieser Phase enthält.
3. Verwende `### Plan` und `### Validierung` aus der vorherigen `Planung (AI)`-Phase als Arbeitsgrundlage für die Ausführung.
4. Wenn neue Erkenntnisse aus der Umsetzung eine Anpassung innerhalb des Auftrags an `### Plan` oder `### Validierung` erforderlich machen, aktualisiere diese Abschnitte im bestehenden Workpad, dokumentiere den Grund knapp in `### Verlauf` und erhalte verpflichtende ticketseitige Validierungsvorgaben aus `Validation`, `Test Plan` oder `Testing`.
   - Nur wenn eine wesentliche, aus dem Kontext nicht auflösbare Entscheidung über Produktziel, Leistungsumfang oder strategisches Verhalten bleibt, stoppe die Umsetzung, dokumentiere die Frage mit empfohlenem Lösungsvorschlag im Workpad und in einem separaten Linear-Kommentar, aktualisiere `### Plan`/`### Validierung` nur als vorgeschlagene Variante und verschiebe das Issue nach `Planung`.
5. Erfasse vor der Implementierung ein konkretes Reproduktionssignal im Abschnitt `### Verlauf`.
6. Implementiere entlang der vorhandenen Plan-Checkliste und aktualisiere den Workpad-Kommentar nach jedem wesentlichen Meilenstein.
7. Führe die für den Scope erforderlichen Validierungen/Tests aus.
   - Verpflichtendes Gate: Erfülle alle jetzt fälligen Anforderungen aus `Validation`, `Test Plan` oder `Testing` in `### Validierung`; unerfüllte fällige Punkte verhindern den Abschluss. Explizit später fällige Nachweise bleiben bindend offen gemäß Phasenpflichten.
   - Bevorzuge einen gezielten Nachweis, der direkt das geänderte Verhalten zeigt.
   - Du darfst temporäre lokale Proof-Änderungen machen, um Annahmen zu validieren, wenn das die Sicherheit erhöht.
   - Nimm jede temporäre Proof-Änderung vor der Übergabe nach `PreReview (AI)` wieder zurück.
   - Dokumentiere diese temporären Proof-Schritte und Ergebnisse in `### Validierung` und/oder `### Verlauf`.
8. Wenn die Ausführung neue Erkenntnisse hervorbringt, prüfe, ob der Plan oder die geplante Validierung angepasst werden müssen. Passe sie bei Bedarf im Workpad an; wenn eine wesentliche, aus dem Kontext nicht auflösbare Produktziel-, Umfangs- oder Strategiefrage verbleibt, erfinde keinen neuen Scope und gib das Issue mit empfohlenem Lösungsvorschlag nach `Planung` zurück.
9. Führe nach dem vorgeschalteten `symphony-pull` keine weiteren automatischen Commits aus. Der Arbeitsstand aus der eigentlichen Umsetzung muss für `PreReview (AI)` und den anschließenden manuellen Schritt `Freigabe Implementierung` bewusst ungecommittet bleiben.
10. Aktualisiere den Workpad-Kommentar mit dem finalen Checklistenstatus und den Validierungsnotizen.
   - Markiere abgeschlossene Punkte in Plan-/Validierungs-Checklisten als erledigt.
   - Füge finale Übergabenotizen (lokaler Stand + Validierungszusammenfassung) im selben Workpad-Kommentar hinzu.
   - Halte explizit fest, dass der Arbeitsstand absichtlich ungecommittet für den `PreReview (AI)`- und anschließenden manuellen Schritt `Freigabe Implementierung` übergeben wird.
   - Füge unten einen kurzen Abschnitt `### Unklarheiten` hinzu, wenn irgendein Teil der Ausführung unklar/verwirrend war, mit knappen Stichpunkten.
   - Poste keinen zusätzlichen Abschluss- oder Zusammenfassungs-Kommentar.
11. Bestätige vor dem Wechsel nach `PreReview (AI)`, dass jeder jetzt fällige ticketseitige Validierungs-/Test-Plan-Punkt im Workpad explizit abgeschlossen ist; später fällige Punkte bleiben mit Verantwortlichkeit und Phase offen.
12. Öffne das Workpad vor dem Statuswechsel erneut und aktualisiere es, sodass `Plan` und `Validierung` exakt zur erledigten Arbeit passen.
13. Verschiebe das Issue erst danach nach `PreReview (AI)` und beende den Turn; führe `PreReview (AI)` nicht im selben Turn aus.

### Abschluss und nächster Status

- Der reguläre Abschluss dieser Phase ist `PreReview (AI)`, nicht direkt `Freigabe Implementierung`.
- Erst nach erfüllten Abschlussbedingungen nach `PreReview (AI)` verschieben und den Turn beenden.
  - Wenn Schritt 4 oder 8 wegen wesentlicher, aus dem Kontext nicht auflösbarer Produktentscheidung greift, ist stattdessen `Planung` der zulässige Abschluss dieser Phase.
  - Ein direkter Übergang von `In Arbeit (AI)` nach `BLOCKER` ist bei fälliger Betreiberübergabe oder über den blocked-access escape hatch zulässig.
  - Ausnahme: Wenn du gemäß blocked-access escape hatch durch fehlende erforderliche Tools/Auth blockiert bist, verschiebe nach `BLOCKER` und füge den Blocker-Hinweis sowie explizite Entblockungsaktionen hinzu.
- Vor dem Wechsel nach `PreReview (AI)` müssen alle folgenden Bedingungen erfüllt sein:
  - Die Checkliste aus diesem Ablauf ist vollständig abgeschlossen und korrekt im einen Workpad-Kommentar abgebildet.
  - Alle jetzt fälligen ticketseitigen Validierungspunkte sind abgeschlossen.
  - Validation/Tests sind für den aktuellen lokalen Arbeitsstand grün.
  - Das Workpad dokumentiert den finalen ungecommitten Übergabestand und die bestandene lokale Validierung explizit.
  - Falls die App berührt wird, sind die Runtime-Validierungsanforderungen aus `App runtime validation (required)` abgeschlossen.

### Sonderfälle

- Wenn du blockiert bist und noch kein Workpad existiert, füge einen Blocker-Kommentar hinzu, der Blocker, Auswirkung und nächste Entblockungsaktion beschreibt.

## Ablauf für `PreReview (AI)`

### Ziel

Den Skill `symphony-prereview` vollständig ausführen und das Issue danach in
den manuellen Schritt `Freigabe Implementierung` übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `PreReview (AI)`.

### Ablauf

1. Öffne den globalen Skill `symphony-prereview` und führe den dort definierten Ablauf aus.

### Abschluss und nächster Status

- Verschiebe das Issue erst danach nach `Freigabe Implementierung` und beende den Turn.
  - Nur dieser Schritt verschiebt regulär von `PreReview (AI)` nach `Freigabe Implementierung`.
- Solange die `### Review`-Checkliste im Workpad offen, fehlend oder nicht
  explizit abgehakt ist, ist kein regulärer Turn-Abschluss zulässig. Arbeite
  weiter oder dokumentiere einen echten Blocker beziehungsweise
  `agent.max_turns` ohne Statuswechsel.

### Sonderfälle

- Falls ein `PreReview (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `PreReview (AI)` steht, übernimmt Symphony den Statuswechsel nach `Freigabe Implementierung` nur als Guardrail-Fallback, wenn die `### Review`-Checkliste geschlossen und bewertbar ist. Bei offener, fehlender oder nicht explizit abgehakter Checkliste bleibt das Issue aktiv.

## Ablauf für `Review (AI)`

### Ziel

Den Skill `symphony-review` vollständig ausführen. Wenn der Skill einen
eindeutigen Review-Abschluss ohne Findings und mit sauberem Workspace ergibt,
`Freigabe Review` gemäß untenstehender Abschlussregel überspringen. In allen
anderen abgeschlossenen Fällen den Abschluss nach der Skill-Evidenz sowie
`--yolo` oder `Skip "Freigabe Review"` bestimmen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Review (AI)`.

### Ablauf

1. Führe zu Beginn den Skill `symphony-pull` aus, solange der Branch noch keine ungecommitten Arbeitsänderungen aus dieser Phase enthält.
2. Wenn das Issue in diesem `Review (AI)`-Aufenthalt erstmals bearbeitet wird und der Workspace dabei offene Änderungen enthält, committe sie einmalig mit der Commit-Nachricht im Format `<Issue-Key> Review (AI) Autocommit` plus kurzem Body, bevor `symphony-review` beginnt.
3. Wiederholte Fortsetzungsläufe oder Retries innerhalb desselben Aufenthalts in `Review (AI)` dürfen keinen weiteren `<Issue-Key> Review (AI) Autocommit` erzeugen, auch dann nicht, wenn inzwischen neue offene Änderungen aus dem Review vorliegen.
4. Öffne den globalen Skill `symphony-review` und führe den dort definierten Ablauf aus.
5. Nutze das Workpad in diesem Status nur als Quelle für Fortschritts- und Review-Protokollierung. Gleiche die aktuelle Implementierung nicht gegen frühere Workpad-Einträge ab. Erzeuge keine Implementierungsänderungen und nimm kein Zurückrollen bestehender Implementierung allein vor, um Details des Workpads zu erfüllen.
6. Führe nach dem vorgeschalteten `symphony-pull` und dem gegebenenfalls einmaligen Einstiegssnapshot keine weiteren automatischen Commits aus. Falls Fixes entstehen, arbeite mit offenen Änderungen weiter.

### Abschluss und nächster Status

- Wenn `symphony-review` ohne Findings und mit sauberem Workspace endet,
  verschiebe das Issue nach `Test (AI)` und beende den Turn, sofern keine
  ausdrücklich vereinbarte, weiterhin fällige PO-Abnahme an `Freigabe Review`
  besteht; in diesem Fall dorthin übergeben. Ein technischer No-Findings-Befund
  ersetzt ihren Beleg nicht. Autorisierte Skips gemäß Statusübersicht bleiben
  wirksam. Der reguläre No-Findings-Skip benötigt kein zusätzliches Skip-Label.
- In allen anderen abgeschlossenen Fällen muss die Review-Evidenz zuerst
  behandelt und dokumentiert sein. Ohne `--yolo` oder
  `Skip "Freigabe Review"` verschiebe das Issue danach nach `Freigabe Review`;
  mit `--yolo` oder `Skip "Freigabe Review"` nach `Test (AI)`. Beende den Turn
  direkt nach diesem Statuswechsel.
  - Nur dieser Schritt verschiebt regulär von `Review (AI)` nach `Freigabe Review`
    oder bei eindeutigem No-Findings-Skip direkt nach `Test (AI)`.
- Solange die `### Review`-Checkliste im Workpad offen, fehlend oder nicht
  explizit abgehakt ist, ist kein regulärer Turn-Abschluss zulässig. Arbeite
  weiter oder dokumentiere einen echten Blocker beziehungsweise
  `agent.max_turns` ohne Statuswechsel.

### Sonderfälle

- Falls ein `Review (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `Review (AI)` steht, übernimmt Symphony den passenden Statuswechsel nur als Guardrail-Fallback, wenn die `### Review`-Checkliste geschlossen und bewertbar ist. Bei offener, fehlender oder nicht explizit abgehakter Checkliste bleibt das Issue aktiv.

## Ablauf für `Freigabe Review`

Manueller Freigabepunkt. Symphony darf diesen Status im Candidate-Polling zur
Erkennung von `Skip "Freigabe Review"` oder `--yolo` mitlesen. Ohne dieses
Skip-Signal wird das Issue nicht dispatcht: weder coden noch Ticket-Inhalt
ändern, der nächste automatische Einstieg erfolgt dann erst nach externem
Statuswechsel. Wenn
Review-Feedback in `Merge (AI)` trotz Ticketkontext, Plan, Code, Tests und
lokaler Dokumentation nicht sicher autonom lösbar ist, dokumentiere es im
Workpad und Review-Thread, verschiebe zurück nach `Freigabe Review` und stoppe.

## Ablauf für `Test (AI)`

### Ziel

Den Branch vor dem Test per Rebase gegen `origin/main` synchronisieren,
`symphony-test` ausführen und das Issue danach nach `Merge (AI)` übergeben.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Test (AI)`.

### Ablauf

1. Falls der Branch bei Eintritt uncommitete Dateien enthält, committe sie in diesem Status mit der Commit-Nachricht im Format `<Issue-Key> Test (AI) Autocommit` plus kurzem Body.
2. Führe anschließend den Skill `symphony-pull` aus.
3. Öffne den globalen Skill `symphony-test` und führe den dort definierten Ablauf aus.
4. Nutze das Workpad in diesem Status für `### Test`, `### Verlauf`, Pull-Nachweise und die bereits aus früheren Phasen übernommene `### Validierung`. Die dort festgehaltenen ticketseitigen Validierungsvorgaben bleiben bindend. Gleiche die aktuelle Implementierung nicht gegen frühere Workpad-Einträge ab. Erzeuge keine Implementierungsänderungen und nimm kein Zurückrollen bestehender Implementierung allein vor, um Details des Workpads zu erfüllen.
5. Falls während des Testlaufs weitere Fixes entstehen, dürfen sie in diesem Status mit `<Issue-Key> Test (AI) Autocommit` plus kurzem Body committet werden.

### Abschluss und nächster Status

- Verschiebe das Issue nach `Merge (AI)` und beende den Turn.
  - Nur dieser Schritt verschiebt regulär von `Test (AI)` nach `Merge (AI)`.
- `### Test` muss vollständig abgeschlossen sein, `### Validierung` hinsichtlich
  aller jetzt fälligen Punkte. Später fällige Nachweise bleiben gemäß
  `symphony-workpad` offen. Fehlende/unbewertbare Pflichtchecklisten verhindern
  den Abschluss; weiterarbeiten oder fällige Betreiberübergabe ausführen.
  Bei `agent.max_turns` ohne Statuswechsel stoppen.

### Sonderfälle

- Falls ein `Test (AI)`-Lauf sauber endet, das Issue aber fälschlich noch in `Test (AI)` steht, übernimmt Symphony den passenden Statuswechsel nach `Merge (AI)` nur als Guardrail-Fallback bei geschlossener `### Test`-Checkliste und erfüllter fälliger `### Validierung`. Nur eindeutig nach `symphony-workpad` erst in Merge oder Review fällige offene Punkte sind ausgenommen; fehlende/unbewertbare Checklisten bleiben sperrend.

## Ablauf für `Planung`

Manueller Planschärfungspunkt nach offenen Fragen aus `Planung (AI)` oder nach
wesentlichem, aus dem Kontext nicht auflösbarem Produktklärungsbedarf aus `In Arbeit (AI)`. Weder coden
noch Ticket-Inhalt ändern, kein Polling. Weiterarbeit beginnt erst nach externem
Statuswechsel in einen AI-Status.

## Ablauf für `Freigabe Implementierung`

Manueller Review- und Commit-Schritt nach `PreReview (AI)`. Symphony darf
diesen Status im Candidate-Polling zur Erkennung von
`Skip "Freigabe Implementierung"` oder `--yolo` mitlesen. Ohne dieses
Skip-Signal wird das Issue nicht dispatcht: weder coden noch Ticket-Inhalt
ändern, Weiterarbeit beginnt dann erst nach externem Statuswechsel in einen
AI-Status.

## Ablauf für `Merge (AI)`

### Ziel

Den Merge-Ablauf mit `symphony-land` abschließen, erforderliche Auto-Commits in diesem Status durchführen und bei landebedingten Codeänderungen sauber nach `Test (AI)` zurückspringen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Merge (AI)`.

### Ablauf

1. Öffne den globalen Skill `symphony-land` und befolge den dort definierten Ablauf.
2. Lokale Volltests werden in `Merge (AI)` nicht pauschal ausgeführt; das vollständige lokale Gate bleibt Aufgabe von `Test (AI)`.
3. GitHub-Checks mit `skipped` ersetzen keine bestandene CI. Wenn GitHub-CI für diesen Push bewusst übersprungen wurde, ist `skipped` nur gemäß Policy akzeptabel; die lokale Test-Evidenz aus `Test (AI)` bleibt dann das maßgebliche Gate. `neutral` muss ausdrücklich neutral/akzeptiert oder blockierend klassifiziert sein; echte Fehler bleiben blockierend.
   Leere Checks nur bei vollständig belegtem No-CI akzeptieren: Im gebundenen
   Repository sind für den PR-Zielbranch keine Checks erforderlich und weder
   CI-Konfiguration noch CI-Signale vorhanden. Unbekannte Policy, unvollständige
   Abfragen oder fehlende erwartete CI blockieren. `symphony_merge` prüft frisch;
   No-CI als „nicht konfiguriert und nicht erforderlich“ melden. Lokale
   Test-/Review-Gates bleiben bestehen; Nachweise unter
   [GitHub-CI und No-CI](docs/linear-app.md#github-ci-und-no-ci).
4. Vor dem Merge müssen PR-/Remote-Evidenz und lokaler Stand konsistent sein:
   aktueller Branch `symphony/<Issue>`, vorhandener Remote-Branch
   `origin/symphony/<Issue>`, offene PR für diesen Branch und PR-Head-SHA gleich
   lokalem `HEAD`. Fehlender Remote-Branch, fehlende PR oder PR-Head-Mismatch
   dürfen nicht stillschweigend als mergefähig gelten.
   Ohne explizites `GH_REPO` ist `origin` für GitHub maßgeblich; eine lokale
   `upstream`-Standardauswahl ersetzt diese Bindung nicht. Beide Tooltransporte
   müssen den gebundenen Issue-Workspace prüfen; Transportdetails stehen unter
   [Dauerhafter Kommentareingang](docs/linear-app.md#dauerhafter-kommentareingang).
5. Wenn Remote-Branch oder offene PR fehlen, darf Recovery nur aus einem
   sauberen, lokal in `Test (AI)` validierten Stand über `symphony-push`
   erfolgen. Nach dem Push PR-Kontext und PR-Head erneut prüfen; Duplicate-URL
   beim Anhängen einer bereits vorhandenen GitHub-PR an Linear ist idempotent,
   andere Attachment-/Auth-/Berechtigungsfehler bleiben Fehler.
6. Falls beim Eintritt oder während des Merge-Ablaufs offene Änderungen vorhanden sind, committe sie ausschließlich in diesem Status mit der Commit-Nachricht im Format `<Issue-Key> Merge (AI) Autocommit` plus kurzem Body, pushe sie und verschiebe das Issue nach `Test (AI)`. Beende den Turn danach sofort; der normale Merge-Pfad wird nur fortgesetzt, wenn `Merge (AI)` keine Dateien verändert oder übernimmt.
7. Das Workpad dient in diesem Status primär der Fortschritts- und Merge-Dokumentation. Es bleibt zulässig, dort festgehaltenen Ticketkontext, Plan-Entscheidungen und Übergabenotizen als Hintergrund für Merge- und Review-Entscheidungen zu lesen. Gleiche die aktuelle Implementierung nicht gegen frühere Workpad-Einträge ab. Erzeuge keine Implementierungsänderungen und nimm kein Zurückrollen bestehender Implementierung allein vor, um Details des Workpads zu erfüllen.
8. Führe anschließend den Skill `symphony-land` in einer Schleife aus, bis die PR gemergt ist. `gh pr merge` nicht direkt aufrufen.
9. Wenn das Label `Requires Manual Review` gesetzt ist, greift nach sauberem
   PR-/Remote-Preflight, Mergebarkeitsprüfung, Review-Feedback-Prüfung und
   akzeptablen GitHub-Checks ein zusätzliches externes GitHub-Merge-Gate.
   Symphony darf erst mergen, wenn ein menschliches GitHub-Approval eines
   Nicht-Autors auf der aktuellen PR-Head-SHA vorliegt. `--yolo` und
   `Skip "Freigabe Review"` dürfen dieses Gate nicht umgehen. Bei fehlendem
   gültigem Approval darf kein Merge-Versuch ausgeführt und keine
   Merge-Evidenz erzeugt werden; dokumentiere im Workpad PR-Nummer oder URL,
   aktuelle Head-SHA, das Label `Requires Manual Review` und den Hinweis, dass
   ein manuelles GitHub-Review angefordert und durchgeführt werden muss.
   Fordere außerdem auf, das Issue nach erfolgtem GitHub-Review wieder nach
   `Merge (AI)` zu verschieben, verschiebe das Issue nach `BLOCKER` und
   beende den Turn.
   Wenn der aktuelle Linear-Labelstand im App-Server-Kontext nicht sicher
   geprüft werden kann, ist das ein eigener fail-closed Blocker vor dem Merge:
   dokumentiere PR-Nummer oder URL, aktuelle Head-SHA, den nicht verifizierbaren
   Labelstand und die notwendige Wiederholung nach behobenem Label-Lookup,
   verschiebe nach `BLOCKER` und beende den Turn.
   Im App-Modus führt der Hauptagent den vollständig paginierten Live-Labelabruf
   über das injizierte `linear_graphql` oder das gebundene `symphony_linear`-MCP
   aus. Der Watch-Helper übergibt nach seinen GitHub-Prüfungen mit Exit `8` an
   diesen noch offenen Schritt; das ist keine Merge-Freigabe. Danach das
   gegebenenfalls erforderliche menschliche Approval und den unveränderten
   lokalen/Remote-/PR-Head prüfen und die Evidenz im Workpad halten. Kein
   Shell-/Mix-Fallback im App-Modus.
   Der injizierte `SYMPHONY_ISSUE_LABELS_JSON`-Snapshot ersetzt keinen Live-Lookup.

10. Nach erfolgreichem PR-Merge dokumentiere vor jedem Abschluss nach `Review` oder `Yolo Review`
   eine eindeutige `Merge-Evidenz` im Workpad-Verlauf: PR-Nummer oder PR-URL,
   gemergter Zustand und Merge-Commit-SHA müssen enthalten sein.
11. Falls ein erneuter Pull/Rebase, die Konfliktlösung, Review-Feedback, ein CI-Fix oder eine andere Handlung in `Merge (AI)` zu Dateiänderungen führt oder Dateiänderungen übernimmt, committe diese mit `<Issue-Key> Merge (AI) Autocommit` plus kurzem Body, pushe sie, verschiebe das Issue nach `Test (AI)` und beende den Turn, damit die Tests auf dem neuen Stand in einer neuen Codex-Session erneut durchlaufen.

### Abschluss und nächster Status

- Nach abgeschlossenem Merge die Delegation frisch prüfen: mit Agentdelegation
  nach `Yolo Review`, sonst nach `Review`; Turn beenden. Das gilt auch für den
  Guardrail-Fallback. Offene Abnahmen bleiben im Workpad, technische Gates
  und Merge-Evidenz bleiben unverändert erforderlich.
- Symphony klärt nach dem Workerabschluss den Ticketzustand frisch und führt bei
  terminalem Status den bestehenden Workspace-Cleanup aus. Offene Statusklärung
  bleibt im Retry; laufende Merge-Abschlussprüfungen behalten den Workspace.
  Reservierte Routine-Testworktrees bereinigt ausschließlich der gebundene Testlauf.
- Ein normal beendeter Hauptturn alleine belegt keinen abgeschlossenen Merge.
  Falls das Issue nach einem sauber beendeten `Merge (AI)`-Turn noch in
  `Merge (AI)` steht, darf Symphony nur mit eindeutiger Workpad-`Merge-Evidenz`
  als Guardrail-Fallback zum oben bestimmten Übergabestatus wechseln; ohne diese Evidenz bleibt das
  Issue aktiv.
- Bei `agent.max_turns` dokumentiere offene Abweichungen im Workpad und stoppe
  ohne Statuswechsel; `agent.max_turns` ist kein normaler Phasenabschluss.

### Sonderfälle

- Wenn der Skill den Status bereits zulässig nach `Test (AI)`, `Yolo Review` oder `Review`
  geändert hat, endet der Turn an dieser Statusgrenze. Wenn der Status nicht
  geändert wurde und keine `Merge-Evidenz` vorhanden ist, weiterarbeiten oder
  einen echten Blocker dokumentieren.

## Ablauf für `Abbruch (AI)`

### Ziel

Laufende Arbeit sofort stoppen, den Workspace bereinigen und das Issue sauber abbrechen.

### Voraussetzungen

- Das Issue befindet sich aktuell in `Abbruch (AI)`.

### Ablauf

1. Brich laufende Arbeit sofort ab.
2. Entferne den zugehörigen Git-Worktree.
3. Lösche eine eventuell vorhandene PR und/oder den Remote-Branch über den bestehenden Cleanup-Ablauf.

### Abschluss und nächster Status

- Verschiebe das Issue danach nach `Abgebrochen` und beende den Turn.

### Sonderfälle

- Keine.

## Verpflichtende Sonderprotokolle

### Erstkontakt-Protokoll für neue Items

Führe dieses Protokoll nur dann aus, wenn alle folgenden Bedingungen gleichzeitig erfüllt sind:

1. Du hast in diesem Turn festgestellt, dass vorab kein aktiver `## Symphony Workpad`-Kommentar existierte und musstest deshalb einen neuen Workpad-Kommentar anlegen.
2. Du hast zusätzlich per separater, vollständig paginierter Kommentarabfrage einschließlich aufgelöster Kommentare bestätigt, dass für dieses Issue außer dem Workpad-Kommentar, den du gerade in diesem Turn neu angelegt hast, noch nie ein `## Symphony Workpad`-Kommentar existiert hat.
3. Wenn du diese Erstkontakt-Bedingung nicht zuverlässig verifizieren kannst, weil Kommentare oder Seiten nicht vollständig abrufbar sind, überspringe das Protokoll vollständig und lasse die Issue-Beschreibung unverändert.

Wenn die Trigger-Bedingungen erfüllt sind:

1. Lies den aktuellen Beschreibungstext des Issues direkt aus Linear.
2. Analysiere den Text auf Rechtschreibung, Grammatik, offensichtliche Spracherkennungsfehler und Formatierungsprobleme.
3. Korrigiere insbesondere falsche oder uneinheitliche Begriffe, die sich auf dieses Repository beziehen. Nutze dafür vorhandene Dateinamen, Modulnamen, Produktnamen, Workflow-Begriffe und andere repository-spezifische Referenzen als Quelle.
4. Bewahre die fachliche Bedeutung und den Scope des Tickets. Verbessere nur Sprache, Begriffswahl und Formatierung; füge keine neuen Anforderungen hinzu.
5. Speichere den bereinigten Beschreibungstext über den in der Sitzung verfügbaren Linear-Zugriff zurück in Linear. Nutze dazu den Linear-MCP-Server oder das injizierte Tool `linear_graphql` mit `issueUpdate(..., input: {description: ...})`, je nachdem was tatsächlich verfügbar ist, und nur wenn gegenüber dem Original tatsächlich eine qualitativ bessere, inhaltlich äquivalente Fassung entsteht.
6. Halte im Workpad knapp fest, ob die Erstkontakt-Korrektur durchgeführt wurde oder keine Änderung nötig war.
7. Führe dieses Protokoll niemals erneut aus, wenn bereits vor oder während eines früheren Turns ein Workpad-Kommentar für das Issue existiert hat.

### Blocked-access escape hatch

Nutze dies nur, wenn der Abschluss durch fehlende erforderliche Tools oder fehlende Auth/Berechtigungen blockiert ist, die in der laufenden Sitzung nicht auflösbar sind.

- Wenn ein erforderliches Tool fehlt, HTTP 401, HTTP 403 ohne Rate-Limit-Signal oder erforderliche Auth nicht verfügbar ist, versuche, das Ticket mit einem kurzen Blocker-Hinweis im Workpad über einen noch funktionierenden, im jeweiligen Modus erlaubten Schreibpfad nach `BLOCKER` zu verschieben. HTTP 403 mit `RATELIMITED`, `classification: "rate_limited"` oder `rateLimit.limited: true` ist ein Rate-Limit-Signal und kein blocked-access-Fall; bloße nicht erschöpfte `rateLimit`-Header ohne `limited: true` bleiben Diagnosehinweise. Dieser Hinweis muss enthalten:
  - was fehlt,
  - warum dadurch erforderliche Validierung blockiert wird,
  - welche exakte menschliche Aktion zum Entblocken nötig ist.
- Im App-Modus gilt der Zugriff ausschließlich über das injizierte `linear_graphql` bzw. das gebundene `symphony_linear`-MCP gemäß `Linear-Zugriff`: Fällt ein Tooltransport aus, nutze den verfügbaren anderen gebundenen Transport. Fehlen oder scheitern beide, stoppe und melde den Blocker sichtbar in der Abschlussnachricht; lokale Fallbacks sind ausgeschlossen.
- Erstelle einen dedizierten Blocker-Kommentar außerhalb des Workpads nur noch als letzte Stufe, wenn ein bestehender Workpad-Kommentar weder über den regulären Edit-Pfad noch über einen anderen erlaubten Toolpfad aktualisiert werden kann.
- Wenn kein im jeweiligen Modus erlaubter Schreibpfad funktioniert, dokumentiere den Blocker in der Abschlussnachricht; ohne irgendeinen funktionierenden Schreibpfad können weder Statuswechsel noch Blocker-Hinweis persistiert werden. Behaupte eine Speicherung nur nach bestätigtem Schreibzugriff.
- Halte den Hinweis knapp und handlungsorientiert; füge außerhalb des Workpads nur dann einen zusätzlichen Top-Level-Kommentar hinzu, wenn dieser dedizierte Blocker-Kommentar gemäß diesem Escape Hatch erforderlich ist.

## Kommentar-Checkpoints für reguläre Arbeit

Für tatsächlich übernommene aktive Issues ist der Kommentareingang Standard.
Der Hintergrundabgleich beobachtet Kommentare frühestens alle
`max(30 Sekunden, polling.interval_ms)`, ohne laufende Turns zu unterbrechen.
Phasenstart und Fortsetzung liefern offene Quellversionen an den Hauptworker. Nach Meilensteinen und vor Handoffs ruft dieser
`symphony_comments` mit `operation: "checkpoint"` auf; `issue_id` ist die interne
ID des aktuellen Issues. Manuelle Gates werden dadurch nicht aktiviert.

Der erste vollständige Scan liefert einmalig eine historische Baseline mit
bestehendem Workpad und Kommentaren. Vor Umsetzung deren noch relevante offene
Hinweise in Plan/Workpad übernehmen und den Startbeleg über `acknowledge`
festhalten. Historie nicht als Auftragsliste wiederholen. Bereits bekannte offene
Versionen bleiben bei der Baseline erhalten.

Optional bindet `tracker.advisory_agent_ids` bzw. `LINEAR_ADVISORY_AGENT_IDS`
Beratungs-App-User-UUIDs an das Projekt/Workspace; Änderungen verlangen Neustart.
Belegte Beratungsstränge und ungeklärte Kandidaten bleiben vor Baseline und
Coding-Zustellung ohne Quelltext ausgeschlossen. Bereits geladener Kontext bleibt
erhalten; [Vertrag und Nachweis](docs/linear-app.md#beratende-agentsession-stränge).

Vollständige lesbare Ack-Einträge mit Quellversion, Ergebnis, Begründung und
gegebenenfalls Ersatzbezug bei Workpad-Updates erhalten; sie sind der idempotente
Beleg. Keine neuen HTML-Ergebnis-Marker oder redundanten Hashes ergänzen.
Details zu Wiederaufnahme und automatischer Bereinigung alter Marker stehen unter
[Dauerhafter Kommentareingang](docs/linear-app.md#dauerhafter-kommentareingang).

Für jede zugestellte Version bestätigt `symphony_comments` mit
`operation: "acknowledge"` und `results: [{key, outcome, reason}]` das fachliche
Ergebnis im einen Workpad. `outcome` ist `übernommen`, `Rückfrage`,
`nicht anwendbar` (mit Begründung) oder `ersetzt` (zusätzlich `replacement` mit
der neueren Quellversion). Die Bestätigung einer Vorgängerversion erledigt keinen
Edit. Empfang und Auflösen allein bestätigen nichts. Bei `deleted: true` den
Quellinhalt nicht neu ausführen; begonnene Auswirkungen einordnen, nicht pauschal
rückgängig machen. War die Quelle bereits zugestellt oder bestätigt, bekommt ihre
nachgewiesene Löschung einen eigenen Quellschlüssel zur Einordnung; die bisherige
Bestätigung bleibt erhalten und erledigt diesen Eingang nicht. Keine separaten
Empfangskommentare erstellen.

Eigene bestätigte App-Ausgaben bleiben Kontext. Abweichende eigene Ausgaben und
unklare Herkunft sichtbar einordnen; Kommentare erteilen keine zusätzlichen
Befugnisse. Andere Integrationen aktivieren keine Arbeit. Der technische Review
bleibt vom ungefilterten Ticket-/Workpad-/Kommentarstand isoliert; die Eingaben
verarbeitet ausschließlich der Hauptworker über die bestehenden Scope-Gates.

Vorwärtsführende `issueUpdate(stateId)`-Aktionen prüfen den Eingang im gemeinsamen
Client unmittelbar frisch. Offene Eingaben und unvollständige/fehlgeschlagene
Scans blockieren die Mutation. Der Aktionsfehler nennt nur Quellschlüssel;
Kommentartexte über `symphony_comments` am nächsten Checkpoint abrufen.
Rückgaben nach Planung/BLOCKER und Abbruch bleiben
möglich. Der bestehende Land-Pfad führt den Merge ausschließlich über das gebundene
`symphony_merge` mit `head_sha` aus; es prüft GitHub-Gates, aktuelle Linear-Labels
und den Kommentareingang vor der tatsächlichen Merge-Anforderung. Bei neuer
Eingabe deren Ergebnis bearbeiten und danach erneut frisch prüfen. Eine durch
GitHub-Rate-Limit gescheiterte Merge-Anforderung wird nicht intern wiederholt;
ein erneuter gebundener Merge durchläuft sämtliche Gates und Checkpoints frisch.

Nur API-seitig beobachtete Fassungen sind nachweisbar; zwischen Polls
überschriebene Zwischenstände sind nicht rekonstruierbar. Unvollständige Scans
bewahren bereits beobachtete Quellen, erlauben aber keinen Abschluss.
Das Fenster zwischen letzter API-Antwort und Aktion bleibt; keine atomare
Linear-/GitHub- oder Exactly-once-Garantie. Scan-/Transportdetails stehen im oben
verlinkten Abschnitt „Dauerhafter Kommentareingang“.

## Workpad-Handhabung

Für Aufbau, Standardstruktur und Pflege des persistierenden Workpad-Kommentars ist
der globale Skill `symphony-workpad` die maßgebliche Quelle.

- Der Skill regelt insbesondere Wiederverwendung/Neuanlage des einen `## Symphony Workpad`-Kommentars, die kanonische Kommentarstruktur sowie die Pflege-Regeln für `Plan`, `Validierung`, `Review`, `Test`, `Verlauf` und `Unklarheiten`.
- Die Schrittreihenfolge der einzelnen Workflow-Phasen und alle Statusübergänge bleiben ausschließlich in dieser `WORKFLOW.md` definiert.

## Planungs-Handhabung

Für Ticketbeschreibung, inhaltliche Planung und geplante Validierung ist
der globale Skill `symphony-planning` die maßgebliche Quelle.

- Automatische inhaltliche Änderungen an `Plan` und geplanter `Validierung` sind zulässig, wenn neue Erkenntnisse aus der Umsetzung sie erforderlich machen. Dokumentiere solche Änderungen im Workpad und erhalte verpflichtende ticketseitige Validierungsvorgaben. Nur bei wesentlichen, aus dem Kontext nicht auflösbaren Produktziel-, Umfangs- oder Strategieentscheidungen dokumentiere sie nur als empfohlenen Lösungsvorschlag und verschiebe nach `Planung`.
- Interaktive Sitzungen dürfen auf Benutzeranweisung später erneut in die Planung eingreifen.

## Leitplanken und Verbote

- Wenn der Issue-Status `Backlog` oder `Todo` ist, ändere ihn nicht; warte, bis ein Mensch ihn in den nächsten vorgesehenen AI-Status verschiebt.
- Bearbeite den Issue-Body/die Beschreibung nicht für Planung oder Fortschrittsverfolgung. Ausnahmen sind nur die automatisierte Beschreibungspflege in `Planung (AI)` und das einmalige `Erstkontakt-Protokoll für neue Items`.
- Verwende pro Issue genau einen persistierenden Workpad-Kommentar (`## Symphony Workpad`).
- Von aufgerufenen Skills ausdrücklich geforderte separate Nachvollziehbarkeitskommentare sind neben dem Workpad zulässig; sie ersetzen den Workpad-Kommentar nicht und zählen nicht als zusätzliche Workpads. Im Review-Kontext bedeutet das kombinierte Nach-Fix-Kommentare pro behandeltem Finding, keine getrennten Vorab-Finding-Kommentare plus spätere Fix-Kommentare.
- Wenn Kommentarbearbeitung in der Sitzung nicht verfügbar ist, nutze den verbleibenden gebundenen Linear-Transport. Sind beide Transporte ausgefallen, melde den Blocker sichtbar; kein Shell-/Mix-/Update-Skript-Fallback.
- Automatische Commits sind ausschließlich in `Test (AI)` und `Merge (AI)` zulässig. Die einzige zusätzliche Ausnahme ist der einmalige Einstiegssnapshot `<Issue-Key> Review (AI) Autocommit` beim ersten Eintritt in `Review (AI)`. Verwende sonst nur `<Issue-Key> Test (AI) Autocommit` oder `<Issue-Key> Merge (AI) Autocommit`.
- Automatische Commit-Nachrichten verwenden als Betreff `<Issue-Key> <Status> Autocommit` und zusätzlich einen kurzen Body. Der Body hält fest, dass der Commit im genannten Schritt erstellt wurde, den bis dahin offenen Arbeitsstand sichert und kein Nachweis für den Abschluss dieses Schritts ist.
- Der vorgeschaltete `symphony-pull` darf uncommittete Änderungen nur staschen und wiederherstellen, nicht committen.
- Temporäre Proof-Änderungen sind nur für lokale Verifikation erlaubt und müssen vor der Übergabe nach `PreReview (AI)` rückgängig gemacht werden.
- Wenn Verbesserungen außerhalb des Scopes gefunden werden, erstelle ein separates Backlog-Issue, statt den aktuellen Scope zu erweitern, und nimm einen klaren Titel/eine klare Beschreibung/klare Validierungspunkte, dieselbe Projektzuweisung, einen `related`-Link zum aktuellen Issue und `blockedBy` auf, wenn das Folge-Issue vom aktuellen Issue abhängt.
- Verschiebe nicht nach `PreReview (AI)`, solange die Abschlussbedingungen im Abschnitt `Ablauf für In Arbeit (AI)` nicht erfüllt sind.
- In `Planung` keine weiteren Codeänderungen vornehmen; auf die Planschärfung warten. In `Freigabe Implementierung` und `Freigabe Review` ohne passendes Skip-Label und ohne `--yolo` keine weiteren Codeänderungen vornehmen und auf den jeweiligen manuellen Schritt warten. Kein regelmäßiges Polling außerhalb der ausdrücklich definierten Skip-/`--yolo`-Weiterläufe.
- In `BLOCKER` keine weiteren Codeänderungen vornehmen und kein regelmäßiges Polling ausführen; warten, bis ein Mensch den Blocker gelöst und das Ticket weiter verschoben hat.
- Wenn der Status terminal ist (`Fertig` oder `Abgebrochen`), nichts tun und beenden.
- Halte den Ticket-Text knapp, spezifisch und reviewer-orientiert.

## Gemeinsame Wissensbasis ohne lokales Codex-Memory

Frische Symphony-/Codex-Prozesse erzwingen `features.memories=false`,
`memories.generate_memories=false` und `memories.use_memories=false`.
Persönliche Memory-Dateien werden weder importiert noch gelöscht. Die
gemeinsame Wissensbasis bilden versionierte AGENTS-, Workflow-, Skill- und
Projektdateien sowie Ticket und Workpad. Codex übernimmt die
versionierten Repository-Skills; persönliche lokale Skill-Erweiterungen werden nicht
in den gemeinsamen Lauf importiert. Gesprächs-/Session-History, Wiederaufnahme
und Tracker-/Journalzustand bleiben erhalten. Bereits geladener Alt-Kontext
wird dadurch nicht rückwirkend entfernt.
