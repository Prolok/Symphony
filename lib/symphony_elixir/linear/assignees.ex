defmodule SymphonyElixir.Linear.Assignees do
  @moduledoc "Human assignee selection shared by polling, dispatch and reconciliation."

  @spec parse(String.t() | nil) :: [String.t()]
  def parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse(nil), do: []

  @spec human?(String.t() | nil, String.t()) :: boolean()
  def human?(value, app_user) do
    assignees = parse(value)

    assignees != [] and
      Enum.all?(assignees, fn assignee ->
        assignee not in ["me", String.downcase(app_user)] and
          (Regex.match?(~r/\A[^\s@]+@[^\s@]+\z/, assignee) or match?({:ok, _}, Ecto.UUID.cast(assignee)))
      end)
  end

  @spec filter(String.t() | nil) :: map()
  def filter(value) do
    %{
      "or" =>
        Enum.map(parse(value), fn assignee ->
          if String.contains?(assignee, "@"),
            do: %{"email" => %{"eqIgnoreCase" => assignee}},
            else: %{"id" => %{"eq" => assignee}}
        end)
    }
  end
end
