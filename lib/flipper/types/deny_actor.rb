module Flipper
  module Types
    # Internal: Wraps an actor that is explicitly denied access to a feature,
    # even when the boolean, percentage or expression gates would otherwise
    # allow it. Stored in the adapter as a member of the `:deny_actors` set.
    class DenyActor < Type
      def self.wrap(actor)
        return actor if actor.is_a?(self)
        actor = Types::Actor.wrap(actor) unless actor.is_a?(Types::Actor)
        new(actor)
      end

      def initialize(actor)
        @actor = actor
        @value = actor.value
      end
    end
  end
end
