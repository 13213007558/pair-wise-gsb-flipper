require "set"
require "flipper/explainer"

module Flipper
  module Expressions
    class FeatureEnabled
      EVALUATING_KEY = :flipper_evaluating_features
      EVALUATING_STACK_KEY = :flipper_evaluating_feature_stack

      def self.call(feature_name, context:)
        evaluating = Thread.current[EVALUATING_KEY] ||= Set.new
        stack = Thread.current[EVALUATING_STACK_KEY] ||= []
        feature_name = feature_name.to_s
        current_feature = context[:feature_name].to_s

        # Track the current feature so A -> B -> A is caught
        added_current = evaluating.add?(current_feature)
        stack.push(current_feature) if added_current

        pushed = false
        begin
          # Circular dependency: return false to break the cycle
          if evaluating.include?(feature_name)
            record_cycle(stack, feature_name, context)
            return false
          end

          evaluating.add(feature_name)
          stack.push(feature_name)
          pushed = true

          actor = context[:actor]
          if actor
            Flipper.enabled?(feature_name, actor)
          else
            Flipper.enabled?(feature_name)
          end
        ensure
          if pushed
            evaluating.delete(feature_name)
            stack.pop
          end
          if added_current
            evaluating.delete(current_feature)
            stack.pop
          end
        end
      end

      # Internal: Records the dependency path of a circular reference on the
      # active explainer, if any, so Feature#explain can show how the cycle
      # was formed, e.g. ["a", "b", "a"].
      def self.record_cycle(stack, feature_name, context)
        explainer = context[:explainer] || Explainer.current
        return unless explainer

        path = stack.dup.push(feature_name)
        cycle_start = path.index(feature_name)
        path = path[cycle_start..] if cycle_start
        explainer.record_cycle(path)
      end
    end
  end
end
