defmodule SymphonyElixir.RelayE2ETest do
  use ExUnit.Case
  alias SymphonyElixir.RelayFixture, as: Server

  defmodule Plug do
    def init(opts), do: opts
    def call(conn, server), do: SymphonyElixir.RelayFixture.http(conn, server, %{"workspace-key" => "workspace"})
  end

  @tag timeout: 60_000
  test "separate OS consumers survive a hard exit between durable receive and ack over HTTP" do
    server = start_supervised!(Server)
    bandit = start_supervised!({Bandit, plug: {Plug, server}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    root = Path.join([File.cwd!(), "_build", "relay-e2e-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    script = Path.join(root, "consumer.exs")
    File.write!(script, consumer_script())
    on_exit(fn -> File.rm_rf!(root) end)
    url = "http://127.0.0.1:#{port}"
    assert {output, 0} = run(script, root, url, "one", "normal")
    assert output =~ "ready executor"
    assert {output, 0} = run(script, root, url, "two", "normal")
    assert output =~ "ready nonlocal"
    Server.publish(server, "workspace")
    assert {_, 71} = run(script, root, url, "one", "crash")
    assert Server.consumer(server, "workspace", "one").cursor == 0
    assert Server.consumer(server, "workspace", "two").cursor == 0
    assert {output, 0} = run(script, root, url, "one", "normal")
    assert output =~ "ready executor"
    assert Server.consumer(server, "workspace", "one").cursor == 1
    assert Server.consumer(server, "workspace", "two").cursor == 0
    assert {output, 0} = run(script, root, url, "two", "normal")
    assert output =~ "ready nonlocal"
    assert Server.consumer(server, "workspace", "two").cursor == 1
    assert File.exists?(Path.join([root, "one", "started"]))
    refute File.exists?(Path.join([root, "two", "started"]))
  end

  defp run(script, root, url, consumer, mode) do
    paths = Path.wildcard(Path.join([File.cwd!(), "_build/test/lib/*/ebin"])) |> Enum.flat_map(&["-pa", &1])
    System.cmd(System.find_executable("elixir"), paths ++ [script, root, url, consumer, mode], env: SymphonyElixir.Config.without_linear_secret([]), stderr_to_stdout: true)
  end

  defp consumer_script do
    ~S"""
    Application.ensure_all_started(:req)
    alias SymphonyElixir.Relay.{Client, Session}
    alias SymphonyElixir.{ProjectContext, Config, Relay}
    alias SymphonyElixir.Config.Schema
    [root, url, consumer, mode] = System.argv()
    config = %{"state_root" => Path.join(root, consumer), "endpoint" => url, "reconcile_ms" => 3_600_000,
      "consumer_id" => consumer}
    persist = fn path, record ->
      result = SymphonyElixir.Linear.DurableState.write(path, record)
      if result == :ok and mode == "crash" and record["pending"], do: System.halt(71)
      result
    end
    assignees = if consumer == "one", do: ["human"], else: ["another-human"]
    {:ok, session} = Session.open(config, "workspace", consumer, assignees, "e2e",
      request: fn op, body -> Client.request(config, %{}, consumer, op, body,
        allow_loopback: true, key: fn -> {:ok, "workspace-key"} end) end,
      snapshot: fn _ -> {:ok, [%{"id" => "issue"}]} end,
      fetch: fn _ -> {:ok, [%{"id" => "issue"}]} end, persist: persist)
    session = Session.tick(session)
    context = %ProjectContext{assignee_ids: assignees, settings: %Schema{tracker: %Schema.Tracker{relay: config, app: %{"workspace_id" => "workspace"}}}}
    ProjectContext.bind(context)
    allowed = Relay.execution_allowed(%{assignee_id: "human", assigned_to_worker: true}) == :ok
    if allowed and session.status == :ready, do: File.write!(Path.join(config["state_root"], "started"), "local-work")
    IO.puts("#{session.status} #{if allowed, do: "executor", else: "nonlocal"}")
    if session.status != :ready, do: System.halt(2)
    """
  end
end
