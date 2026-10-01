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
        return false if percentage <= 0
        return true if percentage >= 100
        rand < (percentage / 100.0)
      end

      # Internal: Explain this gate without re-running anything. The random
      # number drawn this evaluation is recorded in details.
      def explain(result, context, **_options)
        percentage = context.values.percentage_of_time
        result.details[:percentage] = percentage

        if percentage <= 0
          result.complete!(false, reason: :percentage_zero)
        elsif percentage >= 100
          result.complete!(true, reason: :percentage_100)
        else
          threshold = percentage / 100.0
          actual = rand
          open = actual < threshold
          result.details[:actual_value] = actual
          result.details[:threshold] = threshold
          result.complete!(open, reason: open ? :random_in_threshold : :random_over_threshold)
        end
      end

      def protects?(thing)
        thing.is_a?(Flipper::Types::PercentageOfTime)
      end
    end
  end
end
