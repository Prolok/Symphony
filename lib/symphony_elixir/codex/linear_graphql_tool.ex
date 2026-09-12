defmodule SymphonyElixir.Codex.LinearGraphqlTool do
  @moduledoc """
  Shared `linear_graphql` tool implementation for dynamic tool and MCP flows.
  """

  alias SymphonyElixir.Linear.Client

  @tool_name "linear_graphql"
  @tool_aliases ["symphony_linear.linear_graphql"]
  @tool_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @tool_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec tool_name() :: String.t()
  def tool_name, do: @tool_name

  @spec canonical_tool_name(String.t() | nil) :: String.t() | nil
  def canonical_tool_name(name) when is_binary(name) do
    case String.trim(name) do
      @tool_name -> @tool_name
      alias_name when alias_name in @tool_aliases -> @tool_name
      _other -> nil
    end
  end

  def canonical_tool_name(_name), do: nil

  @spec tool_spec() :: map()
  def tool_spec do
    %{
      "name" => @tool_name,
      "description" => @tool_description,
      "inputSchema" => @tool_input_schema
    }
  end

  @spec execute(term(), keyword()) :: map()
  def execute(arguments, opts \\ []) do
    case invoke(arguments, opts) do
      {:ok, payload} -> dynamic_tool_response(true, encode_payload(payload))
      {:error, payload} -> dynamic_tool_response(false, encode_payload(payload))
    end
  end

  @spec mcp_tool() :: map()
  def mcp_tool, do: tool_spec()

  @spec mcp_call(term(), keyword()) :: map()
  def mcp_call(arguments, opts \\ []) do
    case invoke(arguments, opts) do
      {:ok, payload} ->
        %{
          "content" => [%{"type" => "text", "text" => encode_payload(payload)}],
          "isError" => false
        }

      {:error, payload} ->
        %{
          "content" => [%{"type" => "text", "text" => encode_payload(payload)}],
          "isError" => true
        }
    end
  end

  @spec invoke(term(), keyword()) :: {:ok, map()} | {:error, map()}
  def invoke(arguments, opts \\ []) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_result(response)
    else
      {:error, reason} ->
        {:error, tool_error_payload(reason)}
    end
  end

  defp normalize_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments) do
      {:ok, query, variables}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_result(response) do
    case response do
      %{"errors" => errors} when is_list(errors) and errors != [] -> {:error, response}
      %{errors: errors} when is_list(errors) and errors != [] -> {:error, response}
      _ -> {:ok, response}
    end
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony benötigt die projektgebundene Linear-App-Konfiguration und OAuth2 Client Credentials in .symphony/.env(.local)."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status, diagnostics}) when is_map(diagnostics) do
    error =
      %{
        "message" => linear_status_message(status, diagnostics),
        "status" => status
      }
      |> maybe_put("classification", Map.get(diagnostics, :classification))
      |> maybe_put("bodyExcerpt", Map.get(diagnostics, :body_excerpt))
      |> maybe_put("errors", Map.get(diagnostics, :errors))
      |> maybe_put("extensionsCodes", Map.get(diagnostics, :extensions_codes))
      |> maybe_put("rateLimit", Map.get(diagnostics, :rate_limit))

    %{"error" => error}
  end

  defp tool_error_payload({:linear_api_request, :linear_app_rate_limited}) do
    %{"error" => %{"message" => "Linear app request is rate limited.", "classification" => "rate_limited"}}
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp linear_status_message(status, %{classification: "auth"}) do
    "Linear GraphQL request failed with HTTP #{status} (auth/permission)."
  end

  defp linear_status_message(status, %{classification: "rate_limited"}) do
    "Linear GraphQL request failed with HTTP #{status} (rate limited)."
  end

  defp linear_status_message(status, _diagnostics) do
    "Linear GraphQL request failed with HTTP #{status}."
  end

  defp maybe_put(map, _key, value) when value in [nil, "", [], %{}], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
