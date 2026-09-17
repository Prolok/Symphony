defmodule SymphonyElixir.LinearText do
  @moduledoc "Preflight size reserve for agent-authored Linear comments; never truncates content."

  @limit 80_000

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(body) when is_binary(body) do
    size = body |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> byte_size() |> div(2)
    if size < @limit, do: :ok, else: {:error, {:linear_text_compaction_required, size, @limit}}
  end

  def validate(body) when is_map(body) or is_list(body), do: body |> Jason.encode!() |> validate()
  def validate(_body), do: :ok
end
