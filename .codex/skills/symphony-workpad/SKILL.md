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
