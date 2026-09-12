defmodule SymphonyElixir.Linear.LocalState do
  @moduledoc "Detect state that needs an explicit one-time handoff before using the constant installation identity."

  alias SymphonyElixir.Linear.DurableState

  @spec validate(map()) :: :ok | {:error, term()}
  def validate(binding) do
    root = binding["state_root"]

    with :ok <- validate_codex(Path.join(root, "codex")) do
      validate_journals(Path.join(root, "comments"), binding)
    end
  end

  defp validate_codex(codex_root) do
    case File.ls(codex_root) do
      {:ok, names} ->
        old = Enum.filter(names, &(&1 != "symphony" and File.dir?(Path.join(codex_root, &1))))
        if old == [], do: :ok, else: {:error, {:local_state_requires_handoff, codex_root, handoff_message()}}

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:local_state_unavailable, codex_root, reason}}
    end
  end

  defp validate_journals(directory, binding) do
    case File.ls(directory) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".intent.json"))
        |> Enum.reduce_while(:ok, &validate_journal(Path.join(directory, &1), binding, &2))

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:local_state_unavailable, directory, reason}}
    end
  end

  defp validate_journal(path, binding, :ok) do
    case DurableState.read(path) do
      {:ok, record} ->
        if record["installation_id"] == "symphony" and record["workspace_id"] == binding["workspace_id"],
          do: {:cont, :ok},
          else: {:halt, {:error, {:local_state_requires_handoff, path, handoff_message()}}}

      {:error, reason} ->
        {:halt, {:error, {:local_state_unavailable, path, reason}}}
    end
  end

  @spec handoff_message() :: String.t()
  def handoff_message do
    "Aktive Arbeit beenden; .symphony/state sichern, Sessions/Journale gezielt auf die Kennung symphony übernehmen und den alten Stand aufbewahren. Siehe docs/linear-app.md, Einmalige Betreiberübergabe."
  end
end
