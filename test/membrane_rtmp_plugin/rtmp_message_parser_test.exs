defmodule Membrane.RTMP.MessageParserTest do
  use ExUnit.Case, async: true

  alias Membrane.RTMP.{AMF0, Handshake, Header, MessageParser, Messages}

  @fixture "test/fixtures/rtmp/blackmagic_4k_live.chunks.bin"
  @handshake_size 1536
  @invalid_rtmp_version 0x00

  test "consumes a real 4K Blackmagic RTMP capture without leftover buffered data" do
    parser =
      MessageParser.init(Handshake.init_server())
      |> Map.merge(%{state_machine: :connecting, handshake: nil})

    {message_count, parser} =
      @fixture
      |> File.read!()
      |> decode_chunks()
      |> Enum.reduce({0, parser}, fn chunk, {count, parser} ->
        {messages, parser} = MessageParser.parse_packet_messages(chunk, parser)
        {count + length(messages), parser}
      end)

    assert message_count == 502
    assert parser.buffer == <<>>
    assert parser.state_machine == :connected

    if Map.has_key?(Map.from_struct(parser), :partial_messages) do
      assert %{
               4 => %{
                 header: %{chunk_stream_id: 4, type_id: 9, body_size: 18_933, timestamp: 8_100},
                 bytes_received: 12_288
               }
             } = parser.partial_messages
    end
  end

  test "returns an error instead of raising on an invalid handshake version byte" do
    parser = MessageParser.init(Handshake.init_server())
    malformed_c0_c1 = <<@invalid_rtmp_version, 0::size(@handshake_size * 8)>>

    assert {:error, {:invalid_handshake_step, :c0_c1}} =
             MessageParser.parse_packet_messages(malformed_c0_c1, parser)
  end

  test "returns an error instead of raising on a command message with arguments of a wrong type" do
    parser =
      MessageParser.init(Handshake.init_server())
      |> Map.merge(%{state_machine: :connecting, handshake: nil})

    assert {[{_header, %Messages.Publish{stream_key: "key"}}], _parser} =
             ["publish", 1.0, :null, "key", "live"]
             |> command_chunk()
             |> MessageParser.parse_packet_messages(parser)

    for stream_key <- [%{}, 1.0] do
      assert {:error, {:invalid_message, 20, %FunctionClauseError{}}} =
               ["publish", 1.0, :null, stream_key, "live"]
               |> command_chunk()
               |> MessageParser.parse_packet_messages(parser)
    end

    assert {:error, {:invalid_message, 20, %FunctionClauseError{}}} =
             ["connect", 1.0, %{"app" => %{}, "tcUrl" => "rtmp://localhost/live"}]
             |> command_chunk()
             |> MessageParser.parse_packet_messages(parser)

    # empty command body
    assert {:error, {:invalid_message, 20, _error}} =
             MessageParser.parse_packet_messages(chunk(20, <<>>), parser)
  end

  test "returns an error instead of raising on a message of an unknown type" do
    parser =
      MessageParser.init(Handshake.init_server())
      |> Map.merge(%{state_machine: :connecting, handshake: nil})

    # Abort Message
    assert {:error, {:invalid_message, 2, _error}} =
             MessageParser.parse_packet_messages(chunk(2, <<0, 0, 0, 3>>), parser)
  end

  defp command_chunk(command), do: chunk(20, AMF0.Encoder.encode(command))

  defp chunk(type_id, body) do
    header =
      Header.new(chunk_stream_id: 3, type_id: type_id, body_size: byte_size(body), stream_id: 1)
      |> Header.serialize()

    header <> body
  end

  defp decode_chunks(data) do
    Stream.unfold(data, fn
      <<len::little-32, chunk::binary-size(len), rest::binary>> -> {chunk, rest}
      <<>> -> nil
    end)
    |> Enum.to_list()
  end
end
