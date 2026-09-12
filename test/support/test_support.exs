defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "Du arbeitest an einem Ticket dieses Repositorys."
  @repo_workflow_file Path.expand("../../WORKFLOW.md", __DIR__)
  @test_isolation_env_names ["LINEAR_PROJECT_SLUG", "LINEAR_TEAM_KEY", "SYMPHONY_LINEAR_SECRET_ACCESS"]

  # Script fixtures always use the system shell and system utilities. Python is
  # an explicit dependency, so pin only that executable from the host PATH.
  # In particular, never inherit Homebrew bash/coreutils/util-linux on macOS.
  def script_path(bin_dir) do
    python = Path.join(bin_dir, "python3")

    if not File.exists?(python) do
      case File.ln_s(System.find_executable("python3") || raise("python3 required"), python) do
        :ok -> :ok
        {:error, :eexist} -> :ok
      end
    end

    "#{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin"
  end

  def script_env(bin_dir) do
    [
      {"PATH", script_path(bin_dir)},
      {"BASH_ENV", nil},
      {"ENV", nil},
      {"ZDOTDIR", nil}
    ]
  end

  def system_bash_hook(command, test_root) do
    bin_dir = Path.join(test_root, "system-tools")
    File.mkdir_p!(bin_dir)
    path = script_path(bin_dir)
    hook_file = Path.join(test_root, "system-hook.sh")

    File.write!(hook_file, """
    set -eu
    export PATH=#{shell_quote(path)}
    unset BASH_ENV ENV
    if [[ "$(uname -s)" == Darwin ]]; then
      [[ "$BASH_VERSION" == 3.2.* ]]
      [[ "$(command -v ln)" == /bin/ln ]]
    fi
    #{command}
    """)

    "exec /bin/bash --noprofile --norc #{shell_quote(hook_file)}"
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  def install_runtime_fixture!(repo_dir, bin_dir) do
    runtime_dir = Path.join(bin_dir, "runtime")
    File.mkdir_p!(runtime_dir)
    File.write!(Path.join(repo_dir, "mise.toml"), "[tools]\nerlang = \"28\"\nelixir = \"1.19.5-otp-28\"\n")

    for tool <- ["erl", "elixir", "escript"] do
      path = Path.join(runtime_dir, tool)
      File.write!(path, "#!/bin/bash\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    mise = Path.join(bin_dir, "mise")

    File.write!(mise, """
    #!/bin/bash
    case "$1" in
      ls)
        test "${SYMPHONY_TEST_MISE_LS_STATUS:-0}" = 0 || exit "$SYMPHONY_TEST_MISE_LS_STATUS"
        python3 -c 'import json, sys; print(json.dumps([{"installed": sys.argv[2] == "0", "active": True, "source": {"path": sys.argv[1] + "/mise.toml"}}]))' "$3" "${SYMPHONY_TEST_RUNTIME_MISSING:-0}"
        ;;
      env)
        # Output before failure must never be evaluated by the launcher.
        printf 'export PATH=%q:$PATH\\n' "#{runtime_dir}"
        exit "${SYMPHONY_TEST_MISE_ENV_STATUS:-0}"
        ;;
      exec)
        shift 2
        exec "$@"
        ;;
      *) exit 1 ;;
    esac
    """)

    File.chmod!(mise, 0o755)
    runtime_dir
  end

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        runtime_env_snapshot = SymphonyElixir.TestSupport.scrub_symphony_runtime_env()
        System.put_env("SYMPHONY_TEST_LINEAR_SECRET", "synthetic-secret")
        previous_req_options = Req.default_options()
        if pid = Process.whereis(SymphonyElixir.Linear.AppAuth), do: GenServer.stop(pid)

        SymphonyElixir.TestSupport.ensure_application_started()
        # Each fixture is a fresh installation. The shipped workflow now uses
        # app identity; a live store correctly refuses switching it to a test
        # identity. Restart the store at the fixture boundary instead.
        Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        # Runtime-owned comment state must never be read from the developer's
        # checkout when a fixture validates its synthetic app configuration.
        System.put_env("SYMPHONY_LINEAR_ENV_DIR", Path.join(workflow_root, ".symphony"))
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
        stop_default_http_server()

        on_exit(fn ->
          System.delete_env("SYMPHONY_TEST_LINEAR_SECRET")
          Req.default_options(previous_req_options)
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :yolo)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :memory_tracker_comments)
          SymphonyElixir.TestSupport.restore_env_snapshot(runtime_env_snapshot)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        case SymphonyElixir.WorkflowStore.force_reload() do
          {:error, :auth_binding_change_requires_restart} ->
            # A fixture change is a new configured runtime. Live app bindings
            # correctly require restart instead of switching identity in place.
            Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)
            Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.WorkflowStore)

          result ->
            result
        end
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def symphony_runtime_env_keys do
    SymphonyElixir.RuntimePaths.runtime_env_names()
  end

  def cleared_symphony_runtime_env do
    Enum.map(symphony_runtime_env_keys(), &{&1, nil})
  end

  def scrub_symphony_runtime_env do
    env_names = symphony_runtime_env_keys() ++ @test_isolation_env_names
    snapshot = Map.new(env_names, fn key -> {key, System.get_env(key)} end)
    Enum.each(env_names, &System.delete_env/1)
    snapshot
  end

  def restore_env_snapshot(snapshot) when is_map(snapshot) do
    Enum.each(snapshot, fn {key, value} -> restore_env(key, value) end)
    :ok
  end

  def ensure_application_started do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        {:ok, _started} = Application.ensure_all_started(:symphony_elixir)
        :ok
    end
  end

  def stop_default_http_server do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        terminate_default_http_server()

      _ ->
        :ok
    end
  end

  defp terminate_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, child_pid, _type, _modules} when is_pid(child_pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(child_pid) do
          Process.exit(child_pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    prompt_snippets =
      case {Keyword.has_key?(overrides, :prompt_snippets), Keyword.get(overrides, :prompt_snippets)} do
        {false, _value} ->
          default_prompt_snippets!()

        {true, snippets} ->
          snippets
      end

    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_project_slug: "project",
          tracker_team_key: nil,
          tracker_assignee: "dev@example.com",
          tracker_active_states: [
            "Todo (AI)",
            "Planung (AI)",
            "In Arbeit (AI)",
            "PreReview (AI)",
            "Review (AI)",
            "Test (AI)",
            "Abbruch (AI)",
            "Merge (AI)"
          ],
          tracker_terminal_states: ["Review", "Fertig", "Abgebrochen"],
          poll_interval_ms: 30_000,
          poll_idle_shutdown_ms: 3_600_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 30_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt_snippets: prompt_snippets,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_team_key = Keyword.get(config, :tracker_team_key)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    poll_idle_shutdown_ms = Keyword.get(config, :poll_idle_shutdown_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt_snippets = Keyword.get(config, :prompt_snippets)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  auth_mode: app",
        "  app:",
        "    client_id: synthetic-client",
        "    client_secret_env: SYMPHONY_TEST_LINEAR_SECRET",
        "    workspace_id: synthetic-workspace",
        "    user_id: synthetic-app",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  team_key: #{yaml_value(tracker_team_key)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "  idle_shutdown_ms: #{yaml_value(poll_idle_shutdown_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(
          hook_after_create,
          hook_before_run,
          hook_after_run,
          hook_before_remove,
          hook_timeout_ms
        ),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        prompt_snippets_yaml(prompt_snippets),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  def stub_linear_client(request) do
    if pid = Process.whereis(SymphonyElixir.Linear.AppAuth), do: GenServer.stop(pid)

    Req.default_options(
      plug: fn conn ->
        if conn.host == "api.linear.app" and conn.request_path == "/oauth/token" do
          Req.Test.json(conn, %{"access_token" => "synthetic-app-token", "token_type" => "Bearer", "expires_in" => 3600, "scope" => "read,write"})
        else
          raise "unexpected HTTP request in Linear fixture"
        end
      end
    )

    Application.put_env(:symphony_elixir, :linear_client_request_fun, fn payload, headers ->
      query = payload[:query] || payload["query"]

      if String.contains?(query, "SymphonyAppIdentity") do
        {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "synthetic-app", "app" => true, "organization" => %{"id" => "synthetic-workspace"}}}}}}
      else
        request.(payload, headers)
      end
    end)
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms),
    do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(
         hook_after_create,
         hook_before_run,
         hook_after_run,
         hook_before_remove,
         timeout_ms
       ) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp prompt_snippets_yaml(prompt_snippets) when prompt_snippets in [nil, %{}], do: nil

  defp prompt_snippets_yaml(prompt_snippets) when is_map(prompt_snippets) do
    [
      "prompt_snippets:"
      | Enum.map(prompt_snippets, fn
          {name, template} when is_binary(template) ->
            prompt_snippet_entry(to_string(name), template)

          {name, template} ->
            prompt_snippet_entry(to_string(name), to_string(template))
        end)
    ]
    |> Enum.join("\n")
  end

  defp prompt_snippets_yaml(prompt_snippets), do: "prompt_snippets: #{yaml_value(prompt_snippets)}"

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp prompt_snippet_entry(name, template) when is_binary(name) and is_binary(template) do
    indented =
      template
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp default_prompt_snippets! do
    case SymphonyElixir.Workflow.load(@repo_workflow_file) do
      {:ok, %{config: config}} when is_map(config) ->
        case Map.get(config, "prompt_snippets") || Map.get(config, :prompt_snippets) do
          prompt_snippets when is_map(prompt_snippets) ->
            prompt_snippets

          other ->
            raise "expected prompt_snippets map in #{@repo_workflow_file}, got: #{inspect(other)}"
        end

      {:error, reason} ->
        raise "failed to load workflow prompt_snippets from #{@repo_workflow_file}: #{inspect(reason)}"
    end
  end
end
