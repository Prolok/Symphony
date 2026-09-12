defmodule SymphonyElixir.Linear.CommentVersion do
  @moduledoc "An observed Linear comment version; timestamps alone are not an identity."

  @spec key(map()) :: String.t()
  def key(comment) do
    raw = raw(comment)
    fingerprint = digest([raw["updatedAt"], raw["editedAt"], raw["body"], raw["parentId"], raw["resolvedAt"], raw["archivedAt"]])
    raw["id"] <> ":" <> fingerprint
  end

  @spec digest(term()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.encode16(case: :lower)

  @spec raw(map()) :: map()
  def raw(%{source: source}), do: source
  def raw(%{"id" => _} = source), do: source

  @spec normalize(map()) :: {:ok, map()} | {:error, atom()}
  def normalize(%{"id" => id, "body" => body} = source) when is_binary(id) and id != "" and is_binary(body) do
    {:ok,
     %{
       id: id,
       body: body,
       user_id: get_in(source, ["user", "id"]),
       issue_id: get_in(source, ["issue", "id"]),
       created_at: datetime(source["createdAt"]),
       updated_at: datetime(source["updatedAt"]),
       source: source
     }}
  end

  def normalize(_source), do: {:error, :linear_invalid_comment}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp datetime(_value), do: nil
end
