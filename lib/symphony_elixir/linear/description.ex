defmodule SymphonyElixir.Linear.Description do
  @moduledoc "Conservative comparison of the observed Linear Markdown serialization."

  @inline_link ~r/(?<!!)\[([^\[\]\\`<>\r\n]+)\]\((<?)(https:\/\/linear\.app\/[a-zA-Z0-9_-]+\/issue\/[A-Z][A-Z0-9]*-\d+(?:\/[a-zA-Z0-9_-]+)?)(>?)\)/

  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(value, value), do: true

  def equivalent?(expected, actual) when is_binary(expected) and is_binary(actual) do
    # Indented blocks and raw HTML have context-sensitive whitespace. Until their
    # serialization is evidenced, require the original bytes for these documents.
    not Regex.match?(~r/^(?: {4}|\t| {0,3}<)/m, expected <> "\n" <> actual) and canonical(expected) == canonical(actual)
  end

  def equivalent?(_, _), do: false

  defp canonical(text) do
    source_lines = String.split(text, "\n")
    plain = plain_document?(source_lines)
    {lines, _} = Enum.map_reduce(source_lines, nil, &line/2)

    lines
    |> heading_gaps()
    |> list_continuation()
    |> Enum.chunk_by(fn {kind, _} -> kind in [:blank, :literal, :heading] end)
    |> Enum.flat_map(&inline_links/1)
    |> Enum.map(&plain_backslashes(&1, plain))
    |> Enum.reduce([], fn
      {:blank, ""}, [{:blank, ""} | _] = acc ->
        acc

      {kind, _} = item, [{:blank, ""}, {:text, previous} | rest] when kind in [:list, :ordered_list] ->
        list_gap(item, previous, rest)

      item, acc ->
        [item | acc]
    end)
    |> Enum.reverse()
  end

  # Linear inserts blank lines around ATX headings and indents a lazy paragraph
  # continuation immediately following a plain top-level bullet. These bounded
  # CommonMark-equivalent forms retain heading level, list nesting and content.
  defp heading_gaps([{:blank, ""} | rest]) do
    rest = Enum.drop_while(rest, &(&1 == {:blank, ""}))

    case rest do
      [{:heading, _} | _] -> heading_gaps(rest)
      _ -> [{:blank, ""} | heading_gaps(rest)]
    end
  end

  defp heading_gaps([{:heading, text} | rest]), do: [{:heading, text} | heading_gaps(Enum.drop_while(rest, &(&1 == {:blank, ""})))]
  defp heading_gaps([line | rest]), do: [line | heading_gaps(rest)]
  defp heading_gaps([]), do: []

  defp list_continuation([{:list, item} = bullet, {:text, "  " <> text} = continuation | rest]) do
    if Regex.match?(~r/\A[\p{L}\p{N}]/u, item) and Regex.match?(~r/\A[\p{L}\p{N}]/u, text),
      do: [bullet, {:text, text} | list_continuation(rest)],
      else: [bullet | list_continuation([continuation | rest])]
  end

  defp list_continuation([line | rest]), do: [line | list_continuation(rest)]
  defp list_continuation([]), do: []

  defp inline_links([{kind, _} | _] = lines) when kind in [:blank, :literal, :heading], do: lines

  defp inline_links(lines) do
    # CommonMark 0.31.2 §6.3 permits optional angle delimiters for this bounded
    # destination syntax. Preserve labels/URLs and reject ambiguous paragraphs:
    # code spans can cross lines; nested/escaped links, images and HTML stay exact.
    text = Enum.map_join(lines, "\n", &elem(&1, 1))
    remainder = Regex.replace(@inline_link, text, &inline_link(&1, &2, &3, &4, &5, :remove))

    if Regex.match?(~r/[`~\\<>\[\]]|^[ \t>]/m, remainder) do
      lines
    else
      Enum.map(lines, fn {kind, line} ->
        normalized = Regex.replace(@inline_link, line, &inline_link(&1, &2, &3, &4, &5, :normalize))
        {kind, issue_link(normalized)}
      end)
    end
  end

  defp inline_link(_all, label, open, url, close, mode) when {open, close} in [{"", ""}, {"<", ">"}] do
    if mode == :remove, do: "", else: "[#{label}](#{url})"
  end

  defp inline_link(all, _label, _open, _url, _close, _mode), do: all

  # Restrict the observed roundtrip to unambiguous prose. Inline code, links,
  # HTML and nested blocks can span lines; a per-line exclusion is insufficient.
  # Only the already recognized terminal issue links are exempt from this guard.
  defp plain_document?(lines) do
    text = Enum.map_join(lines, "\n", &issue_link/1)
    not Regex.match?(~r/[`~<\[\]]|^[ \t>]/m, text)
  end

  # CommonMark 0.31.2 §2.4: backslash + ASCII letter/digit is literal, whereas
  # a pair of backslashes represents one literal backslash. Preserve complete
  # longer runs, punctuation escapes, line breaks and autolink destinations.
  # This comparison never rewrites the creation intent or the outgoing payload.
  defp plain_backslashes({kind, text}, true) when kind in [:text, :list, :ordered_list] do
    canonical =
      if String.contains?(text, "://") do
        text
      else
        Regex.replace(~r/\\+(?=[A-Za-z0-9])/, text, fn
          "\\" -> "\\\\"
          run -> run
        end)
      end

    {kind, canonical}
  end

  defp plain_backslashes(line, _), do: line

  defp list_gap(item, previous, rest) do
    if String.ends_with?(previous, ":") do
      [item, {:text, previous} | rest]
    else
      [item, {:blank, ""}, {:text, previous} | rest]
    end
  end

  defp line(text, {marker, length} = fence) do
    closing = Regex.match?(~r/\A {0,3}#{Regex.escape(marker)}{#{length},}[ \t]*\z/, text)
    {{:literal, text}, if(closing, do: nil, else: fence)}
  end

  defp line(text, nil) do
    cond do
      Regex.match?(~r/\A {0,3}(`{3,}|~{3,})/, text) ->
        [_, marker] = Regex.run(~r/\A {0,3}(`{3,}|~{3,})/, text)
        {{:literal, text}, {String.first(marker), String.length(marker)}}

      text == "" ->
        {{:blank, ""}, nil}

      Regex.match?(~r/\A\#{1,6} [^ ]/, text) ->
        {{:heading, text}, nil}

      Regex.match?(~r/\A(?:-[ ]*){3,}\z|\A(?:\*[ ]*){3,}\z/, text) ->
        {{:literal, text}, nil}

      Regex.match?(~r/\A[-*] \S/, text) ->
        {{:list, issue_link(String.slice(text, 2..-1//1))}, nil}

      # Only the observed top-level ordered-list opener participates in gap
      # normalization. Keep its number, delimiter and spacing in the comparison.
      Regex.match?(~r/\A1\. \S/, text) ->
        {{:ordered_list, issue_link(text)}, nil}

      true ->
        {{:text, issue_link(text)}, nil}
    end
  end

  # Only a terminal Linear issue link whose visible key equals its URL key is
  # interchangeable with the same bare URL. Keep arbitrary labels, destinations,
  # inline code and all other whitespace/content byte-exact.
  defp issue_link(text) do
    if String.contains?(text, "`") do
      text
    else
      Regex.replace(~r/(\A|[ ])\[([A-Z][A-Z0-9]*-\d+)\]\((https:\/\/linear\.app\/[a-zA-Z0-9_-]+\/issue\/([A-Z][A-Z0-9]*-\d+)(?:\/[a-zA-Z0-9_-]+)?)\)\z/, text, &link/5)
    end
  end

  defp link(_all, prefix, key, url, key), do: prefix <> url
  defp link(all, _prefix, _label, _url, _key), do: all
end
