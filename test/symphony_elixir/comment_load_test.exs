defmodule SymphonyElixir.CommentLoadTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.CommentInbox

  test "fifteen tickets over thirty minutes stay below the workspace request target" do
    root = Path.join([File.cwd!(), "_build", "comment-load-#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf!(root) end)
    binding = %{"state_root" => root, "workspace_id" => "load", "installation_id" => "symphony", "user_id" => "app"}
    {:ok, counts} = Agent.start_link(fn -> %{background_signal: 0, background_full: 0, checkpoint: 0} end)

    for number <- 1..15 do
      issue = %{id: "issue-#{number}"}
      foreign = source(issue.id, "human", "human", "2026-09-14T00:00:00Z")
      classify = fn comment -> if get_in(comment, ["user", "id"]) == "app", do: :own, else: :foreign end

      checkpoint = fn now, own ->
        comments = Enum.reject([own, foreign], &is_nil/1)

        fetch = fn ->
          Agent.update(counts, &Map.update!(&1, :checkpoint, fn n -> n + 1 end))
          {:ok, comments}
        end

        CommentInbox.scan(binding, issue, fetch, cache_key: issue.id, background_now: fn -> now end, classify: classify)
      end

      assert {:ok, _} = checkpoint.(0, nil)

      Enum.reduce(1..30, nil, fn minute, own ->
        now = minute * 60_000
        if rem(minute, 5) == 0, do: assert({:ok, _} = checkpoint.(now, own))
        own = if rem(minute, 5) == 0, do: source(issue.id, "workpad", "app", "2026-09-14T00:#{String.pad_leading(to_string(minute), 2, "0")}:00Z"), else: own
        own = if own, do: %{own | "body" => "Workpad Fassung #{minute}"}, else: nil
        comments = Enum.reject([own, foreign], &is_nil/1)

        signal = fn ->
          Agent.update(counts, &Map.update!(&1, :background_signal, fn n -> n + 1 end))
          {:ok, comments}
        end

        full = fn _ ->
          Agent.update(counts, &Map.update!(&1, :background_full, fn n -> n + 1 end))
          {:ok, comments}
        end

        before_count = Agent.get(counts, &(&1.background_signal + &1.background_full))

        assert {:ok, _} =
                 CommentInbox.scan(binding, issue, fn -> {:ok, comments} end,
                   background_key: issue.id,
                   background_interval: 60_000,
                   maximum_full_age: 1_800_000,
                   background_now: fn -> now end,
                   signal: signal,
                   fetch_after_signal: full,
                   classify: classify
                 )

        after_count = Agent.get(counts, &(&1.background_signal + &1.background_full))
        assert after_count - before_count <= 1
        own
      end)
    end

    result = Agent.get(counts, & &1)
    assert result.background_full == 0
    assert result.background_signal == 15 * 24
    assert result.background_signal * 2 < 1_500
    assert result.checkpoint == 15 * 7
  end

  defp source(issue, id, author, time) do
    %{"id" => "#{issue}-#{id}", "body" => id, "issue" => %{"id" => issue}, "user" => %{"id" => author, "app" => author == "app"}, "updatedAt" => time}
  end
end
