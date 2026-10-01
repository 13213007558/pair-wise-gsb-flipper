require 'flipper/explanation'

module Flipper
  # Internal: Records a single feature evaluation so Feature#explain can
  # report exactly what happened without evaluating a second time. Gates
  # and expressions record into the explainer as they run; the result is
  # built from whatever was recorded.
  class Explainer
    # Internal: Thread key used so nested feature evaluations (triggered by
    # FeatureEnabled expressions) can record circular dependency paths on
    # the explainer of the outer evaluation.
    THREAD_KEY = :flipper_explainer

    def self.current
      Thread.current[THREAD_KEY]
    end

    # Internal: Makes explainer current for the duration of the block,
    # restoring any previously active explainer afterwards.
    def self.activate(explainer)
      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = explainer
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    attr_reader :gates, :cycles

    def initialize(actors: nil, hidden_properties: [])
      @actors = actors
      @hidden_properties = Array(hidden_properties).map(&:to_s)
      @gates = []
      @cycles = []
    end

    def record_gate(gate:, value:, result:, reason:, details: {})
      @gates << Explanation::GateCheck.new(
        name: gate.name,
        value: value,
        open: !!result,
        reason: reason,
        details: details
      )
    end

    # Internal: Marks a gate as not evaluated because an earlier gate
    # already opened the feature.
    def skip_gate(gate, reason)
      @gates << Explanation::GateCheck.new(
        name: gate.name,
        evaluated: false,
        reason: reason
      )
    end

    # Internal: Records a circular FeatureEnabled dependency path, e.g.
    # ["a", "b", "a"].
    def record_cycle(path)
      @cycles << path
    end

    def hidden_property?(key)
      @hidden_properties.include?(key.to_s)
    end

    def mask_properties(properties)
      properties.each_with_object({}) do |(key, value), masked|
        masked[key.to_s] = hidden_property?(key) ? Explanation::HIDDEN : value
      end
    end

    def to_explanation(feature_name:, result:)
      Explanation.new(
        feature_name: feature_name,
        result: result,
        gates: gates,
        actors: actor_attributes,
        cycles: cycles
      )
    end

    private

    def actor_attributes
      Array(@actors).map do |actor|
        properties = {}
        if actor.respond_to?(:flipper_properties)
          properties.update(actor.flipper_properties)
        end

        Explanation::ActorAttributes.new(
          flipper_id: actor.respond_to?(:flipper_id) ? actor.flipper_id : nil,
          properties: mask_properties(properties)
        )
      end
    end
  end
end
