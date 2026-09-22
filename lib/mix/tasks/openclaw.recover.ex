defmodule Mix.Tasks.Openclaw.Recover do
  use Mix.Task
  @moduledoc "Import a reviewed operator evidence package; default to a non-mutating dry run."
  alias SymphonyElixir.{EnvFile, ProjectContext, RuntimePaths}
  alias SymphonyElixir.Yolo.OpenClaw
  alias SymphonyElixir.Yolo.OpenClaw.Recovery
  @shortdoc "Operator-only dry run / apply of an OpenClaw recovery evidence package"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    {opts, rest, invalid} = OptionParser.parse(args, strict: [project: :string, evidence: :string, apply: :boolean])

    result =
      with true <- rest == [] and invalid == [] and is_binary(opts[:project]) and is_binary(opts[:evidence]),
           {:ok, %{size: size}} when size <= 32_768 <- File.stat(opts[:evidence]),
           {:ok, bytes} <- File.read(opts[:evidence]),
           {:ok, evidence} when is_map(evidence) <- Jason.decode(bytes),
           {:ok, sources} <- sources(evidence, Path.dirname(Path.expand(opts[:evidence]))),
           {:ok, env} <- EnvFile.read_root(RuntimePaths.workflow_dir()),
           {:ok, context} <- ProjectContext.load(opts[:project], RuntimePaths.workflow_file(), env) do
        ProjectContext.with_context(context, fn -> Recovery.resolve(Map.drop(evidence, ~w(source_file execution_source_file)), opts[:apply] == true, sources: sources) end)
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
    Enum.reduce_while(["source", "execution_source"], {:ok, %{}}, fn key, {:ok, sources} ->
      with path when is_binary(path) <- evidence[key <> "_file"],
           {:ok, %{size: size}} <- File.stat(Path.expand(path, directory)),
           true <- evidence["version"] != 2 or size <= 1_048_576,
           {:ok, bytes} <- File.read(Path.expand(path, directory)),
           true <- evidence["version"] != 2 or byte_size(bytes) <= 1_048_576,
           true <- OpenClaw.digest(bytes) == evidence[key <> "_sha256"] do
        {:cont, {:ok, Map.put(sources, key, bytes)}}
      else
        _ -> {:halt, {:error, :openclaw_recovery_source_invalid}}
      end
    end)
  end
end
