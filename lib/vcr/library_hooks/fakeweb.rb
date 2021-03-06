require 'vcr/util/version_checker'
require 'fakeweb'
require 'net/http'
require 'vcr/extensions/net_http_response'
require 'vcr/request_handler'
require 'set'

VCR::VersionChecker.new('FakeWeb', FakeWeb::VERSION, '1.3.0', '1.3').check_version!

module VCR
  class LibraryHooks
    module FakeWeb
      class RequestHandler < ::VCR::RequestHandler
        attr_reader :net_http, :request, :request_body, :response_block
        def initialize(net_http, request, request_body = nil, &response_block)
          @net_http, @request, @request_body, @response_block =
           net_http,  request,  request_body,  response_block
          @vcr_response, @recursing = nil, false
        end

        def handle
          super
        ensure
          invoke_after_request_hook(@vcr_response) unless @recursing
        end

        class << self
          def already_seen_requests
            @already_seen_requests ||= Set.new
          end
        end

      private

        def invoke_before_request_hook
          unless self.class.already_seen_requests.include?(request.object_id)
            super
            # we use the object_id so that if there is bug that causes
            # us not to fully cleanup, we'll only be leaking the memory
            # of one integer, not the whole request object.
            self.class.already_seen_requests << request.object_id
          end
        end

        def invoke_after_request_hook(vcr_response)
          self.class.already_seen_requests.delete(request.object_id)
          super
        end

        def on_recordable_request
          perform_request(net_http.started?, :record_interaction)
        end

        def on_stubbed_request
          with_exclusive_fakeweb_stub(stubbed_response) do
            # force it to be considered started since it doesn't
            # recurse in this case like the others.
            perform_request(:started)
          end
        end

        def on_ignored_request
          perform_request(net_http.started?)
        end

        # overriden to prevent it from invoking the after_http_request hook,
        # since we invoke the hook in an ensure block above.
        def on_connection_not_allowed
          raise VCR::Errors::UnhandledHTTPRequestError.new(vcr_request)
        end

        def perform_request(started, record_interaction = false)
          # Net::HTTP calls #request recursively in certain circumstances.
          # We only want to record the request when the request is started, as
          # that is the final time through #request.
          unless started
            @recursing = true
            return net_http.request_without_vcr(request, request_body, &response_block)
          end

          net_http.request_without_vcr(request, request_body) do |response|
            @vcr_response = vcr_response_from(response)

            if record_interaction
              VCR.record_http_interaction VCR::HTTPInteraction.new(vcr_request, @vcr_response)
            end

            response.extend VCR::Net::HTTPResponse # "unwind" the response
            response_block.call(response) if response_block
          end
        end

        def uri
          @uri ||= ::FakeWeb::Utility.request_uri_as_string(net_http, request)
        end

        def response_hash(response)
          (response.headers || {}).merge(
            :body   => response.body,
            :status => [response.status.code.to_s, response.status.message]
          )
        end

        def with_exclusive_fakeweb_stub(response)
          original_map = ::FakeWeb::Registry.instance.uri_map.dup
          ::FakeWeb.clean_registry
          ::FakeWeb.register_uri(:any, /.*/, response_hash(response))

          begin
            return yield
          ensure
            ::FakeWeb::Registry.instance.uri_map = original_map
          end
        end

        def vcr_request
          @vcr_request ||= VCR::Request.new \
            request.method.downcase.to_sym,
            uri,
            request_body,
            request.to_hash
        end

        def vcr_response_from(response)
          VCR::Response.new \
            VCR::ResponseStatus.new(response.code.to_i, response.message),
            response.to_hash,
            response.body,
            response.http_version
        end
      end
    end
  end
end

module Net
  class HTTP
    unless method_defined?(:request_with_vcr)
      def request_with_vcr(*args, &block)
        VCR::LibraryHooks::FakeWeb::RequestHandler.new(
          self, *args, &block
        ).handle
      end

      alias request_without_vcr request
      alias request request_with_vcr
    end
  end
end

VCR.configuration.after_library_hooks_loaded do
  if defined?(WebMock)
    raise ArgumentError.new("You have configured VCR to hook into both :fakeweb and :webmock. You cannot use both.")
  end
end

