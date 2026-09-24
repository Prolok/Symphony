defmodule SymphonyElixir.Linear.Description do
  @moduledoc "Conservative comparison of the observed Linear Markdown serialization."

  @inline_link ~r/(?<!!)\[([^\[\]\\`<>\r\n]+)\]\((<?)(https:\/\/linear\.app\/[a-zA-Z0-9_-]+\/issue\/[A-Z][A-Z0-9]*-\d+(?:\/[a-zA-Z0-9_-]+)?)(>?)\)/
  @issue_link ~r/(\A|[ \n])\[([A-Z][A-Z0-9]*-\d+)\]\((https:\/\/linear\.app\/[a-zA-Z0-9_-]+\/issue\/([A-Z][A-Z0-9]*-\d+)(?:\/[a-zA-Z0-9_-]+)?)\)(?=\z|[ \n])/
  @nested_fence ~r/^[ \t]*(?:(?:[-*+]|\d+[.)]) +|> ?)+(?:`{3,}|~{3,})/m

  @spec equivalent?(term(), term()) :: boolean()
  def equivalent?(value, value), do: true

  def equivalent?(expected, actual) when is_binary(expected) and is_binary(actual) do
    # Indented blocks and raw HTML have context-sensitive whitespace. Until their
    # serialization is evidenced, require the original bytes for these documents.
    text = expected <> "\n" <> actual

    not Regex.match?(~r/^(?: {4}|\t| {0,3}<)/m, text) and
      not Regex.match?(@nested_fence, text) and canonical(expected) == canonical(actual)
  end

  def equivalent?(_, _), do: false

  @doc false
  @spec first_difference(String.t(), String.t()) :: map()
  def first_difference(expected, actual) do
    expected_comparison = comparison_text(expected)
    actual_comparison = comparison_text(actual)

    {expected_text, actual_text} =
      if expected_comparison == actual_comparison,
        do: {expected, actual},
        else: {expected_comparison, actual_comparison}

    offset = common_prefix_bytes(expected_text, actual_text, 0)
    prefix = binary_part(expected_text, 0, offset)
    lines = String.split(prefix, "\n")

    %{
      at: %{byte: offset, line: length(lines), column: byte_size(List.last(lines)) + 1},
      expected_fragment: fragment(expected_text, offset),
      actual_fragment: fragment(actual_text, offset)
    }
  end

  defp comparison_text(text), do: text |> canonical() |> Enum.map_join("\n", fn {kind, line} -> "#{kind}:#{line}" end)

  defp common_prefix_bytes(<<byte, expected::binary>>, <<byte, actual::binary>>, count),
    do: common_prefix_bytes(expected, actual, count + 1)

  defp common_prefix_bytes(_, _, count), do: count

  defp fragment(value, offset), do: value |> binary_part(offset, min(48, byte_size(value) - offset)) |> inspect()

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
    case Enum.drop_while(rest, &(&1 == {:blank, ""})) do
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
    lines = issue_links(lines)
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
        {kind, normalized}
      end)
      |> issue_links()
    end
  end

  defp issue_links(lines) do
    normalized = lines |> Enum.map_join("\n", &elem(&1, 1)) |> normalize_issue_links(lines)
    Enum.zip_with(lines, String.split(normalized, "\n"), fn {kind, _}, text -> {kind, text} end)
  end

  # Normalize only a complete, unambiguous issue link in prose. Paired code
  # spans may cross lines; unmatched backticks and other link syntax stay exact.
  defp normalize_issue_links(text, lines) do
    runs = Regex.scan(~r/`+/, text, return: :index) |> Enum.map(&hd/1)

    case code_chunks(text, runs) do
      {:ok, chunks} ->
        if ambiguous_issue_links?(chunks, lines), do: text, else: Enum.map_join(chunks, &normalize_issue_chunk/1)

      :error ->
        text
    end
  end

  defp ambiguous_issue_links?(chunks, lines) do
    remainder =
      chunks
      |> Enum.map_join(&issue_remainder_chunk/1)
      |> String.split("\n")
      |> Enum.zip(lines)
      |> Enum.map_join("\n", fn
        {"[ ] " <> rest, {:list, _}} -> rest
        {"[x] " <> rest, {:list, _}} -> rest
        {"[X] " <> rest, {:list, _}} -> rest
        {text, _} -> text
      end)

    Regex.match?(~r/[\[\]\\<>]/, remainder)
  end

  defp issue_remainder_chunk({:code, part}), do: Regex.replace(~r/[^\n]/, part, "")
  defp issue_remainder_chunk(chunk), do: normalize_issue_chunk(chunk)
  defp normalize_issue_chunk({:code, part}), do: part
  defp normalize_issue_chunk({:prose, part}), do: Regex.replace(@issue_link, part, &link(&1, &2, &3, &4, &5))

  defp code_chunks(text, runs) do
    {open, previous, chunks} =
      Enum.reduce(runs, {nil, 0, []}, fn {start, length}, {open, previous, chunks} ->
        case open do
          nil ->
            {{start, length}, previous, [{:prose, binary_part(text, previous, start - previous)} | chunks]}

          {opened, ^length} ->
            segment = binary_part(text, opened, start + length - opened)
            {nil, start + length, [{:code, segment} | chunks]}

          _ ->
            {open, previous, chunks}
        end
      end)

    if open do
      :error
    else
      trailing = binary_part(text, previous, byte_size(text) - previous)
      {:ok, Enum.reverse([{:prose, trailing} | chunks])}
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
    text = Enum.map_join(lines, "\n", &terminal_issue_link/1)
    not Regex.match?(~r/[`~<\[\]]|^[ \t>]/m, text)
  end

  defp terminal_issue_link(text) do
    if String.contains?(text, "`") do
      text
    else
      Regex.replace(~r/(\A|[ ])\[([A-Z][A-Z0-9]*-\d+)\]\((https:\/\/linear\.app\/[a-zA-Z0-9_-]+\/issue\/([A-Z][A-Z0-9]*-\d+)(?:\/[a-zA-Z0-9_-]+)?)\)\z/, text, &link/5)
    end
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
        {{:list, String.slice(text, 2..-1//1)}, nil}

      # Only the observed top-level ordered-list opener participates in gap
      # normalization. Keep its number, delimiter and spacing in the comparison.
      Regex.match?(~r/\A1\. \S/, text) ->
        {{:ordered_list, text}, nil}

      true ->
        {{:text, text}, nil}
    end
  end

  defp link(_all, prefix, key, url, key), do: prefix <> url
  defp link(all, _prefix, _label, _url, _key), do: all
end
