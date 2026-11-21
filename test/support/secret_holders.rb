# frozen_string_literal: true

# Every kind of object of the gem that holds a secret (SPEC.md §27): the integration key, a key
# derived from it, the merchant's registry key, CoinGecko's key; and those secrets, each as its
# bytes. Made from the merchant's app's vector (spec/vectors/app/app.json), for the tests of what
# the representations and serializers of these objects show (test/key_test.rb).
module SecretHolders
  Checkout = Sattleme::Checkout
  Internal = Sattleme::Checkout::Internal

  APP = Internal::Json.parse(File.binread(File.expand_path("../../spec/vectors/app/app.json", __dir__)))
  KEY = APP.fetch("secretKey")
  COINGECKO_KEY = "CG-ThisDemoKeyIsSecret42"
  REGISTRY_KEY = Internal::Crypto.sha256("the merchant's registry key".b)
  LINK_KEY = Internal::Crypto.sha256("a checkout link's key".b)
  LINK_SECRET = Internal::Crypto.sha256("a checkout link's author".b)
  ADDRESS = "bc1p#{"q" * 58}".freeze

  module_function

  # [name, object] of each holder.
  def holders
    integration = Internal::IntegrationKey.parse(KEY)
    registry = Internal::Derive.registry(Internal::Text.hex(REGISTRY_KEY), integration.team_public_key)
    channel = Internal::Channels::Channel.new(
      status: :active, business_name: "Sunrise Bakery", lightning_address: "shop@breez.tips",
      registry_key: REGISTRY_KEY, registry_reader: integration.team_public_key, relays: integration.relays,
      checkout_origin: nil, tolerance: 0, bitcoin_node: nil, updated_at: 100
    )
    merchant = Checkout::Client::MerchantChannel.new(
      business_name: "Sunrise Bakery", lightning_address: "shop@breez.tips", registry: registry,
      relays: integration.relays, checkout_origin: nil, tolerance: 0, bitcoin_node: nil,
      explorer: Internal::CallExplorer.new(nil, Internal::NodeFailures.new, -> { 0 })
    )
    [["Client", Checkout::Client.new(key: KEY, coingecko_api_key: COINGECKO_KEY)],
     ["IntegrationKey", integration], ["Secret", Internal::Secret.new(integration.key)],
     ["Registry", registry], ["Sale", Internal::Derive.sale(integration.key, registry, "ORD-1")],
     ["RestKeys", Internal::Derive.rest_keys(integration.key, "ORD-1", ADDRESS, 1_791_379_000)],
     ["SeenKeys", Internal::Derive.seen_keys(integration.key)], ["Channel", channel],
     ["MerchantChannel", merchant],
     ["Rates::Context", Internal::Rates::Context.new(http: nil, coingecko_api_key: COINGECKO_KEY)],
     ["CheckoutLinks::Keys", Internal::CheckoutLinks.keys(LINK_KEY)],
     ["CheckoutLinks::NewLink", new_link], ["CheckoutLinks::Fragment", fragment]]
  end

  # A checkout link before it is published, with its author's secret.
  def new_link
    Internal::CheckoutLinks::NewLink.new(url: "https://pay.example/pay#c", event: link_event, secret_key: LINK_SECRET)
  end

  # What the fragment of a checkout link names: its link key.
  def fragment
    Internal::CheckoutLinks::Fragment.new(status: :link, author: "ab" * 32, link_key: LINK_KEY, relays: [])
  end

  # A checkout link's event, signed by its author.
  def link_event
    zeros = ->(length) { "\x00".b * length }
    Internal::Events.sign(LINK_SECRET, zeros, created_at: 1_791_378_000, kind: 30_078, tags: [], content: "sealed")
  end

  # The bytes of every secret the holders hold.
  def secrets
    key = Internal::IntegrationKey.parse(KEY).key
    registry = Internal::Derive.registry(Internal::Text.hex(REGISTRY_KEY), APP.fetch("parsed").fetch("team"))
    sale = Internal::Derive.sale(key, registry, "ORD-1")
    rest = Internal::Derive.rest_keys(key, "ORD-1", ADDRESS, 1_791_379_000)
    seen = Internal::Derive.seen_keys(key)
    [key, REGISTRY_KEY, sale.key, sale.secret_key, sale.inner_key, rest.key, rest.secret_key,
     rest.encryption_key, seen.secret_key, seen.address_key, seen.encryption_key, LINK_KEY, LINK_SECRET,
     Internal::CheckoutLinks.keys(LINK_KEY).encryption_key, COINGECKO_KEY.b]
  end

  # The spellings of a secret a text may show: its bytes as they are, in hex, in base64 and
  # base64url, as Ruby inspects them.
  def spellings(secret)
    [secret, Internal::Text.hex(secret), [secret].pack("m0"), Internal::Base64.encode_url(secret),
     secret.b.inspect[1..-2]].map(&:b)
  end

  # The secrets `text` shows, by their index in #secrets.
  def shown_in(text)
    bytes = text.to_s.b
    secrets.each_index.select { |index| spellings(secrets[index]).any? { |spelling| bytes.include?(spelling) } }
  end
end
