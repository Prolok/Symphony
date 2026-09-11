defmodule SymphonyElixir.DurableStateTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.DurableState

  test "atomic records reject malformed, missing and unwriteable destinations" do
    root = Path.join([File.cwd!(), "_build", "state-#{System.unique_integer([:positive])}"])
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "record.json")
    assert {:error, :enoent} = DurableState.read(path)
    assert :ok = DurableState.write(path, %{"generation" => 1})
    assert {:ok, %{"generation" => 1}} = DurableState.read(path)
    File.write!(path, "[]")
    assert {:error, :runtime_state_corrupt} = DurableState.read(path)
    assert {:error, :runtime_state_persist_failed} = DurableState.write(Path.join(path, "child"), %{})
    assert {:error, :runtime_state_persist_failed} = DurableState.write(Path.join(root, String.duplicate("x", 250)), %{})
    assert [] = Path.wildcard(Path.join(root, "*.tmp"))
  end
end
