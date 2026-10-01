module Flipper
  class Explain
    # Public: The outcome of a single Flipper.explain? evaluation. The same
    # evaluation that produced #enabled? also produced this object; nothing is
    # re-run.
    class Result
      attr_reader :feature_name, :actors, :properties, :gates, :reason,
                  :gate_values

      def initialize(feature_name:, actors:, properties:, gates:, gate_values:)
        @feature_name = feature_name
        @actors = actors
        @properties = properties
        @gates = gates
        @gate_values = gate_values

        open_gate = gates.detect(&:open?)
        @enabled = !!open_gate
        @reason = open_gate ? :gate_open : :no_open_gate
      end

      # Public: True if the feature was enabled for the actors.
      def enabled?
        @enabled
      end

      # Public: The gate that opened for this check, if any.
      def open_gate
        gates.detect(&:open?)
      end

      # Public: Gates that were actually checked in order.
      def checked_gates
        gates.reject(&:skipped?)
      end

      # Public: Gates not checked because an earlier gate short-circuited.
      def skipped_gates
        gates.select(&:skipped?)
      end

      # Public: Serialized representation suitable for logging or an API.
      def to_h
        {
          feature_name: feature_name.to_s,
          enabled: enabled?,
          reason: reason,
          actors: Array(actors).map { |actor| { flipper_id: actor.value } },
          properties: properties,
          gate_values: serialize_gate_values,
          gates: gates.map(&:to_h),
        }
      end

      def as_json(*)
        to_h
      end

      def to_json(*args)
        require 'json'
        JSON.generate(as_json, *args)
      end

      def inspect
        "#<#{self.class.name} feature=#{feature_name.inspect} enabled=#{enabled?} reason=#{reason.inspect} checked=#{checked_gates.map(&:name).inspect}>"
      end

      private

      def serialize_gate_values
        {
          boolean: gate_values.boolean,
          actors: gate_values.actors.to_a,
          groups: gate_values.groups.to_a,
          expression: gate_values.expression,
          percentage_of_actors: gate_values.percentage_of_actors,
          percentage_of_time: gate_values.percentage_of_time,
        }
      end
    end
  end
end
