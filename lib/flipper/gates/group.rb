module Flipper
  module Gates
    class Group < Gate
      # Internal: The name of the gate. Used for instrumentation, etc.
      def name
        :group
      end

      # Internal: Name converted to value safe for adapter.
      def key
        :groups
      end

      def data_type
        :set
      end

      def enabled?(value)
        !value.empty?
      end

      # Internal: Checks if the gate is open for a thing.
      #
      # Returns true if gate open for thing, false if not.
      def open?(context)
        return false unless context.actors?

        context.values.groups.any? do |name|
          context.actors.any? do |actor|
            Flipper.group(name).match?(actor, context)
          end
        end
      end

      # Internal: Explain this gate without re-running anything. Each group is
      # checked against each actor until one matches, mirroring open?.
      def explain(result, context, **_options)
        unless context.actors?
          result.complete!(false, reason: :no_actor)
          return
        end

        enabled_groups = context.values.groups
        if enabled_groups.empty?
          result.complete!(false, reason: :no_groups_enabled)
          return
        end

        matched = enabled_groups.any? do |name|
          context.actors.any? do |actor|
            hit = Flipper.group(name).match?(actor, context)
            result.actor_results << Flipper::Explain::ActorResult.new(
              actor.value, hit,
              reason: hit ? :group_match : :group_no_match,
              details: { group: name.to_s }
            )
            hit
          end
        end

        result.complete!(matched, reason: matched ? :group_match : :group_no_match)
      end

      def wrap(thing)
        Types::Group.wrap(thing)
      end

      def protects?(thing)
        thing.is_a?(Types::Group) || thing.is_a?(Symbol)
      end
    end
  end
end
