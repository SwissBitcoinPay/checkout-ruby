# frozen_string_literal: true

require "uri"

# An HTTP client for tests (the gem's `http_client:`): each URL goes to the route, which answers
# { status:, json: } or { status:, text: } (raises: no answer). Records every request.
class FakeHttp
  Json = Sattleme::Checkout::Internal::Json

  Call = Data.define(:url, :headers)

  def initialize(&route)
    @route = route
    @mutex = Mutex.new
    @calls = []
  end

  def calls = @mutex.synchronize { @calls.dup }

  def get(url, headers:, timeout:, cancellation:)
    raise ArgumentError, "timeout: #{timeout.inspect}" unless timeout.is_a?(Numeric) && timeout.positive?

    @mutex.synchronize { @calls << Call.new(url: url, headers: headers.dup) }
    cancellation.raise_if_cancelled
    answer = @route.call(URI.parse(url))
    body = answer[:bytes] || answer[:text] || Json.generate(answer[:json])
    body = body.b
    # In chunks, as a server sends them.
    body.bytes.each_slice(16_384) { |chunk| yield chunk.pack("C*") } unless body.empty?
    answer[:status] || 200
  end

  # A JSON answer.
  def self.answer(json, status = 200)
    { status: status, json: json }
  end
end
