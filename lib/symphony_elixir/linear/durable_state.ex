defmodule SymphonyElixir.Linear.DurableState do
  @moduledoc "Atomic, synchronously persisted non-secret runtime records."

  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(bytes) do
      {:ok, value}
    else
      {:error, :enoent} -> {:error, :enoent}
      _ -> {:error, :runtime_state_corrupt}
    end
  end

  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(path, value) do
    directory = Path.dirname(path)
    temporary = path <> "." <> Ecto.UUID.generate() <> ".tmp"

    try do
      with :ok <- mkdir(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- write_file(temporary, Jason.encode!(value)),
           :ok <- File.rename(temporary, path),
           :ok <- sync_directory(directory) do
        :ok
      else
        _ -> {:error, :runtime_state_persist_failed}
      end
    after
      File.rm(temporary)
    end
  end

  defp mkdir(directory) do
    if File.dir?(directory) do
      :ok
    else
      parent = Path.dirname(directory)
      with :ok <- mkdir(parent), result when result in [:ok, {:error, :eexist}] <- File.mkdir(directory), do: sync_directory(parent)
    end
  end

  defp sync_directory(directory) do
    with {:ok, descriptor} <- :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      result = :file.sync(descriptor)
      closed = :file.close(descriptor)
      if result == :ok, do: closed, else: result
    end
  end

  defp write_file(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive, :sync]) do
      {:ok, io} ->
        result = File.chmod(path, 0o600)
        written = IO.binwrite(io, bytes)
        closed = File.close(io)
        if result == :ok and written == :ok and closed == :ok, do: :ok, else: {:error, :write_failed}

      error ->
        error
    end
  end
end
