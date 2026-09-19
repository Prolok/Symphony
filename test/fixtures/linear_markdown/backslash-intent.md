Bei der fachlichen Schlussabnahme von PRO-797 am gemergten Stand 5576eda42733ed099879f34cec7700e86641bc15 fehlt die ausdrücklich verlangte Datei docs/po-proof-pro734-probe503-followup-yolo-20260918-01.md. Tatsächlicher Dateizugriff: exists=False, read_text() ergibt FileNotFoundError. git ls-tree für genau diesen Pfad und Commit endet mit Exit 0 ohne Eintrag. Die Bedienungsdokumentation wurde deshalb nicht abgenommen.

Anforderungen:
1. Die reguläre AI-Ticketpipeline legt docs/po-proof-pro734-probe503-followup-yolo-20260918-01.md als echte, nicht leere Markdown-Datei an.
2. Die Datei erklärt auf Deutsch verständlich die Bedienung des Dummy-Projekts symphony-test: Zweck, Voraussetzungen (uv und Python >=3.12), Einstieg aus dem Repository-Root sowie mindestens ein konkreter vorhandener Skriptaufruf mit erwarteter Ausgabe. Geeignet ist uv run python symphony_probe.py mit der Ausgabe Symphony-Test: bereit.
3. Den normalen Testaufruf uv run pytest bzw. make erklären und auf die vorhandene Skript-Referenz sowie Entwicklungs-/Testdokumentation verweisen. Keine Befehle, Optionen oder Ausgaben erfinden; Angaben anhand des tatsächlichen Codes und der bestehenden Dokumentation prüfen.
4. Die neue stabile Anleitung in docs/README.md auffindbar verlinken; relative Links müssen auf existierende Dateien zeigen. Bestehende Dokumentation konsistent halten.
5. Den Fix auf diese Dokumentationslücke begrenzen; bestehendes Skriptverhalten unverändert erhalten. Die regulären technischen Pflichtgates bleiben wirksam.

Ursprung: PRO-797 (301ed829-1467-4ebd-863c-ee8a36ecac6f). Dieses Ticket behebt den ausgelagerten offenen Mangel. PRO-797 wird nach bestätigter Anlage und Verknüpfung sofort in Review an Tilo übergeben; seine Betreuung wartet nicht auf diesen Fix. Der Fix erhält eine eigene Abnahme am Ende seines regulären Durchlaufs.

## Validierung

1. Am gemergten Fix-Stand die Datei docs/po-proof-pro734-probe503-followup-yolo-20260918-01.md tatsächlich öffnen und ihren Inhalt prüfen; Existenz allein reicht nicht.
2. Prüfen, dass Zweck, Voraussetzungen, ausführbarer Einstieg, mindestens ein konkreter Bedienungsablauf und erwartete Ausgabe sowie der Testaufruf für eine neue Person nachvollziehbar beschrieben sind.
3. Den dokumentierten Beispielaufruf uv run python symphony_probe.py aus dem Repository-Root mit begrenzter Laufzeit tatsächlich ausführen: Exit 0, stdout exakt "Symphony-Test: bereit\n", stderr leer. Weitere dokumentierte Beispiele gegen ihren tatsächlichen Code oder gezielte Prozessaufrufe prüfen.
4. Alle relativen Dokumentationslinks und den Eintrag in docs/README.md prüfen. uv run pytest/make anhand pyproject.toml und Makefile bestätigen; einen vollständigen Testlauf für reine Dokumentation nur ausführen, wenn das reguläre Pflichtgate ihn verlangt.
5. Befehle, Zeitgrenzen und tatsächlich beobachtete Ergebnisse im Fix-Workpad festhalten; nach Prüfungen ausschließlich eigene temporäre Artefakte kontrolliert bereinigen. Die eigene Schlussabnahme des Fixes muss den bisher offenen Dokumentationsmangel ausdrücklich bewerten.

## Ursprung

- [PRO-797](https://linear.app/prolok/issue/PRO-797/symphony-test-pro734-probe503-followup-yolo-20260918-01-symphony-test)