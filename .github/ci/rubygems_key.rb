# frozen_string_literal: true

# Trusted publishing: exchanges this job's GitHub OIDC token for a short-lived RubyGems.org key
# (push only, 15 minutes), naming the account that owns the gem (RUBYGEMS_OWNER, its immutable
# ID). RubyGems.org creates a new gem from a pending trusted publisher only when the exchange
# names the account whose publisher it is, and neither rubygems/release-gem nor
# rubygems/configure-rubygems-credentials sends it yet
# (https://github.com/rubygems/configure-rubygems-credentials/issues/489). For a gem that exists,
# RubyGems.org does not use it.
#
# The key is masked, then given to the next steps as configure-rubygems-credentials gives it:
# GEM_HOST_API_KEY, RUBYGEMS_API_KEY and BUNDLE_GEM__PUSH_KEY, and ~/.gem/credentials (0600).
# Neither the OIDC token nor the key is ever printed.
#
#   RUBYGEMS_OWNER=<the account's ID> ruby .github/ci/rubygems_key.rb
#
# The job needs `id-token: write` (ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN) and runs it on
# GitHub Actions only (GITHUB_ENV).

require "json"
require "net/http"
require "uri"

SERVER = "https://rubygems.org"
AUDIENCE = "rubygems.org"
# A key is plain visible ASCII: anything else could not be written in GITHUB_ENV as one line.
KEY_FORMAT = /\A[[:graph:]]{16,256}\z/

# The mask reaches the runner before anything else this script prints.
$stdout.sync = true

def fail!(message)
  warn "::error::#{message}"
  exit 1
end

def env!(name)
  value = ENV.fetch(name, "")
  fail!("#{name} is not set") if value.empty?
  value
end

def call(uri, request)
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 30) do |http|
    http.request(request)
  end
rescue StandardError => e
  fail!("#{uri.host} did not answer: #{e.class}")
end

# What a failed answer says, never a successful one's body (it would hold the key).
def failure(response)
  "#{response.code} #{response.body.to_s[0, 1000].gsub(/\s+/, ' ')}"
end

def oidc_token
  uri = URI(env!("ACTIONS_ID_TOKEN_REQUEST_URL"))
  uri.query = [uri.query, URI.encode_www_form(audience: AUDIENCE)].compact.join("&")
  request = Net::HTTP::Get.new(uri)
  request["Authorization"] = "bearer #{env!('ACTIONS_ID_TOKEN_REQUEST_TOKEN')}"
  request["Accept"] = "application/json"
  response = call(uri, request)
  fail!("GitHub gave no OIDC token: #{response.code}") unless response.is_a?(Net::HTTPSuccess)

  token = JSON.parse(response.body)["value"]
  fail!("GitHub gave no OIDC token") unless token.is_a?(String) && !token.empty?
  token
rescue JSON::ParserError
  fail!("GitHub gave no OIDC token")
end

def exchange(jwt, owner)
  uri = URI("#{SERVER}/api/v1/oidc/trusted_publisher/exchange_token")
  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/json"
  request["Accept"] = "application/json"
  request.body = JSON.generate(jwt: jwt, owner: owner)
  response = call(uri, request)
  fail!("RubyGems.org refused the exchange: #{failure(response)}") unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue JSON::ParserError
  fail!("RubyGems.org's answer is not JSON")
end

owner = env!("RUBYGEMS_OWNER")
# An immutable ID only: a handle can be renamed, then taken by another account.
fail!("RUBYGEMS_OWNER is not a RubyGems.org account ID (digits only)") unless owner.match?(/\A\d+\z/)
github_env = env!("GITHUB_ENV")

answer = exchange(oidc_token, owner)
key = answer["rubygems_api_key"]
# Checked before it is printed even as a mask: a line break in it would start a line of its own.
unless key.is_a?(String) && key.match?(KEY_FORMAT)
  fail!("RubyGems.org's answer holds no key in the expected format")
end
# Masked first, before it is written anywhere.
puts "::add-mask::#{key}"

File.open(github_env, "a") do |file|
  %w[GEM_HOST_API_KEY RUBYGEMS_API_KEY BUNDLE_GEM__PUSH_KEY].each { |name| file.puts("#{name}=#{key}") }
end
directory = File.join(Dir.home, ".gem")
Dir.mkdir(directory, 0o700) unless Dir.exist?(directory)
credentials = File.join(directory, "credentials")
File.open(credentials, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
  file.write("---\n:rubygems_api_key: #{key}\n")
end
File.chmod(0o600, credentials)

puts "RubyGems.org key: #{answer['name']}, scopes #{Array(answer['scopes']).join(', ')}, " \
     "owner #{answer['owner'] || '(none)'}, expires #{answer['expires_at']}"
