# frozen_string_literal: true

require "rspec/core"
require "rspec/expectations"

require "net/http"
require "openssl"
require "websocket"

require_relative "tracer"
require_relative "network"
require_relative "object"
require_relative "session"
require_relative "reporter"
require_relative "ci"

require "active_support"
require "active_support/notifications"

require "securerandom"

module RSpec::Buildkite::Analytics
  class Uploader
    class Trace
      attr_accessor :example, :failure_reason, :failure_expanded
      attr_reader :id, :history

      def initialize(example, history)
        @id = SecureRandom.uuid
        @example = example
        @history = history
        @failure_reason = nil
        @failure_expanded = []
      end

      def result_state
        case example.execution_result.status
        when :passed; "passed"
        when :failed; "failed"
        when :pending; "skipped"
        end
      end

      def as_hash
        strip_invalid_utf8_chars(
          id: @id,
          scope: example.example_group.metadata[:full_description],
          name: example.description,
          identifier: example.id,
          location: example.location,
          file_name: generate_file_name(example),
          result: result_state,
          failure_reason: failure_reason,
          failure_expanded: failure_expanded,
          history: history,
        ).with_indifferent_access.compact
      end

      private

      def generate_file_name(example)
        file_path_regex = /^(.*?\.(rb|feature))/
        identifier_file_name = strip_invalid_utf8_chars(example.id)[file_path_regex]
        location_file_name = example.location[file_path_regex]

        if identifier_file_name != location_file_name
          # If the identifier and location files are not the same, we assume
          # that the test was run as part of a shared example. If this isn't the
          # case, then there's something we haven't accounted for
          if example.metadata[:shared_group_inclusion_backtrace].any?
            # Taking the last frame in this backtrace will give us the original
            # entry point for the shared example
            example.metadata[:shared_group_inclusion_backtrace].last.inclusion_location[file_path_regex]
          else
            "Unknown"
          end
        else
          identifier_file_name
        end
      end

      def strip_invalid_utf8_chars(object)
        if object.is_a?(Hash)
          Hash[object.map { |key, value| [key, strip_invalid_utf8_chars(value)] }]
        elsif object.is_a?(Array)
          object.map { |value| strip_invalid_utf8_chars(value) }
        elsif object.is_a?(String)
          object.encode('UTF-8', :invalid => :replace, :undef => :replace)
        else
          object
        end
      end
    end

    def self.traces
      @traces ||= []
    end

    REQUEST_EXCEPTIONS = [
      URI::InvalidURIError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      Net::ReadTimeout,
      Net::OpenTimeout,
      OpenSSL::SSL::SSLError,
      OpenSSL::SSL::SSLErrorWaitReadable,
      EOFError
    ]

    def self.configure
      RSpec::Buildkite::Analytics.uploader = self

      RSpec.configure do |config|
        config.before(:suite) do
          config.add_formatter RSpec::Buildkite::Analytics::Reporter

          if RSpec::Buildkite::Analytics.api_token
            contact_uri = URI.parse(RSpec::Buildkite::Analytics.url)

            http = Net::HTTP.new(contact_uri.host, contact_uri.port)
            http.use_ssl = contact_uri.scheme == "https"

            authorization_header = "Token token=\"#{RSpec::Buildkite::Analytics.api_token}\""

            contact = Net::HTTP::Post.new(contact_uri.path, {
              "Authorization" => authorization_header,
              "Content-Type" => "application/json",
            })
            contact.body = {
              run_env: CI.env,
              format: "websocket"
            }.to_json

            response = begin
              http.request(contact)
            rescue *REQUEST_EXCEPTIONS => e
              puts "Buildkite Test Analytics: Error communicating with the server: #{e.message}"
            end

            return unless response

            case response.code
            when "401"
              puts "Buildkite Test Analytics: Invalid Suite API key. Please double check your Suite API key."
            when "200"
              json = JSON.parse(response.body)

              if (socket_url = json["cable"]) && (channel = json["channel"])
                RSpec::Buildkite::Analytics.session = Session.new(socket_url, authorization_header, channel)
              end
            else
              request_id = response.to_hash["x-request-id"]
              puts "rspec-buildkite-analytics could not establish an initial connection with Buildkite. You may be missing some data for this test suite, please contact support."
            end
          else
            if !!ENV["BUILDKITE_BUILD_ID"]
              puts "Buildkite Test Analytics: No Suite API key provided. You can get the API key from your Suite settings page."
            end
          end
        end

        config.around(:each) do |example|
          tracer = RSpec::Buildkite::Analytics::Tracer.new

          # The _buildkite prefix here is added as a safeguard against name collisions
          # as we are in the main thread
          Thread.current[:_buildkite_tracer] = tracer
          example.run
          Thread.current[:_buildkite_tracer] = nil

          tracer.finalize

          trace = RSpec::Buildkite::Analytics::Uploader::Trace.new(example, tracer.history)
          RSpec::Buildkite::Analytics.uploader.traces << trace
        end
      end

      RSpec::Buildkite::Analytics::Network.configure
      RSpec::Buildkite::Analytics::Object.configure

      ActiveSupport::Notifications.subscribe("sql.active_record") do |name, start, finish, id, payload|
        tracer&.backfill(:sql, finish - start, **{ query: payload[:sql] })
      end
    end

    def self.tracer
      Thread.current[:_buildkite_tracer]
    end
  end
end
