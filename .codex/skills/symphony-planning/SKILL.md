---
name: symphony-planning
description:
  Verwende diesen Skill innerhalb eines Symphony-Issue-Workflows für
  Ticketbeschreibung, Umsetzungsplan und geplante Validierung.
---

# Symphony Planning

Dieser Skill bereitet ein Ticket für autonome Folgeschritte vor. Workpad-Aufbau
kommt aus `symphony-workpad`; Statusübergänge aus `WORKFLOW.md` bzw.
`WORKFLOW_INTERACTIVE.md`.

## Linear-Beschreibung

- Scope, Absicht und Grenzen müssen für Plan und Validierung reichen.
- Bei längeren Beschreibungen oben eine kurze Zusammenfassung ergänzen und mit
  `---` vom Haupttext trennen.
- In `Planung (AI)` darf die Beschreibung verbessert werden, wenn das für
  saubere Planung nötig ist; die Originalbeschreibung dann separat in Linear
  dokumentieren.
- Außerhalb von `Planung (AI)` bleibt die Beschreibung unverändert.
- Fehlende Informationen nicht erfinden: Annahme, Lücke und empfohlenen
  Lösungsvorschlag im Workpad bzw. für `Planung` dokumentieren.

## Workpad-Plan

- `### Plan` ist eine hierarchische Checkliste konkreter Umsetzungsschritte.
- Der Plan enthält explizit Entwicklung/Änderung und automatisierte Tests.
- `### Validierung` ist eine Checkliste der geplanten Nachweise.
- Ticketseitige `Validation`-, `Test Plan`- oder `Testing`-Abschnitte werden
  verpflichtend übernommen.
- Bei App-Dateien oder App-Verhalten passende Runtime-Validierung einplanen.
- Jeden Pflichtnachweis mit konkreter Aktion, Verantwortlichem (Worker oder
  Betreiber) und fälliger Phase zuordnen. Bereits festgelegte Zuständigkeit
  übernehmen, nicht erneut erfragen. Bekannte spätere Betreiberpflichten
  verhindern keine autonome lokale Umsetzung; fehlende materielle Entscheidungen
  bleiben Klärungsbedarf. Vereinbarte Fälligkeiten nicht still verschieben.
  Belegformat und Übergabe: `symphony-workpad` sowie
  `docs/linear-app.md`, Abschnitt „Betreiberpflichten und Wiederaufnahme“.

## Qualitätsmaßstab

- Plan und Validierung vor der Umsetzung kritisch prüfen und schärfen.
- Keine unscharfen Sammelpunkte als Hauptschritte.
- Offene Entscheidungen zu Funktionalität, Verhalten oder Produktausgaben nicht
  still treffen; mit empfohlenem Lösungsvorschlag als Klärungsbedarf festhalten.
- Am Ende von `Planung (AI)` entscheiden, ob autonome Umsetzung möglich ist.
  Wenn nicht, müssen offene Fragen und empfohlene Lösungen direkt entscheidbar
  sein.

## Spätere Anpassungen

- Plan- oder Validierungsänderungen sind erlaubt, wenn neue Erkenntnisse sie
  nötig machen.
- Jede Änderung mit Grund und Validierungsauswirkung im Workpad dokumentieren.
- Verpflichtende Ticketvorgaben nicht eigenmächtig entfernen oder abschwächen.
  Spätere belegte menschliche Gateentscheidungen gemäß `symphony-workpad`
  übernehmen; überholte Beschreibungs-/Workpad-Defaults widerrufen sie nicht.
- Bei unklarem oder erweitertem Scope keine Anforderungen erfinden; betrifft die
  neue Erkenntnis Funktionalität, Verhalten oder Produktausgaben, als
  Klärungsbedarf mit empfohlenem Lösungsvorschlag behandeln.
