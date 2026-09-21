Code.require_file(Path.expand("../../scripts/advisory-isolation.exs", __DIR__))

defmodule SymphonyElixir.AdvisoryCommentsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CommentCheckpoint
  alias SymphonyElixir.Linear.{Client, CommentInbox, CommentVersion, DurableState}

  @agent "b57e9f80-53ce-4d96-9180-370f03d60d16"

  setup do
    root = Path.join([File.cwd!(), "_build", "advisory-#{System.unique_integer([:positive])}"])
    System.put_env("SYMPHONY_LINEAR_ENV_DIR", root)
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :linear_client_request_fun) end)
    %{issue: %Issue{id: "issue", identifier: "PRO-1", state: "In Arbeit (AI)"}}
  end

  test "synthetic consultation stays out of delivered baseline and incremental checkpoint", ctx do
    for baseline? <- [true, false] do
      issue = %{ctx.issue | id: "issue-#{baseline?}"}
      comments = fixture(issue.id)
      opts = options(comments)

      unless baseline? do
        assert {:ok, %{"inputs" => [baseline]}} = CommentCheckpoint.checkpoint(issue, options([]))
        assert {:ok, _} = CommentCheckpoint.acknowledge(issue, [result(baseline["key"])], options([]))
      end

      assert {:ok, payload} = CommentCheckpoint.checkpoint(issue, opts)
      assert_safe(payload)
      assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
      assert {:ok, %{"inputs" => []}} = CommentCheckpoint.acknowledge(issue, Enum.map(payload["inputs"], &result(&1["key"])), opts)
      assert {:ok, %{"inputs" => []}} = CommentCheckpoint.checkpoint(issue, opts)
      assert :ok = CommentCheckpoint.before_action(issue, opts)
    end
  end

  test "later root page and delayed session never release the human consultation", ctx do
    [control, reply, answer, answer2, root] = fixture(ctx.issue.id)
    delayed = Map.put(root, "agentSession", nil)
    Process.put(:root, delayed)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      cond do
        payload["query"] =~ "SymphonyCommentScanSignal" ->
          data(%{"issue" => %{"comments" => %{"nodes" => [control]}}})

        payload["query"] =~ "SymphonyLinearIssueComments" ->
          if payload["variables"].after == nil,
            do: page([control, reply, answer, answer2], true, "root"),
            else: page([Process.get(:root)], false, nil)

        true ->
          data(%{"comment" => Process.get(:root)})
      end
    end)

    opts = options([]) |> Keyword.delete(:fetch)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert_safe(payload)
    assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
    Process.put(:root, root)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert_safe(payload)
  end

  test "activation protects undelivered legacy baselines and preserves delivered history and acknowledgements", ctx do
    for mode <- [:recognized, :delivered, :processed] do
      issue = %{ctx.issue | id: to_string(mode)}
      comments = fixture(issue.id)
      legacy = options(comments) |> Keyword.put(:advisory_agent_ids, [])
      assert {:ok, original} = CommentCheckpoint.scan(issue, legacy)
      baseline = original["baseline"]["key"]
      if mode != :recognized, do: assert({:ok, _} = CommentCheckpoint.checkpoint(issue, legacy))
      if mode == :processed, do: assert({:ok, _} = CommentCheckpoint.acknowledge(issue, [result(baseline)], legacy))
      assert {:ok, payload} = CommentCheckpoint.checkpoint(issue, options(comments))
      assert_safe(payload)
      assert Enum.all?(payload["advisory_threads"], &(&1["previously_delivered"] == (mode != :recognized)))
      assert {:ok, stored} = CommentInbox.read(Config.settings!().tracker.app, issue)
      assert stored["baseline"]["key"] == baseline
      assert Jason.encode!(stored["baseline"]["sources"]) =~ "A1-"
      if mode == :processed, do: assert(stored["baseline"]["result"] == result(baseline))
      assert Enum.all?(stored["versions"], fn {_, version} -> not version["deleted"] end)
    end
  end

  test "a missing ordinary parent releases its child once after resolution with unchanged source key", ctx do
    establish(ctx.issue)
    child = source("child", "normale Folgefrage", ctx.issue.id) |> Map.put("parentId", "parent")
    opts = options([child]) |> Keyword.put(:resolve_advisory, fn _ -> {:error, :offline} end)
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    parent = source("parent", "normaler Root", ctx.issue.id)
    opts = options([child, parent])
    assert {:ok, %{"inputs" => inputs}} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Enum.any?(inputs, &(&1["key"] == CommentVersion.key(child)))
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.acknowledge(ctx.issue, Enum.map(inputs, &result(&1["key"])), opts)
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.checkpoint(ctx.issue, opts)
  end

  test "deleted advisory roots, edits, resolution and new descendants retain exclusion across restart", ctx do
    comments = fixture(ctx.issue.id)
    assert {:ok, %{"inputs" => [baseline]}} = CommentCheckpoint.checkpoint(ctx.issue, options(comments))
    assert {:ok, _} = CommentCheckpoint.acknowledge(ctx.issue, [result(baseline["key"])], options(comments))
    [control, reply, answer, answer2, _root] = comments
    edited = reply |> Map.put("body", "A1-EDIT") |> Map.put("resolvedAt", "2026-09-21T12:01:00Z")
    new = source("later", "A1-LATER", ctx.issue.id) |> Map.put("parentId", "root")
    opts = options([control, edited, answer, answer2, new])
    assert {:ok, %{"inputs" => []} = payload} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert_safe(payload)
    assert {:ok, stored} = CommentInbox.read(Config.settings!().tracker.app, ctx.issue)
    assert stored["versions"][CommentVersion.key(List.last(comments))]["deleted"]
    assert {:ok, resumed} = Task.async(fn -> CommentInbox.deliver(Config.settings!().tracker.app, ctx.issue, %{"session_id" => "new"}) end) |> Task.await()
    assert CommentInbox.pending(resumed) == []
    assert CommentInbox.ready?(resumed)
  end

  test "unclear, cyclic, cross-issue and structured-mention candidates stay held through timeout and API errors", ctx do
    establish(ctx.issue)
    root = List.last(fixture(ctx.issue.id))
    mention = source("mention", "A1-STRUCTURED", ctx.issue.id) |> Map.put("bodyData", Jason.encode!(%{"type" => "mention", "attrs" => %{"id" => @agent}}))
    cycle = source("cycle", "A1-CYCLE", ctx.issue.id) |> Map.put("parentId", "cycle")
    wrong = root |> Map.put("id", "wrong") |> put_in(["agentSession", "issue", "id"], "foreign")
    malformed = source("malformed", "A1-MALFORMED", ctx.issue.id) |> Map.put("bodyData", "invalid")
    delayed = Map.put(root, "agentSession", nil)
    control = hd(fixture(ctx.issue.id))
    comments = [mention, cycle, wrong, malformed, delayed, control]

    for {now, error} <- [{1_000, :offline}, {40_000, :rate_limited}, {4_000_000, :unavailable}] do
      Process.put(:lookups, 0)

      fetch = fn _ ->
        Process.put(:lookups, Process.get(:lookups) + 1)
        {:error, error}
      end

      opts = options(comments) |> Keyword.merge(advisory_now: now, resolve_advisory: fetch)
      assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, opts)
      assert_safe(payload)
      assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
      assert Process.get(:lookups) <= 8
      assert Enum.all?(payload["advisory_threads"], &(&1["status"] == "held"))
    end

    opts = options(comments) |> Keyword.put(:resolve_advisory, fn _ -> {:error, :offline} end)
    assert {:ok, %{"inputs" => inputs}} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert {:error, {:comment_inputs_pending, _}} = CommentCheckpoint.before_action(ctx.issue, opts)
    assert {:ok, _} = CommentCheckpoint.acknowledge(ctx.issue, Enum.map(inputs, &result(&1["key"])), opts)
    assert :ok = CommentCheckpoint.before_action(ctx.issue, opts)
  end

  test "separate source mention is excluded through full session binding, without author or name matching", ctx do
    root = List.last(fixture(ctx.issue.id))
    mention = source("trigger", "A1-MENTION-20260921", ctx.issue.id)
    root = put_in(root, ["agentSession", "sourceComment"], %{"id" => mention["id"], "issue" => %{"id" => ctx.issue.id}})
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options([mention, root, hd(fixture(ctx.issue.id))]))
    assert_safe(payload)
    assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
  end

  test "own coding sessions, other agents and ordinary replies keep their normal origins", ctx do
    establish(ctx.issue)
    root = List.last(fixture(ctx.issue.id)) |> Map.put("body", "normale Session")
    root = put_in(root, ["agentSession", "appUser", "id"], "coding-app")
    child = source("child", "normale Anweisung an Symphony", ctx.issue.id) |> Map.put("parentId", "root") |> Map.put("agentSession", root["agentSession"])
    other = source("other", "andere Integration", ctx.issue.id) |> put_in(["user", "app"], true)
    own = source("own", "bestätigte Symphony-Ausgabe", ctx.issue.id)
    changed = source("changed", "geänderte eigene Ausgabe", ctx.issue.id)

    classify = fn raw ->
      case raw["id"] do
        "own" -> :own
        "changed" -> :pending
        _ -> :foreign
      end
    end

    opts = options([root, child, other, own, changed]) |> Keyword.put(:classify, classify)
    assert {:ok, %{"inputs" => inputs}} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Enum.sort(Enum.map(inputs, & &1["source"]["id"])) == ["changed", "child", "root"]
    assert Enum.find(inputs, &(&1["source"]["id"] == "changed"))["origin"] == "changed_app_output"
  end

  test "partial scans retain quarantine and observations without baselining or inventing deletion", ctx do
    comments = fixture(ctx.issue.id)
    opts = options(comments) |> Keyword.put(:fetch, fn -> {:error, {:comment_scan_incomplete, :rate_limited, comments}} end)
    assert {:error, :rate_limited} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert {:ok, stored} = CommentInbox.read(Config.settings!().tracker.app, ctx.issue)
    assert stored["baseline"] == nil
    assert_safe(CommentInbox.pending(stored))
    assert Enum.all?(stored["versions"], fn {_, version} -> not version["deleted"] end)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options(comments))
    assert_safe(payload)
    assert length(String.split(Jason.encode!(payload), "CODING-CONTROL-20260921")) == 2
  end

  @tag timeout: 60_000
  test "independent BEAM restart reuses quarantine, baseline and coding acknowledgement", ctx do
    comments = fixture(ctx.issue.id)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options(comments))
    binding = Config.settings!().tracker.app
    fixture_path = Path.join(binding["state_root"], "advisory-fixture.json")
    :ok = DurableState.write(fixture_path, %{"binding" => binding, "issue_id" => ctx.issue.id, "comments" => comments, "agent" => @agent})
    helper = Path.expand("../support/linear_app/advisory_process.exs", __DIR__)
    paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])
    run = fn mode -> System.cmd(System.find_executable("elixir"), paths ++ [helper, fixture_path, mode], stderr_to_stdout: true) end
    {output, 0} = run.("deliver")
    assert_safe(Jason.decode!(output))
    assert Jason.decode!(output)["inputs"] == payload["inputs"]
    {output, 0} = run.("ack")
    assert Jason.decode!(output)["inputs"] == []
    {output, 0} = run.("deliver")
    assert Jason.decode!(output)["inputs"] == []
  end

  test "actual start and continuation prompt uses project advisory configuration", ctx do
    System.put_env("LINEAR_ADVISORY_AGENT_IDS", @agent)
    comments = fixture(ctx.issue.id)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      cond do
        payload["query"] =~ "SymphonyCommentScanSignal" ->
          data(%{"issue" => %{"comments" => %{"nodes" => [hd(comments)]}}})

        payload["query"] =~ "SymphonyAdvisoryAgents" ->
          data(%{
            "users" => %{
              "nodes" => [%{"id" => @agent, "app" => true, "active" => true, "organization" => %{"id" => Config.settings!().tracker.app["workspace_id"]}}],
              "pageInfo" => %{"hasNextPage" => false}
            }
          })

        true ->
          page(comments, false, nil)
      end
    end)

    assert {:ok, prompt} = CommentCheckpoint.prompt(ctx.issue)
    refute prompt =~ "A1-"
    assert prompt =~ "CODING-CONTROL-20260921"
    assert {:ok, resumed} = CommentCheckpoint.prompt(ctx.issue)
    refute resumed =~ "A1-"
  end

  test "direct root resolution paginates spawned sessions and binds a separate trigger", ctx do
    root = List.last(fixture(ctx.issue.id))
    trigger = source("trigger", "A1-TRIGGER", ctx.issue.id) |> Map.put("isArtificialAgentSessionRoot", true)
    session = put_in(root["agentSession"], ["sourceComment"], %{"id" => trigger["id"], "issue" => %{"id" => ctx.issue.id}})
    Process.put(:lookups, 0)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert payload["query"] =~ "SymphonyAdvisoryThread"
      Process.put(:lookups, Process.get(:lookups) + 1)
      {sessions, more, cursor} = if payload["variables"].spawned == nil, do: {[], true, "next"}, else: {[session], false, nil}
      raw = trigger |> Map.put("agentSessions", connection([], false, nil)) |> Map.put("spawnedAgentSessions", connection(sessions, more, cursor))
      data(%{"comment" => raw})
    end)

    assert {:ok, resolved} = Client.fetch_comment_thread(ctx.issue.id, "trigger")
    assert resolved["spawnedAgentSessions"]["nodes"] == [session]
    assert Process.get(:lookups) == 2
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options([trigger, hd(fixture(ctx.issue.id))]))
    assert_safe(payload)
  end

  test "resolution bounds, cursor cycles, partial errors and foreign roots cannot open quarantine", ctx do
    root = List.last(fixture(ctx.issue.id)) |> Map.put("agentSession", nil)

    for response <- [:pages, :cycle, :partial, :foreign, :limited] do
      Process.put(:lookups, 0)

      SymphonyElixir.TestSupport.stub_linear_client(fn _, _ ->
        n = Process.get(:lookups) + 1
        Process.put(:lookups, n)
        raw = root |> Map.put("agentSessions", connection([], true, if(response == :cycle, do: "cycle", else: "page-#{n}"))) |> Map.put("spawnedAgentSessions", connection([], false, nil))

        case response do
          :partial -> {:ok, %{status: 200, body: %{"data" => %{"comment" => raw}, "errors" => [%{"message" => "partial"}]}}}
          :foreign -> data(%{"comment" => put_in(raw, ["issue", "id"], "foreign")})
          :limited -> {:ok, %{status: 429, body: %{}}}
          _ -> data(%{"comment" => raw})
        end
      end)

      result = Client.fetch_comment_thread(ctx.issue.id, "root")
      assert match?({:error, _}, result) or elem(result, 1)["advisoryIncomplete"] == true
      assert Process.get(:lookups) <= 3
    end

    roots = for n <- 1..20, do: %{root | "id" => "root-#{n}"}
    Process.put(:bounded_lookups, 0)

    resolver = fn _ ->
      Process.put(:bounded_lookups, Process.get(:bounded_lookups) + 1)
      {:error, :offline}
    end

    opts = options(roots) |> Keyword.merge(resolve_advisory: resolver, advisory_now: 1_000)
    assert {:ok, _} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Process.get(:bounded_lookups) == 8
    assert {:ok, _} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Process.get(:bounded_lookups) == 16
    assert {:ok, _} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Process.get(:bounded_lookups) == 20
    assert {:ok, _} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Process.get(:bounded_lookups) == 20
  end

  test "identical-body session observations across overlapping pages survive scanner deduplication", ctx do
    root = List.last(fixture(ctx.issue.id))
    delayed = Map.put(root, "agentSession", nil)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      cond do
        payload["query"] =~ "SymphonyCommentScanSignal" -> data(%{"issue" => %{"comments" => %{"nodes" => [delayed]}}})
        payload["variables"].after == nil -> page([delayed], true, "next")
        true -> page([root], false, nil)
      end
    end)

    assert {:ok, [_]} = Client.fetch_issue_comments(ctx.issue.id)
    assert {:ok, observations} = Client.scan_issue_comments(ctx.issue.id)
    assert length(observations) == 2
    assert Enum.uniq_by(observations, &CommentVersion.key/1) |> length() == 1
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options(observations))
    assert_safe(payload)
  end

  test "an unresolved thread invalidates an unchanged background signal after the bounded interval", ctx do
    [control | _] = fixture(ctx.issue.id)
    root = List.last(fixture(ctx.issue.id))
    Process.put(:background_root, Map.put(root, "agentSession", nil))
    Process.put(:background_full, 0)
    Process.put(:background_clock, 0)

    fetch = fn ->
      Process.put(:background_full, Process.get(:background_full) + 1)
      {:ok, [control, Process.get(:background_root)]}
    end

    opts =
      options([])
      |> Keyword.merge(
        background_key: "bound-config",
        background_interval: 604_800_000,
        advisory_interval: 30_000,
        background_now: fn -> Process.get(:background_clock) end,
        signal: fn -> {:ok, [control]} end,
        fetch_after_signal: fn _ -> fetch.() end,
        resolve_advisory: fn _ -> {:error, :unavailable} end
      )

    binding = Config.settings!().tracker.app
    assert {:ok, state} = CommentInbox.scan(binding, ctx.issue, fetch, opts)
    assert_safe(CommentInbox.pending(state))
    Process.put(:background_clock, 10_000)
    assert {:ok, _} = CommentInbox.scan(binding, ctx.issue, fetch, opts)
    assert Process.get(:background_full) == 1
    Process.put(:background_root, root)
    Process.put(:background_clock, 31_000)
    assert {:ok, state} = CommentInbox.scan(binding, ctx.issue, fetch, opts)
    assert Process.get(:background_full) == 2
    assert state["advisory_threads"]["root"]["decision"] == "excluded"
    assert_safe(CommentInbox.pending(state))
  end

  test "legacy normal guidance is not duplicated when quarantine resolves before baseline acknowledgement", ctx do
    parent = source("parent", "normaler Root", ctx.issue.id)
    child = source("child", "NORMALE-KONTROLLE", ctx.issue.id) |> Map.put("parentId", "parent")
    legacy = options([child]) |> Keyword.put(:advisory_agent_ids, [])
    assert {:ok, _} = CommentCheckpoint.scan(ctx.issue, legacy)
    held = options([child]) |> Keyword.put(:resolve_advisory, fn _ -> {:error, :offline} end)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, held)
    refute Jason.encode!(payload) =~ "NORMALE-KONTROLLE"
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options([parent, child]))
    assert length(String.split(Jason.encode!(payload), "NORMALE-KONTROLLE")) == 2
  end

  test "the operator probe uses the same actual scanner and checks baseline, incremental and resumed results", ctx do
    System.put_env("LINEAR_ADVISORY_AGENT_IDS", @agent)
    comments = fixture(ctx.issue.id)
    workspace = Config.settings!().tracker.app["workspace_id"]
    agent = %{"id" => @agent, "app" => true, "active" => true, "organization" => %{"id" => workspace}}

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      cond do
        payload["query"] =~ "SymphonyAdvisoryAgents" -> data(%{"users" => %{"nodes" => [agent], "pageInfo" => %{"hasNextPage" => false}}})
        payload["query"] =~ "SymphonyCommentScanSignal" -> data(%{"issue" => %{"comments" => %{"nodes" => [hd(comments)]}}})
        true -> page(comments, false, nil)
      end
    end)

    for mode <- [:baseline, :incremental] do
      journal = Path.join(Path.dirname(Config.settings!().tracker.app["state_root"]), "probe-#{mode}")
      assert %{"coding_inputs" => 1, "advisory_markers" => 0} = AdvisoryIsolationProbe.run(ctx.issue.id, journal, mode)
      assert %{"coding_inputs" => 0, "advisory_markers" => 0} = AdvisoryIsolationProbe.run(ctx.issue.id, journal, :resume)
    end
  end

  test "normal guidance resolved during baseline acknowledgement remains available until delivered", ctx do
    parent = source("parent", "normaler Root", ctx.issue.id)
    child = source("child", "NORMALE-KONTROLLE", ctx.issue.id) |> Map.put("parentId", "parent")
    legacy = options([child]) |> Keyword.put(:advisory_agent_ids, [])
    assert {:ok, _} = CommentCheckpoint.scan(ctx.issue, legacy)
    held = options([child]) |> Keyword.put(:resolve_advisory, fn _ -> {:error, :offline} end)
    assert {:ok, %{"inputs" => [baseline]} = payload} = CommentCheckpoint.checkpoint(ctx.issue, held)
    refute Jason.encode!(payload) =~ "NORMALE-KONTROLLE"

    resolved = options([parent, child])
    assert {:ok, _} = CommentCheckpoint.acknowledge(ctx.issue, [result(baseline["key"])], resolved)
    assert {:ok, %{"inputs" => inputs} = payload} = CommentCheckpoint.checkpoint(ctx.issue, resolved)
    assert length(String.split(Jason.encode!(payload), "NORMALE-KONTROLLE")) == 2
    assert Enum.any?(inputs, &(&1["key"] == CommentVersion.key(child)))
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.acknowledge(ctx.issue, Enum.map(inputs, &result(&1["key"])), resolved)
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.checkpoint(ctx.issue, resolved)
  end

  test "unequal session connection lengths complete without restarting finished pagination", ctx do
    root = List.last(fixture(ctx.issue.id)) |> Map.put("body", "normale Coding-Session")
    own_session = put_in(root["agentSession"], ["appUser", "id"], "coding-app")
    root = Map.put(root, "agentSession", nil)
    Process.put(:lookups, 0)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert payload["query"] =~ "SymphonyAdvisoryThread"
      Process.put(:lookups, Process.get(:lookups) + 1)
      agent = if payload["variables"].agent == nil, do: connection([], true, "agent-last"), else: connection([own_session], false, nil)

      spawned =
        case payload["variables"].spawned do
          nil -> connection([], true, "spawned-second")
          "spawned-second" -> connection([], true, "spawned-last")
          "spawned-last" -> connection([], false, nil)
        end

      data(%{"comment" => root |> Map.put("agentSessions", agent) |> Map.put("spawnedAgentSessions", spawned)})
    end)

    assert {:ok, resolved} = Client.fetch_comment_thread(ctx.issue.id, root["id"])
    refute resolved["advisoryIncomplete"]
    assert resolved["agentSessions"]["nodes"] == [own_session]
    assert Process.get(:lookups) == 3
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options([root]))
    assert Jason.encode!(payload) =~ "normale Coding-Session"
  end

  test "metadata-only observations do not duplicate normal baseline guidance", ctx do
    normal = hd(fixture(ctx.issue.id))
    changed = Map.put(normal, "bodyData", nil)
    assert CommentVersion.key(normal) == CommentVersion.key(changed)
    assert {:ok, %{"inputs" => [%{"sources" => sources}]}} = CommentCheckpoint.checkpoint(ctx.issue, options([normal, changed]))
    assert length(sources) == 1
  end

  test "session binding observed during resolution cannot disappear on a later API page", ctx do
    advisory = List.last(fixture(ctx.issue.id))
    root = Map.put(advisory, "agentSession", nil)
    own_session = put_in(advisory["agentSession"], ["appUser", "id"], "coding-app")

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert payload["query"] =~ "SymphonyAdvisoryThread"

      raw =
        if payload["variables"].agent == nil,
          do: Map.put(advisory, "agentSessions", connection([], true, "last")),
          else: Map.put(root, "agentSessions", connection([own_session], false, nil))

      data(%{"comment" => Map.put(raw, "spawnedAgentSessions", connection([], false, nil))})
    end)

    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options([root, hd(fixture(ctx.issue.id))]))
    assert_safe(payload)
    assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
    own = Map.put(root, "agentSession", own_session)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options([own, hd(fixture(ctx.issue.id))]))
    assert_safe(payload)
  end

  test "an incomplete advisory binding cannot be cleared by a later null or unrelated coding session", ctx do
    root = List.last(fixture(ctx.issue.id)) |> Map.put("isArtificialAgentSessionRoot", false)
    incomplete = put_in(root, ["agentSession", "comment"], nil)
    own = put_in(root, ["agentSession", "appUser", "id"], "coding-app")

    for current <- [incomplete, Map.put(root, "agentSession", nil), own, root] do
      opts = options([current, hd(fixture(ctx.issue.id))]) |> Keyword.put(:resolve_advisory, fn _ -> {:error, :unavailable} end)
      assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, opts)
      assert_safe(payload)
      assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
    end
  end

  @tag :review_regression
  test "GraphQL partial errors retain observed advisory bindings before a later coding session", ctx do
    advisory = List.last(fixture(ctx.issue.id))
    root = Map.put(advisory, "agentSession", nil)
    partial = root |> Map.put("agentSessions", connection([advisory["agentSession"]], false, nil)) |> Map.put("spawnedAgentSessions", nil)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert payload["query"] =~ "SymphonyAdvisoryThread"
      {:ok, %{status: 200, body: %{"data" => %{"comment" => partial}, "errors" => [%{"message" => "spawned sessions unavailable"}]}}}
    end)

    assert {:ok, first} = CommentCheckpoint.checkpoint(ctx.issue, options([root, hd(fixture(ctx.issue.id))]))
    assert_safe(first)
    own = put_in(advisory, ["agentSession", "appUser", "id"], "coding-app")
    assert {:ok, later} = CommentCheckpoint.checkpoint(ctx.issue, options([own, hd(fixture(ctx.issue.id))]))
    assert_safe(later)
    assert Enum.find(later["advisory_threads"], &(&1["comment_id"] == "root"))["status"] == "excluded"
    assert Jason.encode!(later) =~ "CODING-CONTROL-20260921"
  end

  @tag :review_regression
  test "successive polling intervals fairly resolve a normal parent behind permanently held roots", ctx do
    root = List.last(fixture(ctx.issue.id)) |> Map.put("agentSession", nil)
    roots = for n <- 1..8, do: Map.put(root, "id", "a#{n}")
    parent = source("z-parent", "normaler Root", ctx.issue.id)
    child = source("z-child", "NORMALE-FOLGEFRAGE", ctx.issue.id) |> Map.put("parentId", parent["id"])
    comments = roots ++ [child, hd(fixture(ctx.issue.id))]
    Process.put(:fair_lookups, [])

    resolver = fn id ->
      Process.put(:fair_lookups, Process.get(:fair_lookups) ++ [id])
      if id == parent["id"], do: {:ok, parent}, else: {:error, :unavailable}
    end

    opts = options(comments) |> Keyword.put(:resolve_advisory, resolver)
    assert {:ok, first} = CommentCheckpoint.checkpoint(ctx.issue, Keyword.put(opts, :advisory_now, 1_000))
    refute Jason.encode!(first) =~ "NORMALE-FOLGEFRAGE"
    assert length(Process.get(:fair_lookups)) == 8
    Process.put(:fair_lookups, [])
    next = Keyword.put(opts, :advisory_now, 31_000)
    assert {:ok, %{"inputs" => inputs} = later} = CommentCheckpoint.checkpoint(ctx.issue, next)
    assert "z-parent" in Process.get(:fair_lookups)
    assert length(Process.get(:fair_lookups)) <= 8
    assert Enum.count(inputs, &(&1["key"] == CommentVersion.key(child))) == 1
    assert_safe(later)
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.acknowledge(ctx.issue, Enum.map(inputs, &result(&1["key"])), next)
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.checkpoint(ctx.issue, Keyword.put(opts, :advisory_now, 61_000))
  end

  @tag :review_regression
  test "absence failures preserve partial observations without spending a second resolution budget", ctx do
    missing = source("missing", "normale frühere Quelle", ctx.issue.id)
    assert {:ok, %{"inputs" => [baseline]}} = CommentCheckpoint.checkpoint(ctx.issue, options([missing]))
    root = List.last(fixture(ctx.issue.id)) |> Map.put("agentSession", nil)
    roots = for n <- 1..16, do: Map.put(root, "id", "root-#{n}")
    Process.put(:absence_lookups, 0)

    resolver = fn _ ->
      Process.put(:absence_lookups, Process.get(:absence_lookups) + 1)
      {:error, :unavailable}
    end

    opts = options(roots) |> Keyword.merge(resolve_advisory: resolver, advisory_now: 1_000, confirm_absence: fn _ -> {:error, :absence_unavailable} end)
    assert {:error, :absence_unavailable} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert Process.get(:absence_lookups) == 8
    assert {:ok, stored} = CommentInbox.read(Config.settings!().tracker.app, ctx.issue)
    assert stored["baseline"]["key"] == baseline["key"]
    assert map_size(stored["versions"]) == 17
    assert Enum.all?(stored["versions"], fn {_, version} -> not version["deleted"] end)
    assert_safe(CommentInbox.pending(stored))
    refute CommentInbox.ready?(stored)
  end

  test "advisory identity transport failure stops scanning without creating a baseline", ctx do
    System.put_env("LINEAR_ADVISORY_AGENT_IDS", @agent)

    SymphonyElixir.TestSupport.stub_linear_client(fn payload, _ ->
      assert payload["query"] =~ "SymphonyAdvisoryAgents"
      send(self(), :advisory_identity_requested)
      {:error, :offline}
    end)

    opts = [fetch: fn -> flunk("comments must not be fetched before advisory identity verification") end]
    assert {:error, {:linear_api_request, :linear_app_request_unavailable}} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert_received :advisory_identity_requested
    assert {:ok, stored} = CommentInbox.read(Config.settings!().tracker.app, ctx.issue)
    assert stored["baseline"] == nil
    assert stored["versions"] == %{}
    refute CommentInbox.ready?(stored)
  end

  test "nested structured mentions and malformed session values stay held beside normal coding input", ctx do
    mention = %{"type" => "doc", "content" => [%{"type" => "paragraph", "content" => [%{"type" => "userMention", "attrs" => %{"userId" => @agent}}]}]}
    targeted = source("nested", "A1-NESTED-MENTION", ctx.issue.id) |> Map.put("bodyData", Jason.encode!(mention))
    malformed = source("malformed", "A1-MALFORMED-SESSION", ctx.issue.id) |> Map.put("agentSession", "invalid")
    opts = options([targeted, malformed, hd(fixture(ctx.issue.id))]) |> Keyword.put(:resolve_advisory, fn _ -> {:error, :offline} end)
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, opts)
    assert_safe(payload)
    assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
    assert Enum.map(payload["advisory_threads"], &{&1["comment_id"], &1["status"]}) == [{"malformed", "held"}, {"nested", "held"}]
    assert {:ok, %{"inputs" => []}} = CommentCheckpoint.acknowledge(ctx.issue, Enum.map(payload["inputs"], &result(&1["key"])), opts)
  end

  test "corrupt persisted advisory records block delivery without resetting the journal", ctx do
    assert {:ok, _} = CommentCheckpoint.checkpoint(ctx.issue, options(fixture(ctx.issue.id)))
    binding = Config.settings!().tracker.app
    assert {:ok, stored} = CommentInbox.read(binding, ctx.issue)
    [path] = Path.wildcard(Path.join([binding["state_root"], "inputs", "*.json"]))
    corrupt = put_in(stored, ["advisory_threads", "root"], %{"excluded" => true})
    assert :ok = DurableState.write(path, corrupt)
    assert {:error, :comment_inbox_corrupt} = CommentCheckpoint.checkpoint(ctx.issue, options([]))
    assert {:error, :comment_inbox_corrupt} = CommentInbox.deliver(binding, ctx.issue, %{})
    assert {:ok, ^corrupt} = DurableState.read(path)
  end

  test "delivery after an incomplete first scan preserves quarantine without inventing a baseline", ctx do
    comments = fixture(ctx.issue.id)
    opts = options(comments) |> Keyword.put(:fetch, fn -> {:error, {:comment_scan_incomplete, :offline, comments}} end)
    assert {:error, :offline} = CommentCheckpoint.scan(ctx.issue, opts)
    binding = Config.settings!().tracker.app
    assert {:ok, delivered} = CommentInbox.deliver(binding, ctx.issue, %{"session_id" => "resumed"})
    assert delivered["baseline"] == nil
    refute CommentInbox.ready?(delivered)
    assert_safe(CommentInbox.pending(delivered))
    assert Enum.map(CommentInbox.pending(delivered), & &1["source"]["id"]) == ["control"]
    assert {:ok, payload} = CommentCheckpoint.checkpoint(ctx.issue, options(comments))
    assert_safe(payload)
    assert Jason.encode!(payload) =~ "CODING-CONTROL-20260921"
  end

  defp connection(nodes, more, cursor), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}

  defp establish(issue) do
    {:ok, %{"inputs" => [baseline]}} = CommentCheckpoint.checkpoint(issue, options([]))
    {:ok, _} = CommentCheckpoint.acknowledge(issue, [result(baseline["key"])], options([]))
  end

  defp fixture(issue) do
    reference = %{"id" => "root", "issue" => %{"id" => issue}}
    session = %{"id" => "session", "appUser" => %{"id" => @agent}, "comment" => reference, "sourceComment" => nil, "issue" => %{"id" => issue}}
    root = source("root", "A1-MENTION-20260921", issue) |> Map.put("agentSession", session) |> Map.put("isArtificialAgentSessionRoot", true)

    [
      source("control", "CODING-CONTROL-20260921", issue),
      source("reply", "A1-FOLGE-20260921", issue) |> Map.put("parentId", "root"),
      source("answer", "A1-MENTION-OK-20260921", issue) |> Map.put("parentId", "root") |> put_in(["user", "app"], true),
      source("answer2", "A1-FOLGE-OK-20260921", issue) |> Map.put("parentId", "reply") |> put_in(["user", "app"], true),
      root
    ]
  end

  defp source(id, body, issue),
    do: %{
      "id" => id,
      "body" => body,
      "issue" => %{"id" => issue},
      "user" => %{"id" => "human", "app" => false},
      "updatedAt" => "2026-09-21T12:00:00Z",
      "agentSession" => nil,
      "isArtificialAgentSessionRoot" => false,
      "bodyData" => "{}"
    }

  defp options(comments), do: [fetch: fn -> {:ok, comments} end, advisory_agent_ids: [@agent], classify: fn _ -> :foreign end, write_workpad: fn _ -> :ok end, confirm_absence: fn _ -> :deleted end]
  defp result(key), do: %{"key" => key, "outcome" => "übernommen", "reason" => "Synthetische Kontrolle bestätigt"}
  defp assert_safe(payload), do: refute(Jason.encode!(payload) =~ "A1-")
  defp page(nodes, more, cursor), do: data(%{"issue" => %{"comments" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more, "endCursor" => cursor}}}})
  defp data(data), do: {:ok, %{status: 200, body: %{"data" => data}}}
end
