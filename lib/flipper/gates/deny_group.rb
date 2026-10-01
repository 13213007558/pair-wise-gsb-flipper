module Flipper
  module Gates
    # Internal: Emergency kill-switch gate. An actor belonging to a group
    # listed here is denied access regardless of every other gate. Checked
    # before any allow gate.
    class DenyGroup < Gate
      def name
        :deny_group
      end

      def key
        :deny_groups
      end

      def data_type
        :set
      end

      def enabled?(value)
        !value.empty?
      end

      # Internal: A deny gate is open (vetoing the check) when ANY of the
      # actors being checked belongs to a denied group.
      def open?(context)
        return false unless context.actors?

        denied_groups = context.values.deny_groups
        return false if denied_groups.empty?

        denied_groups.any? do |name|
          context.actors.any? do |actor|
            Flipper.group(name).match?(actor, context)
          end
        end
      end

      def wrap(thing)
        Types::DenyGroup.wrap(thing)
      end

      def protects?(thing)
        thing.is_a?(Types::DenyGroup)
      end
    end
  end
end
