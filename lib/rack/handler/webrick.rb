# frozen_string_literal: true

require 'webrick'
require 'stringio'

require_relative '../constants'
require_relative '../version'

# This monkey patch allows for applications to perform their own chunking
# through WEBrick::HTTPResponse if rack is set to true.
class WEBrick::HTTPResponse
  attr_accessor :rack

  alias _rack_setup_header setup_header
  def setup_header
    app_chunking = rack && @header['transfer-encoding'] == 'chunked'

    @chunked = app_chunking if app_chunking

    _rack_setup_header

    @chunked = false if app_chunking
  end
end

module Rack
  module Handler
    class WEBrick < ::WEBrick::HTTPServlet::AbstractServlet
      def self.run(app, **options)
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : nil

        if !options[:BindAddress] || options[:Host]
          options[:BindAddress] = options.delete(:Host) || default_host
        end
        options[:Port] ||= 8080
        if options[:SSLEnable]
          require 'webrick/https'
        end

        @server = ::WEBrick::HTTPServer.new(options)
        @server.mount "/", Rack::Handler::WEBrick, app
        yield @server if block_given?
        @server.start
      end

      def self.valid_options
        environment  = ENV['RACK_ENV'] || 'development'
        default_host = environment == 'development' ? 'localhost' : '0.0.0.0'

        {
          "Host=HOST" => "Hostname to listen on (default: #{default_host})",
          "Port=PORT" => "Port to listen on (default: 8080)",
        }
      end

      def self.shutdown
        if @server
          @server.shutdown
          @server = nil
        end
      end

      def initialize(server, app)
        super server
        @app = app
      end

      def service(req, res)
        res.rack = true
        env = req.meta_vars
        env.delete_if { |k, v| v.nil? }

        rack_input = StringIO.new(req.body.to_s)
        rack_input.set_encoding(Encoding::BINARY)

        env.update(
          RACK_VERSION      => Rack::VERSION,
          RACK_INPUT        => rack_input,
          RACK_ERRORS       => $stderr,
          RACK_URL_SCHEME   => ["yes", "on", "1"].include?(env[HTTPS]) ? "https" : "http",
          RACK_IS_HIJACK    => true,
          RACK_HIJACK       => lambda { raise NotImplementedError, "only partial hijack is supported."},
          RACK_HIJACK_IO    => nil
        )

        env[QUERY_STRING] ||= ""
        unless env[PATH_INFO] == ""
          path, n = req.request_uri.path, env[SCRIPT_NAME].length
          env[PATH_INFO] = path[n, path.length - n]
        end
        env[REQUEST_PATH] ||= [env[SCRIPT_NAME], env[PATH_INFO]].join

        status, headers, body = @app.call(env)
        begin
          res.status = status.to_i
          io_lambda = nil
          headers.each { |key, value|
            if key == RACK_HIJACK
              io_lambda = value
            elsif key == "set-cookie"
              res.cookies.concat(Array(value))
            else
              # Since WEBrick won't accept repeated headers,
              # merge the values per RFC 1945 section 4.2.
              res[key] = Array(value).join(", ")
            end
          }

          if io_lambda
            rd, wr = IO.pipe
            res.body = rd
            res.chunked = true
            io_lambda.call wr
          elsif body.respond_to?(:to_path)
            res.body = ::File.open(body.to_path, 'rb')
          else
            body.each { |part|
              res.body << part
            }
          end
        ensure
          body.close  if body.respond_to? :close
        end
      end
    end
  end
end
