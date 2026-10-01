require "flipper/adapter"
require "flipper/typecast"

module Flipper
  module Adapters
    # Public: Adapter for storing everything in memory.
    # Useful for tests/specs.
    class Memory
      include ::Flipper::Adapter

      # Private: Shared frozen config for unknown features. Gate values
      # returned by get are treated as read-only.
      DEFAULT_CONFIG = default_config.each_value(&:freeze).freeze

      # Private: Keys in the feature config that hold explicit deny lists.
      # They are stored outside of default_config so adapters that do not
      # support deny lists are unaffected, and they survive enable(true),
      # disable and clear so safety records are never dropped accidentally.
      DENY_KEYS = %i[denied_actors denied_groups].freeze

      # Public
      def initialize(source = nil, threadsafe: true)
        @source = Typecast.features_hash(source)
        @lock = Mutex.new if threadsafe
      end

      # Public: The set of known features.
      def features
        synchronize { @source.keys }.to_set
      end

      # Public: Adds a feature to the set of known features.
      def add(feature)
        synchronize { @source[feature.key] ||= default_config }
        true
      end

      # Public: Removes a feature from the set of known features and clears
      # all the values for the feature.
      def remove(feature)
        synchronize { @source.delete(feature.key) }
        true
      end

      # Public: Clears all the gate values for a feature.
      def clear(feature)
        synchronize do
          @source[feature.key] = config_preserving_denies(@source[feature.key])
        end
        true
      end

      # Public
      def get(feature)
        synchronize { @source[feature.key] } || DEFAULT_CONFIG
      end

      def get_multi(features)
        synchronize do
          result = {}
          features.each do |feature|
            result[feature.key] = @source[feature.key] || DEFAULT_CONFIG
          end
          result
        end
      end

      def get_all(**kwargs)
        synchronize { Typecast.features_hash(@source) }
      end

      # Public
      def enable(feature, gate, thing)
        synchronize do
          @source[feature.key] ||= default_config

          case gate.data_type
          when :boolean
            @source[feature.key] = config_preserving_denies(@source[feature.key])
            @source[feature.key][gate.key] = thing.value.to_s
          when :integer
            @source[feature.key][gate.key] = thing.value.to_s
          when :set
            @source[feature.key][gate.key] << thing.value.to_s
          when :json
            @source[feature.key][gate.key] = thing.value
          else
            raise "#{gate} is not supported by this adapter yet"
          end

          true
        end
      end

      # Public
      def disable(feature, gate, thing)
        synchronize do
          @source[feature.key] ||= default_config

          case gate.data_type
          when :boolean
            @source[feature.key] = config_preserving_denies(@source[feature.key])
          when :integer
            @source[feature.key][gate.key] = thing.value.to_s
          when :set
            @source[feature.key][gate.key].delete thing.value.to_s
          when :json
            @source[feature.key].delete(gate.key)
          else
            raise "#{gate} is not supported by this adapter yet"
          end

          true
        end
      end

      # Public
      def inspect
        attributes = [
          'name=:memory',
          "source=#{@source.inspect}",
        ]
        "#<#{self.class.name}:#{object_id} #{attributes.join(', ')}>"
      end

      # Public: a more efficient implementation of import for this adapter
      def import(source)
        adapter = self.class.from(source)
        get_all = Typecast.features_hash(adapter.get_all)
        synchronize { @source.replace(get_all) }
        true
      end

      # Public: Explicitly deny an actor or group for a feature.
      def deny(feature, thing)
        synchronize do
          @source[feature.key] ||= default_config
          key, value = deny_entry(thing)
          (@source[feature.key][key] ||= Set.new) << value
          true
        end
      end

      # Public: Remove an actor or group from the explicit deny list for a
      # feature. Empty deny lists are removed so the config returns to its
      # default shape once no denies remain.
      def allow(feature, thing)
        synchronize do
          key, value = deny_entry(thing)
          config = @source[feature.key]
          if config && (entries = config[key])
            entries.delete(value)
            config.delete(key) if entries.empty?
          end
          true
        end
      end

      private

      # Private: Maps a wrapped deny target to its config key and stored
      # value.
      def deny_entry(thing)
        case thing
        when Types::Actor
          [:denied_actors, thing.value.to_s]
        when Types::Group
          [:denied_groups, thing.value.to_s]
        else
          raise ArgumentError,
            "only actors and groups can be denied, got #{thing.inspect}"
        end
      end

      # Private: A fresh default config that keeps any deny list entries
      # from the given config. Deny records are safety critical, so
      # enable(true), disable and clear must not drop them; they are only
      # removed explicitly via allow.
      def config_preserving_denies(config)
        fresh = default_config
        return fresh unless config

        DENY_KEYS.each do |key|
          entries = config[key]
          fresh[key] = entries.dup if entries.is_a?(Set) && !entries.empty?
        end
        fresh
      end

      def synchronize(&block)
        if @lock
          @lock.synchronize(&block)
        else
          block.call
        end
      end
    end
  end
end
