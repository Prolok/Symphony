defmodule SymphonyElixir.EscalationConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.{CommentVersion, TrustedAgents}
  alias SymphonyElixir.ProjectContext

  @agent "b57e9f80-53ce-4d96-9180-370f03d60d16"
  @other "847f6c00-eb63-4738-bc5b-c9f0f652bf96"

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    :ok
  end

  test "escalation target is optional, normalized and supports explicit workflow overrides" do
    assert Config.escalation_trusted_agent_id() == nil
    System.put_env("LINEAR_TRUSTED_AGENT_IDS", @agent)

    for blank <- ["", "  "] do
      System.put_env("LINEAR_ESCALATION_TRUSTED_AGENT_ID", blank)
      assert Config.escalation_trusted_agent_id() == nil
    end

    System.put_env("LINEAR_ESCALATION_TRUSTED_AGENT_ID", " #{String.upcase(@agent)} ")
    assert Config.escalation_trusted_agent_id() == @agent
    assert :ok = Config.validate!()
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"escalation_trusted_agent_id" => "$LINEAR_ESCALATION_TRUSTED_AGENT_ID"}})
    assert settings.tracker.escalation_trusted_agent_id == @agent
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"escalation_trusted_agent_id" => nil}})
    assert settings.tracker.escalation_trusted_agent_id == @agent
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"escalation_trusted_agent_id" => ""}})
    assert settings.tracker.escalation_trusted_agent_id == nil
    assert {:ok, settings} = Schema.parse(%{"tracker" => %{"escalation_trusted_agent_id" => @other}})
    assert settings.tracker.escalation_trusted_agent_id == @other

    for invalid <- ["Pai", "#{@agent},#{@other}", [@agent], 42] do
      assert {:error, {:invalid_workflow_config, errors}} = Schema.parse(%{"tracker" => %{"escalation_trusted_agent_id" => invalid}})
      assert inspect(errors) =~ "escalation_trusted_agent_id"
    end

    System.put_env("LINEAR_ESCALATION_TRUSTED_AGENT_ID", @other)
    assert {:error, :linear_escalation_trusted_agent_not_trusted} = Config.validate!()
  end

  test "verified opt-in survives worker export and configuration changes require restart" do
    root = Path.dirname(Workflow.workflow_file_path())
    env_path = Path.join(root, ".symphony/.env")
    File.mkdir_p!(Path.dirname(env_path))
    env = "LINEAR_ASSIGNEE=dev@example.com\nLINEAR_TRUSTED_AGENT_IDS=#{@agent},#{@other}\nPUBLIC_EXTRA=before\n"
    File.write!(env_path, env)
    # Public local project overrides take precedence over the base env file.
    local_path = Path.join(root, ".symphony/.env.local")
    File.write!(local_path, "LINEAR_ESCALATION_TRUSTED_AGENT_ID=#{@agent}\n")
    assert {:ok, original} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    tracker = original.settings.tracker
    verified = %{original | trusted_binding: CommentVersion.digest([tracker.app, tracker.trusted_agent_ids])}
    assert TrustedAgents.verified?(verified)
    System.put_env("SYMPHONY_WORKFLOW_FILE", verified.workflow_path)

    ProjectContext.with_context(verified, fn ->
      hash = Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"]
      encoded = ProjectContext.runtime_env()["SYMPHONY_PROJECT_CONTEXT"]
      ProjectContext.bind(nil)
      assert :ok = ProjectContext.restore(encoded, Path.join(root, ".symphony"))
      assert TrustedAgents.ids() == Enum.sort([@agent, @other])
      assert Config.escalation_trusted_agent_id() == @agent
      assert Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"] == hash

      changed = put_in(ProjectContext.current().settings.tracker.escalation_trusted_agent_id, nil)
      refute ProjectContext.with_context(changed, fn -> Config.linear_runtime_env()["SYMPHONY_LINEAR_BINDING_HASH"] end) == hash
    end)

    for value <- ["invalid", "", @other, "e538a490-a80e-446a-bfec-e0c4a60b7b0e"] do
      File.write!(local_path, "LINEAR_ESCALATION_TRUSTED_AGENT_ID=#{value}\n")
      assert ProjectContext.refresh(verified) == verified
    end

    File.write!(local_path, "LINEAR_ESCALATION_TRUSTED_AGENT_ID=#{@agent}\nPUBLIC_EXTRA=after\n")
    refreshed = ProjectContext.refresh(verified)
    assert refreshed.env["PUBLIC_EXTRA"] == "after"
    assert TrustedAgents.verified?(refreshed)

    # The target is project-local while trusted identities remain workspace-wide.
    without_target = put_in(verified.settings.tracker.escalation_trusted_agent_id, nil)
    assert TrustedAgents.consistent?([verified, without_target])
    assert ProjectContext.with_context(without_target, &Config.escalation_trusted_agent_id/0) == nil
  end

  test "opt-in retains the startup verification of active foreign app identities" do
    root = Path.dirname(Workflow.workflow_file_path())
    File.mkdir_p!(Path.join(root, ".symphony"))
    File.write!(Path.join(root, ".symphony/.env"), "LINEAR_ASSIGNEE=dev@example.com\nLINEAR_TRUSTED_AGENT_IDS=#{@agent}\nLINEAR_ESCALATION_TRUSTED_AGENT_ID=#{@agent}\n")
    assert {:ok, context} = ProjectContext.load(root, Workflow.workflow_file_path(), %{})
    app = context.settings.tracker.app
    candidate = %{"id" => @agent, "app" => true, "active" => true, "organization" => %{"id" => app["workspace_id"]}}

    for {user, expected} <- [
          {candidate, :ok},
          {Map.put(candidate, "app", false), :error},
          {Map.put(candidate, "active", false), :error},
          {put_in(candidate, ["organization", "id"], "foreign"), :error}
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
        {:ok, %{status: 200, body: %{"data" => %{"users" => %{"nodes" => [user], "pageInfo" => %{"hasNextPage" => false}}}}}}
      end)

      result = TrustedAgents.resolve({:ok, context})

      if expected == :ok do
        assert match?({:ok, _}, result)
      else
        assert result == {:error, :linear_trusted_agents_invalid}
      end
    end

    own = put_in(context.settings.tracker.app["user_id"], @agent)
    assert {:error, :linear_trusted_agents_invalid} = TrustedAgents.resolve({:ok, own})
  end
end
