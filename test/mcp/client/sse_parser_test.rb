# frozen_string_literal: true

require "test_helper"
require "mcp/client/sse_parser"

module MCP
  class Client
    class SSEParserTest < Minitest::Test
      def setup
        @parser = SSEParser.new
      end

      def test_parses_simple_data_event
        @parser.parse_line("data: hello world")
        event = @parser.parse_line("")

        assert_equal "message", event.event
        assert_equal "hello world", event.data
        assert_nil event.id
        assert_nil event.retry
      end

      def test_parses_data_without_space_after_colon
        @parser.parse_line("data:no space")
        event = @parser.parse_line("")

        assert_equal "no space", event.data
      end

      def test_parses_multiline_data
        @parser.parse_line("data: line one")
        @parser.parse_line("data: line two")
        @parser.parse_line("data: line three")
        event = @parser.parse_line("")

        assert_equal "line one\nline two\nline three", event.data
      end

      def test_parses_event_with_id
        @parser.parse_line("id: 123")
        @parser.parse_line("data: test")
        event = @parser.parse_line("")

        assert_equal "123", event.id
        assert_equal "test", event.data
        assert_equal "123", @parser.last_event_id
      end

      def test_parses_event_type
        @parser.parse_line("event: custom")
        @parser.parse_line("data: test")
        event = @parser.parse_line("")

        assert_equal "custom", event.event
      end

      def test_parses_retry_field
        @parser.parse_line("retry: 5000")
        @parser.parse_line("data: test")
        event = @parser.parse_line("")

        assert_equal 5000, event.retry
      end

      def test_ignores_non_integer_retry
        @parser.parse_line("retry: invalid")
        @parser.parse_line("data: test")
        event = @parser.parse_line("")

        assert_nil event.retry
      end

      def test_ignores_comment_lines
        result = @parser.parse_line(": this is a comment")

        assert_nil result
      end

      def test_ignores_keepalive_pings
        result = @parser.parse_line(": ping 2024-01-01T00:00:00Z")

        assert_nil result
      end

      def test_returns_nil_for_incomplete_event
        result = @parser.parse_line("data: incomplete")

        assert_nil result
      end

      def test_returns_nil_for_empty_data
        @parser.parse_line("event: empty")
        event = @parser.parse_line("")

        assert_nil event
      end

      def test_empty_id_resets_to_nil
        @parser.parse_line("id: first")
        @parser.parse_line("data: test1")
        @parser.parse_line("")

        @parser.parse_line("id:")
        @parser.parse_line("data: test2")
        event = @parser.parse_line("")

        assert_nil event.id
      end

      def test_last_event_id_persists_across_events
        @parser.parse_line("id: event-1")
        @parser.parse_line("data: first")
        @parser.parse_line("")

        @parser.parse_line("data: second without id")
        @parser.parse_line("")

        assert_equal "event-1", @parser.last_event_id
      end

      def test_parse_stream_with_string
        input = "data: hello\n\ndata: world\n\n"
        events = @parser.parse_stream(input).to_a

        assert_equal 2, events.length
        assert_equal "hello", events[0].data
        assert_equal "world", events[1].data
      end

      def test_parse_stream_with_io
        input = StringIO.new("id: 1\ndata: first\n\nid: 2\ndata: second\n\n")
        events = @parser.parse_stream(input).to_a

        assert_equal 2, events.length
        assert_equal "1", events[0].id
        assert_equal "2", events[1].id
      end

      def test_parse_stream_with_block
        input = "data: one\n\ndata: two\n\n"
        collected = []

        @parser.parse_stream(input) { |event| collected << event.data }

        assert_equal ["one", "two"], collected
      end

      def test_parse_stream_handles_trailing_event
        input = "data: trailing"
        events = @parser.parse_stream(input).to_a

        assert_equal 1, events.length
        assert_equal "trailing", events[0].data
      end

      def test_parses_json_data
        json = '{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}'
        @parser.parse_line("data: #{json}")
        event = @parser.parse_line("")

        parsed = JSON.parse(event.data)
        assert_equal "2.0", parsed["jsonrpc"]
        assert_equal 1, parsed["id"]
      end

      def test_parses_complete_sse_stream
        input = <<~SSE
          : keepalive ping

          id: msg-001
          event: message
          data: {"jsonrpc":"2.0","method":"notifications/message","params":{"content":"hello"}}

          id: msg-002
          retry: 3000
          data: {"jsonrpc":"2.0","id":1,"result":{}}

        SSE

        events = @parser.parse_stream(input).to_a

        assert_equal 2, events.length

        assert_equal "msg-001", events[0].id
        assert_equal "message", events[0].event
        assert_includes events[0].data, "notifications/message"

        assert_equal "msg-002", events[1].id
        assert_equal 3000, events[1].retry
      end

      def test_reset_clears_state
        @parser.parse_line("id: test")
        @parser.parse_line("data: test")
        @parser.parse_line("")

        @parser.reset

        assert_nil @parser.last_event_id
      end

      def test_handles_field_without_value
        @parser.parse_line("data")
        event = @parser.parse_line("")

        assert_equal "", event.data
      end

      def test_handles_crlf_line_endings
        @parser.parse_line("data: with crlf\r\n")
        event = @parser.parse_line("\r\n")

        assert_equal "with crlf", event.data
      end
    end
  end
end
