# Architekturentscheidung: gemeinsamer Linear-Lesepfad

Tool-Aufrufe, Kommentar-Checkpoints und PO-Läufe lesen bei bereitem Relay über
den bestehenden `IssueReadCache` und die persistierte `CommentInbox`.
`Tracker` bildet den Einstieg; interne direkte HTTP-Leser bleiben im Adapter.
Issue- und Abhängigkeitsprojektionen teilen Verifikation, relevante Relay-Epochen
und die Sicherheitsfrist von 15 Minuten. Advisory-Verifikation verwendet dieselben
Cache-Einträge, gebunden an App, Workspace, Agentbindung und Relaygeneration.

Die getrennte Wartemarker-Kommentarfrische entfällt. Zielauflösungen und
Fehlerberichte behalten ihre fachlichen Metadaten. Bestätigte eigene Kommentare
invalidieren Kommentarleser über das bestehende Journal, auch vor dem Relay-Echo.
Vollständige Prüfungen vor Starts, Statusaktionen und Abschlussbestätigungen sowie
Workpad-Ausgangstexte beim Schreiben bleiben direkt. Kommentarlesen prüft seine
eigene Epoche und Frist; eine fällige Issue-Sicherheitsprüfung sperrt keine gültigen
Kommentarstände unter kritischem Budget. Freie GraphQL-Abfragen bleiben Durchreichung.

Damit hängt die Leselast von Änderungen und Sicherheitsprüfungen ab, statt von
der Anzahl der Werkzeugaufrufe. Weitere Caches je Einstieg würden dieselben
Datenstände und Invalidierungsregeln erneut vervielfachen. Ein allgemeiner
GraphQL-Antwortcache wäre wegen freier Queries und Schreib-/Scope-Grenzen schwer
prüfbar. Beide Alternativen wurden verworfen. Ohne bereites Relay bleibt der
bisherige direkte Rückfall mit den bestehenden Budgetgrenzen erhalten.
