#!/bin/sh
# Installs Gemfile.lock as it is (BUNDLE_FROZEN), its checksums checked, compiling nothing: the job
# needs no C compiler.
#
#   .github/ci/bundle.sh tests   the gems of the tests and the package (the job sets
#                                BUNDLE_WITHOUT=lint): none has a C extension to build (ffi's
#                                is prebuilt for x86_64-linux-gnu)
#   .github/ci/bundle.sh lint    every gem, on Ruby 4.0.9: RuboCop's json and prism are its default
#                                gems, racc a bundled one, at the versions the Gemfile pins. Bundler
#                                would still fetch and build the default ones, so every gem is
#                                fetched first (`bundle cache`), the .gem of those two set aside,
#                                then the bundle installed from there alone (`--local`): Bundler
#                                then uses Ruby's own.
set -eu
: "${RUNNER_TEMP:?}" "${GEM_HOME:?}"

case ${1:-} in
  tests)
    bundle install
    ;;
  lint)
    cache="$RUNNER_TEMP/gem-cache"
    BUNDLE_CACHE_PATH="$cache" bundle cache --no-install
    rm -f "$cache"/json-*.gem "$cache"/prism-*.gem "$GEM_HOME"/cache/json-*.gem "$GEM_HOME"/cache/prism-*.gem
    BUNDLE_CACHE_PATH="$cache" bundle install --local
    ;;
  *)
    echo "Usage: $0 tests|lint" >&2
    exit 2
    ;;
esac
bundle list
