## Validierung

Für die spätere Umsetzung:

1. docs/po-proof-pro734-capability-aggregation-retry-20260918-01.md existiert als Markdown-Dokument.
2. Die Abschnitte „Backlog“, „Todo“ und „Definiert“ sind einzeln auffindbar; jeder enthält einen verständlichen Zweck und explizite, prüfbare Abnahmekriterien.
3. Ein Anforderungsabgleich deckt PRO-781 → Backlog, PRO-782 → Todo und PRO-783 → Definiert vollständig ab.
4. Die Ablaufbeschreibung erhält die Reihenfolge gemeinsame Bewertung → bestätigte Aggregation/Verknüpfung → Ursprungsabschluss und behauptet keine automatische Implementierungs- oder technische Freigabe.
5. docs/README.md verlinkt die neue Datei mit auflösbarem relativem Pfad. Markdown-/Linkprüfung und git diff --check dokumentieren; weitere Tests richten sich nach den tatsächlichen Änderungen und den regulären Pflichtgates.

Abnahme dieses begrenzten PO-Laufs:

* Genau ein Aggregationsticket im selben Projekt und Team, Status Backlog, Label symphony-generated, Assignee Fixture-Assignee und Delegation Fixture-Agent sind bestätigt.
* Alle drei Ursprünge sind mit dem Aggregationsticket verknüpft und erst danach in „Umsetzungsticket erstellt“.
* Keine Abhängigkeit geht verloren, keine Zyklen entstehen; aktuell sind keine blockedBy-Relationen erforderlich.
* Je Ursprung existiert genau ein Symphony Workpad mit Entscheidung, tatsächlich erhobenen Belegen und bestätigten Kommentarversionen; jedes Mitglied wird über symphony_yolo_complete bestätigt.
* Keine Implementierung, Quelländerung, Commits oder Bearbeitung des neuen Tickets im aktuellen Sammellauf.
