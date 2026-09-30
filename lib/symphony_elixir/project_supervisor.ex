defmodule SymphonyElixir.ProjectSupervisor do
  @moduledoc false
  use Supervisor

  alias SymphonyElixir.{Orchestrator, ProjectPoller, Projects}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    contexts = Keyword.fetch!(opts, :contexts)

    children =
      [
        {Registry, keys: :unique, name: SymphonyElixir.ProjectRegistry},
        {ProjectPoller, contexts: contexts}
      ] ++
        Enum.map(contexts, fn context ->
          Supervisor.child_spec({Orchestrator, name: Projects.server(context), context: context, external_poll: true}, id: context.id)
        end) ++ [{Projects, contexts: contexts}]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
