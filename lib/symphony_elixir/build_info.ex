defmodule SymphonyElixir.BuildInfo do
  @moduledoc "Source identity embedded by the regular checkout build."
  @stamp Path.expand("../../_build/symphony-source.json", __DIR__)
  @external_resource @stamp
  @source (case File.read(@stamp) do
             {:ok, json} -> Jason.decode!(json)
             _ -> nil
           end)

  @spec source() :: map() | nil
  def source, do: @source
end
