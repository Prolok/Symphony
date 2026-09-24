defmodule Mix.Tasks.Yolo.ReviewCheckouts do
  use Mix.Task
  @moduledoc "Inspect an explicit review checkout inventory; removal requires --apply."
  alias SymphonyElixir.{EnvFile, ProjectContext, RuntimePaths}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Yolo.ReviewCheckouts
  @shortdoc "Dry run or remove safe orphaned YOLO review checkouts"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, rest, invalid} = OptionParser.parse(args, strict: [project: :string, inventory: :string, apply: :boolean])

    result =
      with true <- rest == [] and invalid == [] and is_binary(opts[:project]) and is_binary(opts[:inventory]),
           {:ok, %{size: size}} when size <= 1_048_576 <- File.stat(opts[:inventory]),
           {:ok, bytes} <- File.read(opts[:inventory]),
           {:ok, inventory} <- Jason.decode(bytes),
           {:ok, env} <- EnvFile.read_root(RuntimePaths.workflow_dir()),
           {:ok, context} <- ProjectContext.load(opts[:project], RuntimePaths.workflow_file(), env),
           {:ok, _} <- Application.ensure_all_started(:req),
           {:ok, [context]} <- Client.resolve_relay_contexts([context]) do
        ProjectContext.with_context(context, fn -> ReviewCheckouts.sweep(inventory, opts[:apply] == true) end)
      else
        _ -> {:error, :review_checkout_inventory_invalid}
      end

    case result do
      {:ok, summary} -> Mix.shell().info(Jason.encode!(summary, pretty: true))
      {:error, reason} -> Mix.raise("Review checkout cleanup refused: #{inspect(reason)}")
    end
  end
end
