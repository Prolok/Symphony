defmodule SymphonyElixir.TestInstanceGuard do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :verify, 1_000)
    owner = Application.fetch_env!(:symphony_elixir, :test_instance_owner)
    {:ok, %{instance: SymphonyElixir.Config.test_instance(), owner: owner}}
  end

  @impl true
  def handle_info(:verify, %{instance: instance, owner: owner} = state) do
    root = instance["source"]["checkout"]
    python = System.find_executable("python3") || "python3"
    result = System.cmd(python, [Path.join(root, "scripts/test-instance.py"), "preflight", instance["name"], root], stderr_to_stdout: true)

    case result do
      {json, 0} ->
        if Jason.decode(json) == {:ok, instance}, do: Process.send_after(self(), :verify, 1_000), else: send(owner, :test_instance_invalid)

      _ ->
        send(owner, :test_instance_invalid)
    end

    {:noreply, state}
  end
end
