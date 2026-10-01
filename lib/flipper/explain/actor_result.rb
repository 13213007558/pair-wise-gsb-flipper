module Flipper
  class Explain
    # Internal: Per-actor outcome recorded while checking a gate that can be
    # evaluated for several actors (expression, actor, group, percentage).
    class ActorResult
      attr_reader :flipper_id, :result, :reason, :details, :tree

      def initialize(flipper_id, result, reason: nil, details: {}, tree: nil)
        @flipper_id = flipper_id
        @result = !!result
        @reason = reason
        @details = details
        @tree = tree
      end

      def to_h
        hash = { flipper_id: flipper_id, result: result }
        hash[:reason] = reason if reason
        hash[:details] = details unless details.empty?
        hash[:expression] = tree.to_h if tree
        hash
      end
    end
  end
end
