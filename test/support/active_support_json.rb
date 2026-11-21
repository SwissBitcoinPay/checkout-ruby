# frozen_string_literal: true

# What ActiveSupport (every Rails application) adds for `as_json` and `to_json`, as
# active_support/core_ext/object/json.rb of ActiveSupport 8.0 defines it: an object's JSON is its
# instance variables' (instance_values), a Data's and a Struct's are their members', each value's
# in turn; `to_json` writes `as_json`. Loaded only in a process of its own (test/key_test.rb): it
# changes every object, as Rails does.
require "json"

module ActiveSupportJson
  module ToJson
    def to_json(options = nil)
      return super if options.is_a?(::JSON::State)

      ::JSON.generate(as_json)
    end
  end
end

[Enumerable, Object, Array, FalseClass, Float, Hash, Integer, NilClass, String, TrueClass].reverse_each do |klass|
  klass.include(ActiveSupportJson::ToJson)
end

class Object
  def instance_values
    instance_variables.to_h { |ivar| [ivar[1..], instance_variable_get(ivar)] }
  end

  def as_json(options = nil)
    respond_to?(:to_hash) ? to_hash.as_json(options) : instance_values.as_json(options)
  end
end

class Module
  def as_json(_options = nil) = name
end

class Data
  def as_json(options = nil) = to_h.as_json(options)
end

class Struct
  def as_json(options = nil) = to_h.as_json(options)
end

[TrueClass, FalseClass, NilClass, String, Numeric].each do |klass|
  klass.define_method(:as_json) { |_options = nil| self }
end

class Symbol
  def as_json(_options = nil) = name
end

class Float
  def as_json(_options = nil) = finite? ? self : nil
end

module Enumerable
  def as_json(options = nil) = to_a.as_json(options)
end

class Array
  def as_json(options = nil) = map { |value| value.as_json(options) }
end

class Hash
  def as_json(options = nil) = to_h { |name, value| [name.to_s, value.as_json(options)] }
end

[Regexp, IO, Range].each do |klass|
  klass.define_method(:as_json) { |_options = nil| to_s }
end
