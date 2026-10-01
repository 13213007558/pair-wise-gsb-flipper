module Flipper
  module Types
    # Internal: Wraps a registered Flipper::Types::Group whose members are
    # explicitly denied access to a feature, even when the other gates would
    # otherwise allow it. Stored in the adapter as a member of the
    # `:deny_groups` set.
    class DenyGroup < Type
      def self.wrap(group_or_name)
        return group_or_name if group_or_name.is_a?(self)
        new(Types::Group.wrap(group_or_name))
      end

      def initialize(group)
        @group = group
        @value = group.name
      end
    end
  end
end
