module Flipper
  class Explain
    # Internal: The outcome of checking one gate during an explain pass.
    class GateResult
      attr_reader :name, :result, :status, :reason, :details, :actor_results
      attr_accessor :expression_tree

      def initialize(name)
        @name = name
        @result = false
        @status = :evaluated
        @reason = nil
        @details = {}
        @expression_tree = nil
        @actor_results = []
      end

      def skipped!(reason)
        @status = :skipped
        @reason = reason
        self
      end

      def complete!(result, reason: nil)
        @status = :evaluated
        @result = !!result
        @reason = reason
        self
      end

      def open?
        @result
      end

      def skipped?
        status == :skipped
      end

      def to_h
        hash = {
          name: name,
          result: result,
          status: status,
        }
        hash[:reason] = reason if reason
        hash[:details] = details unless details.empty?
        if expression_tree
          hash[:expression] = expression_tree.to_h
        end
        unless actor_results.empty?
          hash[:actors] = actor_results.map(&:to_h)
        end
        hash
      end
    end
  end
end
