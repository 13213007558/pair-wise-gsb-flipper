module Flipper
  class FeatureCheckContext
    # Public: The name of the feature.
    attr_reader :feature_name

    # Public: The GateValues instance that keeps track of the values for the
    # gates for the feature.
    attr_reader :values

    # Public: The actors we want to know if a feature is enabled for.
    attr_reader :actors

    # Internal: When set (by Feature#explain), gates record what they
    # checked into this explainer as part of the evaluation.
    attr_accessor :recorder

    def initialize(feature_name:, values:, actors:)
      @feature_name = feature_name
      @values = values
      @actors = actors
    end

    def actors?
      !@actors.nil? && !@actors.empty?
    end

    # Internal: Records the outcome of a gate check when explaining. Always
    # returns result unchanged so gates can use it as their return value.
    def explain_gate(gate, result, reason, details = {})
      if (recorder = @recorder)
        value = values.respond_to?(gate.key) ? values.public_send(gate.key) : nil
        recorder.record_gate(
          gate: gate,
          value: value,
          result: result,
          reason: reason,
          details: details
        )
      end
      result
    end

    # Public: Convenience method for groups value like Feature has.
    def groups_value
      values.groups
    end

    # Public: Convenience method for actors value value like Feature has.
    def actors_value
      values.actors
    end

    # Public: Convenience method for boolean value value like Feature has.
    def boolean_value
      values.boolean
    end

    # Public: Convenience method for percentage of actors value like Feature has.
    def percentage_of_actors_value
      values.percentage_of_actors
    end

    # Public: Convenience method for percentage of time value like Feature has.
    def percentage_of_time_value
      values.percentage_of_time
    end
  end
end
