# frozen_string_literal: true

module MCP
  class Client
    # Parses Server-Sent Events (SSE) streams according to the W3C specification.
    # SSE format uses line-based messages with fields like `data:`, `id:`, `event:`, `retry:`.
    # Events are separated by blank lines.
    class SSEParser
      Event = Struct.new(:id, :event, :data, :retry, keyword_init: true)

      def initialize
        reset_event
      end

      # Parses a single line from an SSE stream.
      # Returns an Event when a complete event is ready (blank line encountered),
      # or nil if more lines are needed.
      def parse_line(line)
        line = line.chomp

        if line.empty?
          return emit_event
        end

        # Comments start with colon - used for keepalive pings
        if line.start_with?(":")
          return nil
        end

        field, value = parse_field(line)
        return nil unless field

        case field
        when "data"
          @data_buffer << value
        when "id"
          # Empty id resets to nil per spec
          @current_id = value.empty? ? nil : value
        when "event"
          @current_event = value
        when "retry"
          # Only accept integer values
          @current_retry = value.to_i if value.match?(/\A\d+\z/)
        end

        nil
      end

      # Parses an IO or string containing SSE data, yielding each complete event.
      def parse_stream(input, &block)
        return enum_for(:parse_stream, input) unless block_given?

        input = StringIO.new(input) if input.is_a?(String)

        input.each_line do |line|
          event = parse_line(line)
          yield event if event
        end

        # Emit any remaining event at end of stream
        final_event = emit_event
        yield final_event if final_event
      end

      # Resets parser state for a new stream
      def reset
        reset_event
        @last_event_id = nil
      end

      # Returns the last successfully received event ID (for reconnection)
      attr_reader :last_event_id

      private

      def reset_event
        @data_buffer = []
        @current_event = nil
        @current_id = nil
        @current_retry = nil
      end

      def parse_field(line)
        # Field format: "field: value" or "field:value" or just "field"
        colon_index = line.index(":")

        if colon_index.nil?
          # Entire line is the field name with empty value
          [line, ""]
        elsif colon_index == 0
          # Comment line (already handled above, but be defensive)
          nil
        else
          field = line[0...colon_index]
          # Skip single space after colon if present
          value_start = colon_index + 1
          value_start += 1 if line[value_start] == " "
          value = line[value_start..] || ""
          [field, value]
        end
      end

      def emit_event
        return nil if @data_buffer.empty?

        # Update last_event_id when id field was present
        @last_event_id = @current_id if @current_id

        # Join multiple data lines with newlines
        data = @data_buffer.join("\n")

        event = Event.new(
          id: @current_id,
          event: @current_event || "message",
          data: data,
          retry: @current_retry,
        )

        reset_event
        event
      end
    end
  end
end
