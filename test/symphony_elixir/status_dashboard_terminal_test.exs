defmodule SymphonyElixir.StatusDashboardTerminalTest do
  use SymphonyElixir.TestSupport

  test "terminal redraw preserves full rows and removes shortened rows and the old tail" do
    {:ok, dashboard} = StatusDashboard.init(enabled: false)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        dashboard.render_fun.("12345\nABCDE\nold")
        dashboard.render_fun.("6789Z\nxy")
      end)

    assert screen_rows(output, 5) == ["6789Z", "xy   ", "     ", "     "]
    refute output =~ IO.ANSI.clear()
  end

  # Minimal VT screen for the commands emitted here. Cursor positions remain
  # within the screen: writing the rightmost cell sets pending wrap, and EL
  # erases that cell inclusively (as in Ghostty), unlike a cursor past the edge.
  defp screen_rows(output, columns) do
    screen = %{cells: %{}, x: 0, y: 0, columns: columns, pending_wrap: false}
    screen = feed_screen(output, screen)

    for y <- 0..3 do
      for(x <- 0..(columns - 1), into: "", do: Map.get(screen.cells, {x, y}, " "))
    end
  end

  defp feed_screen("", screen), do: screen

  defp feed_screen("\e[H" <> rest, screen),
    do: feed_screen(rest, %{screen | x: 0, y: 0, pending_wrap: false})

  defp feed_screen("\e[K" <> rest, screen) do
    cells = Map.reject(screen.cells, fn {{x, y}, _} -> y == screen.y and x >= screen.x end)
    feed_screen(rest, %{screen | cells: cells, pending_wrap: false})
  end

  defp feed_screen("\e[J" <> rest, screen) do
    cells = Map.reject(screen.cells, fn {{x, y}, _} -> y > screen.y or (y == screen.y and x >= screen.x) end)
    feed_screen(rest, %{screen | cells: cells, pending_wrap: false})
  end

  # The PTY's normal ONLCR output mode maps LF to CRLF.
  defp feed_screen("\n" <> rest, screen),
    do: feed_screen(rest, %{screen | x: 0, y: screen.y + 1, pending_wrap: false})

  defp feed_screen(<<char, rest::binary>>, screen) when char in 32..126 do
    screen = if screen.pending_wrap, do: %{screen | x: 0, y: screen.y + 1}, else: screen
    cells = Map.put(screen.cells, {screen.x, screen.y}, <<char>>)
    pending_wrap = screen.x == screen.columns - 1
    x = min(screen.x + 1, screen.columns - 1)
    feed_screen(rest, %{screen | cells: cells, x: x, pending_wrap: pending_wrap})
  end
end
