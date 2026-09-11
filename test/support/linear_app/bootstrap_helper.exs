alias SymphonyElixir.{CLI, EnvFile, Workflow}
alias SymphonyElixir.Codex.{MCPServer, ScriptSupport}

[mode, root, workflow] = System.argv()

System.get_env()
|> Map.keys()
|> Enum.filter(&(String.starts_with?(&1, "SYMPHONY_") or String.starts_with?(&1, "LINEAR_") or &1 in ~w(SECRET_SELECTOR SYNTHETIC_SECRET_DEFAULT SYNTHETIC_SECRET_LOCAL)))
|> Enum.each(&System.delete_env/1)

File.cd!(root)
true = is_nil(Process.whereis(SymphonyElixir.WorkflowStore))
:ok = Workflow.set_workflow_file_path(Path.join(root, "WORKFLOW.md"))

case mode do
  "cli" ->
    deps = %{
      file_regular?: &File.regular?/1,
      load_env_files: &EnvFile.load_runtime/1,
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      validate_startup_requirements: fn -> :ok end,
      ensure_all_started: fn -> {:ok, []} end
    }

    :ok = CLI.run(workflow, root, deps)

  "mcp" ->
    System.put_env("SYMPHONY_SOURCE_REPO", root)
    System.put_env("SYMPHONY_WORKFLOW_FILE", workflow)
    :ok = MCPServer.bootstrap(logger_configurer: fn -> :ok end)

  "script" ->
    {:ok, _} = ScriptSupport.workspace_root(workflow, root)
end

true = Workflow.workflow_file_path() == workflow
exported = Enum.any?(~w(SYNTHETIC_SECRET_DEFAULT SYNTHETIC_SECRET_LOCAL), &(System.get_env(&1) != nil))
{:ok, "synthetic-local-value"} = EnvFile.linear_secret("SYNTHETIC_SECRET_LOCAL")
IO.puts(Jason.encode!(%{exported: exported, selected_workflow: true}))
