require 'zlib'

module Flipper
  module Gates
    class PercentageOfActors < Gate
      # Internal: The name of the gate. Used for instrumentation, etc.
      def name
        :percentage_of_actors
      end

      # Internal: Name converted to value safe for adapter.
      def key
        :percentage_of_actors
      end

      def data_type
        :integer
      end

      def enabled?(value)
        value > 0
      end

      # Private: this constant is used to support up to 3 decimal places
      # in percentages.
      SCALING_FACTOR = 1_000
      private_constant :SCALING_FACTOR

      # Internal: Checks if the gate is open for one or more actors.
      #
      # Returns true if gate open for any actors, false if not.
      def open?(context)
        return context.explain_gate(self, false, "no actors were provided") unless context.actors?

        percentage = context.values.percentage_of_actors
        if percentage <= 0
          return context.explain_gate(self, false, "percentage of actors is #{percentage}")
        end
        if percentage >= 100
          return context.explain_gate(self, true, "percentage of actors is 100")
        end

        actors = context.actors
        id = if actors.size == 1
          "#{context.feature_name}#{actors.first.value}"
        else
          "#{context.feature_name}#{actors.map(&:value).sort.join}"
        end
        # NOTE: `crc32 % 100_000` has a tiny modulo bias (2**32 is not a
        # multiple of 100_000, so buckets 0..67_295 are ~0.0023% over-
        # represented). This is intentionally left as-is: the bias is
        # negligible, and any "fix" changes the hash-to-bucket mapping,
        # which would re-bucket essentially every actor on upgrade and
        # silently flip who is enabled. Stable, deterministic bucketing
        # matters far more here than perfect uniformity. Do not change.
        bucket = Zlib.crc32(id) % (100 * SCALING_FACTOR)
        result = bucket < percentage * SCALING_FACTOR
        reason = "bucket #{bucket} is #{result ? 'below' : 'not below'} " +          "#{percentage * SCALING_FACTOR} (percentage of actors #{percentage})"
        context.explain_gate(self, result, reason, percentage: percentage, bucket: bucket)
      end

      def protects?(thing)
        thing.is_a?(Types::PercentageOfActors)
      end
    end
  end
end
