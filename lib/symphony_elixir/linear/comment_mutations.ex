defmodule SymphonyElixir.Linear.CommentMutations do
  @moduledoc """
  Parses raw GraphQL before app writes. Comment mutations receive a durable ID
  and a separate result selection, independent of the caller's requested fields.
  """

  alias Absinthe.Language, as: L
  alias Absinthe.Phase.Parse

  @selection "{ symphonyReceipt: comment { id body bodyData quotedText resolvingUser { id } resolvingComment { id } updatedAt user { id } issue { id identifier } } }"
  @update_fields ~w(body bodyData quotedText resolvingUserId resolvingCommentId)

  @spec prepare(map()) :: {:ok, map(), [map()]} | {:error, term()}
  def prepare(%{"query" => query} = payload) do
    with {:ok, %{input: document}} <- Parse.run(%L.Source{body: query}),
         {:ok, operation} <- select_operation(document, payload["operationName"]) do
      prepare_operation(operation, document, payload)
    else
      _ -> {:error, :invalid_graphql_document}
    end
  rescue
    _ -> {:error, :invalid_comment_mutation}
  catch
    :invalid_comment_mutation -> {:error, :invalid_comment_mutation}
  end

  defp select_operation(document, name) do
    operations = Enum.filter(document.definitions, &match?(%L.OperationDefinition{}, &1))

    case Enum.filter(operations, &(is_nil(name) or &1.name == name)) do
      [operation] -> {:ok, operation}
      _ -> {:error, :ambiguous_operation}
    end
  end

  defp prepare_operation(%{operation: :mutation} = operation, document, payload) do
    variables = variable_values(operation, payload["variables"] || %{})
    fragments = Map.new(Enum.filter(document.definitions, &match?(%L.Fragment{}, &1)), &{&1.name, &1})
    selections = expand(operation.selection_set.selections, fragments, [])
    {selections, receipts} = rewrite(selections, variables, [])
    # A lost batch response cannot prove intermediate versions of one comment.
    # Reject it before HTTP instead of leaving an unreconcilable journal intent.
    if length(Enum.uniq_by(receipts, & &1["comment_id"])) != length(receipts), do: throw(:invalid_comment_mutation)
    operation = %{operation | selection_set: %{operation.selection_set | selections: selections}}
    used = variable_names([operation.selection_set, operation.directives])
    operation = %{operation | variable_definitions: Enum.filter(operation.variable_definitions, &(&1.variable.name in used))}
    query = inspect(encode_strings(%L.Document{definitions: [operation]}), pretty: true, limit: :infinity)
    if receipts == [], do: {:ok, payload, []}, else: {:ok, %{payload | "query" => query}, Enum.reverse(receipts)}
  end

  defp prepare_operation(_operation, _document, payload), do: {:ok, payload, []}

  defp expand(selections, fragments, visited) do
    Enum.map(selections, fn
      %L.FragmentSpread{name: name, directives: directives} ->
        if name in visited, do: throw(:invalid_comment_mutation)
        fragment = Map.fetch!(fragments, name)

        %L.InlineFragment{
          type_condition: fragment.type_condition,
          directives: directives ++ fragment.directives,
          selection_set: expanded_fragment(fragment, fragments, [name | visited])
        }

      %{selection_set: %L.SelectionSet{} = set} = node ->
        %{node | selection_set: %{set | selections: expand(set.selections, fragments, visited)}}

      node ->
        node
    end)
  end

  defp expanded_fragment(fragment, fragments, visited) do
    %{fragment.selection_set | selections: expand(fragment.selection_set.selections, fragments, visited)}
  end

  defp rewrite(selections, variables, receipts) do
    {nodes, receipts} =
      selections
      |> Enum.filter(&enabled?(&1.directives, variables))
      |> Enum.map_reduce(receipts, &rewrite_node(&1, variables, &2))

    {Enum.reject(nodes, &match?(%L.InlineFragment{selection_set: %{selections: []}}, &1)), receipts}
  end

  defp rewrite_node(%L.InlineFragment{} = node, variables, receipts) do
    {selections, receipts} = rewrite(node.selection_set.selections, variables, receipts)
    {%{node | selection_set: %{node.selection_set | selections: selections}}, receipts}
  end

  defp rewrite_node(%L.Field{name: name} = field, variables, receipts) when name in ["commentCreate", "commentUpdate"] do
    arguments = Map.new(field.arguments, &{&1.name, value(&1.value, variables)})
    input = Map.fetch!(arguments, "input")
    validate_input(name, input)
    previous = Enum.find(receipts, &(&1["field"] == (field.alias || name)))
    id = comment_id(name, input, arguments, previous)
    if not is_binary(id) or id == "", do: throw(:invalid_comment_mutation)
    input = if name == "commentCreate", do: Map.put(input, "id", id), else: input

    arguments =
      Enum.map(field.arguments, fn
        %L.Argument{name: "input"} = argument -> %{argument | value: literal(input)}
        argument -> argument
      end)

    {:ok, %{input: %{definitions: [selection]}}} = Parse.run(%L.Source{body: @selection})
    # A private, collision-checked alias prevents caller directives or aliases
    # from removing the fields needed to confirm a successful write.
    if receipt_alias?(field.selection_set.selections),
      do: throw(:invalid_comment_mutation)

    set = %{field.selection_set | selections: field.selection_set.selections ++ selection.selection_set.selections}
    receipt = %{"comment_id" => id, "issue_id" => input["issueId"], "input" => input, "field" => field.alias || name, "operation" => name, "operation_id" => Ecto.UUID.generate()}
    validate_previous(previous, input, name)
    {%{field | arguments: arguments, selection_set: set}, if(previous, do: receipts, else: [receipt | receipts])}
  end

  defp rewrite_node(node, _variables, receipts), do: {node, receipts}

  defp validate_input("commentUpdate", input) do
    if not Enum.all?(Map.keys(input), &(&1 in @update_fields)), do: throw(:invalid_comment_mutation)
  end

  defp validate_input(_name, _input), do: :ok

  defp validate_previous(nil, _input, _name), do: :ok

  defp validate_previous(previous, input, name) do
    if previous["input"] != input or previous["operation"] != name, do: throw(:invalid_comment_mutation)
  end

  defp comment_id("commentCreate", _input, _arguments, previous) when is_map(previous), do: previous["comment_id"]
  defp comment_id("commentCreate", input, _arguments, _previous), do: input["id"] || Ecto.UUID.generate()
  defp comment_id("commentUpdate", _input, arguments, _previous), do: arguments["id"]

  defp receipt_alias?(selections) do
    Enum.any?(selections, fn
      %L.Field{alias: "symphonyReceipt"} -> true
      %L.InlineFragment{selection_set: set} -> receipt_alias?(set.selections)
      _ -> false
    end)
  end

  defp enabled?(directives, variables) do
    Enum.all?(directives, fn
      %L.Directive{name: name, arguments: arguments} when name in ["skip", "include"] ->
        argument = Enum.find(arguments, &(&1.name == "if"))
        condition = value(argument.value, variables)
        if not is_boolean(condition), do: throw(:invalid_comment_mutation)
        if name == "skip", do: not condition, else: condition

      _ ->
        true
    end)
  end

  defp variable_values(operation, provided) do
    defaults = operation.variable_definitions |> Enum.reject(&is_nil(&1.default_value)) |> Map.new(&{&1.variable.name, value(&1.default_value, %{})})
    variables = Map.merge(defaults, provided |> Jason.encode!() |> Jason.decode!())

    Enum.each(operation.variable_definitions, fn definition ->
      if match?(%L.NonNullType{}, definition.type) and is_nil(variables[definition.variable.name]), do: throw(:invalid_comment_mutation)
    end)

    variables
  end

  defp value(%L.Variable{name: name}, variables), do: Map.get(variables, name, :undefined)

  defp value(%L.ObjectValue{fields: fields}, variables) do
    fields |> Map.new(&{&1.name, value(&1.value, variables)}) |> Map.reject(fn {_key, item} -> item == :undefined end)
  end

  defp value(%L.ListValue{values: values}, variables),
    do:
      Enum.map(values, fn item ->
        case value(item, variables) do
          :undefined -> nil
          resolved -> resolved
        end
      end)

  defp value(%L.NullValue{}, _variables), do: nil
  defp value(%{value: value}, _variables), do: value

  defp literal(value) when is_map(value), do: %L.ObjectValue{fields: Enum.map(value, fn {key, item} -> %L.ObjectField{name: key, value: literal(item)} end)}
  defp literal(value) when is_list(value), do: %L.ListValue{values: Enum.map(value, &literal/1)}
  defp literal(value) when is_binary(value), do: %L.StringValue{value: value}
  defp literal(value) when is_boolean(value), do: %L.BooleanValue{value: value}
  defp literal(value) when is_integer(value), do: %L.IntValue{value: value}
  defp literal(value) when is_float(value), do: %L.FloatValue{value: value}
  defp literal(nil), do: %L.NullValue{}

  # Absinthe's pretty renderer trims StringValue contents and emits multiline
  # blockstrings. At the render boundary only, use its raw value leaf for a
  # JSON-escaped, ordinary GraphQL string. Traverse the whole operation so that
  # retained defaults, directives and adjacent mutation inputs are also lossless.
  defp encode_strings(%L.StringValue{value: value}), do: %{value: Jason.encode!(value)}
  defp encode_strings(%module{} = value), do: struct(module, encode_strings(Map.from_struct(value)))
  defp encode_strings(value) when is_map(value), do: Map.new(value, fn {key, item} -> {key, encode_strings(item)} end)
  defp encode_strings(value) when is_list(value), do: Enum.map(value, &encode_strings/1)
  defp encode_strings(value), do: value

  defp variable_names(%L.Variable{name: name}), do: [name]
  defp variable_names(value) when is_list(value), do: Enum.flat_map(value, &variable_names/1)
  defp variable_names(%_{} = value), do: value |> Map.from_struct() |> variable_names()
  defp variable_names(value) when is_map(value), do: value |> Map.values() |> variable_names()
  defp variable_names(_value), do: []
end
