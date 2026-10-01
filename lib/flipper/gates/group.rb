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
        return context.explain_gate(self, false, "no actors were provided") unless context.actors?

        match = nil
        context.values.groups.each do |name|
          actor = context.actors.find do |candidate|
            Flipper.group(name).match?(candidate, context)
          end
          if actor
            match = [name, actor]
            break
          end
        end

        if match
          group_name, actor = match
          context.explain_gate(
            self,
            true,
            "actor #{actor.value} matches group #{group_name}",
            group: group_name,
            actor: actor.value
          )
        else
          reason = context.values.groups.empty? ?
            "no groups are enabled for this feature" :
            "no actor matches any enabled group"
          context.explain_gate(self, false, reason)
        end
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
