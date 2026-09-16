defmodule SymphonyElixir.ServiceMutex do
  @moduledoc "Acquires the same per-user OS mutex for direct escript starts."

  alias SymphonyElixir.Linear.ScopeBinding

  @spec acquire(String.t() | nil) :: :ok | {:error, String.t()}
  def acquire(name \\ nil) do
    if System.get_env("SYMPHONY_SERVICE_OWNER_PID") == System.pid() and
         (name == nil or System.get_env("SYMPHONY_SERVICE_LOCK_MODE") == name) do
      :ok
    else
      root = SymphonyElixir.Workflow.default_workflow_file_path() |> Path.dirname()
      python = System.find_executable("python3") || "python3"
      args = if name, do: ["--test-instance", name], else: []

      port =
        Port.open({:spawn_executable, String.to_charlist(python)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [Path.join(root, "scripts/service-lock.py"), "hold"] ++ args
        ])

      receive do
        {^port, {:data, "locked\n"}} ->
          Process.put({__MODULE__, :port}, port)
          :ok

        {^port, {:data, message}} ->
          Port.close(port)
          {:error, String.trim(message)}

        {^port, {:exit_status, _}} ->
          {:error, "Symphony-Dienstlock konnte nicht erworben werden"}
      after
        5_000 ->
          Port.close(port)
          {:error, "Symphony-Dienstlock antwortet nicht"}
      end
    end
  end

  @spec reserve_projects([SymphonyElixir.ProjectContext.t()]) :: :ok | {:error, String.t()}
  def reserve_projects(contexts) do
    {:ok, _} = Application.ensure_all_started(:req)

    contexts
    |> Enum.reduce_while({:ok, []}, fn context, {:ok, scopes} ->
      case ScopeBinding.resolve(context) do
        {:ok, scope} -> {:cont, {:ok, [scope | scopes]}}
        {:error, _} -> {:halt, {:error, "Projekt-/Teambindung konnte nicht frisch und vollständig verifiziert werden"}}
      end
    end)
    |> case do
      {:ok, scopes} -> reserve_scopes(scopes)
      error -> error
    end
  end

  defp reserve_scopes(scopes) do
    root = SymphonyElixir.RuntimePaths.workflow_dir()

    port =
      Port.open({:spawn_executable, System.find_executable("python3") || "python3"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [Path.join(root, "scripts/service-scopes.py")]
      ])

    Port.command(port, Jason.encode!(scopes) <> "\n")

    receive do
      {^port, {:data, "locked\n"}} ->
        Process.put({__MODULE__, :scopes}, port)
        :ok

      {^port, {:data, _message}} ->
        if Port.info(port), do: Port.close(port)
        {:error, "Projektbereich wird bereits ausgeführt oder kann nicht reserviert werden"}

      {^port, {:exit_status, _}} ->
        {:error, "Projektreservierung fehlgeschlagen"}
    after
      5_000 ->
        if Port.info(port), do: Port.close(port)
        {:error, "Projektreservierung antwortet nicht"}
    end
  end
end
