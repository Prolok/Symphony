defmodule SymphonyElixir.LinearTextTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.CommentMutations
  alias SymphonyElixir.LinearText
  alias SymphonyElixir.Workpad

  test "UTF-16 size reserve also covers structured comment bodies" do
    assert :ok = LinearText.validate(String.duplicate("ä", 79_999))
    astral_body = String.duplicate("😀", 40_000)
    assert {:error, {:linear_text_compaction_required, 80_000, 80_000}} = LinearText.validate(astral_body)
    assert :ok = LinearText.validate(%{"type" => "doc"})
    assert {:error, _} = LinearText.validate(%{"text" => String.duplicate("x", 80_000)})
    assert :ok = LinearText.validate(nil)
  end

  test "oversized workpads and raw comments stop before a journal intent or HTTP write" do
    body = "## Symphony Workpad\n\n### Verlauf\n" <> String.duplicate("Historische Diagnose.\n", 4_000)
    assert {:error, {:linear_text_compaction_required, _, 80_000}} = Workpad.validate_update_body(body)

    for operation <- ["commentCreate", "commentUpdate"] do
      payload = %{
        "query" => "mutation($body: String!) { #{operation}(#{if operation == "commentUpdate", do: "id: \"existing\", ", else: ""}input: {body: $body}) { success } }",
        "variables" => %{"body" => body}
      }

      assert {:error, {:linear_text_compaction_required, _, 80_000}} = CommentMutations.prepare(payload)
    end
  end

  test "semantic condensation retains gates, source, skip and complete acknowledgement" do
    obligations = """
    ## Symphony Workpad

    ### Plan
    - [x] Fix auf Quelle `abc1234` umgesetzt.

    ### Validierung
    - [ ] Betreiber bestätigt Paket A; fällig: Merge (AI)

    ### Review
    - [x] Keine Findings; technischer Review abgeschlossen.

    ### Test
    - [x] make all auf Quelle `abc1234` bestanden.

    ### Kommentareingang
    - Quelle `comment:version`: **übernommen** — Skip Freigabe Review bewusst übersprungen; nur manuelles Gate, Quelle comment:version.
    """

    large = obligations <> "\n### Verlauf\n" <> String.duplicate("Lokaler Zwischenstand geprüft; vollständige Diagnose im Gatelog.\n", 1_600)
    compact = obligations <> "\n### Verlauf\n- 2026-09-17 18:00 – Paket A lokal grün; Logs: `_build/gate.log`. Betreiberabnahme offen.\n"
    assert String.length(compact) < div(String.length(large), 10)
    assert {:error, _} = Workpad.validate_update_body(large)
    assert :ok = Workpad.validate_update_body(compact)

    for section <- ["Plan", "Validierung", "Review", "Test"] do
      assert Workpad.section_checklist_status(large, section) == Workpad.section_checklist_status(compact, section)
    end

    assert Workpad.review_handoff_status(large) == Workpad.review_handoff_status(compact)
    assert Workpad.section_checklist_status(compact, "Validierung", "Test (AI)") == :deferred
    assert Workpad.merge_handoff_status(compact) == :blocked
  end

  test "delegated live evidence stays open until Yolo Review while an early unassigned obligation blocks" do
    delegated = """
    ## Symphony Workpad

    ### Validierung
    - [ ] Betreiber prüft Live-Dienst mit Produkt-Quellhash; fällig: Yolo Review

    ### Test
    - [x] Gebundene Routinetests bestanden.
    """

    assert Workpad.section_checklist_status(delegated, "Test") == :closed
    assert Workpad.section_checklist_status(delegated, "Validierung", "Test (AI)") == :deferred
    assert Workpad.section_checklist_status(delegated, "Validierung", "Merge (AI)") == :deferred
    assert Workpad.section_checklist_status(String.replace(delegated, "; fällig: Yolo Review", ""), "Validierung", "Test (AI)") == :open
  end
end
