module Flipper
  class Explain
    # Internal: A single node in the tree of expression functions actually
    # visited while evaluating a feature check.
    class Node
      attr_reader :name, :result
      attr_accessor :args
      attr_accessor :status, :reason, :details, :feature_enabled

      def initialize(name, args)
        @name = name
        @args = args
        @result = nil
        @status = :evaluated
        @reason = nil
        @details = {}
        @feature_enabled = nil
      end

      def evaluated?
        status == :evaluated
      end

      def skipped?
        status == :skipped
      end

      def skipped!(reason)
        @status = :skipped
        @reason = reason
        self
      end

      def complete!(result, reason: nil)
        @result = result
        @reason = reason
        self
      end

      # Internal: Serialize this node (and its arguments) for inspection.
      def to_h
        hash = {
          name: name,
          args: args.map { |arg| serialize(arg) },
          result: serialize(result),
          status: status,
        }
        hash[:reason] = reason if reason
        hash[:details] = details unless details.empty?
        hash[:feature_enabled] = feature_enabled.to_h if feature_enabled
        hash
      end

      def inspect
        "#<#{self.class.name} name=#{name.inspect} result=#{result.inspect} status=#{status.inspect}>"
      end

      private

      def serialize(value)
        case value
        when Node then value.to_h
        when ::Time then value.utc.iso8601(6)
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
