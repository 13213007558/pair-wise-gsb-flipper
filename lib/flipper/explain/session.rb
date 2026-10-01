require 'set'

module Flipper
  class Explain
    # Internal: Carries the state of a single explain evaluation across gate
    # checks and across nested FeatureEnabled conditions: the ordered stack of
    # features being evaluated (for circular dependency paths) and the actor
    # properties that must never be exposed in an explanation.
    class Session
      EVALUATING_KEY = :flipper_evaluating_features
      attr_reader :stack, :hidden_properties

      def initialize(hidden_properties: [])
        @stack = []
        @hidden_properties = hidden_properties.map(&:to_s)
      end

      # Internal: Is target already being evaluated in this pass? Returns the
      # ordered dependency path that closes the cycle, or nil.
      def cycle_for(target)
        target = target.to_s
        index = @stack.index(target)
        return nil unless index

        @stack[index..] + [target]
      end

      # Internal: Run the explain check for a nested FeatureEnabled condition
      # as part of this same evaluation pass.
      def feature_enabled(target, actor, hidden_properties: @hidden_properties)
        if actor.nil?
          Flipper.feature(target).explain?(session: self, hidden_properties: hidden_properties)
        else
          Flipper.feature(target).explain?(actor, session: self, hidden_properties: hidden_properties)
        end
      end

      def with_feature(feature_name)
        @stack.push(feature_name.to_s)
        evaluating = Thread.current[EVALUATING_KEY] ||= Set.new
        added = evaluating.add?(feature_name.to_s)
        yield
      ensure
        @stack.pop
        evaluating.delete(feature_name.to_s) if added && evaluating
      end
    end
  end
end
