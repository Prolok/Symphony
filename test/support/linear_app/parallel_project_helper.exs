alias SymphonyElixir.{Config, EnvFile, Workflow}
alias SymphonyElixir.Linear.Client

:ok = Workflow.set_workflow_file_path(System.fetch_env!("SYMPHONY_WORKFLOW_FILE"))
:ok = EnvFile.load_runtime(EnvFile.config_dir(File.cwd!()))
{:ok, _} = Application.ensure_all_started(:req)
:ok = Config.validate_startup_requirements()
tracker = Config.settings!().tracker
binding = tracker.app
instance = System.fetch_env!("PROBE_INSTANCE")
System.put_env(Config.linear_runtime_env())

File.cd!(System.fetch_env!("SYMPHONY_RELEASE_ROOT"), fn ->
  :ok = SymphonyElixir.Application.startup_preflight()
  true = Config.settings!().tracker == tracker
  nil = System.get_env("LINEAR_APP_SECRET")
end)

Req.default_options(
  plug: fn conn ->
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    form = URI.decode_query(body)
    true = form["client_id"] == binding["client_id"]
    true = form["client_secret"] == "synthetic-" <> binding["client_id"]
    Req.Test.json(conn, %{access_token: "synthetic-token-" <> instance, token_type: "Bearer", expires_in: 2_591_999, scope: "read write"})
  end
)

Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
  true = {"Authorization", "Bearer synthetic-token-" <> instance} in headers
  query = payload[:query] || payload["query"]

  data =
    if query =~ "SymphonyAppIdentity" do
      %{"viewer" => %{"id" => binding["user_id"], "app" => true, "organization" => %{"id" => binding["workspace_id"]}}}
    else
      input = payload["variables"]["input"]
      comment = %{"id" => input["id"], "body" => input["body"], "updatedAt" => "2026-09-10T00:00:00Z", "issue" => %{"id" => input["issueId"]}, "user" => %{"id" => binding["user_id"]}}
      %{"commentCreate" => %{"success" => true, "symphonyReceipt" => comment}}
    end

  {:ok, %{status: 200, body: %{"data" => data}}}
end)

barrier = System.fetch_env!("PROBE_BARRIER")
File.write!(Path.join(barrier, instance), "ready")

Enum.reduce_while(1..200, nil, fn _, _ ->
  if File.exists?(Path.join(barrier, "go")),
    do: {:halt, :ok},
    else:
      (
        :timer.sleep(25)
        {:cont, nil}
      )
end)

true = File.exists?(Path.join(barrier, "go"))
{:ok, _} = Client.graphql("mutation($input: CommentCreateInput!){commentCreate(input:$input){success}}", %{"input" => %{"issueId" => "same-synthetic-issue", "body" => binding["client_id"]}})
runtime = Config.linear_runtime_env()
session_root = runtime["SYMPHONY_CODEX_STATE_ROOT"]
File.mkdir_p!(session_root)
File.write!(Path.join(session_root, "synthetic-session.json"), Jason.encode!(%{workspace: binding["workspace_id"], assignee: tracker.assignee}))

IO.puts(
  Jason.encode!(%{
    client: binding["client_id"],
    workspace: binding["workspace_id"],
    assignee: tracker.assignee,
    project: tracker.project_slug,
    session: session_root,
    hash: runtime["SYMPHONY_LINEAR_BINDING_HASH"]
  })
)
