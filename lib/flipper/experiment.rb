require 'zlib'
require 'flipper/typecast'

module Flipper
  # Public: A multi-variant experiment that deterministically assigns an
  # actor to at most one weighted variant.
  #
  # Assignment is stable per actor for a given namespace and set of variant
  # weights: the same actor always lands in the same variant (or in the
  # unassigned bucket when the weights do not total 100%). It uses its own
  # crc32-based bucketing keyed by the experiment namespace and is
  # deliberately independent of the percentage_of_actors gate mapping.
  class Experiment
    # Internal: Supports up to 3 decimal places in weights (matching the
    # percentage_of_actors gate) and gives 100_000 total buckets.
    SCALING_FACTOR = 1_000
    private_constant :SCALING_FACTOR

    TOTAL_BUCKETS = 100 * SCALING_FACTOR
    private_constant :TOTAL_BUCKETS

    class InvalidConfiguration < Flipper::Error; end

    Variant = Struct.new(:name, :weight, keyword_init: true) do
      def to_h
        { name: name, weight: weight }
      end
    end

    # Public: The String/Symbol namespace that scopes bucketing. Two
    # experiments with different namespaces assign independently.
    attr_reader :namespace

    # Public: The value returned for actors that do not land in a variant.
    attr_reader :unassigned_result

    # Public: Build an experiment.
    #
    # namespace         - The String/Symbol namespace used to scope bucketing.
    # variants          - The Array of variants. Each variant is either a
    #                     { name:, weight: } Hash (weight may also be keyed
    #                     :percentage) or a Variant.
    # unassigned_result - The value returned for unassigned actors
    #                     (default: nil).
    def initialize(namespace:, variants:, unassigned_result: nil)
      @namespace = Typecast.to_feature_name(namespace)
      raise InvalidConfiguration, 'namespace cannot be blank' if @namespace.empty?

      @unassigned_result = unassigned_result
      @variants = normalize_variants(variants)
      validate!

      freeze
    end

    # Public: Returns the Array of frozen Variants in configured order.
    def variants
      @variants.dup
    end

    # Public: Returns the variant names in configured order.
    def variant_names
      @variants.map(&:name)
    end

    # Public: Look up a variant's weight by name.
    def weight(name)
      variant = @variants.find { |candidate| candidate.name == name.to_s || candidate.name == name.to_sym }
      variant&.weight
    end

    # Public: Total allocated percentage (0..100). The remainder is the
    # unassigned bucket.
    def allocated_weight
      @variants.sum(&:weight)
    end

    # Public: Assign an actor to a variant.
    #
    # actor - The actor. May be a String/Symbol id, a Flipper::Actor, or any
    #         object responding to #flipper_id.
    #
    # Returns the assigned variant name, or the unassigned_result when the
    # actor does not land in a weighted variant.
    def result_for(actor)
      variant = variant_for(actor)
      variant ? variant.name : @unassigned_result
    end
    alias_method :assigned_result, :result_for

    # Public: Like #result_for but returns the Variant instance or nil.
    def variant_for(actor)
      bucket = bucket_for(actor)
      cutoff = 0
      @variants.each do |variant|
        next if variant.weight.zero?
        cutoff += (variant.weight * SCALING_FACTOR).round
        return variant if bucket < cutoff
      end
      nil
    end

    # Public: Returns true when the actor does not land in a variant.
    def unassigned?(actor)
      variant_for(actor).nil?
    end

    # Public: Returns true when the actor lands in the named variant.
    def variant?(name, actor)
      variant = variant_for(actor)
      !variant.nil? && (variant.name == name.to_s || variant.name == name.to_sym)
    end

    # Public: The Integer bucket (0...100_000) the actor lands in.
    def bucket_for(actor)
      Zlib.crc32("#{@namespace}#{actor_value(actor)}") % TOTAL_BUCKETS
    end

    # Public: Returns a JSON-safe Hash representation. Round trips through
    # .from_h without changing assignment.
    def to_h
      {
        'namespace' => @namespace,
        'variants' => @variants.map do |variant|
          { 'name' => variant.name, 'weight' => variant.weight }
        end,
        'unassigned_result' => @unassigned_result,
      }
    end

    # Public: Serialize to a JSON String.
    def to_json(*args)
      Typecast.to_json(to_h)
    end

    # Public: Reconstruct an experiment from a Hash (e.g. parsed JSON).
    def self.from_h(source)
      source = Typecast.from_json(source) if source.is_a?(String)
      source = source.transform_keys(&:to_s)
      new(
        namespace: source.fetch('namespace'),
        variants: source.fetch('variants'),
        unassigned_result: source.fetch('unassigned_result', nil),
      )
    end

    # Public: Reconstruct an experiment from a JSON String.
    def self.from_json(source)
      from_h(Typecast.from_json(source))
    end

    def eql?(other)
      self.class.eql?(other.class) &&
        namespace == other.namespace &&
        variants == other.variants &&
        unassigned_result == other.unassigned_result
    end
    alias_method :==, :eql?

    def hash
      [self.class, namespace, @variants, unassigned_result].hash
    end

    def inspect
      "#<#{self.class.name} namespace=#{@namespace.inspect} " +        "variants=#{@variants.map { |variant| { variant.name => variant.weight } }.inspect} " +        "unassigned_result=#{@unassigned_result.inspect}>"
    end

    private

    def normalize_variants(variants)
      raise InvalidConfiguration, 'variants must be an Array' unless variants.is_a?(Array)
      raise InvalidConfiguration, 'variants cannot be empty' if variants.empty?

      variants.map do |variant|
        variant = variant.to_h if variant.is_a?(Variant)
        unless variant.is_a?(Hash)
          raise InvalidConfiguration, "variant must be a Hash, but was #{variant.inspect}"
        end

        source = variant.transform_keys(&:to_s)
        name = source.fetch('name')
        weight = if source.key?('weight')
          source.fetch('weight')
        else
          source.fetch('percentage')
        end
        weight = Typecast.to_number(weight)
        name = name.to_s

        Variant.new(name: name, weight: weight)
      end.freeze
    end

    def validate!
      names = []
      @variants.each do |variant|
        if variant.name.strip.empty?
          raise InvalidConfiguration, 'variant name cannot be blank'
        end
        if variant.weight.negative?
          raise InvalidConfiguration,
            "variant #{variant.name.inspect} has a negative weight (#{variant.weight})"
        end
        if names.include?(variant.name)
          raise InvalidConfiguration, "variant name #{variant.name.inspect} is duplicated"
        end
        names << variant.name
      end

      if allocated_weight > 100
        raise InvalidConfiguration,
          "variant weights total #{allocated_weight}, which exceeds 100"
      end
    end

    def actor_value(actor)
      value = if actor.is_a?(Flipper::Types::Actor)
        actor.value
      elsif actor.respond_to?(:flipper_id)
        actor.flipper_id
      else
        actor
      end
      raise ArgumentError, 'actor cannot be nil' if value.nil?
      value.to_s
    end
  end
end
