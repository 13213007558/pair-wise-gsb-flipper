module Flipper
  module Gates
    # Internal: Emergency kill-switch gate. An actor listed here is denied
    # access regardless of every other gate. Checked before any allow gate.
    class DenyActor < Gate
      def name
        :deny_actor
      end

      def key
        :deny_actors
      end

      def data_type
        :set
      end

      def enabled?(value)
        !value.empty?
      end

      # Internal: A deny gate is open (vetoing the check) when ANY of the
      # actors being checked is on the deny list.
      def open?(context)
        return false unless context.actors?

        denied_actors = context.values.deny_actors
        return false if denied_actors.empty?

        context.actors.any? { |actor| denied_actors.include?(actor.value) }
      end

      def wrap(actor)
        Types::DenyActor.wrap(actor)
      end

      def protects?(actor)
        actor.is_a?(Types::DenyActor)
      end
    end
  end
end
