# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "mcp/client/streamable_http"
require "mcp/client"

module MCP
  class Client
    class StreamableHTTPTest < Minitest::Test
      def setup
        WebMock.disable_net_connect!
      end

      def teardown
        WebMock.reset!
      end

      def test_send_request_returns_json_response
        stub_request(:post, url)
          .with(
            body: { jsonrpc: "2.0", id: "1", method: "tools/list" }.to_json,
            headers: { "Content-Type" => "application/json" },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        response = transport.send_request(request: {
          jsonrpc: "2.0",
          id: "1",
          method: "tools/list",
        })

        assert_equal({ "result" => { "tools" => [] } }, response)
      end

      def test_captures_session_id_from_response
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-123",
            },
            body: { result: {} }.to_json,
          )

        transport.send_request(request: {
          jsonrpc: "2.0",
          id: "1",
          method: "initialize",
        })

        assert_equal "session-123", transport.session_id
      end

      def test_sends_session_id_in_subsequent_requests
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-456",
            },
            body: { result: {} }.to_json,
          )

        # First request gets session ID
        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        # Second request should include session ID
        stub_request(:post, url)
          .with(headers: { "Mcp-Session-Id" => "session-456" })
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "2", method: "tools/list" })
      end

      def test_includes_custom_headers
        custom_transport = StreamableHTTP.new(
          url: url,
          headers: { "Authorization" => "Bearer token123" },
        )

        stub_request(:post, url)
          .with(headers: { "Authorization" => "Bearer token123" })
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: {} }.to_json,
          )

        custom_transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "ping" })
      end

      def test_handles_sse_response
        sse_body = <<~SSE
          id: msg-1
          data: {"jsonrpc":"2.0","id":"1","result":{"tools":[]}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        messages = []
        transport.on_message = ->(msg) { messages << msg }

        response = transport.send_request(request: {
          jsonrpc: "2.0",
          id: "1",
          method: "tools/list",
        })

        assert_equal({ "jsonrpc" => "2.0", "id" => "1", "result" => { "tools" => [] } }, response)
        assert_equal 1, messages.length
        assert_equal "msg-1", transport.last_event_id
      end

      def test_handles_multiple_sse_events
        sse_body = <<~SSE
          data: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":50}}

          data: {"jsonrpc":"2.0","id":"1","result":{"done":true}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        messages = []
        transport.on_message = ->(msg) { messages << msg }

        response = transport.send_request(request: {
          jsonrpc: "2.0",
          id: "1",
          method: "tools/call",
          params: { name: "slow_tool" },
        })

        assert_equal 2, messages.length
        assert_equal 50, messages[0]["params"]["progress"]
        assert_equal true, response["result"]["done"]
      end

      def test_handles_202_accepted
        stub_request(:post, url)
          .to_return(status: 202, body: "")

        response = transport.send_request(request: {
          jsonrpc: "2.0",
          method: "notifications/cancelled",
        })

        assert_equal({}, response)
      end

      def test_raises_bad_request_error
        stub_request(:post, url)
          .to_return(status: 400, body: { error: "Bad request" }.to_json)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: {
            jsonrpc: "2.0",
            id: "1",
            method: "invalid",
          })
        end

        assert_equal :bad_request, error.error_type
        assert_includes error.message, "invalid"
      end

      def test_raises_unauthorized_error
        stub_request(:post, url).to_return(status: 401)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
        end

        assert_equal :unauthorized, error.error_type
      end

      def test_raises_forbidden_error
        stub_request(:post, url).to_return(status: 403)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
        end

        assert_equal :forbidden, error.error_type
      end

      def test_raises_not_found_error
        stub_request(:post, url).to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
        end

        assert_equal :not_found, error.error_type
      end

      def test_raises_method_not_allowed_error
        stub_request(:post, url).to_return(status: 405)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
        end

        assert_equal :method_not_allowed, error.error_type
      end

      def test_raises_unprocessable_entity_error
        stub_request(:post, url).to_return(status: 422)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
        end

        assert_equal :unprocessable_entity, error.error_type
      end

      def test_raises_internal_error_for_5xx
        stub_request(:post, url).to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
        end

        assert_equal :internal_error, error.error_type
      end

      def test_connect_sse_requires_session_id
        error = assert_raises(ArgumentError) do
          transport.connect_sse
        end

        assert_includes error.message, "Session ID required"
      end

      def test_sse_connected_returns_false_initially
        refute transport.sse_connected?
      end

      def test_close_sends_delete_request
        # Set up session
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-to-close",
            },
            body: { result: {} }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        # Expect DELETE request
        delete_stub = stub_request(:delete, url)
          .with(headers: { "Mcp-Session-Id" => "session-to-close" })
          .to_return(status: 200)

        transport.close

        assert_requested(delete_stub)
        assert_nil transport.session_id
      end

      def test_close_clears_session_even_on_error
        # Set up session
        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: {
              "Content-Type" => "application/json",
              "Mcp-Session-Id" => "session-error",
            },
            body: { result: {} }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "initialize" })

        # DELETE fails
        stub_request(:delete, url).to_return(status: 500)

        transport.close

        assert_nil transport.session_id
      end

      def test_works_with_mcp_client
        stub_request(:post, url)
          .with(body: hash_including("method" => "tools/list"))
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: {
              result: {
                tools: [
                  { name: "echo", description: "Echo tool", inputSchema: {} },
                ],
              },
            }.to_json,
          )

        client = MCP::Client.new(transport: transport)
        tools = client.tools

        assert_equal 1, tools.length
        assert_equal "echo", tools.first.name
      end

      def test_reconnect_delay_calculation
        custom_transport = StreamableHTTP.new(
          url: url,
          initial_reconnect_delay: 1.0,
          max_reconnect_delay: 10.0,
          reconnect_grow_factor: 2.0,
        )

        # Use send to access private method for testing
        assert_equal 1.0, custom_transport.send(:calculate_reconnect_delay, 1)
        assert_equal 2.0, custom_transport.send(:calculate_reconnect_delay, 2)
        assert_equal 4.0, custom_transport.send(:calculate_reconnect_delay, 3)
        assert_equal 8.0, custom_transport.send(:calculate_reconnect_delay, 4)
        assert_equal 10.0, custom_transport.send(:calculate_reconnect_delay, 5) # Capped
      end

      def test_on_resumption_token_callback
        sse_body = <<~SSE
          id: token-abc
          data: {"jsonrpc":"2.0","id":"1","result":{}}

          id: token-xyz
          data: {"jsonrpc":"2.0","id":"2","result":{}}

        SSE

        stub_request(:post, url)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/event-stream" },
            body: sse_body,
          )

        tokens = []
        transport.on_resumption_token = ->(token) { tokens << token }

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })

        assert_equal ["token-abc", "token-xyz"], tokens
        assert_equal "token-xyz", transport.last_event_id
      end

      def test_session_id_can_be_set_manually
        transport.session_id = "manual-session-id"
        assert_equal "manual-session-id", transport.session_id

        stub_request(:post, url)
          .with(headers: { "Mcp-Session-Id" => "manual-session-id" })
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: {} }.to_json,
          )

        transport.send_request(request: { jsonrpc: "2.0", id: "1", method: "test" })
      end

      def test_custom_timeout_configuration
        custom_transport = StreamableHTTP.new(
          url: url,
          read_timeout: 120,
          open_timeout: 15,
        )

        refute_nil custom_transport
      end

      def test_connect_sse_is_thread_safe
        transport.session_id = "test-session"

        stub_request(:get, url)
          .with(headers: { "Mcp-Session-Id" => "test-session" })
          .to_return(status: 405)

        threads = 5.times.map do
          Thread.new { transport.connect_sse }
        end
        threads.each(&:join)

        # Should only have started once
        transport.disconnect_sse
      end

      private

      def url
        "http://localhost:9393/mcp"
      end

      def transport
        @transport ||= StreamableHTTP.new(url: url)
      end
    end
  end
end
