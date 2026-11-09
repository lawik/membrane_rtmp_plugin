defmodule Membrane.RTMPServerTest do
  use ExUnit.Case, async: true

  @handshake_size 1536
  @c1_time_and_zero_size 8
  @c1_random_size @handshake_size - @c1_time_and_zero_size
  @s0_s1_s2_size 1 + 2 * @handshake_size
  @recv_timeout 2_000
  @open_connection_probe_timeout 200
  @rtmp_version 0x03
  @invalid_rtmp_version 0x00

  setup do
    {:ok, server} =
      Membrane.RTMPServer.start_link(
        port: 0,
        handle_new_client: fn _client_ref, _app, _stream_key ->
          Membrane.RTMP.Source.ClientHandlerImpl
        end
      )

    port = Membrane.RTMPServer.get_port(server)
    server_monitor = Process.monitor(server)

    %{server: server, port: port, server_monitor: server_monitor}
  end

  test "malformed handshake closes only the offending connection", ctx do
    socket = connect(ctx.port)
    :ok = :gen_tcp.send(socket, malformed_c0_c1())

    assert {:error, :closed} = :gen_tcp.recv(socket, 0, @recv_timeout)
    refute_received {:DOWN, _ref, :process, _pid, _reason}
    assert Process.alive?(ctx.server)
  end

  test "malformed handshake doesn't disconnect other clients", ctx do
    healthy = connect(ctx.port)
    :ok = :gen_tcp.send(healthy, valid_c0_c1())

    assert {:ok, <<@rtmp_version, _rest::binary>>} =
             :gen_tcp.recv(healthy, @s0_s1_s2_size, @recv_timeout)

    malicious = connect(ctx.port)
    :ok = :gen_tcp.send(malicious, malformed_c0_c1())
    assert {:error, :closed} = :gen_tcp.recv(malicious, 0, @recv_timeout)

    assert {:error, :timeout} = :gen_tcp.recv(healthy, 0, @open_connection_probe_timeout)
    assert {:ok, _peer} = :inet.peername(healthy)

    fresh = connect(ctx.port)
    :ok = :gen_tcp.send(fresh, valid_c0_c1())

    assert {:ok, <<@rtmp_version, _rest::binary>>} =
             :gen_tcp.recv(fresh, @s0_s1_s2_size, @recv_timeout)

    refute_received {:DOWN, _ref, :process, _pid, _reason}
    assert Process.alive?(ctx.server)
  end

  describe "RTMPS" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      cert_path = Path.join(tmp_dir, "test_cert.pem")
      key_path = Path.join(tmp_dir, "test_key.pem")
      generate_test_certificates(cert_path, key_path)

      {:ok, server} =
        Membrane.RTMPServer.start_link(
          port: 0,
          use_ssl?: true,
          ssl_options: [certfile: cert_path, keyfile: key_path],
          handle_new_client: fn _client_ref, _app, _stream_key ->
            Membrane.RTMP.Source.ClientHandlerImpl
          end
        )

      %{ssl_server: server, ssl_port: Membrane.RTMPServer.get_port(server)}
    end

    test "a client stalling the TLS handshake doesn't block other clients", ctx do
      # connects on the TCP level, but never sends the ClientHello
      stalled = connect(ctx.ssl_port)

      assert {:ok, healthy} =
               :ssl.connect(
                 ~c"localhost",
                 ctx.ssl_port,
                 [:binary, active: false, verify: :verify_none],
                 @recv_timeout
               )

      :ok = :ssl.send(healthy, valid_c0_c1())

      assert {:ok, <<@rtmp_version, _rest::binary>>} =
               :ssl.recv(healthy, @s0_s1_s2_size, @recv_timeout)

      :ok = :gen_tcp.close(stalled)
      assert Process.alive?(ctx.ssl_server)
    end
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
    socket
  end

  defp valid_c0_c1() do
    <<@rtmp_version, 0::size(@c1_time_and_zero_size * 8),
      :crypto.strong_rand_bytes(@c1_random_size)::binary>>
  end

  defp malformed_c0_c1(), do: <<@invalid_rtmp_version, 0::size(@handshake_size * 8)>>

  defp generate_test_certificates(cert_path, key_path) do
    {_result, 0} = System.cmd("openssl", ["genrsa", "-out", key_path, "2048"])

    {_result, 0} =
      System.cmd("openssl", [
        "req",
        "-new",
        "-x509",
        "-key",
        key_path,
        "-out",
        cert_path,
        "-days",
        "1",
        "-subj",
        "/C=US/ST=Test/L=Test/O=Test/CN=localhost"
      ])
  end
end
