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
        return false unless context.actors?

        enabled_actors = context.values.actors
        return false if enabled_actors.empty?

        context.actors.any? do |actor|
          enabled_actors.include?(actor.value)
        end
      end

      # Internal: Explain this gate without re-running anything.
      def explain(result, context, **_options)
        unless context.actors?
          result.complete!(false, reason: :no_actor)
          return
        end

        enabled_actors = context.values.actors
        if enabled_actors.empty?
          result.complete!(false, reason: :no_actors_enabled)
          return
        end

        matched = context.actors.any? do |actor|
          hit = enabled_actors.include?(actor.value)
          result.actor_results << Flipper::Explain::ActorResult.new(
            actor.value, hit,
            reason: hit ? :actor_enabled : :actor_not_enabled
          )
          hit
        end

        result.complete!(matched, reason: matched ? :actor_enabled : :actor_not_enabled)
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
