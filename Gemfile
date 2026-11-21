# frozen_string_literal: true

source "https://rubygems.org"

# The gem's own dependencies: sattleme-checkout.gemspec.
gemspec

# The tools of `bundle exec rake`, each pinned exactly (Gemfile.lock pins their dependencies, with
# their checksums). No version younger than a week is taken: time for a compromised release to be
# found and yanked first (`bundle lock --update --cooldown 7`; Dependabot proposes the newer ones
# with the same cooldown, .github/dependabot.yml). The cooldown is never set in a file Bundler
# reads: the Bundler Dependabot runs may read it otherwise than the CI's.
group :development do
  # Minitest 5: no dependency (minitest 6 needs prism, a C extension, on every Ruby).
  gem "minitest", "5.27.0"
  gem "rake", "13.4.2"
end

# RuboCop, in a group of its own: the CI's test jobs install without it (BUNDLE_WITHOUT=lint).
group :lint do
  gem "rubocop", "1.92.2"
  gem "rubocop-minitest", "0.41.0"
  # RuboCop's dependencies with a C extension, at the versions Ruby 4.0.9 ships (json and prism
  # its default gems, racc a bundled one): on Ruby 4.0.9, the CI's lint job compiles nothing.
  gem "json", "2.18.0"
  gem "parser", "3.3.13.0"
  gem "prism", "1.8.2"
  gem "racc", "1.8.1"
end
