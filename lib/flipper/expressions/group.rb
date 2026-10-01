module Flipper
  module Expressions
    # Internal: Matches a registered Flipper group. Exposed in expressions as
    # {Group: :admins} / Flipper.in_group(:admins) so group membership can be
    # combined with the rest of the expression tree and explained.
    class Group
      def self.call(name, context:)
        actor = context[:actor]
        return false if actor.nil?

        Flipper.group(name).match?(actor, context)
      end
    end
  end
end
