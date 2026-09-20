defmodule SymphonyElixir.Yolo.OpenClaw.Checkout do
  @moduledoc "Measured helper working directory, checked again against the frozen Git checkout."
  alias SymphonyElixir.{Config, PathSafety}

  @spec verify(map(), term()) :: {:ok, map()} | {:error, atom()}
  def verify(order, proof) when is_map(proof) do
    expected = Map.take(order, ~w(id project_id session_id workspace sha))

    with true <- Enum.all?(expected, fn {key, value} -> is_binary(value) and proof[key] == value end),
         true <- map_size(expected) == 5 and proof["clean"] == true,
         {:ok, root} <- PathSafety.canonicalize(order["workspace"]),
         true <- File.dir?(root),
         true <- proof["cwd"] == root and proof["git_root"] == root,
         {top, 0} <- git(root, ["rev-parse", "--show-toplevel"]),
         {:ok, ^root} <- PathSafety.canonicalize(String.trim(top)),
         {sha, 0} <- git(root, ["rev-parse", "HEAD"]),
         true <- String.trim(sha) == order["sha"],
         {"", 0} <- git(root, ["status", "--porcelain", "--untracked-files=all"]) do
      {:ok, Map.merge(expected, %{"cwd" => root, "git_root" => root, "clean" => true, "payload_sha256" => order["payload_sha256"]})}
    else
      _ -> {:error, :openclaw_checkout_unverified}
    end
  rescue
    _ -> {:error, :openclaw_checkout_unverified}
  end

  def verify(_, _), do: {:error, :openclaw_checkout_unverified}

  defp git(root, args) do
    env = Enum.map(System.get_env(), fn {name, _} -> {name, nil} end) |> Enum.filter(fn {name, _} -> String.starts_with?(name, "GIT_") end)
    System.cmd("git", args, cd: root, stderr_to_stdout: true, env: Config.without_linear_secret(env))
  end
end
