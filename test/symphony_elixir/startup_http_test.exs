defmodule SymphonyElixir.StartupHttpTest do
  use ExUnit.Case, async: true

  @workspace "11111111-1111-4111-8111-111111111111"
  @project "22222222-2222-4222-8222-222222222222"
  @teams [%{"id" => "33333333-3333-4333-8333-333333333333", "key" => "PRO"}]

  defmodule Fixture do
    def init(opts), do: opts

    def call(conn, {owner, rejection}) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      response =
        if conn.request_path == "/oauth/token" do
          send(owner, :token_requested)
          %{"access_token" => "synthetic-token", "token_type" => "Bearer", "expires_in" => 3600, "scope" => "read write"}
        else
          query = Jason.decode!(body)["query"]
          send(owner, {:graphql, query})

          %{
            "data" => %{
              "viewer" => %{
                "id" => if(rejection == :identity, do: "foreign-app", else: "fixture-app"),
                "app" => true,
                "organization" => %{"id" => "11111111-1111-4111-8111-111111111111", "urlKey" => "prolok"}
              },
              "project" => %{
                "id" => "22222222-2222-4222-8222-222222222222",
                "name" => "symphony-test",
                "slugId" => "dummy",
                "teams" => %{"nodes" => [%{"id" => "33333333-3333-4333-8333-333333333333", "key" => if(rejection == :teams, do: "OTHER", else: "PRO")}], "pageInfo" => %{"hasNextPage" => false}}
              }
            }
          }
        end

      conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end
  end

  setup context do
    root = Path.join([File.cwd!(), "tmp", "cold-http-#{System.unique_integer([:positive])}"])
    project = Path.join(root, "projects/symphony-test")
    File.mkdir_p!(Path.join(project, ".symphony"))

    File.write!(
      Path.join(project, ".symphony/.env"),
      "LINEAR_APP_CLIENT_ID=fixture-client\nLINEAR_APP_WORKSPACE_ID=#{@workspace}\nLINEAR_APP_USER_ID=fixture-app\nLINEAR_PROJECT_SLUG=dummy\nLINEAR_ASSIGNEE=fixture@example.invalid\n"
    )

    File.write!(Path.join(project, ".symphony/.env.local"), "LINEAR_APP_SECRET=synthetic-secret\n")

    config = %{
      "tracker" => %{
        "kind" => "linear",
        "auth_mode" => "app",
        "project_slug" => "$LINEAR_PROJECT_SLUG",
        "assignee" => "$LINEAR_ASSIGNEE",
        "app" => %{
          "client_id" => "$LINEAR_APP_CLIENT_ID",
          "workspace_id" => "$LINEAR_APP_WORKSPACE_ID",
          "user_id" => "$LINEAR_APP_USER_ID",
          "client_secret_env" => "LINEAR_APP_SECRET",
          "installation_id" => "symphony"
        }
      },
      "workspace" => %{"root" => "$SYMPHONY_PROJECT_WORKTREES_ROOT"},
      "worker" => %{
        "test_executor_socket" => Path.join(root, "executor/test.sock"),
        "test_executor" => %{
          "workspace_id" => @workspace,
          "project_id" => @project,
          "slug_id" => "dummy",
          "teams" => @teams,
          "scenarios" => ["workflow"],
          "timeout" => 30,
          "result_root" => Path.join(root, "results")
        }
      }
    }

    File.write!(Path.join(root, "WORKFLOW.md"), "---\n" <> Jason.encode!(config) <> "\n---\nSynthetic cold startup\n")
    on_exit(fn -> File.rm_rf!(root) end)
    server = start_supervised!({Bandit, plug: {Fixture, {self(), context[:rejection]}}, port: 0, ip: {127, 0, 0, 1}})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    %{root: root, port: port}
  end

  for stage <- [nil, "run", "prepare", "probe", "cleanup"] do
    @tag stage: stage
    test "cold CLI verifies the managed target over HTTP before service startup in #{stage || "normal"}", context do
      {output, status} = run_isolated(context)
      assert status == 1, output
      assert output =~ "cold-http-runtime"
      assert output =~ "target-verified-before-service"
      assert_received :token_requested
      assert_received {:graphql, "query SymphonyAppIdentity" <> _}
      assert_received {:graphql, "query SymphonyRoutineBinding" <> _}
      refute File.exists?(Path.join(context.root, "executor"))
      refute File.exists?(Path.join(context.root, "results"))
    end
  end

  for rejection <- [:identity, :teams] do
    @tag rejection: rejection
    test "cold startup retains #{rejection} rejection before service and executor start", context do
      {output, status} = run_isolated(context)
      assert status == 1, output
      assert output =~ "cold-http-runtime"
      refute output =~ "target-verified-before-service"
      assert_received :token_requested
      assert_received {:graphql, "query SymphonyAppIdentity" <> _}

      if context.rejection == :identity do
        assert output =~ "linear_app_identity_mismatch"
        refute_received {:graphql, "query SymphonyRoutineBinding" <> _}
      else
        assert output =~ "routine_test_project_binding_rejected"
        assert_received {:graphql, "query SymphonyRoutineBinding" <> _}
      end

      refute File.exists?(Path.join(context.root, "executor"))
    end
  end

  defp run_isolated(context) do
    script = """
    Code.compiler_options(ignore_module_conflict: true)
    # Isolate the host lock and stop after real discovery/auth/target verification.
    # No Symphony service, executor or live Linear request is started by this fixture.
    defmodule SymphonyElixir.ServiceMutex do
      def acquire(_name), do: :ok
      def reserve_projects([context]) do
        nil = Process.whereis(SymphonyElixir.Supervisor)
        nil = Process.whereis(SymphonyElixir.TestExecutor)
        "symphony-test" = context.name
        IO.puts("target-verified-before-service")
        {:error, :fixture_stop}
      end
    end
    defmodule SymphonyElixir.TestRun do
      def stage, do: System.get_env("SYMPHONY_TEST_RUN_STAGE")
      def bind_contexts(contexts), do: {:ok, contexts}
      def execute(_stage) do
        SymphonyElixir.ServiceMutex.reserve_projects(SymphonyElixir.Projects.configured())
      end
    end
    false = Enum.any?(Application.started_applications(), fn {app, _, _} -> app in [:req, :finch, :symphony_elixir] end)
    IO.puts("cold-http-runtime")
    # Redirect only the destination inside this disposable BEAM; use real Req/Finch.
    defmodule LocalHttp do
      def run(request) do
        uri = %{request.url | scheme: "http", host: "127.0.0.1", port: #{context.port}}
        Req.Finch.run(%{request | url: uri})
      end
    end
    Req.default_options(adapter: LocalHttp)
    SymphonyElixir.CLI.main([])
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

    env =
      SymphonyElixir.RuntimePaths.cleaned_system_env(%{
        "SYMPHONY_WORKFLOW_FILE" => Path.join(context.root, "WORKFLOW.md"),
        "SYMPHONY_ROOT_DIR" => context.root,
        "SYM_PROJECT_ROOT" => Path.join(context.root, "projects")
      })
      |> List.keystore("SYMPHONY_TEST_RUN_STAGE", 0, {"SYMPHONY_TEST_RUN_STAGE", context[:stage]})
      |> List.keystore("SYMPHONY_LINEAR_SECRET_ACCESS", 0, {"SYMPHONY_LINEAR_SECRET_ACCESS", nil})

    System.cmd(System.find_executable("elixir"), paths ++ ["-e", script], cd: context.root, env: env, stderr_to_stdout: true)
  end
end
