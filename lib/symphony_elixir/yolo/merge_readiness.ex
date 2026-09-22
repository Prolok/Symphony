defmodule SymphonyElixir.Yolo.MergeReadiness do
  @moduledoc "Prevent dirty merge workspaces from entering or completing monotone acceptance."
  alias SymphonyElixir.{Config, Workspace}

  @spec check(map()) :: :ok | {:error, term()}
  def check(issue) do
    hosts =
      case Config.settings!().worker.ssh_hosts do
        [] -> [nil]
        hosts -> hosts
      end

    Enum.reduce_while(hosts, :ok, fn host, _ ->
      case Workspace.git_status_snapshot_for_existing_issue_workspace(issue, host) do
        {:ok, status} when status in ["", :missing] -> {:cont, :ok}
        {:ok, _} -> {:halt, {:error, :merge_workspace_requires_test}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
