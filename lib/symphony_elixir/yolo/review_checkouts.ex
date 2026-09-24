defmodule SymphonyElixir.Yolo.ReviewCheckouts do
  @moduledoc "Operator inventory check for unjournaled, inactive review checkouts."
  alias SymphonyElixir.{Config, PathSafety, ProjectContext}
  alias SymphonyElixir.Yolo.OpenClaw.Journal
  alias SymphonyElixir.Yolo.{Store, Workspace}

  @spec sweep(map()) :: {:ok, map()} | {:error, term()}
  def sweep(inventory), do: sweep(inventory, false)

  @spec sweep(map(), boolean()) :: {:ok, map()} | {:error, term()}
  def sweep(%{"version" => 1, "checkouts" => entries}, apply?) when is_list(entries) and is_boolean(apply?) do
    with true <- is_binary(Config.yolo_agent_id()),
         :ok <- validate(entries),
         {:ok, root} <- PathSafety.canonicalize(Config.settings!().workspace.root) do
      Store.lock("review", fn -> sweep_locked(entries, apply?, root) end)
    else
      _ -> {:error, :review_checkout_inventory_invalid}
    end
  end

  def sweep(_, _), do: {:error, :review_checkout_inventory_invalid}

  defp validate(entries) do
    valid? =
      Enum.all?(entries, fn
        %{"path" => path, "sha" => sha} -> is_binary(path) and is_binary(sha) and String.match?(sha, ~r/\A[0-9a-f]{40}\z/)
        _ -> false
      end)

    paths = Enum.map(entries, & &1["path"])
    if valid? and length(paths) == length(Enum.uniq(paths)), do: :ok, else: {:error, :review_checkout_inventory_invalid}
  end

  defp sweep_locked(entries, apply?, root) do
    with {:ok, record} <- Store.read("review"),
         {:ok, journal} <- Journal.read("review"),
         {:ok, before_count} <- count(root) do
      results = Enum.map(entries, &inspect_entry(&1, record, journal, apply?, root))

      with {:ok, after_count} <- count(root) do
        {:ok,
         %{
           "mode" => if(apply?, do: "apply", else: "dry_run"),
           "before" => before_count,
           "after" => after_count,
           "removable" => Enum.count(results, &(&1["status"] in ["removable", "removed"])),
           "removed" => Enum.count(results, &(&1["status"] == "removed")),
           "entries" => results
         }}
      end
    end
  end

  defp inspect_entry(%{"path" => path, "sha" => sha}, record, journal, apply?, root) do
    id = Path.basename(path)
    workspace = %{path: path, sha: sha}

    status =
      with {:ok, _} <- Ecto.UUID.cast(id),
           true <- path == Path.join([root, "yolo", "review", id]),
           true <- inactive_attempt?(record["attempt"], id),
           true <- no_delivery?(record["deliveries"], id),
           true <- journal == nil or journal["id"] != id,
           {:error, :enoent} <- Journal.history("review", id),
           false <- File.exists?(Path.join([root, "yolo-runs", id])),
           :ok <- Workspace.remove_review(workspace, id, apply?) do
        if(apply?, do: "removed", else: "removable")
      else
        _ -> "protected"
      end

    %{"path" => path, "sha" => sha, "status" => status}
  end

  defp inactive_attempt?(nil, _id), do: true
  defp inactive_attempt?(%{"id" => other_id}, id) when is_binary(other_id), do: other_id != id
  defp inactive_attempt?(_, _), do: false

  defp no_delivery?(nil, _id), do: true

  defp no_delivery?(deliveries, id) when is_map(deliveries) do
    Enum.all?(Map.values(deliveries), fn
      %{"run_id" => other_id} when is_binary(other_id) -> other_id != id
      _ -> false
    end)
  end

  defp no_delivery?(_, _), do: false

  defp count(root) do
    context = ProjectContext.current()

    case System.cmd("git", ["worktree", "list", "--porcelain"], cd: context.root, stderr_to_stdout: true, env: Config.without_linear_secret([])) do
      {listing, 0} ->
        prefix = Path.join([root, "yolo", "review"]) <> "/"
        {:ok, listing |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "worktree " <> prefix))}

      _ ->
        {:error, :review_checkout_listing_unavailable}
    end
  end
end
