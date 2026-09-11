# Loaded only by the isolated offline Codex/MCP probe, never by production.
:ok = SymphonyElixir.Codex.MCPServer.bootstrap()
settings = SymphonyElixir.Config.settings!()
:ok = SymphonyElixir.Linear.AppAuth.validate(settings.tracker)
true = settings.tracker.assignee == "human@example.invalid"
true = settings.tracker.project_slug == "synthetic-project"
present = match?({:ok, value} when byte_size(value) > 0, SymphonyElixir.Config.linear_client_secret(settings.tracker.app))
nil = System.get_env("LINEAR_APP_SECRET")
File.write!(System.fetch_env!("PROBE_FILE"), Jason.encode!(%{present: present}))
