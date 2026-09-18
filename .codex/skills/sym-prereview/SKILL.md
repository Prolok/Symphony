---
name: sym-prereview
description: Repository-spezifische PreReview-Checkliste für Symphony Elixir.
---

# Sym PreReview

Nur über `symphony-prereview` verwenden.

## Checkliste

1. `make check`
2. Passende gezielte Testevidenz für den aktuellen Änderungsstand prüfen;
   fehlende oder durch Änderungen entwertete Nachweise gezielt ausführen.

`make check` verwendet den repo-lokalen Wrapper `scripts/mix-gate` und führt
Build, Format und Lint inklusive `specs.check` ohne Tests aus. Die vollständige
Suite mit Coverage und Dialyzer bleibt in `Test (AI)`. Keine
geerbten `SYMPHONY_*`-Runtime-Variablen manuell übernehmen und kein
dauerhaftes `mise trust` voraussetzen; der Wrapper vertraut eine vorhandene
`mise.toml` nur prozesslokal über `MISE_TRUSTED_CONFIG_PATHS`.

Bei Abweichungen direkt fixen, den fehlgeschlagenen Schritt wiederholen und
danach fortsetzen.
