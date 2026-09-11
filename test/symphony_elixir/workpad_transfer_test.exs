defmodule SymphonyElixir.WorkpadTransferTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.WorkpadTransfer
  alias SymphonyElixir.Workpad

  setup do
    root = Path.join([File.cwd!(), "_build", "transfer-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    source = %{"id" => "old", "body" => "## Symphony Workpad\n\n### Plan\n\n- [x] Bestehender Stand\n", "user" => %{"id" => "human"}}
    Process.put(:comments, [source])
    Process.put(:writer, "human")
    {:ok, binding: %{"workspace_id" => "workspace", "state_root" => root, "user_id" => "app"}, source: source}
  end

  test "migration preserves history, verifies edits and reverses with the latest state", %{binding: binding, source: source} do
    assert {:error, :workpad_migration_required} = WorkpadTransfer.ready(binding, "issue", comments())
    assert {:ok, prepared} = start(binding)
    assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, "issue", comments())
    assert {:ok, %{"phase" => "retired"}} = WorkpadTransfer.retire(binding, "issue", &api/2)
    assert [retired] = comments()
    assert retired["id"] == source["id"]
    assert retired["user"] == source["user"]
    assert retired["body"] =~ "- [x] Bestehender Stand"
    refute Workpad.comment_matches?(retired["body"])
    Process.put(:writer, "app")
    assert {:ok, active} = WorkpadTransfer.activate(binding, "issue", &api/2)
    assert active["active_id"] == prepared["target_id"]
    assert :ok = WorkpadTransfer.ready(binding, "issue", comments())
    assert {:ok, workpad} = Workpad.find_comment(comments())
    assert workpad.body =~ "Vorgänger: old"
    api(:update, %{"id" => active["active_id"], "body" => workpad.body <> "\nNeuer Stand"})
    # A repeated activation must never restore an old body over later work.
    assert {:ok, _} = WorkpadTransfer.activate(binding, "issue", &api/2)
    assert {:ok, latest} = Workpad.find_comment(comments())
    assert latest.body =~ "Neuer Stand"
    assert {:ok, _} = WorkpadTransfer.begin(binding, "issue", "human", backup(), &api/2)
    assert {:ok, _} = WorkpadTransfer.retire(binding, "issue", &api/2)
    Process.put(:writer, "human")
    assert {:ok, _} = WorkpadTransfer.activate(binding, "issue", &api/2)
    assert {:ok, final} = Workpad.find_comment(comments())
    assert final.body =~ "Neuer Stand"
    assert :ok = WorkpadTransfer.ready(Map.put(binding, "user_id", "human"), "issue", comments())
    assert length(Path.wildcard(Path.join([binding["state_root"], "transfers", "history", "*.json"]))) == 2
  end

  test "lost responses at every remote transition keep the issue blocked and resume idempotently", %{binding: binding} do
    assert {:ok, prepared} = start(binding)
    assert {:ok, ^prepared} = start(binding)
    Process.put(:fail_after_write, true)
    assert {:error, :lost_response} = WorkpadTransfer.retire(binding, "issue", &api/2)
    assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, "issue", comments())
    assert {:ok, _} = WorkpadTransfer.retire(binding, "issue", &api/2)
    Process.put(:writer, "app")
    Process.put(:fail_after_write, true)
    assert {:error, :lost_response} = WorkpadTransfer.activate(binding, "issue", &api/2)
    assert length(comments()) == 2
    assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, "issue", comments())
    Process.put(:fail_after_write, true)
    assert {:error, :lost_response} = WorkpadTransfer.activate(binding, "issue", &api/2)
    assert {:ok, _} = WorkpadTransfer.activate(binding, "issue", &api/2)
    assert length(comments()) == 2
  end

  test "wrong writer, missing or multiple markers, changed source and incomplete backup fail closed", %{binding: binding, source: source} do
    assert {:error, :workpad_transfer_precondition_failed} = WorkpadTransfer.begin(binding, "issue", "app", %{}, &api/2)
    Process.put(:comments, [])
    assert {:error, :workpad_comment_not_found} = start(binding)
    assert {:error, :workpad_comment_not_found} = WorkpadTransfer.ready(binding, "issue", [])
    Process.put(:comments, [source, %{source | "id" => "duplicate"}])
    assert {:error, {:multiple_workpad_comments, 2}} = start(binding)
    Process.put(:comments, [source])
    assert {:ok, _} = start(binding)
    Process.put(:writer, "app")
    assert {:error, :workpad_wrong_writer} = WorkpadTransfer.retire(binding, "issue", &api/2)
    Process.put(:writer, "human")
    api(:update, %{"id" => "old", "body" => source["body"] <> "changed"})
    assert {:error, :workpad_source_changed} = WorkpadTransfer.retire(binding, "issue", &api/2)
  end

  test "corrupt records, invalid transitions and read failures never release a transfer", %{binding: binding} do
    assert {:error, :enoent} = WorkpadTransfer.activate(binding, "absent", &api/2)
    assert {:ok, _} = start(binding)
    Process.put(:writer, "app")
    assert {:error, :workpad_transfer_verification_failed} = WorkpadTransfer.activate(binding, "issue", &api/2)
    Process.put(:writer, "human")
    assert {:error, :offline} = WorkpadTransfer.retire(binding, "issue", fn _, _ -> {:error, :offline} end)
    [path] = Path.wildcard(Path.join([binding["state_root"], "transfers", "*.json"]))
    File.write!(path, "invalid record")
    assert {:error, :runtime_state_corrupt} = start(binding)
    assert {:error, :runtime_state_corrupt} = WorkpadTransfer.ready(binding, "issue", comments())
  end

  test "changed active identity and failed post-edit verification keep the issue closed", %{binding: binding, source: source} do
    for mode <- [:wrong_body, :missing] do
      issue = Atom.to_string(mode)
      Process.put(:writer, "human")
      Process.put(:comments, [source])
      assert {:ok, _} = WorkpadTransfer.begin(binding, issue, "app", backup(), &api/2)
      assert {:ok, _} = WorkpadTransfer.retire(binding, issue, &api/2)
      Process.put(:writer, "app")
      Process.put(:reads, 0)

      tampered = fn action, input ->
        result = api(action, input)

        if action == :list do
          read = Process.get(:reads) + 1
          Process.put(:reads, read)
          if read == 2, do: tampered_comments(mode), else: result
        else
          result
        end
      end

      assert {:error, _} = WorkpadTransfer.activate(binding, issue, tampered)
      assert {:error, :workpad_transfer_incomplete} = WorkpadTransfer.ready(binding, issue, comments())
      assert {:ok, _} = WorkpadTransfer.activate(binding, issue, &api/2)
      assert {:error, :workpad_active_identity_changed} = WorkpadTransfer.ready(Map.put(binding, "user_id", "different"), issue, comments())
      assert {:error, :workpad_comment_not_found} = WorkpadTransfer.ready(binding, issue, [])
      Process.put(:writer, "human")
      assert {:error, :workpad_transfer_verification_failed} = WorkpadTransfer.retire(binding, issue, &api/2)
    end
  end

  defp tampered_comments(:missing), do: {:ok, []}
  defp tampered_comments(:wrong_body), do: {:ok, Enum.map(comments(), &Map.update!(&1, "body", fn body -> body <> "changed" end))}

  defp start(binding), do: WorkpadTransfer.begin(binding, "issue", "app", backup(), &api/2)
  defp backup, do: %{"turns_stopped" => true, "files" => %{"config" => "synthetic-backup"}}
  defp comments, do: Process.get(:comments)

  defp api(:identity, _), do: {:ok, %{"workspace_id" => "workspace", "user_id" => Process.get(:writer)}}
  defp api(:list, _), do: {:ok, comments()}

  defp api(:create, input) do
    refute Enum.any?(comments(), &(&1["id"] == input["id"]))
    Process.put(:comments, comments() ++ [Map.put(input, "user", %{"id" => Process.get(:writer)})])
    write_result()
  end

  defp api(:update, input) do
    comment = Enum.find(comments(), &(&1["id"] == input["id"]))
    assert comment["user"]["id"] == Process.get(:writer)
    Process.put(:comments, Enum.map(comments(), fn item -> if item["id"] == input["id"], do: Map.put(item, "body", input["body"]), else: item end))
    write_result()
  end

  defp write_result do
    if Process.delete(:fail_after_write), do: {:error, :lost_response}, else: :ok
  end
end
