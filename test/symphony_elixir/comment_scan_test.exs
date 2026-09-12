defmodule SymphonyElixir.CommentScanTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Linear.{Client, CommentVersion}

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    :ok
  end

  test "multiple pages retain threads, equal timestamps and both observed edits while deduplicating exact page overlap" do
    first = source("first", "eins")
    edited = %{first | "body" => "zwei"}
    reply = source("reply", "Antwort") |> Map.put("parentId", "first") |> Map.put("resolvedAt", "2026-09-12T12:01:00Z")

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert payload["query"] =~ "user { id app }"
      assert payload["query"] =~ "onBehalfOf"

      case payload["variables"].after do
        nil -> page([first, reply], true, "next")
        "next" -> page([first, edited], false, nil)
      end
    end)

    assert {:ok, [a, b, c]} = Client.fetch_issue_comments("issue")
    assert a.source == first
    assert b.source == reply
    assert c.source == edited
    assert CommentVersion.key(a) != CommentVersion.key(c)
  end

  test "cursor cycles, missing metadata, malformed rows, cross-issue records and partial GraphQL errors are incomplete" do
    first = source("first", "eins")

    for second <- [
          page([first], true, "next"),
          page([first], true, nil),
          page([first], "false", nil),
          {:ok, %{status: 200, body: %{"data" => %{"issue" => %{"comments" => %{"nodes" => [first]}}}}}},
          page([%{"body" => "missing ID"}], false, nil),
          page([put_in(first, ["issue", "id"], "foreign")], false, nil),
          add_errors(page([first], false, nil)),
          {:error, :network_failure}
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        if payload["variables"].after == nil, do: page([first], true, "next"), else: second
      end)

      assert {:error, {:comment_scan_incomplete, _reason, [%{source: ^first}]}} = Client.fetch_issue_comments("issue")
    end
  end

  test "a failed first page is not a full empty scan, including rate-limited 403" do
    partial = add_errors(page([], false, nil))
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> partial end)
    assert {:error, {:linear_graphql_errors, [_]}} = Client.fetch_issue_comments("issue")
    limited = {:ok, %{status: 403, body: %{"errors" => [%{"extensions" => %{"code" => "RATELIMITED"}}]}}}
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> limited end)
    assert {:error, {:linear_api_status, 403, %{classification: "rate_limited"}}} = Client.fetch_issue_comments("issue")
  end

  test "valid observations on a partial page survive errors and malformed or foreign siblings" do
    first = source("first", "beobachtete Fassung")
    second = source("second", "weitere beobachtete Fassung")
    foreign = put_in(source("foreign", "fremdes Issue"), ["issue", "id"], "other")

    for response <- [
          add_errors(page([first, second], false, nil)),
          page([first, %{"body" => "missing ID"}, second], false, nil),
          page([first, foreign, second], false, nil),
          data(%{"issue" => %{"comments" => %{"nodes" => [first, second]}}})
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> response end)
      assert {:error, {:comment_scan_incomplete, _, observations}} = Client.fetch_issue_comments("issue")
      assert Enum.map(observations, & &1.source) == [first, second]
    end
  end

  test "fresh signal around full pagination detects visible edits and preserves scanned versions" do
    first = source("first", "eins")
    changed = %{first | "body" => "zwei"}

    for final <- [signal([changed]), {:error, :lost_final_probe}] do
      Process.put(:signal_reads, 0)

      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        if payload["query"] =~ "SymphonyCommentScanSignal" do
          count = Process.get(:signal_reads)
          Process.put(:signal_reads, count + 1)
          if count == 0, do: signal([first]), else: final
        else
          page([first], false, nil)
        end
      end)

      assert {:error, {:comment_scan_incomplete, _, observed}} = Client.scan_issue_comments("issue")
      assert Enum.map(observed, & &1.source) == if(final == signal([changed]), do: [first, changed], else: [first])
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      if payload["query"] =~ "SymphonyCommentScanSignal", do: signal([first]), else: page([first], false, nil)
    end)

    assert {:ok, [%{source: ^first}]} = Client.scan_issue_comments("issue")
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> signal([%{}]) end)
    assert {:error, :comment_scan_signal_unavailable} = Client.scan_issue_comments("issue")
  end

  test "a pre-scan version survives pagination failure and a later changed version", _ctx do
    first = source("first", "nur im Vorsignal beobachtet")
    changed = %{first | "body" => "in Paginierung beobachtet"}

    for page_result <- [page([changed], false, nil), {:error, :page_offline}] do
      Process.put(:signal_reads, 0)

      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        if payload["query"] =~ "SymphonyCommentScanSignal" do
          count = Process.get(:signal_reads)
          Process.put(:signal_reads, count + 1)
          if count == 0, do: signal([first]), else: signal([changed])
        else
          page_result
        end
      end)

      assert {:error, {:comment_scan_incomplete, _, observed}} = Client.scan_issue_comments("issue")
      assert hd(observed).source == first
      if page_result == page([changed], false, nil), do: assert(Enum.map(observed, & &1.source) == [first, changed])
    end
  end

  test "partial signal errors preserve valid observed versions at both scan boundaries" do
    first = source("first", "vorher")
    changed = %{first | "body" => "nachher"}

    for boundary <- [:before, :after] do
      Process.put(:signal_reads, 0)

      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        if payload["query"] =~ "SymphonyCommentScanSignal" do
          count = Process.get(:signal_reads)
          Process.put(:signal_reads, count + 1)

          cond do
            boundary == :before -> add_errors(signal([first]))
            count == 0 -> signal([first])
            true -> add_errors(signal([changed]))
          end
        else
          page([first], false, nil)
        end
      end)

      assert {:error, {:comment_scan_incomplete, _, observed}} = Client.scan_issue_comments("issue")
      assert Enum.map(observed, & &1.source) == if(boundary == :before, do: [first], else: [first, changed])
    end
  end

  test "deletion needs explicit not-found plus still-visible issue; denied or missing responses never prove deletion" do
    missing = {:ok, %{status: 200, body: %{"data" => nil, "errors" => [%{"path" => ["comment"], "message" => "Entity not found: Comment", "extensions" => %{"code" => "INPUT_ERROR"}}]}}}

    for {result, expected} <- [
          {missing, :deleted},
          {data(%{"comment" => %{"id" => "first"}}), {:present, %{"id" => "first"}}},
          {data(%{"comment" => nil}), {:error, :comment_absence_unverified}},
          {data(%{"comment" => %{"id" => "other"}}), {:error, :comment_absence_unverified}},
          {add_errors(data(%{"comment" => nil})), {:error, :comment_absence_unverified}}
        ] do
      SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
        if payload["query"] =~ "issue(id:", do: data(%{"issue" => %{"id" => "issue"}}), else: result
      end)

      assert Client.confirm_comment_absence("issue", "first") == expected
    end

    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> data(%{"issue" => nil}) end)
    assert {:error, :comment_absence_unverified} = Client.confirm_comment_absence("issue", "first")
    SymphonyElixir.TestSupport.stub_linear_client(fn _, _ -> {:error, :offline} end)
    assert {:error, {:linear_api_request, :linear_app_request_unavailable}} = Client.confirm_comment_absence("issue", "first")
  end

  defp source(id, body), do: %{"id" => id, "body" => body, "issue" => %{"id" => "issue"}, "user" => %{"id" => "human", "app" => false}, "updatedAt" => "2026-09-12T12:00:00Z"}
  defp page(nodes, more, cursor), do: data(%{"issue" => %{"comments" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}}})
  defp signal(nodes), do: data(%{"issue" => %{"comments" => %{"nodes" => nodes}}})
  defp data(data), do: {:ok, %{status: 200, body: %{"data" => data}}}
  defp add_errors({:ok, response}), do: {:ok, %{response | body: Map.put(response.body, "errors", [%{"message" => "partial", "extensions" => %{"code" => "FORBIDDEN"}}])}}
end
