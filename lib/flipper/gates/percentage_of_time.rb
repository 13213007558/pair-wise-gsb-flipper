module Flipper
  module Gates
    class PercentageOfTime < Gate
      # Internal: The name of the gate. Used for instrumentation, etc.
      def name
        :percentage_of_time
      end

      # Internal: Name converted to value safe for adapter.
      def key
        :percentage_of_time
      end

      def data_type
        :integer
      end

      def enabled?(value)
        value > 0
      end

      # Internal: Checks if the gate is open for a thing.
      #
      # Returns true if gate open for thing, false if not.
      def open?(context)
        percentage = context.values.percentage_of_time
        if percentage <= 0
          return context.explain_gate(self, false, "percentage of time is #{percentage}")
        end
        if percentage >= 100
          return context.explain_gate(self, true, "percentage of time is 100")
        end

        random = rand
        result = random < (percentage / 100.0)
        reason = "random roll #{random} is #{result ? 'below' : 'not below'} " +          "#{percentage / 100.0} (percentage of time #{percentage})"
        context.explain_gate(self, result, reason, percentage: percentage, random: random)
      end

      def protects?(thing)
        thing.is_a?(Flipper::Types::PercentageOfTime)
      end
    end
  end
end
