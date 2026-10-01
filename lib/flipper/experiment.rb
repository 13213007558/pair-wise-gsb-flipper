require 'zlib'
require 'flipper/typecast'

module Flipper
  class Experiment
    SCALING_FACTOR = 1_000
    private_constant :SCALING_FACTOR

    Variant = Struct.new(:name, :weight, keyword_init: true) do
      def initialize(name:, weight:)
        super(name: name.to_s, weight: Typecast.to_number(weight).to_f)
      end

      def to_h
        {
          'name' => name,
          'weight' => weight == weight.to_i ? weight.to_i : weight,
        }
      end
    end

    def self.from_payload(payload)
      payload = Typecast.from_json(payload) if payload.is_a?(String)

      new(
        namespace: self.payload_value(payload, :namespace),
        variants: self.payload_value(payload, :variants),
        unassigned: self.payload_value(payload, :unassigned)
      )
    end

    attr_reader :namespace, :variants, :unassigned

    def initialize(namespace:, variants:, unassigned:)
      @namespace = namespace.to_s
      @unassigned = unassigned.is_a?(Symbol) ? unassigned.to_s : unassigned
      @variants = normalize_variants(variants)

      validate!
    end

    def result_for(actor)
      variant_for(actor) || unassigned
    end
    alias_method :[], :result_for

    def variant_for(actor)
      bucket = bucket_for(actor)
      cumulative_scaled_weight = 0

      variants.each do |variant|
        cumulative_scaled_weight += scaled_weight_for(variant)
        return variant.name if bucket < cumulative_scaled_weight
      end

      nil
    end

    def enabled?(actor)
      !variant_for(actor).nil?
    end

    def assigned?(actor)
      !variant_for(actor).nil?
    end

    def variant_names
      variants.map(&:name)
    end

    def weight_for(name)
      variant = variants_by_name.fetch(name.to_s) { return nil }
      variant.weight
    end

    def total_weight
      variants.sum(&:weight).to_f
    end

    def to_payload
      {
        'namespace' => namespace,
        'variants' => variants.map(&:to_h),
        'unassigned' => unassigned,
      }
    end
    alias_method :to_h, :to_payload

    def as_json(_options = nil)
      to_payload
    end

    def to_json(*args)
      Typecast.to_json(to_payload)
    end

    def eql?(other)
      other.is_a?(self.class) && to_payload == other.to_payload
    end
    alias_method :==, :eql?

    def hash
      to_payload.hash
    end

    private

    def normalize_variants(variants)
      if variants.is_a?(Hash) && !variants.key?(:name) && !variants.key?('name')
        return variants.map do |name, weight|
          Variant.new(name: name, weight: weight)
        end
      end

      Array(variants).flat_map do |variant|
        case variant
        when Variant
          variant
        when Hash
          Variant.new(
            name: variant.fetch(:name) { variant.fetch('name') },
            weight: variant.fetch(:weight) { variant.fetch('weight') }
          )
        else
          raise ArgumentError, "#{variant.inspect} must be a variant hash"
        end
      end
    end

    def validate!
      raise ArgumentError, 'namespace cannot be empty' if namespace.empty?
      raise ArgumentError, 'variants cannot be empty' if variants.empty?

      names = variants.map(&:name)
      if names.any?(&:empty?)
        raise ArgumentError, 'variant names cannot be empty'
      end

      duplicates = names.group_by(&:itself).select { |_, group| group.size > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError, "duplicate variant names: #{duplicates.join(', ')}"
      end

      validate_weights!

      total = total_weight
      if total > 100
        raise ArgumentError, "total variant weight cannot exceed 100, but was #{total}"
      end
    end

    def self.payload_value(payload, key)
      payload.fetch(key) { payload.fetch(key.to_s) }
    rescue KeyError
      raise ArgumentError, "experiment payload is missing #{key.inspect}"
    end
    private_class_method :payload_value

    def validate_weights!
      variants.each do |variant|
        scaled_weight = scaled_weight_for(variant)

        if scaled_weight.negative?
          raise ArgumentError, "variant weights cannot be negative: #{variant.name}"
        end
      end
    end

    def scaled_weight_for(variant)
      scaled_weight = variant.weight * SCALING_FACTOR
      unless scaled_weight.finite? && (scaled_weight - scaled_weight.round).abs <= 0.0001
        raise ArgumentError,
          "variant weight cannot have more than 3 decimal places: #{variant.name}"
      end

      scaled_weight.round
    end

    def variants_by_name
      @variants_by_name ||= variants.to_h { |variant| [variant.name, variant] }
    end

    def bucket_for(actor)
      actor_id = actor_id_for(actor)
      Zlib.crc32("#{namespace}:#{actor_id}") % (100 * SCALING_FACTOR)
    end

    def actor_id_for(actor)
      if actor.respond_to?(:value)
        actor.value.to_s
      elsif actor.respond_to?(:flipper_id)
        actor.flipper_id.to_s
      elsif actor.nil?
        raise ArgumentError, 'actor cannot be nil'
      else
        actor.to_s
      end
    end
  end
end
