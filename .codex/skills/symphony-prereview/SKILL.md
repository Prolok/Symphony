---
name: symphony-prereview
description:
  Prüft im Status `PreReview (AI)` den gesamten Ticketdiff fachlich und mit der
  repo-lokalen `sym-prereview`-Checkliste; korrigiert Findings in derselben Phase.
---

# Symphony PreReview

Nur im Status `PreReview (AI)` verwenden.

## Ablauf

- `<aktives-repo-root>/.codex/skills/sym-prereview/SKILL.md` vollständig lesen.
- Projektprüfungen und ihre Reihenfolge aus dieser Checkliste übernehmen;
  fehlende Datei im Workpad dokumentieren und stoppen.
- Den gesamten Ticketdiff gegen Zielbranch und Akzeptanzkriterien prüfen,
  einschließlich bereits committeter und offener Änderungen. Betroffene
  Produktpfade, relevante Schnittstellen und Fehlerfälle einbeziehen; die
  fachliche Selbstprüfung nicht auf die seit dem letzten Fix geänderten Zeilen
  beschränken.
- Passende Tests aus dem betroffenen Verhalten auswählen, auch unveränderte
  bestehende Tests. Fehlende Nachweise ausführen, vorhandene auf Gültigkeit für
  den aktuellen Stand prüfen. Fällige Pflichtgates erfüllen; eine Pflichtvollsuite
  bleibt in ihrer vorgesehenen Phase.
- Selbstprüfung, Projektcheckliste und ausgewählte Nachweise unter `### Review`
  spiegeln, Ergebnisse in `### Verlauf` festhalten.
- Relevante Findings im Scope unmittelbar in derselben PreReview-Phase/Session
  korrigieren und passend nachprüfen. Ein roter Test allein begründet weder
  BLOCKER noch einen Rücksprung nach `In Arbeit (AI)`.
- Nach Fixes fehlgeschlagene, durch Änderungen entwertete und davon abhängige
  Prüfungen wiederholen. Unabhängige, weiterhin gültige Evidenz erhalten;
  geänderte Voraussetzungen wie Konfiguration, Schnittstellen oder Fixtures bei
  der Auswahl berücksichtigen.
- Im Workpad knapp geprüften Stand (Basis, HEAD und offene Änderungen), relevante
  Prüfungen mit Ergebnis, Korrekturen und verbleibende Punkte mit Zuständigkeit
  und fälliger Phase dokumentieren. Kein Erfolg ohne gültigen Nachweis.

## Abschluss

Wenn die Selbstprüfung abgeschlossen, relevante Findings behoben und alle
fälligen Prüfungen gültig belegt sind,
`### Review` vollständig abhaken und gemäß Workflow nach `Freigabe Implementierung`
(einschließlich autorisierter Skips) übergeben; danach den Turn beenden.
Die fachliche Prüfung bleibt mit und ohne YOLO gleich und benötigt weder Pai
noch OpenClaw; Nicht-YOLO-Freigaben bleiben ohne autorisierten Skip erhalten.
Keine Commits. Bei
offener, fehlender oder nicht explizit abgehakter `### Review`-Checkliste den
Hauptturn nicht final beenden: im selben Turn weiterarbeiten oder einen echten
Blocker im Workpad dokumentieren. Bei `agent.max_turns` verbleibende
Abweichungen dokumentieren und ohne Statuswechsel stoppen; `agent.max_turns` ist
kein normaler Phasenabschluss.

## Nacharbeit und knappe Übergaben

Negative Befunde im Scope zuerst autonom beheben; fehlender positiver Beleg
sperrt das Gate, nicht zulässige Nacharbeit. Die bestehenden Wiederholungsregeln
und Merge→Test bei Dateiänderungen bleiben erhalten. Entscheidungs-/Eskalations-
schwelle gemäß Workflow, knappe Texte und Nach-Fix-Kommentare gemäß
`symphony-workpad`; Fehlerzahl/Aufwand/max_turns allein begründen keinen BLOCKER.
