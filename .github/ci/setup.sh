#!/bin/sh
# Sets up a job without root (no sudo, no apt), without a Ruby of the runner's, nor a C compiler:
# what it downloads has its SHA-256 checked, and nothing is compiled nor installed outside the job's
# own directory ($RUNNER_TEMP).
#
#   .github/ci/setup.sh <Ruby version> <SHA-256 of its archive>
#
# - Ruby, prebuilt by ruby/ruby-builder for Ubuntu 24.04 x64 (setup-ruby's own builds). They are
#   built for /opt/hostedtoolcache (where setup-ruby installs them, writing outside the job's own
#   directory): this one runs from $RUNNER_TEMP instead, given its libruby
#   (LD_LIBRARY_PATH) and its standard library (RUBYLIB); RbConfig and RubyGems find the rest from
#   where they are, and its scripts' shebangs are rewritten to the Ruby of the PATH.
# - libsecp256k1 of Ubuntu 24.04 (0.2.0, the oldest version the gem supports), as `apt install
#   libsecp256k1-1` installs it, extracted from its package without installing it.
# - Bundler of Gemfile.lock's BUNDLED WITH, from its .gem.
#
# Gems go to GEM_HOME, in $RUNNER_TEMP (the job's first step sets it): never in HOME, outside the
# job's own directory.
set -eu

ruby_version=$1
ruby_sha256=$2
: "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}" "${GITHUB_PATH:?}" "${GEM_HOME:?}"
: "${SECP256K1_DEB:?}" "${SECP256K1_DEB_SHA256:?}" "${BUNDLER_VERSION:?}" "${BUNDLER_SHA256:?}"

download() { # <url> <sha256> <file>
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

archive="$RUNNER_TEMP/ruby-$ruby_version.tar.gz"
download "https://github.com/ruby/ruby-builder/releases/download/ruby-$ruby_version/ruby-$ruby_version-ubuntu-24.04-x64.tar.gz" \
  "$ruby_sha256" "$archive"
mkdir -p "$RUNNER_TEMP/ruby"
tar -xzf "$archive" -C "$RUNNER_TEMP/ruby"
rm "$archive"
prefix="$RUNNER_TEMP/ruby/x64"
lib="$prefix/lib/ruby"
abi=$(basename "$(find "$lib" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*.[0-9]*.[0-9]*')")
arch=x86_64-linux
for script in "$prefix"/bin/*; do
  if head -n 1 "$script" | grep -q '^#!.*/ruby$'; then
    sed -i '1s|^#!.*$|#!/usr/bin/env ruby|' "$script"
  fi
done
export LD_LIBRARY_PATH="$prefix/lib"
export RUBYLIB="$lib/site_ruby/$abi:$lib/site_ruby/$abi/$arch:$lib/site_ruby:$lib/vendor_ruby/$abi:$lib/vendor_ruby/$abi/$arch:$lib/vendor_ruby:$lib/$abi:$lib/$abi/$arch"
export GEM_PATH="$GEM_HOME:$lib/gems/$abi"
export PATH="$GEM_HOME/bin:$prefix/bin:$PATH"
{
  echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
  echo "RUBYLIB=$RUBYLIB"
  echo "GEM_PATH=$GEM_PATH"
} >> "$GITHUB_ENV"
# Each line is put first in PATH, in this order: GEM_HOME's executables (Bundler's) before Ruby's.
{
  echo "$prefix/bin"
  echo "$GEM_HOME/bin"
} >> "$GITHUB_PATH"

deb="$RUNNER_TEMP/libsecp256k1.deb"
download "$SECP256K1_DEB" "$SECP256K1_DEB_SHA256" "$deb"
dpkg-deb -x "$deb" "$RUNNER_TEMP/secp256k1"
rm "$deb"
library=$(find "$RUNNER_TEMP/secp256k1" -name 'libsecp256k1.so.*' -type f | head -n 1)
echo "SATTLEME_SECP256K1_LIBRARY=$library" >> "$GITHUB_ENV"

gem="$RUNNER_TEMP/bundler-$BUNDLER_VERSION.gem"
download "https://rubygems.org/downloads/bundler-$BUNDLER_VERSION.gem" "$BUNDLER_SHA256" "$gem"
gem install --local --no-document "$gem"
rm "$gem"

ruby -v
ruby -ropenssl -e 'puts OpenSSL::OPENSSL_LIBRARY_VERSION'
bundle -v
echo "libsecp256k1: $library"
