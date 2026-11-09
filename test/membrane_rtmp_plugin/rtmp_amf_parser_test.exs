defmodule Membrane.RTMP.AMFParserTest do
  use ExUnit.Case, async: true

  alias Membrane.RTMP.AMF0

  @object_end <<0x00, 0x00, 0x09>>

  test "parses nested objects and arrays within the depth limit" do
    nested = nest_objects(10, <<0x02, 5::16, "value">>)

    assert [%{"" => %{"" => _nested}}] = AMF0.Parser.parse(nested)

    assert [[1.0, [2.0, []]]] =
             AMF0.Parser.parse(
               <<0x0A, 2::32, 0x00, 1.0::float-size(64), 0x0A, 2::32, 0x00, 2.0::float-size(64),
                 0x0A, 0::32>>
             )
  end

  test "rejects objects nested deeper than the limit instead of recursing without bound" do
    # millions of nesting levels in a few MB of `0x03 0x00 0x00`, which never terminate
    payload = :binary.copy(<<0x03, 0x00, 0x00>>, 1_000_000)

    assert_raise RuntimeError, ~r/nested deeper than/, fn -> AMF0.Parser.parse(payload) end

    # the same with ECMA arrays and strict arrays
    payload = :binary.copy(<<0x08, 0::32, 0x00, 0x00>>, 1_000)
    assert_raise RuntimeError, ~r/nested deeper than/, fn -> AMF0.Parser.parse(payload) end

    payload = :binary.copy(<<0x0A, 1::32>>, 1_000)
    assert_raise RuntimeError, ~r/nested deeper than/, fn -> AMF0.Parser.parse(payload) end
  end

  test "rejects strict arrays declaring more elements than there is data" do
    assert_raise RuntimeError, ~r/declares 4294967295 elements/, fn ->
      AMF0.Parser.parse(<<0x0A, 0xFFFFFFFF::32, 0x05>>)
    end
  end

  test "parses an empty strict array" do
    assert [[], :null] = AMF0.Parser.parse(<<0x0A, 0::32, 0x05>>)
  end

  test "applies the limits to embedded AMF3 data" do
    # AMF3 dense array with 2^28 - 1 elements
    assert_raise RuntimeError, ~r/declares 268435455 elements/, fn ->
      AMF0.Parser.parse(<<0x11, 0x09, 0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x01>>)
    end

    # AMF3 arrays nested without end
    payload = :binary.copy(<<0x09, 0x03, 0x01>>, 1_000)

    assert_raise RuntimeError, ~r/nested deeper than/, fn ->
      AMF0.Parser.parse(<<0x11>> <> payload)
    end
  end

  test "parses 4-byte AMF3 integers" do
    assert [1] = AMF0.Parser.parse(<<0x11, 0x04, 0x80, 0x80, 0x80, 0x01>>)
    assert [0x0FFFFFFF] = AMF0.Parser.parse(<<0x11, 0x04, 0xBF, 0xFF, 0xFF, 0xFF>>)
  end

  defp nest_objects(0, value), do: value

  defp nest_objects(depth, value),
    do: <<0x03, 0::16>> <> nest_objects(depth - 1, value) <> @object_end
end
