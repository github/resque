require 'multi_json'

# OkJson won't work because it doesn't serialize symbols
# in the same way yajl and json do.
if MultiJson.engine.to_s == 'MultiJson::Engines::OkJson'
  raise "Please install the yajl-ruby or json gem"
end

module Resque
  # Methods used by various classes in Resque.
  module Helpers
    class DecodeException < StandardError; end

    # Direct access to the Redis instance.
    def redis
      Resque.redis
    end

    # Given a Ruby object, returns a string suitable for storage in a
    # queue.
    def encode(object)
      ::MultiJson.encode(object)
    end

    # Given a string, returns a Ruby object.
    def decode(object)
      return unless object

      begin
        ::MultiJson.decode(object)
      rescue ::MultiJson::DecodeError => e
        raise DecodeException, e.message, e.backtrace
      end
    end

    # Given a word with dashes, returns a camel cased version of it.
    #
    # classify('job-name') # => 'JobName'
    def classify(dashed_word)
      dashed_word.split('-').each { |part| part[0] = part[0].chr.upcase }.join
    end

    # Tries to find a constant with the name specified in the argument string:
    #
    # constantize("Module") # => Module
    # constantize("Test::Unit") # => Test::Unit
    #
    # The name is assumed to be the one of a top-level constant, no matter
    # whether it starts with "::" or not. No lexical context is taken into
    # account:
    #
    # C = 'outside'
    # module M
    #   C = 'inside'
    #   C # => 'inside'
    #   constantize("C") # => 'outside', same as ::C
    # end
    #
    # NameError is raised when the constant is unknown.
    def constantize(camel_cased_word)
      camel_cased_word = camel_cased_word.to_s

      if camel_cased_word.include?('-')
        camel_cased_word = classify(camel_cased_word)
      end

      names = camel_cased_word.split('::')
      names.shift if names.empty? || names.first.empty?

      constant = Object
      names.each do |name|
        args = Module.method(:const_get).arity != 1 ? [false] : []

        if constant.const_defined?(name, *args)
          constant = constant.const_get(name)
        else
          constant = constant.const_missing(name)
        end
      end
      constant
    end

    # Retry a limited number of times if we encounter a Redis::TimeoutError.
    # These errors can happen when:
    #  * Redis goes away.
    #  * We failover through a proxy layer.
    #  * Redis accepts connections but does not respond, which can happen
    #    if Redis CPU utilization is high.
    def with_retries(retries: 3)
      yield
    rescue Redis::TimeoutError => e
      reconnected = false
      while retries > 0
        # Wait for a random time to reduce thundering reconnect herds.
        sleep rand * 3
        retries -= 1
        if Resque.reconnect(1)
          reconnected = true
          break
        end
      end

      if reconnected
        retry
      else
        raise e
      end
    end
  end
end
