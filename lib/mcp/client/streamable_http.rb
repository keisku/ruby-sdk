# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require_relative "sse_parser"
require_relative "../client"

module MCP
  class Client
    # HTTP transport with SSE streaming support for the MCP protocol.
    # Handles session management, SSE parsing, and reconnection.
    class StreamableHTTP
      attr_reader :url, :last_event_id
      attr_accessor :session_id, :on_message, :on_error, :on_close, :on_resumption_token

      # Reconnection settings
      DEFAULT_INITIAL_DELAY = 1.0
      DEFAULT_MAX_DELAY = 30.0
      DEFAULT_GROW_FACTOR = 2.0
      DEFAULT_MAX_ATTEMPTS = 5
      DEFAULT_READ_TIMEOUT = 60
      DEFAULT_OPEN_TIMEOUT = 30

      def initialize(
        url:,
        headers: {},
        reconnect: true,
        initial_reconnect_delay: DEFAULT_INITIAL_DELAY,
        max_reconnect_delay: DEFAULT_MAX_DELAY,
        reconnect_grow_factor: DEFAULT_GROW_FACTOR,
        max_reconnect_attempts: DEFAULT_MAX_ATTEMPTS,
        read_timeout: DEFAULT_READ_TIMEOUT,
        open_timeout: DEFAULT_OPEN_TIMEOUT
      )
        @url = url
        @headers = headers
        @session_id = nil
        @last_event_id = nil
        @sse_thread = nil
        @sse_running = false
        @mutex = Mutex.new

        @reconnect_enabled = reconnect
        @initial_reconnect_delay = initial_reconnect_delay
        @max_reconnect_delay = max_reconnect_delay
        @reconnect_grow_factor = reconnect_grow_factor
        @max_reconnect_attempts = max_reconnect_attempts
        @read_timeout = read_timeout
        @open_timeout = open_timeout
        @server_retry_ms = nil

        @on_message = nil
        @on_error = nil
        @on_close = nil
        @on_resumption_token = nil
      end

      # Sends a JSON-RPC request and handles the response.
      # Automatically captures session_id from initialize responses.
      # Handles both JSON and SSE response formats.
      def send_request(request:)
        method = request[:method] || request["method"]
        params = request[:params] || request["params"]

        uri = URI(@url)

        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          read_timeout: @read_timeout,
          open_timeout: @open_timeout,
        ) do |http|
          req = Net::HTTP::Post.new(uri)
          req["Content-Type"] = "application/json"
          req["Accept"] = "application/json, text/event-stream"

          @headers.each { |key, value| req[key] = value }
          req["Mcp-Session-Id"] = @session_id if @session_id

          req.body = request.to_json

          response = http.request(req)
          handle_response(response, method, params)
        end
      rescue RequestHandlerError
        raise
      rescue Net::HTTPClientException, Net::HTTPServerException => e
        raise_request_error(e, method, params)
      rescue StandardError => e
        raise RequestHandlerError.new(
          "Internal error handling #{method} request: #{e.message}",
          { method: method, params: params },
          error_type: :internal_error,
          original_error: e,
        )
      end

      # Starts an SSE connection for receiving server-initiated messages.
      # Runs in a background thread and calls on_message for each event.
      # Returns immediately; use sse_connected? to check status.
      def connect_sse
        @mutex.synchronize do
          return if @sse_running

          unless @session_id
            raise ArgumentError, "Session ID required for SSE connection. Send an initialize request first."
          end

          @sse_running = true
        end

        @sse_thread = Thread.new { run_sse_loop }
      end

      # Disconnects the SSE stream gracefully.
      def disconnect_sse
        @sse_running = false
        @sse_thread&.join(5)
        @sse_thread = nil
      end

      # Returns true if SSE connection is active.
      def sse_connected?
        @sse_running && @sse_thread&.alive?
      end

      # Closes the session by sending a DELETE request and disconnecting SSE.
      def close
        disconnect_sse

        return unless @session_id

        uri = URI(@url)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          req = Net::HTTP::Delete.new(uri)
          @headers.each { |key, value| req[key] = value }
          req["Mcp-Session-Id"] = @session_id
          http.request(req)
        end
      rescue StandardError
        # Ignore errors during close
      ensure
        @session_id = nil
      end

      private

      def handle_response(response, method, params)
        capture_session_id(response)

        case response.code.to_i
        when 200
          handle_success_response(response)
        when 202
          # Accepted - no content expected
          {}
        when 400
          raise RequestHandlerError.new(
            "The #{method} request is invalid",
            { method: method, params: params },
            error_type: :bad_request,
          )
        when 401
          raise RequestHandlerError.new(
            "You are unauthorized to make #{method} requests",
            { method: method, params: params },
            error_type: :unauthorized,
          )
        when 403
          raise RequestHandlerError.new(
            "You are forbidden to make #{method} requests",
            { method: method, params: params },
            error_type: :forbidden,
          )
        when 404
          raise RequestHandlerError.new(
            "The #{method} request is not found",
            { method: method, params: params },
            error_type: :not_found,
          )
        when 405
          # Method not allowed - server doesn't support this method
          raise RequestHandlerError.new(
            "The #{method} request method is not allowed",
            { method: method, params: params },
            error_type: :method_not_allowed,
          )
        when 422
          raise RequestHandlerError.new(
            "The #{method} request is unprocessable",
            { method: method, params: params },
            error_type: :unprocessable_entity,
          )
        else
          raise RequestHandlerError.new(
            "Internal error handling #{method} request",
            { method: method, params: params },
            error_type: :internal_error,
          )
        end
      end

      def handle_success_response(response)
        content_type = response["Content-Type"]&.split(";")&.first&.strip

        case content_type
        when "text/event-stream"
          handle_sse_response(response.body)
        when "application/json"
          JSON.parse(response.body)
        else
          # Default to JSON parsing
          JSON.parse(response.body)
        end
      end

      def handle_sse_response(body)
        parser = SSEParser.new
        messages = []

        parser.parse_stream(body) do |event|
          update_last_event_id(event.id) if event.id

          next if event.data.empty?

          begin
            message = JSON.parse(event.data)
            messages << message
            @on_message&.call(message)
          rescue JSON::ParserError
            # Skip non-JSON events
          end
        end

        # Return the last message as the response for synchronous callers
        messages.last || {}
      end

      def capture_session_id(response)
        # Header name can vary in case
        session_id = response["Mcp-Session-Id"] || response["mcp-session-id"]
        @session_id = session_id if session_id
      end

      def run_sse_loop
        attempt = 0

        while @sse_running
          begin
            attempt += 1
            connect_and_stream_sse
            # Successful connection resets attempt counter
            attempt = 0
          rescue StandardError => e
            @on_error&.call(e)

            break unless @sse_running && @reconnect_enabled
            break if attempt >= @max_reconnect_attempts

            delay = calculate_reconnect_delay(attempt)
            sleep(delay)
          end
        end

        @on_close&.call
      end

      def connect_and_stream_sse
        uri = URI(@url)

        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          read_timeout: @read_timeout,
          open_timeout: @open_timeout,
        ) do |http|
          req = Net::HTTP::Get.new(uri)
          req["Accept"] = "text/event-stream"
          req["Cache-Control"] = "no-cache"

          @headers.each { |key, value| req[key] = value }
          req["Mcp-Session-Id"] = @session_id if @session_id
          req["Last-Event-ID"] = @last_event_id if @last_event_id

          http.request(req) do |response|
            case response.code.to_i
            when 200
              stream_sse_response(response)
            when 405
              # Server doesn't support SSE GET endpoint - this is acceptable per spec
              @sse_running = false
            else
              raise "SSE connection failed: #{response.code} #{response.message}"
            end
          end
        end
      end

      def stream_sse_response(response)
        parser = SSEParser.new

        response.read_body do |chunk|
          break unless @sse_running

          chunk.each_line do |line|
            event = parser.parse_line(line)
            next unless event

            update_last_event_id(event.id) if event.id

            if event.retry
              @server_retry_ms = event.retry
            end

            next if event.data.empty?

            begin
              message = JSON.parse(event.data)
              @on_message&.call(message)
            rescue JSON::ParserError
              # Skip non-JSON events
            end
          end
        end
      end

      def update_last_event_id(event_id)
        @mutex.synchronize { @last_event_id = event_id }
        @on_resumption_token&.call(event_id)
      end

      def calculate_reconnect_delay(attempt)
        if @server_retry_ms
          # Server specified retry delay in milliseconds
          return @server_retry_ms / 1000.0
        end

        delay = @initial_reconnect_delay * (@reconnect_grow_factor**(attempt - 1))
        [delay, @max_reconnect_delay].min
      end

      def raise_request_error(error, method, params)
        error_type = case error
        when Net::HTTPClientException
          :bad_request
        else
          :internal_error
        end

        raise RequestHandlerError.new(
          "Error handling #{method} request: #{error.message}",
          { method: method, params: params },
          error_type: error_type,
          original_error: error,
        )
      end
    end
  end
end
