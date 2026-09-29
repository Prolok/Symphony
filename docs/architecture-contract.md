# Architekturvertrag im Zielrepository

Ein Repository kann `docs/architecture/contract.json` enthalten. Nur bei vorhandenem Vertrag aktiviert Symphony beim Merge eine Architekturprüfung. Fehlt die Datei auf Basis und Kandidat eindeutig, bleibt der bisherige Merge-Ablauf unverändert.

```json
{
  "command": ["npm", "run", "check:arch"],
  "timeout_seconds": 120,
  "architecture_paths": ["docs/architecture/**", "rules/**"]
}
```

`command` ist eine nicht leere argv-Liste, `timeout_seconds` ist größer als null und höchstens 120, `architecture_paths` enthält relative Globs. Die Vertragsdatei zählt immer als Architekturpfad. Ungültige oder unlesbare Verträge sind Fehler; allein die bestätigte Abwesenheit deaktiviert die Prüfung. Fehlt die PR-Basis lokal, lädt der Helper sie mit einem begrenzten Fetch von `origin` nach. Ein fehlgeschlagener Fetch meldet `architecture_base_unavailable` als vorübergehenden Fehler.

Der Merge-Helper vergleicht Basis und Head, berücksichtigt die Pfad-Globs beider Verträge und führt den Prüfbefehl aus dem Merge-Kandidaten auf dessen Checkout aus. Ein rotes Ergebnis oder Timeout liefert `architecture_check_failed` mit gekürzter Ausgabe. Eine veraltete Basis erfordert einen neuen Kandidaten.

Für geänderte, neue oder gelöschte Architekturpfade braucht die Änderung einen neuen oder geänderten ADR unter `docs/architecture/adr/` oder einen PR-Abschnitt `## Architekturänderung` mit den Feldern `Änderung:`, `Grund:` und `Alternativen:`. Die Felder dürfen als Markdown-Liste und mit fetten Bezeichnern erscheinen, etwa `- **Änderung:** ...`. Ohne Begründung liefert der Helper `architecture_change_unjustified`. Er schreibt nach erfolgreicher Prüfung eine maschinenlesbare Pfadliste mit Begründungsverweis in die PR und das Symphony Workpad. Existiert im Linear-Team das Label `Architekturänderung`, ergänzt er es am Ticket; ein fehlendes Label blockiert nicht. Eine Freigabe ist nicht vorgesehen.
