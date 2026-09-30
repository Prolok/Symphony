---
name: symphony-architecture
description: Leitet Worker und separate Architekturprüfungen an, wenn ein Zielrepository docs/architecture/contract.json enthält.
---

# Architekturvertrag

Nur für Repositories mit `docs/architecture/contract.json`. Format und Merge-Gate stehen in [docs/architecture-contract.md](../../../docs/architecture-contract.md).

## Worker

- Führe den vertraglichen Prüfbefehl aus und halte Architekturregeln, Baselines und Vertrag grundsätzlich ein, ohne sie zu ändern.
- Setze ausdrückliche Architekturvorgaben des Tickets um. Eine andere Änderung an Regeln, Baselines oder Vertrag ist nur im Extremfall vertretbar, wenn sich die Anforderung sonst nicht sinnvoll erfüllen lässt. Begründe die Ausnahme mit einem neuen oder geänderten ADR oder dem PR-Abschnitt `## Architekturänderung`.
- Verschärfungen, etwa eine kleinere Baseline oder strengere Regel, sind erwünscht. Auch sie müssen als Architekturänderung begründet und sichtbar sein.
- Der Merge-Helper meldet eine fehlende Begründung oder eine rote Prüfung als benannten Merge-Gate-Befund. Behebe den Befund selbst und lasse den Kandidaten erneut prüfen. Eine Architekturfreigabe wird nicht eingeholt.

## Separate Architekturprüfung

Bewerte die gekennzeichneten Pfade und die Begründung gegen Bausteinsicht, Qualitätsziele und bestehende ADRs. Prüfe, ob Duplikation entsteht und welche Folgen die Änderung hat. Halte als Ergebnis **belassen**, **nachsteuern** oder **per Folgeticket zurückführen** fest. Die Prüfung verändert das Merge-Gate nicht.
