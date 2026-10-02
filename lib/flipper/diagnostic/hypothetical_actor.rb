module Flipper
  module Diagnostic
    # Internal: Immutable stand-in for the real actor used while verifying a
    # candidate plan through Feature#enabled?. It never writes back to the
    # actor or any gate.
    class HypotheticalActor
      attr_reader :flipper_id, :flipper_properties

      def initialize(flipper_id:, flipper_properties:)
        @flipper_id = flipper_id
        @flipper_properties = flipper_properties
      end
    end
  end
end
