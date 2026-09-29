defmodule SymphonyElixir.AdvisoryConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.{AdvisoryAgents, AppAuth, Client, TrustedAgents}
  alias SymphonyElixir.ProjectContext

  @agent "b57e9f80-53ce-4d96-9180-370f03d60d16"

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    on_exit(fn -> System.delete_env("LINEAR_TRUSTED_AGENT_IDS") end)
    :ok
  end

  test "optional project setting trims and deduplicates UUIDs without replacing existing configuration" do
    assert Config.settings!().tracker.advisory_agent_ids == []
    before = Config.settings!().tracker
    System.put_env("LINEAR_ADVISORY_AGENT_IDS", " #{@agent}, #{@agent}, ")
    after_config = Config.settings!().tracker
    assert after_config.advisory_agent_ids == [@agent]
    assert %{after_config | advisory_agent_ids: []} == before
    assert {:ok, config} = Schema.parse(%{"tracker" => %{"advisory_agent_ids" => []}})
    assert config.tracker.advisory_agent_ids == []
    assert {:ok, config} = Schema.parse(%{"tracker" => %{"advisory_agent_ids" => "$LINEAR_ADVISORY_AGENT_IDS"}})
    assert config.tracker.advisory_agent_ids == [@agent]

    for invalid <- ["display name", ["invalid"], 42, List.duplicate(42, 2)] do
      assert {:error, _} = Schema.parse(%{"tracker" => %{"advisory_agent_ids" => invalid}})
    end

    tracker = %{after_config | app: Map.put(after_config.app, "user_id", @agent)}
    assert {:error, :linear_advisory_agent_is_coding_app} = AppAuth.validate(tracker)
  end

  test "workspace verification rejects humans, foreign apps, partial responses and a coding-app alias" do
    System.put_env("LINEAR_ADVISORY_AGENT_IDS", @agent)
    workspace = Config.settings!().tracker.app["workspace_id"]
    agent = %{"id" => @agent, "app" => true, "active" => true, "organization" => %{"id" => workspace}}

    for {candidate, expected} <- [
          {agent, :ok},
          {Map.put(agent, "app", false), :error},
          {put_in(agent, ["organization", "id"], "foreign"), :error},
          {Map.put(agent, "active", false), :error},
          {Map.put(agent, "id", "another"), :error}
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        assert payload["query"] =~ "SymphonyAdvisoryAgents"
        assert payload["variables"].filter == %{"id" => %{"in" => [@agent]}}
        response([candidate])
      end)

      if expected == :ok, do: assert(AdvisoryAgents.verify() == :ok), else: assert(match?({:error, _}, AdvisoryAgents.verify()))
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> response([]) end)
    assert {:error, _} = AdvisoryAgents.verify()
    partial = {:ok, %{status: 200, body: %{"data" => %{"users" => nil}, "errors" => [%{"message" => "partial"}]}}}
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> partial end)
    assert {:error, _} = AdvisoryAgents.verify()
  end

  test "trusted apps are optional, verified in the same workspace, and never include Symphony itself" do
    assert Config.settings!().tracker.trusted_agent_ids == []
    assert Config.settings!().tracker.agent_hop_limit == 10
    System.put_env("LINEAR_TRUSTED_AGENT_IDS", " #{@agent}, #{@agent}, ")
    tracker = Config.settings!().tracker
    assert tracker.trusted_agent_ids == [@agent]
    assert {:ok, config} = Schema.parse(%{"tracker" => %{"trusted_agent_ids" => [], "agent_hop_limit" => 3}})
    assert config.tracker.agent_hop_limit == 3
    assert {:error, _} = Schema.parse(%{"tracker" => %{"trusted_agent_ids" => ["not-a-uuid"]}})
    assert {:error, _} = Schema.parse(%{"tracker" => %{"trusted_agent_ids" => 42}})
    assert {:error, _} = Schema.parse(%{"tracker" => %{"agent_hop_limit" => 0}})
    assert {:error, :linear_trusted_agent_is_coding_app} = AppAuth.validate(%{tracker | app: Map.put(tracker.app, "user_id", @agent)})

    workspace = tracker.app["workspace_id"]
    agent = %{"id" => @agent, "app" => true, "active" => true, "name" => "Pai", "organization" => %{"id" => workspace}}

    for {candidate, valid?} <- [{agent, true}, {Map.put(agent, "app", false), false}, {Map.put(agent, "active", false), false}, {put_in(agent, ["organization", "id"], "foreign"), false}] do
      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        assert payload["query"] =~ "SymphonyTrustedAgents"
        response([candidate])
      end)

      if valid?, do: assert(TrustedAgents.verify() == :ok), else: assert(match?({:error, _}, TrustedAgents.verify()))
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:error, :offline} end)
    assert {:error, {:linear_api_request, :linear_app_request_unavailable}} = TrustedAgents.verify()
  end

  test "projects sharing a workspace reject different trusted lists before relay resolution" do
    settings = Config.settings!()
    first = %ProjectContext{settings: settings}
    other = %ProjectContext{settings: %{settings | tracker: %{settings.tracker | trusted_agent_ids: [@agent]}}}
    assert {:error, :linear_trusted_agents_workspace_mismatch} = Client.resolve_relay_contexts([first, other])
    assert {:ok, []} = Client.resolve_relay_contexts([])
  end

  test "relay keeps the verified trusted binding when it publishes refreshed project contexts" do
    context = %ProjectContext{id: "project", settings: Config.settings!()}
    verified = %{context | trusted_binding: "verified-binding"}

    assert [%ProjectContext{trusted_binding: "verified-binding"}] =
             SymphonyElixir.Relay.resolved_contexts(%{contexts: [verified]}, [context])
  end

  test "verified project identity survives worker export and requires restart for configuration changes" do
    root = Path.dirname(Workflow.workflow_file_path())
    env_path = Path.join(root, ".symphony/.env")
    File.mkdir_p!(Path.dirname(env_path))
    File.write!(env_path, "LINEAR_ASSIGNEE=dev@example.com\nLINEAR_ADVISORY_AGENT_IDS=#{@agent}\nPUBLIC_EXTRA=preserved\n")
    assert {:ok, original} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    workspace = original.settings.tracker.app["workspace_id"]
    agent = %{"id" => @agent, "app" => true, "active" => true, "organization" => %{"id" => workspace}}
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> response([agent]) end)
    assert {:ok, verified} = AdvisoryAgents.resolve({:ok, original})
    assert AdvisoryAgents.verified?(verified)
    refute AdvisoryAgents.verified?(put_in(verified.settings.tracker.app["workspace_id"], "other"))
    System.put_env("SYMPHONY_WORKFLOW_FILE", verified.workflow_path)

    ProjectContext.with_context(verified, fn ->
      hash = Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"]
      encoded = ProjectContext.runtime_env()["SYMPHONY_PROJECT_CONTEXT"]
      ProjectContext.bind(nil)
      assert :ok = ProjectContext.restore(encoded, Path.join(root, ".symphony"))
      assert AdvisoryAgents.verified?(ProjectContext.current())
      assert Config.settings!().tracker.advisory_agent_ids == [@agent]
      assert Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"] == hash
      assert ProjectContext.env("PUBLIC_EXTRA") == "preserved"
    end)

    for value <- ["invalid", "", "847f6c00-eb63-4738-bc5b-c9f0f652bf96"] do
      File.write!(env_path, "LINEAR_ASSIGNEE=dev@example.com\nLINEAR_ADVISORY_AGENT_IDS=#{value}\n")
      assert ProjectContext.refresh(verified) == verified
    end

    File.write!(env_path, "LINEAR_ASSIGNEE=dev@example.com\nLINEAR_ADVISORY_AGENT_IDS=#{@agent}\nPUBLIC_EXTRA=new\n")
    refreshed = ProjectContext.refresh(verified)
    assert refreshed.env["PUBLIC_EXTRA"] == "new"
    assert AdvisoryAgents.verified?(refreshed)

    changed = put_in(verified.settings.tracker.advisory_agent_ids, [])
    hash = fn -> Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"] end
    refute ProjectContext.with_context(changed, hash) == ProjectContext.with_context(verified, hash)
  end

  defp response(nodes), do: {:ok, %{status: 200, body: %{"data" => %{"users" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}}}}}
end
