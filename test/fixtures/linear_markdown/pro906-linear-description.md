## Ziel

Der PO-Review-Sammellauf darf bei wiederholtem technischem Nichtstart keine Reviewcheckouts akkumulieren; verwaiste Reviewcheckouts werden erkannt und kontrolliert bereinigt. Ursprung: [PRO-854](https://linear.app/prolok/issue/PRO-854/yolo-review) (gemeinsame Schlussabnahme PRO-854/PRO-873 am 24.09.2026, PO-Lauf a07ea629-8f25-4e8a-98fd-e742be3e069a, Stand 544b95940fdee0404eb281b3c2ee940be1d15b72).

## Befund (Betreiberbeleg; keine doppelte Agentenzustellung)

* Unter `/Users/tr/QuantHub/Symphony-worktrees/yolo/review/` existieren 111 registrierte Reviewcheckouts (`git worktree list`). 96 davon entstanden am 22.09.2026 zwischen 18:31 und 20:00 Uhr im Minutentakt auf `68ed627` (Stand direkt nach Merge PRO-873, während PRO-873/PRO-854 gemeinsam in Yolo Review standen). Alle außer `4c2c7194` sind ohne Build, ohne `yolo-runs`-Journal und ohne OpenClaw-Sitzung; es gab keine doppelte Modell-/Agentenzustellung, die Zustell-Deduplizierung hielt. Seit 22.09. 20:05 entstanden nur noch sechs Reviewcheckouts, alle mit Journal (echte Läufe).
* Struktur: `Yolo.Runner.execute/8` legt den Worktree über `Yolo.Workspace.create/2` an, bevor `execute_session` Prompt/Checkpoints, `verify_start`, `current_project` und die OpenClaw-Zustellung ausführt. Scheitert einer dieser Schritte, bleibt der Worktree registriert; der nächste Poll startet nach `retry_at` mit neuer `run_id` und legt einen weiteren an. Es gibt keinen Entfernungs- oder Wiederverwendungspfad für Reviewcheckouts fehlgeschlagener Starts.
* Die konkrete Ursache des 90-minütigen Nichtstarts ist nicht mehr rekonstruierbar (`log/symphony.log` rotiert; ältester vorhandener Stand 23.09.2026 18:29). Keine rückwirkende Schuldzuweisung; PRO-854 definierte kein Verhalten für wiederholte technische Nichtstarts.
* Beleg: `/Users/tr/ProjectHub/OpenClaw-Workspaces/pai/reports/pro854-pro873-review-a07ea629/review-checkout-inventory.json` (Inventar mit Erstellzeit, HEAD, Build-/Journalstatus je Checkout).

## Anforderungen

1. Ein nach Checkout-Anlage scheiternder Gruppenstart entfernt seinen eigenen unveränderten Reviewcheckout (`git worktree remove`) oder verwendet ihn beim nächsten Versuch derselben unveränderten Gruppe wieder. Grund, `run_id` und Gruppe werden als Log-Warnung und im Gruppen-Store festgehalten.
2. Wiederholte Nichtstarts derselben unveränderten Gruppe erhalten ein begrenztes, wachsendes Backoff über `retry_at`; keine minütliche Neuanlage.
3. Verwaiste Reviewcheckouts (kein Journal, kein aktiver Lauf, HEAD gleich dokumentierter SHA, sauber) werden über einen dokumentierten Betreiberweg im Repository (bestehendes Skript oder Mix-Task, mit Trockenlauf) erkannt und entfernt; veränderte, aktive oder unklare Checkouts bleiben zur Recovery erhalten. Die einmalige Bereinigung der 95 Altcheckouts vom 22.09.2026 ist Betreiberanteil in Yolo Review (Pai), kein Nutzergate.
4. Keine Änderung an Hauptcheckout, laufenden Läufen, Ticket-Worktrees, Zustell-Deduplizierung oder Leases; keine OpenClaw-Änderung.

## Scope und Autonomie

Eigenständiger Anforderungsscope zu PRO-854 (kind new_requirement, keine Abnahmesperre). Reguläre AI-Pipeline mit Planung, PreReview, technischem Review, Test und sicherem Merge; keine persönliche Bedienung oder Routinefreigabe durch Tilo.

## Validierung

1. ExUnit am Runner-/Coordinator-Pfad: synthetischer Fehler nach Checkout-Anlage (verify_start bzw. abgelehnte Zustellung) hinterlässt keinen zusätzlichen Worktree oder verwendet ihn wieder; Backoff-Fall mit unveränderter Gruppe belegt; Erfolgsfall unverändert. Bestehende yolo_runtime-/yolo_workspace-Fälle grün.
2. Bereinigungsweg an Fixture-Worktrees: verwaiste entfernt, veränderte/aktive/unklare erhalten; Trockenlauf und Zählung vorher/nachher ausgewiesen.
3. make check in In Arbeit (AI)/PreReview (AI); make all in Test (AI). Yolo Review (Pai): einmalige Betreiberbereinigung der Altcheckouts vom 22.09.2026 mit `git worktree list`-Zählung vorher/nachher belegen; Hauptcheckout und aktive Läufe unverändert.

## Ursprung

* [PRO-854](https://linear.app/prolok/issue/PRO-854/yolo-review)