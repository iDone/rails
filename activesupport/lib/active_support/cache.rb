require 'benchmark'
require 'active_support/core_ext/benchmark'
require 'active_support/core_ext/exception'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/object/to_param'

module ActiveSupport
  # See ActiveSupport::Cache::Store for documentation.
  module Cache
    autoload :FileStore, 'active_support/cache/file_store'
    autoload :MemoryStore, 'active_support/cache/memory_store'
    autoload :SynchronizedMemoryStore, 'active_support/cache/synchronized_memory_store'
    autoload :MemCacheStore, 'active_support/cache/mem_cache_store'
    autoload :CompressedMemCacheStore, 'active_support/cache/compressed_mem_cache_store'

    module Strategy
      autoload :LocalCache, 'active_support/cache/strategy/local_cache'
    end

    # Creates a new CacheStore object according to the given options.
    #
    # If no arguments are passed to this method, then a new
    # ActiveSupport::Cache::MemoryStore object will be returned.
    #
    # If you pass a Symbol as the first argument, then a corresponding cache
    # store class under the ActiveSupport::Cache namespace will be created.
    # For example:
    #
    #   ActiveSupport::Cache.lookup_store(:memory_store)
    #   # => returns a new ActiveSupport::Cache::MemoryStore object
    #   
    #   ActiveSupport::Cache.lookup_store(:mem_cache_store)
    #   # => returns a new ActiveSupport::Cache::MemCacheStore object
    #
    # Any additional arguments will be passed to the corresponding cache store
    # class's constructor:
    #
    #   ActiveSupport::Cache.lookup_store(:file_store, "/tmp/cache")
    #   # => same as: ActiveSupport::Cache::FileStore.new("/tmp/cache")
    #
    # If the first argument is not a Symbol, then it will simply be returned:
    #
    #   ActiveSupport::Cache.lookup_store(MyOwnCacheStore.new)
    #   # => returns MyOwnCacheStore.new
    def self.lookup_store(*store_option)
      store = store_option.shift
      parameters = store_option

      case store
      when Symbol
        store_class_name = store.to_s.camelize
        store_class = ActiveSupport::Cache.const_get(store_class_name)
        store_class.new(*parameters)
      when nil
        ActiveSupport::Cache::MemoryStore.new
      else
        store
      end
    end

    RAILS_CACHE_ID   = ENV["RAILS_CACHE_ID"]
    RAILS_APP_VERION = ENV["RAILS_APP_VERION"]
    EXPANDED_CACHE   = RAILS_CACHE_ID || RAILS_APP_VERION

    def self.expand_cache_key(key, namespace = nil)
      expanded_cache_key = namespace ? "#{namespace}/" : ""

      if EXPANDED_CACHE
        expanded_cache_key << "#{RAILS_CACHE_ID || RAILS_APP_VERION}/"
      end

      expanded_cache_key <<
        if key.respond_to?(:cache_key)
          key.cache_key
        elsif key.is_a?(Array)
          if key.size > 1
            key.collect { |element| expand_cache_key(element) }.to_param
          else
            key.first.to_param
          end
        elsif key
          key.to_param
        end.to_s

      expanded_cache_key
    end

    # An abstract cache store class. There are multiple cache store
    # implementations, each having its own additional features. See the classes
    # under the ActiveSupport::Cache module, e.g.
    # ActiveSupport::Cache::MemCacheStore. MemCacheStore is currently the most
    # popular cache store for large production websites.
    #
    # ActiveSupport::Cache::Store is meant for caching strings. Some cache
    # store implementations, like MemoryStore, are able to cache arbitrary
    # Ruby objects, but don't count on every cache store to be able to do that.
    #
    #   cache = ActiveSupport::Cache::MemoryStore.new
    #   
    #   cache.read("city")   # => nil
    #   cache.write("city", "Duckburgh")
    #   cache.read("city")   # => "Duckburgh"
    class Store
      cattr_accessor :logger, :instance_writter => false

      attr_reader :silence
      alias :silence? :silence

      def silence!
        @silence = true
        self
      end

      def mute
        previous_silence, @silence = defined?(@silence) && @silence, true
        yield
      ensure
        @silence = previous_silence
      end

      # Set to true if cache stores should be instrumented. By default is false.
      def self.instrument=(boolean)
        Thread.current[:instrument_cache_store] = boolean
      end

      def self.instrument
        Thread.current[:instrument_cache_store] || false
      end

      # Fetches data from the cache, using the given key. If there is data in
      # the cache with the given key, then that data is returned.
      #
      # If there is no such data in the cache (a cache miss occurred), then
      # then nil will be returned. However, if a block has been passed, then
      # that block will be run in the event of a cache miss. The return value
      # of the block will be written to the cache under the given cache key,
      # and that return value will be returned.
      #
      #   cache.write("today", "Monday")
      #   cache.fetch("today")  # => "Monday"
      #   
      #   cache.fetch("city")   # => nil
      #   cache.fetch("city") do
      #     "Duckburgh"
      #   end
      #   cache.fetch("city")   # => "Duckburgh"
      #
      # You may also specify additional options via the +options+ argument.
      # Setting <tt>:force => true</tt> will force a cache miss:
      #
      #   cache.write("today", "Monday")
      #   cache.fetch("today", :force => true)  # => nil
      #
      # Other options will be handled by the specific cache store implementation.
      # Internally, #fetch calls #read, and calls #write on a cache miss.
      # +options+ will be passed to the #read and #write calls.
      #
      # For example, MemCacheStore's #write method supports the +:expires_in+
      # option, which tells the memcached server to automatically expire the
      # cache item after a certain period. This options is also supported by
      # FileStore's #read method. We can use this option with #fetch too:
      #
      #   cache = ActiveSupport::Cache::MemCacheStore.new
      #   cache.fetch("foo", :force => true, :expires_in => 5.seconds) do
      #     "bar"
      #   end
      #   cache.fetch("foo")  # => "bar"
      #   sleep(6)
      #   cache.fetch("foo")  # => nil
      def fetch(key, options = {}, &block)
        if !options[:force] && value = read(key, options)
          value
        elsif block_given?
          result = instrument(:generate, key, options, &block)
          write(key, result, options)
          result
        end
      end

      # Fetches data from the cache, using the given key. If there is data in
      # the cache with the given key, then that data is returned. Otherwise,
      # nil is returned.
      #
      # You may also specify additional options via the +options+ argument.
      # The specific cache store implementation will decide what to do with
      # +options+.
      #
      # For example, FileStore supports the +:expires_in+ option, which
      # makes the method return nil for cache items older than the specified
      # period.
      def read(key, options = nil, &block)
        instrument(:read, key, options, &block)
      end

      # Writes the given value to the cache, with the given key.
      #
      # You may also specify additional options via the +options+ argument.
      # The specific cache store implementation will decide what to do with
      # +options+.
      # 
      # For example, MemCacheStore supports the +:expires_in+ option, which
      # tells the memcached server to automatically expire the cache item after
      # a certain period:
      #
      #   cache = ActiveSupport::Cache::MemCacheStore.new
      #   cache.write("foo", "bar", :expires_in => 5.seconds)
      #   cache.read("foo")  # => "bar"
      #   sleep(6)
      #   cache.read("foo")  # => nil
      def write(key, value, options = nil, &block)
        instrument(:write, key, options, &block)
      end

      def delete(key, options = nil, &block)
        instrument(:delete, key, options, &block)
      end

      def delete_matched(matcher, options = nil, &block)
        instrument(:delete_matched, matcher.inspect, options, &block)
      end

      def exist?(key, options = nil, &block)
        instrument(:exist?, key, options, &block)
      end

      def increment(key, amount = 1)
        if num = read(key)
          write(key, num + amount)
        else
          nil
        end
      end

      def decrement(key, amount = 1)
        if num = read(key)
          write(key, num - amount)
        else
          nil
        end
      end

      private
        def expires_in(options)
          expires_in = options && options[:expires_in]
          raise ":expires_in must be a number" if expires_in && !expires_in.is_a?(Numeric)
          expires_in || 0
        end

        def instrument(operation, key, options, &block)
          log(operation, key, options)

          if self.class.instrument
            payload = { :key => key }
            payload.merge!(options) if options.is_a?(Hash)
            ActiveSupport::Notifications.instrument(:"cache_#{operation}", payload, &block)
          else
            yield
          end
        end

        def log(operation, key, options)
          return unless logger && !silence?
          logger.debug("Cache #{operation}: #{key}#{options ? " (#{options.inspect})" : ""}")
        end
    end
  end
end
