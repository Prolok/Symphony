defmodule Mix.Tasks.Openclaw.Recover do
  use Mix.Task
  @moduledoc "Import a reviewed operator evidence package; default to a non-mutating dry run."
  alias SymphonyElixir.{EnvFile, ProjectContext, RuntimePaths}
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Recovery
  @shortdoc "Operator-only dry run / apply of an OpenClaw rejection evidence package"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, rest, invalid} = OptionParser.parse(args, strict: [project: :string, evidence: :string, apply: :boolean])

    result =
      with true <- rest == [] and invalid == [] and is_binary(opts[:project]) and is_binary(opts[:evidence]),
           {:ok, %{size: size}} when size <= 32_768 <- File.stat(opts[:evidence]),
           {:ok, bytes} <- File.read(opts[:evidence]),
           {:ok, evidence} when is_map(evidence) <- Jason.decode(bytes),
           :ok <- sources(evidence, Path.dirname(Path.expand(opts[:evidence]))),
           {:ok, env} <- EnvFile.read_root(RuntimePaths.workflow_dir()),
           {:ok, context} <- ProjectContext.load(opts[:project], RuntimePaths.workflow_file(), env) do
        ProjectContext.with_context(context, fn -> Recovery.resolve(Map.drop(evidence, ~w(source_file execution_source_file)), opts[:apply] == true) end)
      else
        _ -> {:error, :openclaw_recovery_input_invalid}
      end

    case result do
      {:ok, order} ->
        Mix.shell().info(Jason.encode!(%{mode: if(opts[:apply], do: "applied", else: "dry_run"), id: order["id"], group: order["group"], state: order["state"], recovery: order["recovery"]}))

      {:error, reason} ->
        Mix.raise("OpenClaw recovery refused: #{reason}")
    end
  end

  defp sources(evidence, directory) do
    Enum.reduce_while(["source", "execution_source"], :ok, fn key, _ ->
      with path when is_binary(path) <- evidence[key <> "_file"],
           {:ok, bytes} <- File.read(Path.expand(path, directory)),
           true <- OpenClaw.digest(bytes) == evidence[key <> "_sha256"] do
        {:cont, :ok}
      else
        _ -> {:halt, {:error, :openclaw_recovery_source_invalid}}
      end
    end)
  end
end
