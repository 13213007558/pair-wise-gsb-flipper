module Flipper
  module Types
    # Internal: Wraps a Flipper::RolloutSchedule for the
    # scheduled_rollout gate.
    class ScheduledRollout < Type
      def self.wrap(value_or_instance)
        return value_or_instance if value_or_instance.is_a?(self)
        new(value_or_instance)
      end

      def initialize(value)
        # nil is the internal "unset" marker used by Feature#disable: the
        # :json disable path deletes the stored gate key and never reads
        # value, so no schedule is built (and validation is skipped).
        if value.nil?
          @value = nil
        else
          @schedule = Flipper::RolloutSchedule.build(value)
          # Adapters serialize the raw `value` of a :json gate; expose the
          # JSON-native nodes array so every backend stores exactly the
          # same curve with no object-to-String conversion.
          @value = @schedule.as_json
        end
      end

      # Public: The validated Flipper::RolloutSchedule.
      def schedule
        @schedule
      end
    end
  end
end
