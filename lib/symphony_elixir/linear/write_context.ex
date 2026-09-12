defmodule SymphonyElixir.Linear.WriteContext do
  @moduledoc """
  Runtime-owned attribution for tracker and tool writes, independent of model text.
  """

  @key {__MODULE__, :context}

  @spec current() :: map()
  def current do
    %{"run_id" => System.get_env("SYMPHONY_RUN_ID"), "phase" => System.get_env("SYMPHONY_PHASE"), "issue_id" => System.get_env("SYMPHONY_ISSUE_ID")}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(Process.get(@key, %{}))
  end

  @spec with_context(map(), (-> result)) :: result when result: term()
  def with_context(context, callback) do
    previous = Process.get(@key)

    normalized =
      context
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(~w(issue_id issue_identifier phase run_id session_id thread_id turn_id tool_call_id worker_host workspace_path))
      |> Map.reject(fn {_key, value} -> not (is_binary(value) or is_number(value)) end)

    Process.put(@key, Map.merge(current(), normalized))

    try do
      callback.()
    after
      if is_nil(previous), do: Process.delete(@key), else: Process.put(@key, previous)
    end
  end
end
