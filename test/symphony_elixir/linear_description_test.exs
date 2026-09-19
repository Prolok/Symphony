defmodule SymphonyElixir.LinearDescriptionTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Linear.Description

  test "PRO-808 original journal and returned inline link preserve the same requirement" do
    expected = File.read!("test/fixtures/linear_markdown/inline-link-intent.md")
    actual = File.read!("test/fixtures/linear_markdown/inline-link-returned.md")
    assert Description.equivalent?(expected, actual)
    assert Description.equivalent?(actual, expected)

    for changed <- [
          String.replace(actual, "[Ursprung]", "[Anderer Auftrag]"),
          String.replace(actual, "/PRO-807/", "/PRO-809/"),
          String.replace(actual, "/prolok/", "/foreign/"),
          String.replace(actual, "Follow-up: verified", "Follow-up: ignored"),
          String.replace(actual, "108 Bytes", "109 Bytes")
        ] do
      refute Description.equivalent?(expected, changed)
    end
  end

  test "inline link destination brackets are bounded to unambiguous prose paragraphs" do
    url = "https://linear.app/prolok/issue/PRO-807/example"
    expected = "[Ursprung](#{url})"
    actual = "[Ursprung](<#{url}>)"
    assert Description.equivalent?("Quelle (#{expected}), danach.", "Quelle (#{actual}), danach.")
    assert Description.equivalent?(url, "[PRO-807](<#{url}>)")

    for {open, close} <- [
          {"`", "`"},
          {"`begin\n", "\nend`"},
          {"```\n", "\n```"},
          {"~~~\n", "\n~~~"},
          {"    ", ""},
          {"> ", ""},
          {"!", ""},
          {"\\", ""},
          {"[outer ", "]"},
          {"Text <code>", "</code>"}
        ] do
      refute Description.equivalent?(open <> expected <> close, open <> actual <> close)
    end

    for changed <- [
          "[Ursprung](<#{url})",
          "[Ursprung](#{url}>)",
          "[Ursprung](<#{url}> \"title\")",
          "[Ursprung](<#{url}?query=1>)",
          "[Ursprung](<#{url}#section>)"
        ] do
      refute Description.equivalent?(expected, changed)
    end
  end

  test "PRO-798 original journal and returned description differ only in presentation" do
    expected = File.read!("test/fixtures/linear_markdown/backslash-intent.md")
    actual = File.read!("test/fixtures/linear_markdown/backslash-returned.md")
    assert Description.equivalent?(expected, actual)
    assert Description.equivalent?(actual, expected)

    for changed <- [
          String.replace(actual, "Python >=3.12", "Python >=3.13"),
          String.replace(actual, ~S(bereit\\n), ~S(bereit\\t)),
          String.replace(actual, ~S(bereit\\n), ~S(bereit\\\\n)),
          String.replace(actual, ~S(bereit\\n), "bereit\n"),
          String.replace(actual, "docs/README.md", "docs/OTHER.md"),
          String.replace(actual, "PRO-797]", "PRO-798]")
        ] do
      refute Description.equivalent?(expected, changed)
    end
  end

  test "plain text backslash serialization preserves escapes and literal counts" do
    for suffix <- ["n", "t", "A", "3"] do
      assert Description.equivalent?("Ausgabe: \\" <> suffix, "Ausgabe: \\\\" <> suffix)
    end

    for {expected, actual} <- [
          {~S(\*literal*), ~S(\\*literal*)},
          {~S(\[label]), ~S(\\[label])},
          {~S(\n), ~S(\\t)},
          {~S(\\n), ~S(\\\\n)},
          {~S(\\n), ~S(\\\n)},
          {~S(\n), "n"},
          {~S(\n), "\n"},
          {"Zeile\\\nWeiter", "Zeile\\\\\nWeiter"},
          {~S(C:\new\file), ~S(C:\next\file)},
          {~S(./new\file), ~S(./next\file)}
        ] do
      refute Description.equivalent?(expected, actual)
    end
  end

  test "backslash tolerance excludes code, nested blocks, HTML and general links" do
    for {open, close} <- [
          {"`", "`"},
          {"``", "``"},
          {"```\n", "\n```"},
          {"~~~\n", "\n~~~"},
          {"~~~\n\n", "\n~~~"},
          {"    ", ""},
          {"\t", ""},
          {"> ~~~\n", "\n> ~~~"},
          {"- ~~~\n", "\n  ~~~"},
          {"<pre>\n", "\n</pre>"},
          {"Text <span>", "</span>"},
          {"[label](https://example.org/", ")"},
          {"[label](\nhttps://example.org/", ")"},
          {"[label]:\n", ""},
          {"<https://example.org/", ">"}
        ] do
      expected = open <> ~S(\n) <> close
      actual = open <> ~S(\\n) <> close
      refute Description.equivalent?(expected, actual), inspect({expected, actual})
    end

    # A code span may cross line boundaries; do not treat the middle as prose.
    refute Description.equivalent?("`begin\n" <> ~S(\n) <> "\nend`", "`begin\n" <> ~S(\\n) <> "\nend`")
  end

  test "observed API diff excerpts preserve requirements while changing serialization" do
    # Exact changed lines and context from the operator's description-diff.patch,
    # not an assertion that the complete live issue has been accepted locally.
    expected = File.read!("test/fixtures/linear_markdown/intent.md")
    actual = File.read!("test/fixtures/linear_markdown/returned.md")
    assert Description.equivalent?(expected, actual)
    refute Description.equivalent?(expected, String.replace(actual, "keine leeren", "leere"))
    refute Description.equivalent?(expected, String.replace(actual, "/PRI-149/", "/PRI-999/"))
    refute Description.equivalent?(expected, String.replace(actual, "[PRI-149]", "[anderes Ticket]"))
    refute Description.equivalent?(expected, String.replace(actual, "tilor/issue", "foreign/issue"))
  end

  test "only bounded presentation changes are interchangeable" do
    assert Description.equivalent?(nil, nil)
    refute Description.equivalent?(nil, "")
    assert Description.equivalent?("Text\n\n\n## Abschnitt", "Text\n\n## Abschnitt")
    assert Description.equivalent?("Prüfen:\n- eins", "Prüfen:\n\n* eins")
    refute Description.equivalent?("eins\nzwei", "eins\n\nzwei")
    refute Description.equivalent?("eins\n\n* zwei", "eins\n* zwei")
    refute Description.equivalent?("- [ ] Pflicht", "* [x] Pflicht")
    refute Description.equivalent?("- - -", "* - -")
    refute Description.equivalent?("* * *", "- * *")
    refute Description.equivalent?("- eins\n  - zwei", "* eins\n- zwei")
    refute Description.equivalent?("Text  \nWeiter", "Text\nWeiter")
    refute Description.equivalent?("Text **Pflicht**", "Text Pflicht")
    refute Description.equivalent?("<pre>- a</pre>", "<pre>* a</pre>")
    refute Description.equivalent?("<pre>\n- a\n\n\n</pre>", "<pre>\n* a\n\n</pre>")
    refute Description.equivalent?("    code\n\n\n    more", "    code\n\n    more")
  end

  test "observed ordered-list serialization preserves every requirement and marker" do
    # Exact validation excerpt from the operator's PRO-784 description pair.
    expected = File.read!("test/fixtures/linear_markdown/ordered-intent.md")
    actual = File.read!("test/fixtures/linear_markdown/ordered-returned.md")
    assert Description.equivalent?(expected, actual)
    assert Description.equivalent?(actual, expected)

    for changed <- [
          String.replace(actual, "1. docs/", "2. docs/"),
          String.replace(actual, "2. Die", "3. Die"),
          String.replace(actual, "1. docs/", "1) docs/"),
          String.replace(actual, "1. docs/", "01. docs/"),
          String.replace(actual, "1. docs/", "1.  docs/"),
          String.replace(actual, "Keine Implementierung", "Implementierung"),
          String.replace(actual, "docs/README.md", "docs/OTHER.md")
        ] do
      refute Description.equivalent?(expected, changed)
    end
  end

  test "ordered-list gap tolerance excludes unobserved syntax and literal blocks" do
    expected = "Validierung:\n1. Anforderung prüfen.\n2. Ergebnis bestätigen."
    actual = "Validierung:\n\n1. Anforderung prüfen.\n2. Ergebnis bestätigen."
    assert Description.equivalent?(expected, actual)

    for opener <- ["2. ", "1) ", "01. ", "  1. ", "    1. ", "\t1. "] do
      refute Description.equivalent?("Prüfen:\n#{opener}Pflicht", "Prüfen:\n\n#{opener}Pflicht")
    end

    refute Description.equivalent?("Text\n1. Pflicht", "Text\n\n1. Pflicht")
    refute Description.equivalent?("Prüfen:\n1. eins\n2. zwei", "Prüfen:\n1. eins\n\n2. zwei")
    refute Description.equivalent?("Prüfen:\n1. eins\n  1. zwei", "Prüfen:\n\n1. eins\n1. zwei")
    refute Description.equivalent?("Prüfen:\n1. [Link](https://example.org/a)", "Prüfen:\n\n1. [Link](https://example.org/b)")
    refute Description.equivalent?("Prüfen:\n1. `a b`", "Prüfen:\n\n1. `a  b`")

    for {open, close} <- [{"```", "```"}, {"~~~~", "~~~~"}, {"<pre>", "</pre>"}] do
      refute Description.equivalent?("#{open}\n#{expected}\n#{close}", "#{open}\n#{actual}\n#{close}")
    end
  end

  test "literal code retains its bytes while surrounding lists may be serialized" do
    for fence <- ["```", "~~~~"] do
      code = "#{fence}\n- literal\n\n\nhttps://linear.app/tilor/issue/PRI-149\n#{fence}\n"
      assert Description.equivalent?(code <> "- item", code <> "* item")
      refute Description.equivalent?(code, String.replace(code, "- literal", "* literal"))
      refute Description.equivalent?(code, String.replace(code, "\n\n\n", "\n\n"))
    end

    refute Description.equivalent?("    - literal", "    * literal")
    refute Description.equivalent?("\t- literal", "\t* literal")
    url = "https://linear.app/tilor/issue/PRI-149"
    refute Description.equivalent?("`#{url}`", "`[PRI-149](#{url})`")
    assert Description.equivalent?(url, "[PRI-149](#{url})")
  end
end
