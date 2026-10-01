module Flipper
  module Gates
    class Actor < Gate
      # Internal: The name of the gate. Used for instrumentation, etc.
      def name
        :actor
      end

      # Internal: Name converted to value safe for adapter.
      def key
        :actors
      end

      def data_type
        :set
      end

      def enabled?(value)
        !value.empty?
      end

      # Internal: Checks if the gate is open for an actor.
      #
      # Returns true if gate open for actor, false if not.
      def open?(context)
        return context.explain_gate(self, false, "no actors were provided") unless context.actors?

        enabled_actors = context.values.actors
        if enabled_actors.empty?
          return context.explain_gate(self, false, "no actors are enabled for this feature")
        end

        matching = context.actors.select do |actor|
          enabled_actors.include?(actor.value)
        end

        if matching.empty?
          context.explain_gate(self, false, "no actor is in the enabled actors set")
        else
          context.explain_gate(
            self,
            true,
            "actor #{matching.map(&:value).join(', ')} is in the enabled actors set",
            matching_actors: matching.map(&:value)
          )
        end
      end

      def wrap(actor)
        Types::Actor.wrap(actor)
      end

      def protects?(actor)
        Types::Actor.wrappable?(actor)
      end
    end
  end
end
