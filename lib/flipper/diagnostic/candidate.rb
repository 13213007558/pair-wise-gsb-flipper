module Flipper
  module Diagnostic
    # Public: A value an attribute may be changed to, optionally with an
    # explicit cost used to break ties between plans that change the same
    # number of attributes.
    class Candidate
      attr_reader :value, :cost

      def self.coerce(entry)
        value, cost = entry
        new(value, cost || 0)
      end

      def initialize(value, cost = 0)
        @value = value
        unless cost.is_a?(Numeric)
          raise ArgumentError, "candidate cost must be numeric, got #{cost.inspect}"
        end
        @cost = cost
      end

      def to_a
        [value, cost]
      end
    end
  end
end
