# frozen_string_literal: true

module Syspro
  # This class is the main syspro client
  class SysproClient # rubocop:disable Metrics/ClassLength
    attr_accessor :conn, :api_base

    @verify_ssl_warned = false

    def initialize(conn = nil)
      self.conn = conn || self.class.default_conn
      @system_profiler = SystemProfiler.new
    end

    def logon(username, password, company_id, company_password)
      Syspro::Logon.logon(username, password, company_id, company_password)
    end

    def get_syspro_version # rubocop:disable Naming/AccessorMethodName
      Syspro::GetVersion.get_version
    end

    def self.active_client
      Thread.current[:syspro_client] || default_client
    end

    def self.default_client
      Thread.current[:syspro_client_default_client] ||= SysproClient.new(default_conn) # rubocop:disable Metrics/LineLength
    end

    # A default Faraday connection to be used when one isn't configured. This
    # object should never be mutated, and instead instantiating your own
    # connection and wrapping it in a SysproClient object should be preferred.
    def self.default_conn # rubocop:disable Metrics/MethodLength
      # We're going to keep connections around so that we can take advantage
      # of connection re-use, so make sure that we have a separate connection
      # object per thread.
      Thread.current[:syspro_client_default_conn] ||= begin
        conn = Faraday.new do |c|
          c.use Faraday::Request::Multipart
          c.use Faraday::Request::UrlEncoded
          c.use Faraday::Response::RaiseError
          c.adapter Faraday.default_adapter
        end

        # For now, we're not verifying SSL certificates.
        # The warning will appear.
        # if Syspro.verify_ssl_certs
        # conn.ssl.verify = true
        # conn.ssl.cert_store = Syspro.ca_store
        # else
        conn.ssl.verify = false

        unless @verify_ssl_warned
          @verify_ssl_warned = true
          warn('WARNING: Running without SSL cert verification. ' \
            'You should never do this in production. ' \
            "Execute 'Syspro.verify_ssl_certs = true' to enable verification.")
        end
        # end

        conn
      end
    end

    # Executes the API call within the given block. Usage looks like:
    #
    #     client = SysproClient.new
    #     charge, resp = client.request { Charge.create }
    #
    def request
      @last_response = nil
      old_syspro_client = Thread.current[:syspro_client]
      Thread.current[:syspro_client] = self

      begin
        res = yield
        [res, @last_response]
      ensure
        Thread.current[:syspro_client] = old_syspro_client
      end
    end

    def execute_request(method, path, user_id: nil, api_base: nil, headers: {}, params: {}) # rubocop:disable Metrics/LineLength, Metrics/MethodLength
      api_base ||= Syspro.api_base
      user_id  ||= ''

      params = Util.objects_to_ids(params)
      url = api_url(path, api_base)

      body = nil
      query_params = nil

      case method.to_s.downcase.to_sym
      when :get, :head, :delete
        query_params = params
      else
        body = if headers[:content_type] && headers[:content_type] == 'multipart/form-data' # rubocop:disable Metrics/LineLength
                 params
               else
                 Util.encode_parameters(params)
               end
      end

      headers = request_headers(method)
                .update(Util.normalize_headers(headers))

      # stores information on the request we're about to make so that we don't
      # have to pass as many parameters around for logging.
      context = RequestLogContext.new
      context.body            = body
      context.method          = method
      context.path            = path
      context.user_id         = user_id
      context.query_params    = query_params ? Util.encode_parameters(query_params) : nil # rubocop:disable Metrics/LineLength

      http_resp = execute_request_with_rescues(api_base, context) do
        conn.run_request(method, url, body, headers) do |req|
          req.options.open_timeout = Syspro.configuration.open_timeout
          req.options.timeout = Syspro.configuration.read_timeout
          req.params = query_params unless query_params.nil?
        end
      end

      begin
        resp = SysproResponse.from_faraday_response(http_resp)
      rescue JSON::ParserError
        raise general_api_error(http_resp.status, http_resp.body)
      end

      # Allows SysproClient#request to return a response object to a caller.
      @last_response = resp
      [resp]
    end

    def general_api_error(status, body)
      ApiError.new("Invalid response object from API: #{body.inspect} " \
                   "(HTTP response code was #{status})",
                   http_status: status, http_body: body)
    end

    def api_url(url = '', api_base = nil)
      (api_base || Syspro.api_base) + url
    end

    def request_headers(_method)
      user_agent = "Syspro/7 RubyBindings/#{Syspro::VERSION}"

      headers = {
        'User-Agent' => user_agent,
        'Content-Type' => 'application/x-www-form-urlencoded'
      }

      headers
    end

    def execute_request_with_rescues(api_base, context) # rubocop:disable Metrics/LineLength, Metrics/MethodLength
      num_retries = 0
      begin
        request_start = Time.now
        log_request(context, num_retries)
        resp = yield
        log_response(context, request_start, resp.status, resp.body)

      # We rescue all exceptions from a request so that we have an easy spot to
      # implement our retry logic across the board. We'll re-raise if it's a
      # type of exception that we didn't expect to handle.
      rescue StandardError => e
        if e.respond_to?(:response) && e.response
          log_response(context, request_start,
                       e.response[:status], e.response[:body])
        else
          log_response_error(context, request_start, e)
        end

        if self.class.should_retry?(e, num_retries)
          num_retries += 1
          sleep self.class.sleep_time(num_retries)
          retry
        end

        case e
        when Faraday::ClientError
          if e.response
            handle_error_response(e.response, context)
          else
            handle_network_error(e, context, num_retries, api_base)
          end

        # Only handle errors when we know we can do so, and re-raise otherwise.
        # This should be pretty infrequent.
        else
          raise
        end
      end

      resp
    end

    def handle_network_error(e, context, num_retries, api_base = nil) # rubocop:disable Metrics/LineLength, Metrics/MethodLength, Naming/UncommunicativeMethodParamName
      Util.log_error('Syspro network error',
                     error_message: e.message,
                     request_id: context.request_id)

      case e
      when Faraday::ConnectionFailed
        message = 'Unexpected error communicating when trying to connect to Syspro.' # rubocop:disable Metrics/LineLength

      when Faraday::SSLError
        message = 'Could not establish a secure connection to Syspro.'

      when Faraday::TimeoutError
        api_base ||= Syspro.api_base
        message = "Could not connect to Syspro (#{api_base}). " \
          'Please check your internet connection and try again. ' \
          'If this problem persists, you should check your Syspro service status.' # rubocop:disable Metrics/LineLength

      else
        message = 'Unexpected error communicating with Syspro. ' \
          'If this problem persists, talk to your Syspro implementation team.'

      end

      message += " Request was retried #{num_retries} times." if num_retries.positive? # rubocop:disable Metrics/LineLength

      raise ApiConnectionError, message + "\n\n(Network error: #{e.message})"
    end

    def self.should_retry?(e, num_retries) # rubocop:disable Metrics/LineLength, Naming/UncommunicativeMethodParamName
      return false if num_retries >= Syspro.max_network_retries

      # Retry on timeout-related problems (either on open or read).
      return true if e.is_a?(Faraday::TimeoutError)

      # Destination refused the connection, the connection was reset, or a
      # variety of other connection failures. This could occur from a single
      # saturated server, so retry in case it's intermittent.
      return true if e.is_a?(Faraday::ConnectionFailed)

      if e.is_a?(Faraday::ClientError) && e.response
        # 409 conflict
        return true if e.response[:status] == 409
      end

      false
    end

    def log_request(context, num_retries)
      Util.log_info('Request to Syspro API',
                    account: context.account,
                    api_version: context.api_version,
                    method: context.method,
                    num_retries: num_retries,
                    path: context.path)
      Util.log_debug('Request details',
                     body: context.body,
                     query_params: context.query_params)
    end
    private :log_request

    def log_response(context, request_start, status, body) # rubocop:disable Metrics/LineLength, Metrics/MethodLength
      Util.log_info('Response from Syspro API',
                    account: context.account,
                    api_version: context.api_version,
                    elapsed: Time.now - request_start,
                    method: context.method,
                    path: context.path,
                    request_id: context.request_id,
                    status: status)
      Util.log_debug('Response details',
                     body: body,
                     request_id: context.request_id)
    end
    private :log_response

    def log_response_error(context, request_start, e) # rubocop:disable Metrics/LineLength, Naming/UncommunicativeMethodParamName
      Util.log_error('Request error',
                     elapsed: Time.now - request_start,
                     error_message: e.message,
                     method: context.method,
                     path: context.path)
    end
    private :log_response_error

    def handle_error_response(http_resp, context) # rubocop:disable Metrics/LineLength, Metrics/MethodLength
      begin
        resp = SysproResponse.from_faraday_hash(http_resp)
        error_data = resp.data[:error]

        raise SysproError, 'Indeterminate error' unless error_data
      rescue Nokogiri::XML::SyntaxError, SysproError
        raise general_api_error(http_resp[:status], http_resp[:body])
      end

      error = if error_data.is_a?(String)
                specific_oauth_error(resp, error_data, context)
              else
                specific_api_error(resp, error_data, context)
              end

      error.response = resp
      raise(error)
    end

    # RequestLogContext stores information about a request that's begin made so
    # that we can log certain information. It's useful because it means that we
    # don't have to pass around as many parameters.
    class RequestLogContext
      attr_accessor :body
      attr_accessor :account
      attr_accessor :api_version
      attr_accessor :method
      attr_accessor :path
      attr_accessor :query_params
      attr_accessor :request_id
      attr_accessor :user_id
    end

    # SystemProfiler extracts information about the system that we're running
    # in so that we can generate a rich user agent header to help debug
    # integrations.
    class SystemProfiler
      def self.uname # rubocop:disable Metrics/MethodLength
        if File.exist?('/proc/version')
          File.read('/proc/version').strip
        else
          case RbConfig::CONFIG['host_os']
          when /linux|darwin|bsd|sunos|solaris|cygwin/i
            uname_from_system
          when /mswin|mingw/i
            uname_from_system_ver
          else
            'unknown platform'
          end
        end
      end

      def self.uname_from_system
        (`uname -a 2>/dev/null` || '').strip
      rescue Errno::ENOENT
        'uname executable not found'
      rescue Errno::ENOMEM # couldn't create subprocess
        'uname lookup failed'
      end

      def self.uname_from_system_ver
        (`ver` || '').strip
      rescue Errno::ENOENT
        'ver executable not found'
      rescue Errno::ENOMEM # couldn't create subprocess
        'uname lookup failed'
      end

      def initialize
        @uname = self.class.uname
      end

      def user_agent # rubocop:disable Metrics/MethodLength
        lang_version = "#{RUBY_VERSION} p#{RUBY_PATCHLEVEL} (#{RUBY_RELEASE_DATE})" # rubocop:disable Metrics/LineLength

        {
          application: Syspro.app_info,
          bindings_version: Syspro::VERSION,
          lang: 'ruby',
          lang_version: lang_version,
          platform: RUBY_PLATFORM,
          engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : '',
          uname: @uname,
          hostname: Socket.gethostname
        }.delete_if { |_k, v| v.nil? }
      end
    end
  end
end
