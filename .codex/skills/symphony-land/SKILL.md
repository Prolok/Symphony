---
name: symphony-land
description:
  Führt im Status `Merge (AI)` eine PR bis zum Merge, beobachtet Checks und
  Review-Feedback und behandelt autonome Fixes.
---

# Land

Nur im Merge-Schritt des Workflows verwenden.

## Ziele

- PR für den aktuellen Branch finden.
- Konfliktfreiheit zu `main` sicherstellen.
- GitHub-Checks gemäß Policy beobachten und behebbare Fehler autonom fixen.
- Review-Feedback vor dem Merge bestätigen oder bearbeiten.
- Lokale Volltests nicht pauschal wiederholen; `Test (AI)` bleibt der Status
  für das vollständige lokale Gate.
- GitHub-Checks nach Policy bewerten: `success` ist bestanden, `skipped` ist
  bei bewusster Skip-Policy akzeptabel, `neutral` ist neutral akzeptiert,
  echte Fehler bleiben blockierend. Skipped/neutral nie als bestandene CI
  ausgeben.
- Erst nach akzeptabler GitHub-Check-Policy, erledigtem Feedback und klarer
  PR-/Merge-Evidenz per Merge-Commit mergen.

## Ablauf

1. PR-/Remote-Preflight ausführen: aktueller Branch muss
   `symphony/<IssueId>` sein, `origin/<branch>` muss existieren, eine offene PR
   für genau diesen Branch muss existieren und die PR-Head-SHA muss dem
   lokalen `HEAD` entsprechen. Fehlenden Remote-Branch, fehlende PR oder
   PR-Head-Mismatch nicht als mergefähig behandeln.
   Ohne explizites `GH_REPO` bindet der Land-Helper seine GitHub-Aufrufe an
   die URL von `origin`; eine GitHub-CLI-Standardauswahl von `upstream`
   ersetzt diese Projektbindung nicht. Explizites `GH_REPO` bleibt erhalten.
2. Keine pauschalen lokalen Volltests in `Merge (AI)` ausführen. Vorhandene
   Test-Evidenz aus `Test (AI)` ist das maßgebliche lokale Gate. Wenn
   GitHub-Checks durch bewusste Skip-Policy `skipped` sind, ersetzt das keine
   bestandene CI, sondern ist nur zusammen mit der lokalen Test-Evidenz aus
   `Test (AI)` mergefähig.
3. Falls beim Eintritt offene Änderungen vorhanden sind, diese als im
   Merge-Schritt übernommene Dateiänderungen behandeln: mit `<Issue-Key>
   Merge (AI) Autocommit` plus kurzem Body committen, über `symphony-push`
   veröffentlichen, nach `Test (AI)` zurückverschieben und stoppen.
4. Mergebarkeit prüfen.
5. Bei Konflikten `symphony-pull` nutzen. Wenn Pull/Rebase oder Konfliktlösung
   Dateien ändert, committen, pushen, nach `Test (AI)` zurückverschieben und
   stoppen.
6. Review-Kommentare und Codex-Review-Issue-Kommentare prüfen.
7. Feedback autonom anhand von Ticketkontext, Plan, Code, Tests und lokaler
   Dokumentation akzeptieren oder begründet ablehnen/zurückstellen. Wenn
   Feedback Dateiänderungen erfordert, vor Codeänderungen die beabsichtigte
   Aktion antworten, den Fix umsetzen, committen, pushen, nach `Test (AI)`
   zurückverschieben und stoppen.
8. Checks beobachten. `success` als bestanden melden, `skipped` als
   „GitHub checks acceptable: skipped by policy“ oder Mischform ausgeben,
   `neutral` als neutral akzeptiert ausgeben. Bei Fehlschlag Logs holen. Wenn
   eine Behebung Dateiänderungen erfordert, Fix umsetzen, committen, pushen,
   nach `Test (AI)` zurückverschieben und stoppen; reine CI-Neuläufe ohne
   Dateiänderungen dürfen weiter beobachtet werden.
   Bei leeren Checks den No-CI-Nachweis des Helpers verwenden: „GitHub CI not
   configured and not required“ ist keine bestandene CI. Nur vollständig
   bestätigte fehlende CI-Konfiguration und nicht erforderliche Checks erlauben
   diesen Pfad; die lokale Test-Evidenz bleibt Pflicht. Erwartete fehlende CI
   und unbekannte/unvollständige Policy bleiben blockierend. API-Details stehen
   in `docs/linear-app.md`; im bestätigten No-CI-Fall keine CI-Einrichtung fordern.
9. Wenn das Linear-Label `Requires Manual Review` gesetzt ist, nach sauberer
   PR-/Remote-Preflight-Evidenz, erledigtem Review-Feedback und akzeptablen
   GitHub-Checks ein gültiges menschliches GitHub-Approval auf der aktuellen
   PR-Head-SHA verlangen. `--yolo` und `Skip "Freigabe Review"` dürfen dieses
   externe Merge-Gate nicht umgehen. Bei fehlendem Approval keinen Merge
   versuchen und keine Merge-Evidenz erzeugen; den Blocker im Workpad
   dokumentieren, das Issue nach `BLOCKER` verschieben und stoppen. Keine
   Review-Requests, GitHub-Kommentare oder Label-Entfernungen erzeugen.
   Wenn der aktuelle Linear-Labelstand im App-Server-Kontext nicht sicher
   verifiziert werden kann, ebenfalls vor jedem Merge-Versuch als eigener
   Label-Lookup-Blocker nach `BLOCKER` stoppen.
   Im App-Modus liest der Hauptagent die aktuellen Labels unmittelbar vor
   dieser Prüfung über das injizierte `linear_graphql` oder das gebundene
   `symphony_linear`-MCP vollständig paginiert für das aktuelle Issue. Der
   Watch-Helper übergibt diese Prüfung mit Exit `8`, weil seine Modell-Shell
   keinen Auth-Zugriff hat. Exit `8` ist weder Merge-Freigabe noch Blocker:
   Live-Lookup und gegebenenfalls menschliches GitHub-Approval müssen danach
   noch abgeschlossen werden. Bei gesetztem Label nur ein Approval eines
   menschlichen Nicht-Autors auf der aktuellen PR-Head-SHA akzeptieren;
   Bots, veraltete oder zurückgezogene Approvals erfüllen das Gate nicht.
   Vor dem Merge lokalen/Remote-/PR-Head nochmals vergleichen und den
   aktuellen Live-Labelstand samt etwaiger Approval-Evidenz im Workpad halten.
   Scheitert der erlaubte Live-Lookup, bleibt der Label-Lookup-Blocker bestehen.
   Kein Dispatch-Snapshot, kein Shell-/Mix-Fallback und keine Lockerung der
   Secret-Abschirmung. Kein lokaler Tracker-Refresh über die Modell-Shell.
10. Wenn GitHub-Checks bestanden, gemäß Skip-/Neutral-Policy akzeptabel oder
   durch den Helper nachweislich nicht konfiguriert und nicht erforderlich sind
   und Feedback erledigt ist, das gebundene Tool `symphony_merge` mit
   `head_sha` (aktuelle lokale/PR-Head-SHA) und optional `issue_id` aufrufen.
   Dieses führt den bestehenden Land-Helper, Live-Label-/Approval-Gates und
   eine erneute CI-Evidenzprüfung für den aktuellen PR-/Base-/Head-Stand sowie
   unmittelbar vor der tatsächlichen Merge-Anforderung einen frischen
   Kommentarcheck aus. Merge-Betreff bleibt `<IssueId>: <IssueTitle>`.
   Bei offenen Eingaben `symphony_comments` (`checkpoint`, danach
   `acknowledge` mit Quellversion/Ergebnis) verwenden und den gebundenen Merge
   erneut aufrufen. Scan-/Vollständigkeitsfehler verhindern den Merge.
   Nur dessen bestätigtes `MERGED`-Ergebnis mit `mergeCommit.oid` ist Evidenz.
11. Nach erfolgreichem Merge vor jedem Statuswechsel im Workpad-Verlauf eine
    eindeutige Zeile im Format `Merge-Evidenz: PR #<nummer> gemergt,
    Merge-Commit <sha>.` dokumentieren.

`gh pr merge` nicht direkt aus dem Workflow heraus aufrufen; nutze diesen Skill
und bevorzugt den Watch-Helper.

## Watch-Helper

```sh
python3 .codex/skills/symphony-land/land_watch.py
```

Exit-Codes: `2` Review-Kommentare, `3` CI-Fehler, `4` PR-Head während des
Watch-Laufs aktualisiert, `5` Merge-Konflikt, `6` fehlende oder inkonsistente
PR-/Remote-Preflight-Evidenz, `7` fehlendes gültiges manuelles GitHub-Approval
bei gesetztem Label `Requires Manual Review` oder nicht verifizierbarer
aktueller Linear-Labelstand im App-Server-Kontext; `8` App-Übergabe zum noch
offenen Live-Label-/Approval-Gate über den gebundenen Toolzugriff (Schritt 9).

Bei Exit `8` im selben Turn Schritt 9 über die erlaubten Tools vollständig
ausführen. Der Helper hat dann lediglich seine GitHub-Prüfungen abgeschlossen;
weder das gesamte Merge-Gate noch der Merge selbst sind dadurch abgeschlossen.

Bei Exit-Code `7` nennt die Helper-Ausgabe PR-Nummer oder URL und aktuelle
Head-SHA. Wenn `Requires Manual Review` gesetzt ist, nennt sie zusätzlich das
Label und die Aufforderung, ein manuelles GitHub-Review durchzuführen und das
Linear-Issue danach wieder nach `Merge (AI)` zu verschieben. Wenn der aktuelle
Labelstand nicht verifiziert werden konnte, nennt sie stattdessen den
Label-Lookup-Fehler und fordert zur Wiederholung nach behobenem Lookup auf.
Diese Meldung im Workpad dokumentieren und das Issue nach `BLOCKER`
verschieben.

## Review-Umgang

- Menschliche Inline-Kommentare über den PR-Review-Comment-Endpunkt beantworten.
- Codex-Reviews kommen als Issue-Kommentare mit `## Codex Review`; darauf im
  Issue-Thread antworten.
- Alle Agent-Kommentare beginnen mit `[codex]`.
- Menschliche Review-Zusammenfassungen im Zustand `COMMENTED` nach Bearbeitung
  im PR-Issue-Thread mit einer `[codex]`-Ergebnisantwort dokumentieren. Wie bei
  sonstigem Issue-Feedback berücksichtigt der Helper deren Zeitstand; spätere
  Reviews bleiben offen. `CHANGES_REQUESTED` und das separate Manual-Approval-Gate
  werden dadurch nicht aufgehoben.
- Für jedes Feedback entscheiden: akzeptieren, zurückstellen oder ablehnen. Bei
  correctness-Feedback konkrete Validierung liefern.
- File-changing Review-Fixes in `Merge (AI)` immer mit Commit-SHA und Ergebnis
  an derselben Stelle melden, nach `Test (AI)` zurückverschieben und stoppen.
- Wenn Feedback trotz vorhandener Quellen nicht sicher lösbar ist, Blocker im
  Workpad und Review-Thread dokumentieren, nach `Freigabe Review` verschieben
  und stoppen.

Nützliche Endpunkte:

```sh
gh api repos/{owner}/{repo}/pulls/<pr_number>/comments
gh api repos/{owner}/{repo}/issues/<pr_number>/comments
gh api -X POST /repos/{owner}/{repo}/pulls/<pr_number>/comments \
  -f body='[codex] <response>' -F in_reply_to=<comment_id>
```

## Fehlerbehandlung

- Instabile CI-Ausreißer nach Prüfung erneut beobachten.
- Wenn `origin/<branch>` oder eine offene PR fehlt, nicht mergen. Nur aus einem
  sauberen, lokal in `Test (AI)` validierten Stand per `symphony-push`
  veröffentlichen beziehungsweise erstellen, danach PR-Kontext und PR-Head-SHA
  erneut prüfen.
- Wenn die PR-Head-SHA nicht dem lokalen `HEAD` entspricht, nicht mergen:
  aktuellen Stand veröffentlichen oder lokalen Stand auf den PR-Head bringen,
  danach erneut beobachten.
- Auto-Fix-Commits von CI lokal übernehmen, bei Bedarf rebasen, mit eigenem
  Commit/Push veröffentlichen, nach `Test (AI)` zurückverschieben und stoppen.
- Bei `mergeable: UNKNOWN` warten und erneut prüfen.
- Nicht mergen, solange Review-Kommentare offen sind.
- Auto-Merge nur aktivieren, wenn Workflow und Repository es ausdrücklich
  verlangen.

## PR-Metadaten

PR-Titel und Beschreibung müssen den gesamten Änderungsscope abbilden. Nach
Fix-Batches einen knappen Root-Level-`[codex]`-Kommentar mit Deltas, Commits
und Tests schreiben, wenn das den Stand klärt. Neues Codex-Review nur anfordern,
wenn seit der letzten Anfrage neue Commits entstanden sind.

## Abschluss

Den Hauptturn erst final beenden, wenn der PR-Merge nachweislich abgeschlossen
ist und die `Merge-Evidenz` im Workpad steht, ein zulässiger Statuswechsel nach
`Test (AI)` oder `Review` erfolgt ist oder ein echter Blocker dokumentiert ist.
Ohne diese Evidenz keinen normalen Abschluss behaupten und den Hauptturn nicht
final beenden; im selben Turn die Merge-/Watch-Schleife fortsetzen oder einen
echten Blocker dokumentieren. Bei `agent.max_turns` Abweichungen dokumentieren
und ohne Statuswechsel stoppen; `agent.max_turns` ist kein normaler
Phasenabschluss.

Der Watch-Helper allein erteilt weiterhin keine Merge-Freigabe. Exit `9` im
gebundenen Pfad bedeutet fehlgeschlagenen Kommentarcheckpoint; Eingaben prüfen
oder den Scan nach Erholung der API wiederholen. Das API-/Aktionszeitfenster ist
nicht atomar; `--match-head-commit` bewahrt zusätzlich die bestehende Head-Bindung.
