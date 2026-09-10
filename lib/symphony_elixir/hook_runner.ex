defmodule SymphonyElixir.HookRunner do
  @moduledoc false

  require Logger

  @type env :: %{optional(String.t()) => String.t() | nil} | [{String.t(), String.t() | nil}]
  @type option ::
          {:env, env()}
          | {:timeout_ms, pos_integer()}
          | {:log_context, %{optional(atom()) => term()}}

  @spec run_local(String.t(), Path.t(), String.t(), [option()]) :: :ok | {:error, term()}
  def run_local(command, cwd, hook_name, opts \\ [])
      when is_binary(command) and is_binary(cwd) and is_binary(hook_name) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)

    env =
      opts
      |> Keyword.get(:env, %{})
      |> Map.new()
      |> Map.put("SYMPHONY_LINEAR_AUTH_MODE", SymphonyElixir.Config.settings!().tracker.auth_mode)

    log_context = Keyword.get(opts, :log_context, %{})
    formatted_log_context = format_log_context(log_context)

    Logger.info("Running workspace hook hook=#{hook_name}#{formatted_log_context}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: cwd,
          env: SymphonyElixir.Config.without_linear_secret(env),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_command_result(cmd_result, hook_name, formatted_log_context)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name}#{formatted_log_context} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_command_result({_output, 0}, _hook_name, _formatted_log_context), do: :ok

  defp handle_command_result({output, status}, hook_name, formatted_log_context) do
    sanitized_output = sanitize_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name}#{formatted_log_context} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp format_log_context(log_context) when map_size(log_context) == 0, do: ""

  defp format_log_context(log_context) when is_map(log_context) do
    log_context
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
    |> Enum.map_join("", fn {key, value} -> " #{key}=#{value}" end)
  end
end
