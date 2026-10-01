require 'zlib'
require 'time'

module Flipper
  module Gates
    # Internal: Piecewise rollout curve. The current percentage is derived
    # from a RolloutSchedule evaluated against the clock injected into the
    # DSL/Flipper instance, and actors are admitted with the same stable,
    # deterministic crc32 bucketing used by PercentageOfActors.
    class ScheduledRollout < Gate
      # Internal: The name of the gate. Used for instrumentation, etc.
      def name
        :scheduled_rollout
      end

      # Internal: Name converted to value safe for adapter.
      def key
        :scheduled_rollout
      end

      def data_type
        :json
      end

      def enabled?(value)
        !value.nil?
      end

      # Internal: Checks if the gate is open for one or more actors.
      #
      # Returns true if gate open for any actors, false if not.
      def open?(context)
        return false unless context.actors?

        schedule = context.values.scheduled_rollout
        return false if schedule.nil?
        clock = context.clock
        now = clock.respond_to?(:call) ? clock.call : clock.now

        threshold = schedule.bucket_threshold_at(now)
        return false if threshold <= 0
        return true if threshold >= 100 * Flipper::RolloutSchedule::SCALING_FACTOR

        actors = context.actors
        id = if actors.size == 1
          "#{context.feature_name}#{actors.first.value}"
        else
          "#{context.feature_name}#{actors.map(&:value).sort.join}"
        end

        # Same stable hash-to-bucket mapping as
        # Gates::PercentageOfActors (including its documented, intentional
        # modulo bias). Must not change: an actor admitted early in a
        # non-decreasing curve must stay admitted as the percentage rises.
        Zlib.crc32(id) % (100 * Flipper::RolloutSchedule::SCALING_FACTOR) < threshold
      end

      def protects?(thing)
        thing.is_a?(Types::ScheduledRollout)
      end

      def wrap(thing)
        Types::ScheduledRollout.wrap(thing)
      end
    end
  end
end
