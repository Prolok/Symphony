---
name: symphony-test
description:
  Führt im Status `Test (AI)` die repo-lokale `sym-test`-Checkliste inklusive
  Test-/Fix-Schleife aus.
---

# Symphony Test

Nur im Status `Test (AI)` verwenden. Pull/Rebase ist Aufgabe des aufrufenden
Workflows.

## Ablauf

- `<aktives-repo-root>/.codex/skills/sym-test/SKILL.md` vollständig lesen.
- Nur diese Checkliste und Reihenfolge verwenden; fehlende Datei im Workpad
  dokumentieren und stoppen.
- Fehlende Pull-Evidence im Workpad ergänzen.
- `### Test` pflegen, Details knapp in `### Verlauf`.
- Autorisierten Direkteinstieg und Review-Skip gemäß `symphony-workpad`
  dokumentieren; fehlende frühere Planungs-/PreReview-/Reviewhistorie allein
  erfordert keine Nachholrunde. Aktuelle Pflichtnachweise bleiben erforderlich.

## Test-/Fix-Schleife

1. Bei Wiederaufnahme zuerst passende neue Betreiberbelege gemäß
   `symphony-workpad` prüfen, dann die repo-lokale Wiederholungsregel anwenden;
   ohne besondere Regel mit dem ersten repo-lokalen Testschritt beginnen.
2. Nach jedem Schritt den zugehörigen `### Test`-Punkt aktualisieren.
3. Bei Fehlern Fix umsetzen, Workpad aktualisieren und wieder bei Schritt 1
   starten.
4. Lokale Fixes dürfen mit `<Issue-Key> Test (AI) Autocommit` plus kurzem Body
   committet werden.

Fehlt eine externe Testvoraussetzung, den erlaubten repo-lokalen Startpfad
nutzen. Ist etwa Docker/Testdatenbank nicht erreichbar und die Host-Bereitstellung
Betreiberaufgabe, bestandene Teilprüfungen erhalten und einmalig konkret mit
benötigtem Verfügbarkeitsnachweis und Fortsetzung in `Test (AI)` übergeben.
Keine Host-/Colima-Reparatur, neue Containerplattform oder Datenlöschung.
Ohne neuen passenden Beleg denselben unerfüllbaren Auftrag nicht wiederholen;
Status-/BLOCKER-Weg gemäß aufrufendem Workflow verwenden.

## Abschluss

Wenn alle Schritte sauber sind, `### Test` und die jetzt fälligen Punkte in
`### Validierung` abhaken, nach `Merge (AI)` verschieben und den Turn beenden.
Eindeutig erst in Merge oder Review fällige Nachweise gemäß `symphony-workpad`
bleiben bindend offen. Die finale Produktabnahme folgt den Phasenpflichten in
`WORKFLOW.md`; fehlende notwendige Testumgebung bleibt ein technisches Gate.
Bei offener `### Test`-Checkliste, offenen fälligen Validierungspunkten oder
fehlender/unbewertbarer Pflichtcheckliste im selben Turn weiterarbeiten oder
eine fällige Betreiberübergabe gemäß Workflow ausführen. Bei
`agent.max_turns` Abweichungen dokumentieren und ohne Statuswechsel stoppen;
`agent.max_turns` ist kein normaler Phasenabschluss.

## Nacharbeit und knappe Übergaben

Negative Befunde im Scope zuerst autonom beheben; fehlender positiver Beleg
sperrt das Gate, nicht zulässige Nacharbeit. Die bestehenden Wiederholungsregeln
und Merge→Test bei Dateiänderungen bleiben erhalten. Entscheidungs-/Eskalations-
schwelle gemäß Workflow, knappe Texte und Nach-Fix-Kommentare gemäß
`symphony-workpad`; Fehlerzahl/Aufwand/max_turns allein begründen keinen BLOCKER.
