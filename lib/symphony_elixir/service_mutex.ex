defmodule SymphonyElixir.ServiceMutex do
  @moduledoc "Acquires the same per-user OS mutex for direct escript starts."

  @spec acquire() :: :ok | {:error, String.t()}
  def acquire do
    if System.get_env("SYMPHONY_SERVICE_OWNER_PID") == System.pid() do
      :ok
    else
      root = SymphonyElixir.Workflow.default_workflow_file_path() |> Path.dirname()
      python = System.find_executable("python3") || "python3"

      port =
        Port.open({:spawn_executable, String.to_charlist(python)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [Path.join(root, "scripts/service-lock.py"), "hold"]
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
end
