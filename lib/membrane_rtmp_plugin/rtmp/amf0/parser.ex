defmodule Membrane.RTMP.AMF0.Parser do
  @moduledoc false

  alias Membrane.RTMP.AMF3

  # The parser recurses into nested objects and arrays, so the nesting is limited to keep
  # a peer from making us build a stack of millions of frames with a few MB of `0x03 0x00 0x00`.
  @max_depth 32

  @doc """
  Parses message from [AMF0](https://en.wikipedia.org/wiki/Action_Message_Format#AMF0) format to Erlang terms.

  Raises when the data is malformed, contains unsupported types or is nested deeper than #{@max_depth} levels.
  """
  @spec parse(binary()) :: list()
  def parse(binary) do
    do_parse(binary, [])
  end

  defp do_parse(<<>>, acc), do: Enum.reverse(acc)

  defp do_parse(payload, acc) do
    {value, rest} = parse_value(payload, 0)

    do_parse(rest, [value | acc])
  end

  defp parse_value(_data, depth) when depth > @max_depth do
    raise "AMF0 data nested deeper than #{@max_depth} levels"
  end

  # parsing a number
  defp parse_value(<<0x00, number::float-size(64), rest::binary>>, _depth) do
    {number, rest}
  end

  # parsing a boolean
  defp parse_value(<<0x01, boolean::8, rest::binary>>, _depth) do
    {boolean == 1, rest}
  end

  # parsing a string
  defp parse_value(<<0x02, size::16, string::binary-size(size), rest::binary>>, _depth) do
    {string, rest}
  end

  # parsing a key-value object
  defp parse_value(<<0x03, rest::binary>>, depth) do
    {acc, rest} = parse_object_pairs(rest, [], depth + 1)

    {Map.new(acc), rest}
  end

  # parsing a null value
  defp parse_value(<<0x05, rest::binary>>, _depth) do
    {:null, rest}
  end

  defp parse_value(<<0x08, _array_size::32, rest::binary>>, depth) do
    parse_object_pairs(rest, [], depth + 1)
  end

  # every element takes at least one byte, so an array can't have more elements than bytes left
  defp parse_value(<<0x0A, size::32, rest::binary>>, _depth) when size > byte_size(rest) do
    raise "AMF0 strict array declares #{size} elements, but only #{byte_size(rest)} bytes are left"
  end

  defp parse_value(<<0x0A, size::32, rest::binary>>, depth) do
    parse_strict_array(rest, size, [], depth + 1)
  end

  # switch to AMF3
  defp parse_value(<<0x11, rest::binary>>, depth) do
    AMF3.Parser.parse_one(rest, depth)
  end

  defp parse_value(data, _depth) do
    raise "Unknown data type #{inspect(data)}"
  end

  # we reached object end
  defp parse_object_pairs(<<0x00, 0x00, 0x09, rest::binary>>, acc, _depth) do
    {Enum.reverse(acc), rest}
  end

  defp parse_object_pairs(
         <<key_size::16, key::binary-size(key_size), rest::binary>>,
         acc,
         depth
       ) do
    {value, rest} = parse_value(rest, depth)

    parse_object_pairs(rest, [{key, value} | acc], depth)
  end

  defp parse_strict_array(rest, 0, acc, _depth), do: {Enum.reverse(acc), rest}

  defp parse_strict_array(rest, size, acc, depth) do
    {value, rest} = parse_value(rest, depth)

    parse_strict_array(rest, size - 1, [value | acc], depth)
  end
end
