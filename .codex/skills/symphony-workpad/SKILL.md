---
name: symphony-workpad
description:
  Verwende diesen Skill nur innerhalb eines laufenden Symphony-Issue-Workflows
  für Aufbau und Pflege des einen `## Symphony Workpad`-Kommentars.
---

# Symphony Workpad

Dieser Skill regelt nur das Workpad. Statuslogik bleibt in `WORKFLOW.md` bzw.
`WORKFLOW_INTERACTIVE.md`; Planung von `### Plan` und `### Validierung` liegt
bei `symphony-planning`.

## Kommentar

- Verwende pro Issue genau einen aktiven Kommentar mit dem Marker
  `## Symphony Workpad`.
- Suche vorhandene Kommentare nach diesem Marker und nutze einen aktiven Treffer
  weiter; sonst erstelle einen neuen Kommentar in der Standardstruktur.
- Fortschritt, Review, Test und Handoff bleiben in derselben Kommentar-ID.
- Im App-Modus ausschließlich das injizierte `linear_graphql` oder den
  gebundenen `symphony_linear`-MCP verwenden. Bei Ausfall eines Transports den
  anderen verwenden; sind beide nicht verfügbar, den Zugriffsblocker sichtbar
  melden. Kein Shell-/Mix-/Update-Skript-Fallback, keine privaten Envdateien
  laden und keine unbestätigte Workpad-/Statusspeicherung behaupten.
- HTTP 403 mit `RATELIMITED`, `classification: "rate_limited"` oder
  `rateLimit.limited: true` ist ein Rate-Limit-Signal und kein fehlender
  Linear-Zugriff. Nicht erschöpfte `rateLimit`-Header ohne `limited: true` sind
  nur Diagnosehinweise.

## Standardstruktur

````md
## Symphony Workpad

```text
<hostname>:<abs-path>@<short-sha>
```

### Plan

- [ ] 1\. Übergeordnete Aufgabe
  - [ ] 1.1 Teilaufgabe

### Validierung

- [ ] gezielte Tests: `<command>`

### Review

- [ ] `<PreReview-/Review-Schritt>`: `<kurze Statusnotiz>`

### Test

- [ ] `<Test-Schritt>`: `<kurze Statusnotiz>`

### Verlauf

- <Zeitstempel in lokaler Zeit> - <kurze Notiz>
````

`### Unklarheiten` nur ergänzen, wenn wirklich etwas unklar oder
widersprüchlich war.

## Pflege

- Environment-Stamp: `<host>:<abs-workdir>@<short-sha>` ohne Issue-ID, Status
  oder Branch.
- `### Plan` bleibt hierarchisch, `### Validierung` eine explizite Checkliste.
- `### Verlauf` nutzt lokale Zeit, keine UTC- oder `Z`-Zeitstempel.
- `### Review` und `### Test` spiegeln nur die jeweiligen Skill-Checklisten;
  Befehle, Ergebnisse und Fix-Notizen stehen knapp in `### Verlauf`.
- Vor Implementierungsbeginn ein konkretes Reproduktionssignal notieren.
- Nach wesentlichen Meilensteinen Checklisten abhaken und Verlauf aktualisieren.
- Finalen Handoff-Zustand inklusive lokalem Stand, Validierung und bei Bedarf
  bewusst ungecommitteten Änderungen im selben Kommentar festhalten.

## Pflichtnachweise und Übergaben

- Jeden Validierungspunkt mit Aktion, ausführendem Verantwortlichen und fälliger
  Phase samt Entscheidungsquelle/technischer Begründung gemäß `WORKFLOW.md`,
  „Phasenpflichten und Betreiberübergaben“, führen. Später fällige Nachweise offen
  lassen; `[x]` setzt einen passenden Beleg voraus. Irrtümliche agentenseitige
  Frühfristen begründet korrigieren, keine tatsächliche frühe Freigabe verschieben.
  Bei Wiederaufnahme/Verdichtung Quelle, offene Pflicht und aktuelle technische
  Belege erhalten.
- Eine weiterhin fällige PO-Abnahme in `### Validierung` als offenen Punkt mit
  `; fällig: Freigabe Review` führen. Auch der automatische No-Findings-Handoff
  erhält dann das manuelle Gate; autorisierte Skip-Labels und `--yolo` gelten weiter.
- Für spätere offene Validierung jeden Punkt auf einer eigenen Zeile mit genau
  einem abschließenden Suffix `; fällig: Merge (AI)` , `; fällig: Yolo Review` oder `; fällig: Review`
  schreiben, ohne Backticks oder weitere Fälligkeitsangaben auch in Folgezeilen.
  In Test sind diese später, in Merge nur die Schlussabnahmen; in Yolo Review
  sind die übernommenen Abnahmen fällig. Für Tickets ohne Agent bleibt Review
  die Schlussphase.
  Rückstellung schließt keinen Punkt. Unzugeordnete, aktuelle, überfällige,
  unbekannte oder mehrdeutige Einträge sperren weiterhin, auch neben späteren
  Punkten. `### Test` und die technische `### Review`-Checkliste haben keine
  solche Ausnahme. Finale Produktabnahme unter `### Validierung` führen;
  `Review (AI)` und `Freigabe Review` sind keine Aliase für `Review`.
- Eine fällige Betreiberübergabe im selben Workpad enthält konkrete Aktion,
  zuständige Rolle, Quell-/Paketstand (bei offenen Änderungen HEAD plus Diffbezug),
  bereits bestandene lokale Prüfungen, fehlende externe Nachweise und genaue
  Fortsetzungsphase. Als ausstehende Betreiberaktion kennzeichnen; fehlende
  Testumgebung nicht als Review-/Linear-Authfehler ausgeben.
- Vor Wiederaufnahme Belegquelle, Ergebnis, Geltungsbereich und relevanten Stand
  abgleichen. Negative Befunde im Scope autonom korrigieren und erneut prüfen;
  fehlender positiver Nachweis sperrt den Gateabschluss, nicht die Nacharbeit.
  Statusschieben allein ist keine Abnahme. Ohne passenden neuen Beleg
  das Gate offen halten; nur ohne zulässigen autonomen Fortsetzungsweg die
  Betreiberübergabe erhalten. Keinen unerfüllbaren Auftrag oder Review allein
  wegen Wartezeit neu starten. Relevante Änderungen entwerten betroffene Belege,
  reine Wartezeit nicht. Negative Abnahme bleibt offen; Details und Fälle stehen in
  `docs/linear-app.md`, Abschnitt „Betreiberpflichten und Wiederaufnahme“.
- Autorisierten technischen Review-Skip als `bewusst übersprungen` mit
  Entscheidungsquelle und Geltungsbereich dokumentieren. Historische Reviewpunkte
  als übersprungen einordnen, nicht als bestanden abhaken. Fehlende Historie
  allein fordert beim autorisierten Test-/Merge-Einstieg keine Nachholrunde;
  unbekannter Vorzustand ist kein Skipbeleg. `Skip "Freigabe Review"` ersetzt
  keinen technischen Review-Skip. Fällige Test-/Merge-Gates bleiben bestehen.
- Spätere belegte menschliche Gateentscheidungen ersetzen ältere Beschreibungs-/
  Workpad-Defaults. Skip-Labels erhalten; betroffene frühere Pflichtpunkte mit
  Quelle und Geltungsbereich als `bewusst übersprungen` einordnen, nie als bestanden.
  Separat übernommene PO-Prüfungen außerhalb der fälligen Gate-Checkliste führen,
  damit sie keinen autorisierten manuellen Skip als versteckten Pflichtstop
  aufheben. Tatsächlich weiterhin fällige Betreiberbelege bleiben bindend.

## Ticket-Interaktionen

- Issue-Beschreibung nicht für Fortschritt oder Workpad-Pflege ändern.
- Beschreibungspflege in `Planung (AI)` übernimmt `symphony-planning`.
- Abweichungen zwischen Status und Inhalt im Workpad notieren.
- Zulässige Ausnahmen zu separaten Kommentaren sind alle ausdrücklich von
  `WORKFLOW.md` oder aufgerufenen Skills verlangten Nachvollziehbarkeitskommentare,
  etwa für Originalbeschreibungen, Klärungsfragen oder kombinierte
  Review-Finding-Fix-Kommentare; sie ersetzen das Workpad nicht.
- Ein separater Blocker-Kommentar ist bei bestehendem Workpad nur letzte Stufe,
  wenn kein erlaubter Toolpfad den vorhandenen Kommentar aktualisieren kann.

## Versionsbezogene Eingaben

Bei regulären aktiven Issues den Eingang mit `symphony_comments` (`checkpoint`)
bei Phasenstart/Fortsetzung, nach Meilensteinen und vor Handoffs frisch lesen.
Die einmalige Baseline enthält historische Kommentare und Workpad; noch relevante
offene Hinweise konsolidieren und den Startbeleg einmal bestätigen.

Fachliche Ergebnisse über `acknowledge` mit `results: [{key, outcome, reason}]`
speichern. Zulässige Ergebnisse: `übernommen`, `Rückfrage`, `nicht anwendbar`
(mit Begründung), `ersetzt` (mit `replacement` auf eine neuere Quellversion).
Das Tool ergänzt `### Kommentareingang` im bestehenden Workpad. Diesen Abschnitt
und seine vollständigen fachlichen Einträge mit Quellversion, Ergebnis,
Begründung und gegebenenfalls Ersatzbezug bei späteren Workpad-Updates erhalten.
Sie sind zugleich der idempotente Workpad-Beleg; keine zusätzlichen technischen
Ergebnis-Marker ergänzen. Alte eindeutig zugehörige HTML-Ergebnis-Marker entfernt
das Tool beim nächsten Ack selbst.
Ein Edit benötigt eine eigene Bestätigung; Auflösen ist kein fachlicher Abschluss.
Gelöschte Quellen nicht neu ausführen; begonnene Auswirkungen einordnen.
Ein eigener Löschungs-Quellschlüssel nach vorheriger Zustellung/Bestätigung
benötigt ein eigenes Ergebnis; das frühere Ergebnis bleibt erhalten.
Keine zusätzlichen Empfangskommentare. Technische Review-Subagenten erhalten
weiterhin keinen ungefilterten Kommentar-/Workpad-Kontext.

## Schreibvertrag für alle Linear-Texte

- Ergebnis/offene Entscheidung zuerst, danach nur notwendige Begründung,
  aussagekräftige Validierung und gegebenenfalls Fortsetzungsbedingung.
  Kurze Absätze oder Stichpunkte, keine Ticketwiederholung, Debug-Erzählung,
  duplizierten Betreiberanleitungen oder zusätzliche Zusammenfassung.
- Workpad als aktuellen Arbeitsstand pflegen: Plan, offene Pflichten,
  relevante Entscheidungen, jüngster Handoff. Überholte Versuche und alte
  Übergaben durch ihren noch relevanten Befund und einen Belegverweis ersetzen.
- Arbeitsziel höchstens 20.000 Zeichen. Vor jedem Update einschließlich neuer
  Acks Größe prüfen; spätestens bei 80.000 UTF-16-Einheiten semantisch verdichten.
  Der gemeinsame Schreibpfad weist größere Texte vor HTTP/Journal zurück;
  das ist ein korrigierbarer Schreibfehler, kein BLOCKER. Er verändert nichts.
  Anschließend dieselbe Kommentar-ID aktualisieren und offene Acks erneut
  bestätigen. Kein Abschneiden, Löschen von Pflichten oder zweites Workpad.
- Pflichtnachweise, offene Anforderungen, Einschränkungen, Quellen-/Standbezug,
  bewusste Skips und vollständige Ack-Einträge mit Quelle/Ergebnis/Begründung/
  Ersatzbezug bewahren. Maschinelle Überschriften, Checklisten und Fälligkeits-
  suffixe unverändert auswertbar halten. Alte Logs separat referenzieren.
- Vor Speicherung die verdichtete Fassung gegen diese Pflichten prüfen.
  Erforderliche Nach-Fix-Kommentare bleiben bestehen, enthalten aber jeweils
  nur Befund, Fix oder begründete Nichteinordnung und gezielten Nachweis.
  Beispiele und Szenarien: `docs/linear-app.md`, „Knappe Linear-Texte“.
