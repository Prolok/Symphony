defmodule SymphonyElixir.Yolo.OpenClaw.Adapter do
  @moduledoc "Replaceable OpenClaw boundary. Submission is never retried by an adapter."
  @callback preflight(String.t(), keyword()) :: :ok | {:error, term()}
  @callback submit(map(), String.t(), keyword()) :: {:ok, map()} | {:rejected, map()} | {:error, term()}
  @callback status(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback cancel(map(), keyword()) :: :ok | {:error, term()}
end
