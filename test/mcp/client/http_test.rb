# frozen_string_literal: true

require "test_helper"
require "faraday"
require "webmock/minitest"
require "mcp/client/http"
require "mcp/client/tool"
require "mcp/client"

module MCP
  class Client
    class HTTPTest < Minitest::Test
      def test_raises_load_error_when_faraday_not_available
        client = HTTP.new(url: url)

        # simulate Faraday not being available
        HTTP.any_instance.stubs(:require).with("faraday").raises(LoadError, "cannot load such file -- faraday")

        error = assert_raises(LoadError) do
          # This should immediately try to instantiate the client and fail
          client.send_request(request: {})
        end

        assert_includes(error.message, "The 'faraday' gem is required to use the MCP client HTTP transport")
        assert_includes(error.message, "Add it to your Gemfile: gem 'faraday', '>= 2.0'")
      end

      def test_headers_are_added_to_the_request
        headers = { "Authorization" => "Bearer token" }
        client = HTTP.new(url: url, headers: headers)

        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(
            headers: {
              "Authorization" => "Bearer token",
              "Content-Type" => "application/json",
              "Accept" => "application/json, text/event-stream",
            },
            body: request.to_json,
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        # The test passes if the request is made with the correct headers
        # If headers are wrong, the stub_request won't match and will raise
        client.send_request(request: request)
      end

      def test_accept_header_is_included_in_requests
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(
            headers: {
              "Accept" => "application/json, text/event-stream",
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        client.send_request(request: request)
      end

      def test_custom_accept_header_overrides_default
        custom_accept = "application/json"
        custom_client = HTTP.new(url: url, headers: { "Accept" => custom_accept })

        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(
            headers: {
              "Accept" => custom_accept,
            },
          )
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        custom_client.send_request(request: request)
      end

      def test_send_request_returns_faraday_response
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "application/json" },
            body: { result: { tools: [] } }.to_json,
          )

        response = client.send_request(request: request)
        assert_instance_of(Hash, response)
        assert_equal({ "result" => { "tools" => [] } }, response)
      end

      def test_send_request_raises_bad_request_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 400)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("The tools/list request is invalid", error.message)
        assert_equal(:bad_request, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_unauthorized_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 401)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("You are unauthorized to make tools/list requests", error.message)
        assert_equal(:unauthorized, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_forbidden_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 403)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("You are forbidden to make tools/list requests", error.message)
        assert_equal(:forbidden, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_not_found_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 404)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("The tools/list request is not found", error.message)
        assert_equal(:not_found, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_unprocessable_entity_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 422)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("The tools/list request is unprocessable", error.message)
        assert_equal(:unprocessable_entity, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_internal_error
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 500)

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal("Internal error handling tools/list request", error.message)
        assert_equal(:internal_error, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_raises_error_for_unsupported_content_type
        request = {
          jsonrpc: "2.0",
          id: "test_id",
          method: "tools/list",
        }

        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(
            status: 200,
            headers: { "Content-Type" => "text/html" },
            body: "<html></html>",
          )

        error = assert_raises(RequestHandlerError) do
          client.send_request(request: request)
        end

        assert_equal(
          'Unsupported Content-Type: "text/html". Expected application/json or text/event-stream.',
          error.message,
        )
        assert_equal(:unsupported_media_type, error.error_type)
        assert_equal({ method: "tools/list", params: nil }, error.request)
      end

      def test_send_request_parses_sse_single_event
        stub_sse_response("data: #{tools_response_json}\n\n")
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_parses_sse_without_space_after_colon
        stub_sse_response("data:#{tools_response_json}\n\n")
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_parses_sse_with_keepalive_comments
        stub_sse_response(": ping\n\ndata: #{tools_response_json}\n\n: ping\n\n")
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_ignores_sse_lines_without_colon
        stub_sse_response("malformed line\ndata: #{tools_response_json}\n\n")
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_parses_sse_without_trailing_newline
        stub_sse_response("data: #{tools_response_json}")
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_parses_sse_multiline_data
        stub_sse_response("data: {\"result\":\ndata: {\"tools\":[]}}\n\n")
        assert_equal({ "result" => { "tools" => [] } }, client.send_request(request: tools_list_request))
      end

      def test_send_request_tracks_last_event_id
        stub_sse_response("id: event-123\ndata: #{tools_response_json}\n\n")
        http_client = HTTP.new(url: url)
        http_client.send_request(request: tools_list_request)
        assert_equal("event-123", http_client.last_event_id)
      end

      def test_send_request_ignores_event_id_with_null_character
        stub_sse_response("id: event\0id\ndata: #{tools_response_json}\n\n")
        http_client = HTTP.new(url: url)
        http_client.send_request(request: tools_list_request)
        assert_nil(http_client.last_event_id)
      end

      def test_send_request_updates_last_event_id_for_priming_event
        stub_sse_response("id: priming-123\n\ndata: #{tools_response_json}\n\n")
        http_client = HTTP.new(url: url)
        http_client.send_request(request: tools_list_request)
        assert_equal("priming-123", http_client.last_event_id)
      end

      def test_send_request_parses_valid_retry_field
        stub_sse_response("retry: 3000\ndata: #{tools_response_json}\n\n")
        http_client = HTTP.new(url: url)
        http_client.send_request(request: tools_list_request)
        assert_equal(3000, http_client.retry_ms)
      end

      def test_send_request_ignores_non_numeric_retry_field
        stub_sse_response("retry: not-a-number\ndata: #{tools_response_json}\n\n")
        http_client = HTTP.new(url: url)
        http_client.send_request(request: tools_list_request)
        assert_nil(http_client.retry_ms)
      end

      def test_send_request_raises_error_for_invalid_json_response
        stub_response("application/json", "not valid json")
        error = assert_raises(RequestHandlerError) { client.send_request(request: tools_list_request) }
        assert_equal("Invalid JSON in response for tools/list request", error.message)
        assert_equal(:parse_error, error.error_type)
      end

      def test_send_request_raises_error_for_invalid_json_in_sse
        stub_sse_response("data: not valid json\n\n")
        error = assert_raises(RequestHandlerError) { client.send_request(request: tools_list_request) }
        assert_equal("Invalid JSON in response for tools/list request", error.message)
        assert_equal(:parse_error, error.error_type)
      end

      def test_send_request_handles_json_content_type_with_charset
        stub_response("application/json; charset=utf-8", tools_response_json)
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_handles_sse_content_type_with_charset
        stub_response("text/event-stream; charset=utf-8", "data: #{tools_response_json}\n\n")
        assert_equal(expected_tools_response, client.send_request(request: tools_list_request))
      end

      def test_send_request_handles_sse_response_with_multiple_events
        notification1 = { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 50 } }
        notification2 = { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 100 } }
        final_response = { jsonrpc: "2.0", id: "test_id", result: { content: [{ type: "text", text: "done" }] } }

        stub_sse_response("data: #{notification1.to_json}\n\ndata: #{notification2.to_json}\n\ndata: #{final_response.to_json}\n\n")
        assert_equal(JSON.parse(final_response.to_json), client.send_request(request: tools_list_request))
      end

      def test_send_request_yields_each_sse_message_to_block
        notification = { jsonrpc: "2.0", method: "notifications/progress", params: { progress: 50 } }
        final_response = { jsonrpc: "2.0", id: "test_id", result: { content: [] } }

        stub_sse_response("data: #{notification.to_json}\n\ndata: #{final_response.to_json}\n\n")

        yielded_messages = []
        response = client.send_request(request: tools_list_request) { |msg| yielded_messages << msg }

        assert_equal(2, yielded_messages.size)
        assert_equal(JSON.parse(notification.to_json), yielded_messages[0])
        assert_equal(JSON.parse(final_response.to_json), response)
      end

      def test_send_request_raises_error_for_sse_response_with_no_data_events
        stub_sse_response(": ping\n\n: ping\n\n")
        error = assert_raises(HTTP::SSEParseError) { client.send_request(request: tools_list_request) }
        assert_equal("SSE stream contained no data events", error.message)
      end

      def test_send_request_ignores_non_message_event_types
        stub_sse_response("event: custom\ndata: {\"ignored\":true}\n\nevent: message\ndata: #{tools_response_json}\n\n")

        yielded_messages = []
        response = client.send_request(request: tools_list_request) { |msg| yielded_messages << msg }

        assert_equal(1, yielded_messages.size)
        assert_equal(expected_tools_response, response)
      end

      def test_send_request_yields_event_id_to_block
        stub_sse_response("id: id-1\ndata: {\"method\":\"progress\"}\n\nid: id-2\ndata: {\"result\":{}}\n\n")

        http_client = HTTP.new(url: url)
        yielded_event_ids = []
        http_client.send_request(request: tools_list_request) { |_, event_id| yielded_event_ids << event_id }

        assert_equal(["id-1", "id-2"], yielded_event_ids)
        assert_equal("id-2", http_client.last_event_id)
      end

      def test_send_request_handles_string_keys_in_request
        request = { "jsonrpc" => "2.0", "id" => "test_id", "method" => "tools/list" }
        stub_response("application/json", tools_response_json, request)
        assert_equal(expected_tools_response, client.send_request(request: request))
      end

      private

      def stub_request(method, url)
        WebMock.stub_request(method, url)
      end

      def stub_response(content_type, body, request = tools_list_request)
        stub_request(:post, url)
          .with(body: request.to_json)
          .to_return(status: 200, headers: { "Content-Type" => content_type }, body: body)
      end

      def stub_sse_response(body)
        stub_response("text/event-stream", body)
      end

      def tools_list_request
        { jsonrpc: "2.0", id: "test_id", method: "tools/list" }
      end

      def expected_tools_response
        @expected_tools_response ||= JSON.parse(tools_response_json)
      end

      def tools_response_json
        @tools_response_json ||= {
          result: {
            tools: [
              {
                name: "get_weather",
                description: "Get current weather for a location",
                inputSchema: {
                  type: "object",
                  properties: { location: { type: "string" } },
                  required: ["location"],
                },
              },
            ],
          },
        }.to_json
      end

      def url
        "http://example.com"
      end

      def client
        @client ||= HTTP.new(url: url)
      end
    end
  end
end
