---
name: symphony-linear
description: Nutze `linear_graphql` für rohe Linear-GraphQL-Operationen.
---

# Linear GraphQL

Nutze das bereitgestellte `linear_graphql`-Tool. Pro Call genau eine Operation
senden und Top-Level-`errors` als Fehler behandeln.

HTTP-Fehler werden im Tool-Payload mit `status`, `classification`,
`bodyExcerpt`, `errors`, `extensionsCodes` und bei Bedarf `rateLimit`
ausgegeben. Behandle `classification: "auth"`, HTTP 401 und HTTP 403 ohne
Rate-Limit-Signal als fehlenden Linear-Zugriff für den regulären Tool-Pfad.
`classification: "rate_limited"`, `extensionsCodes` wie `RATELIMITED` und
`rateLimit.limited: true` sind Rate-Limit-Signale, keine Schema- oder
Auth-Fehler. Nicht erschöpfte `rateLimit`-Header ohne `limited: true` sind nur
Diagnosehinweise.

## Issue-Lookup

### Ein Issue per Key, Team/Nummer oder id abfragen

Bevorzuge den engsten bestätigten Pfad.

```graphql
query BootstrapIssue($key: String!) {
  issue(id: $key) {
    id
    identifier
    title
    state { id name type }
  }
}
```

Wenn du dich am Repo-Lookup orientieren willst, splitte den Identifier in
Team-Key und Nummer:

```graphql
query BootstrapIssueByTeamAndNumber($teamKey: String!, $number: Float!) {
  issues(filter: { team: { key: { eq: $teamKey } }, number: { eq: $number } }, first: 1) {
    nodes {
      id
      identifier
      title
      state { id name type }
    }
  }
}
```

Danach die interne `id` verwenden:

```graphql
query IssueById($id: String!) {
  issue(id: $id) {
    id
    identifier
    title
  }
}
```

Nutze keinen Fallback `issues(filter: { identifier: ... })`. Nimm keine
spekulativen Felder wie `links` in die erste Anfrage aufzunehmen. Wenn du ein
Beispiel brauchst: vermeide spekulative Felder wie `links` in die erste Anfrage aufzunehmen.

## Häufige Operationen

Kommentar erstellen:

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment { id url body }
  }
}
```

Kommentar bearbeiten:

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment { id body }
  }
}
```

Status wechseln:

```graphql
mutation MoveIssueToState($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id identifier state { id name } }
  }
}
```

Team-States laden:

```graphql
query IssueTeamStates($id: String!) {
  issue(id: $id) {
    team {
      states { nodes { id name type } }
    }
  }
}
```

GitHub-PR anhängen:

```graphql
mutation AttachGitHubPR($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) {
    success
    attachment { id title url }
  }
}
```

## Expliziter App-Betrieb

Wenn `SYMPHONY_LINEAR_AUTH_MODE=app` gesetzt ist, ausschließlich das injizierte
`linear_graphql` oder den gebundenen `symphony_linear`-MCP verwenden.
Fällt ein Transport aus, den anderen gebundenen Transport verwenden. Fehlen
oder scheitern beide, den Zugriffsblocker sichtbar melden; Kommentar und Status
nur bei bestätigtem erlaubtem Schreibzugriff als gespeichert behandeln.
Keine Shell-/Mix-/Update-Skript-Fallbacks im App-Modus und keine privaten
Envdateien laden. `scripts/linear-app` bleibt ein geschütztes Betreiberwerkzeug.
Kein persönlicher Linear-MCP,
kein direkter API-Key und keine Tokenabfrage. Providerfehler sichtbar behandeln.
Der App-Client erfasst Kommentar-IDs/Fassungen selbst; offene Schreibabsichten
anhand der gemeldeten Kommentar-ID abgleichen und keine blinde Neuanlage auslösen.

Ein versiegelter Legacy-Lauf (`SYMPHONY_RELEASE_ROOT`) verwendet beim Mix-Fallback
zusätzlich `--no-compile`, damit seine Build-Artefakte unverändert bleiben.
Workflow-, Source- und Env-Roots weiterhin getrennt gemäß folgendem Bootstrap
auflösen. Den gebundenen Auth-Modus/Hash nicht löschen oder ersetzen.

## Lokaler Workpad-Fallback (nur Legacy)

Wenn der reguläre Kommentar-Edit-Pfad wegen fehlendem Tool, HTTP 401, HTTP 403
ohne Rate-Limit-Signal oder Auth-Ausfall nicht nutzbar ist, aktualisiere einen
bestehenden Workpad-Kommentar lokal über den Tracker-Helfer. HTTP 403 mit
`RATELIMITED`, `classification: "rate_limited"` oder `rateLimit.limited: true`
ist ein Rate-Limit-Signal und kein fehlender Linear-Zugriff. Nicht erschöpfte
`rateLimit`-Header ohne `limited: true` sind nur Diagnosehinweise. Der Body muss
den Marker `## Symphony Workpad` enthalten und darf kein leerer
Probe-/Placeholder-Body sein.

```bash
source_repo="${SYMPHONY_SOURCE_REPO:-}"
if [ -z "${source_repo//[[:space:]]/}" ]; then
  source_repo="$(git rev-parse --show-toplevel)"
fi

(
cd "$SYMPHONY_WORKFLOW_DIR"
SYMPHONY_SOURCE_REPO="$source_repo" ISSUE_KEY=PRO-496 WORKPAD_BODY_FILE=/tmp/workpad.md mise exec -- mix run --no-start -e '
case System.get_env("SYMPHONY_WORKFLOW_FILE") do
  value when is_binary(value) ->
    case String.trim(value) do
      "" -> :ok
      workflow_file -> SymphonyElixir.Workflow.set_workflow_file_path(workflow_file)
    end

  _ ->
    :ok
end

source_repo = System.fetch_env!("SYMPHONY_SOURCE_REPO") |> String.trim()

:ok =
  SymphonyElixir.EnvFile.load(
    SymphonyElixir.EnvFile.config_dir(source_repo),
    override_existing: true
  )

{:ok, _} = Application.ensure_all_started(:req)
{:ok, issue} = SymphonyElixir.Tracker.fetch_issue_by_identifier(System.fetch_env!("ISSUE_KEY"))
body = File.read!(System.fetch_env!("WORKPAD_BODY_FILE"))
:ok = SymphonyElixir.Workpad.update_tracker_workpad(issue.id, body)
'
)
```

Erstelle im Legacy-Modus einen separaten Blocker-Kommentar nur dann, wenn sowohl der reguläre
Kommentar-Edit-Pfad als auch dieser lokale Workpad-Update-Helfer scheitern.

## Introspection und Uploads

Nutze gezielte Introspection, wenn Mutations-, Feld- oder Input-Formen unklar
sind. Für Uploads: `fileUpload` holen, Bytes per `curl -X PUT` mit gelieferten
Headern senden und `assetUrl` in Kommentar-Mutationen verwenden. Keine
Shell-Helper mit Raw-Tokens einführen.
