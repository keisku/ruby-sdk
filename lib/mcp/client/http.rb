# frozen_string_literal: true

require "json"

module MCP
  class Client
    class HTTP
      class SSEParseError < StandardError; end
      ACCEPT_HEADER = "application/json, text/event-stream"

      # last_event_id and retry_ms track SSE resumability fields.
      # TODO: Use for GET-based SSE reconnection with Last-Event-ID header.
      # See: https://modelcontextprotocol.io/specification/2025-06-18/basic/transports#resumability-and-redelivery
      # See: https://html.spec.whatwg.org/multipage/server-sent-events.html#the-last-event-id-header
      attr_reader :url, :last_event_id, :retry_ms

      def initialize(url:, headers: {})
        @url = url
        @headers = headers
        @last_event_id = nil
        @retry_ms = nil
      end

      def send_request(request:, &block)
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]

        response = client.post("", request)
        validate_response_content_type!(response, method, params)
        parse_response(response, &block)
      rescue Faraday::BadRequestError => e
        raise RequestHandlerError.new(
          "The #{method} request is invalid",
          { method: method, params: params },
          error_type: :bad_request,
          original_error: e,
        )
      rescue Faraday::UnauthorizedError => e
        raise RequestHandlerError.new(
          "You are unauthorized to make #{method} requests",
          { method: method, params: params },
          error_type: :unauthorized,
          original_error: e,
        )
      rescue Faraday::ForbiddenError => e
        raise RequestHandlerError.new(
          "You are forbidden to make #{method} requests",
          { method: method, params: params },
          error_type: :forbidden,
          original_error: e,
        )
      rescue Faraday::ResourceNotFound => e
        raise RequestHandlerError.new(
          "The #{method} request is not found",
          { method: method, params: params },
          error_type: :not_found,
          original_error: e,
        )
      rescue Faraday::UnprocessableEntityError => e
        raise RequestHandlerError.new(
          "The #{method} request is unprocessable",
          { method: method, params: params },
          error_type: :unprocessable_entity,
          original_error: e,
        )
      rescue Faraday::Error => e # Catch-all
        raise RequestHandlerError.new(
          "Internal error handling #{method} request",
          { method: method, params: params },
          error_type: :internal_error,
          original_error: e,
        )
      rescue JSON::ParserError => e
        raise RequestHandlerError.new(
          "Invalid JSON in response for #{method} request",
          { method: method, params: params },
          error_type: :parse_error,
          original_error: e,
        )
      end

      private

      attr_reader :headers

      def client
        require_faraday!
        @client ||= Faraday.new(url) do |faraday|
          faraday.request(:json)
          faraday.response(:raise_error)

          faraday.headers["Accept"] = ACCEPT_HEADER
          headers.each do |key, value|
            faraday.headers[key] = value
          end
        end
      end

      def require_faraday!
        require "faraday"
      rescue LoadError
        raise LoadError, "The 'faraday' gem is required to use the MCP client HTTP transport. " \
          "Add it to your Gemfile: gem 'faraday', '>= 2.0'" \
          "See https://rubygems.org/gems/faraday for more details."
      end

      def validate_response_content_type!(response, method, params)
        content_type = response.headers["Content-Type"]
        return if content_type&.include?("application/json")
        return if content_type&.include?("text/event-stream")

        raise RequestHandlerError.new(
          "Unsupported Content-Type: #{content_type.inspect}. " \
            "Expected application/json or text/event-stream.",
          { method: method, params: params },
          error_type: :unsupported_media_type,
        )
      end

      def parse_response(response, &block)
        content_type = response.headers["Content-Type"]

        if content_type&.include?("text/event-stream")
          parse_sse_response(response.body, &block)
        else
          JSON.parse(response.body)
        end
      end

      def parse_sse_response(body, &block)
        messages = []
        data_buffer = []
        event_type = nil
        event_id = nil

        body.each_line do |line|
          line = line.chomp

          if line.empty?
            process_sse_event(data_buffer, event_type, event_id, messages, &block)
            data_buffer = []
            event_type = nil
            event_id = nil
            next
          end

          next if line.start_with?(":")

          field, value = parse_sse_field(line)
          case field
          when "data"
            data_buffer << value
          when "event"
            event_type = value
          when "id"
            event_id = value unless value.include?("\0")
          when "retry"
            @retry_ms = value.to_i if value.match?(/\A\d+\z/)
          end
        end

        process_sse_event(data_buffer, event_type, event_id, messages, &block)

        raise SSEParseError, "SSE stream contained no data events" if messages.empty?

        messages.last
      end

      def parse_sse_field(line)
        return [nil, nil] unless line.include?(":")

        colon_index = line.index(":")
        field = line[0...colon_index]
        value = line[(colon_index + 1)..]
        value = value[1..] if value.start_with?(" ")
        [field, value]
      end

      def process_sse_event(data_buffer, event_type, event_id, messages, &block)
        @last_event_id = event_id if event_id
        return if data_buffer.empty?
        return unless event_type.nil? || event_type == "message"

        data = data_buffer.join("\n")
        message = JSON.parse(data)
        messages << message
        yield message, @last_event_id if block_given?
      end
    end
  end
end
