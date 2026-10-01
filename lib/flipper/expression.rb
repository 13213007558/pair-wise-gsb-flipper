require "flipper/explanation"
require "flipper/expression/builder"
require "flipper/expression/constant"

module Flipper
  class Expression
    include Builder

    PruneResult = Struct.new(:expression, :constant_value, keyword_init: true)
    private_constant :PruneResult

    def self.build(object)
      return object if object.is_a?(self) || object.is_a?(Constant)

      case object
      when Hash
        name = object.keys.first
        args = object.values.first
        unless name
          raise ArgumentError, "#{object.inspect} cannot be converted into an expression"
        end

        new(name, Array(args).map { |o| build(o) })
      when String, Numeric, FalseClass, TrueClass
        Expression::Constant.new(object)
      when Symbol
        Expression::Constant.new(object.to_s)
      else
        raise ArgumentError, "#{object.inspect} cannot be converted into an expression"
      end
    end

    # Use #build
    private_class_method :new

    attr_reader :name, :function, :args

    def initialize(name, args = [])
      @name = name.to_s
      @function = Expressions.const_get(name)
      @args = args
    end

    def evaluate(context = {})
      if call_with_context?
        function.call(*args.map {|arg| arg.evaluate(context) }, context: context)
      else
        function.call(*args.map {|arg| arg.evaluate(context) })
      end
    end

    # Internal: Like #evaluate, but returns a
    # Flipper::Explanation::ExpressionNode tree describing exactly what this
    # evaluation did. Any/All groups stop evaluating as soon as their result
    # is known; branches that were never executed are included in the tree
    # marked as short-circuited. Time and random nodes record the actual
    # value used as their result, and FeatureEnabled nodes record circular
    # dependency paths when a cycle is detected.
    def explain(context = {})
      return explain_group(context) if group?

      explainer = context[:explainer]
      child_nodes = args.map { |arg| explain_child(arg, context) }
      values = child_nodes.map(&:result)
      cycles_before = explainer ? explainer.cycles.length : 0

      result = if call_with_context?
        function.call(*values, context: context)
      else
        function.call(*values)
      end

      details = {}
      display_result = Explanation::ExpressionNode::UNSET

      case name
      when "Property"
        key = values.first
        details[:key] = key.to_s
        if explainer && explainer.hidden_property?(key)
          details[:hidden] = true
          display_result = Explanation::HIDDEN
        end
      when "FeatureEnabled"
        details[:feature] = values.first.to_s
        if explainer && explainer.cycles.length > cycles_before
          details[:cycle] = explainer.cycles.last
        end
      end

      Explanation::ExpressionNode.new(
        name: name,
        args: child_nodes,
        result: result,
        details: details,
        display_result: display_result
      )
    end

    def eql?(other)
      other.is_a?(self.class) && @function == other.function && @args == other.args
    end
    alias_method :==, :eql?

    # Public: Returns true if this expression contains an Any/All group with
    # no arguments anywhere in its tree. An empty All evaluates to true for
    # every actor and an empty Any to false for every actor, so persisting
    # one is almost always a mistake.
    def empty_groups?
      return true if group? && args.empty?

      args.any? { |arg| arg.is_a?(Expression) && arg.empty_groups? }
    end

    # Public: Returns a copy of this expression with empty Any/All groups
    # removed wherever removal cannot broaden the expression, or nil when no
    # conditions remain. An empty All can be removed from an All parent (it
    # contributes a constant true) and an empty Any from an Any parent (a
    # constant false), but an empty Any inside an All is kept because
    # removing it would broaden the expression from never-true.
    def prune_empty_groups
      prune_empty_groups_with_identity.expression
    end

    # Public: Returns true when this expression is guaranteed to match every
    # actor, e.g. an empty All group reaches an Any group or the root.
    def always_true?
      constant_group_value == true
    end

    def value
      {
        name => args.map(&:value)
      }
    end

    protected

    def prune_empty_groups_with_identity
      return PruneResult.new(expression: self) unless group?
      return PruneResult.new(constant_value: all?) if args.empty?

      pruned_args = args.map do |arg|
        if arg.is_a?(Expression)
          arg.prune_empty_groups_with_identity
        else
          PruneResult.new(expression: arg)
        end
      end

      kept = pruned_args.map do |result|
        if result.constant_value == false
          result.expression || build("Any" => []) if all?
        elsif result.constant_value.nil?
          result.expression
        end
      end.compact

      # No condition remains. Preserve this group's constant value for an
      # enclosing group, which lets an empty All disappear from All without
      # treating it as the unsafe empty-Any-in-All case.
      if kept.empty?
        return PruneResult.new(constant_value: constant_group_value)
      end

      pruned = build(name => kept)
      PruneResult.new(
        expression: pruned,
        constant_value: pruned.constant_group_value
      )
    end

    def constant_group_value
      return nil unless group?
      return all? if args.empty?

      values = args.map do |arg|
        arg.is_a?(Expression) ? arg.constant_group_value : nil
      end

      if all?
        return false if values.include?(false)
        return true if values.all?(true)
      else
        return true if values.include?(true)
        return false if values.all?(false)
      end

      nil
    end

    private

    def explain_child(arg, context)
      if arg.respond_to?(:explain)
        arg.explain(context)
      else
        Explanation::ExpressionNode.new(name: "Constant", result: arg)
      end
    end

    # Internal: Evaluates an Any/All group lazily, marking branches after
    # the result is known as short-circuited instead of evaluating them.
    def explain_group(context)
      child_nodes = []
      decided = false
      result = all?

      args.each do |arg|
        if decided
          child_nodes << Explanation::ExpressionNode.unevaluated(arg)
          next
        end

        node = explain_child(arg, context)
        child_nodes << node

        if all?
          unless node.result
            result = false
            decided = true
          end
        else
          if node.result
            result = true
            decided = true
          end
        end
      end

      Explanation::ExpressionNode.new(name: name, args: child_nodes, result: result)
    end

    def call_with_context?
      function.method(:call).parameters.any? do |type, name|
        name == :context && [:key, :keyreq].include?(type)
      end
    end
  end
end

Dir[File.join(File.dirname(__FILE__), 'expressions', '*.rb')].sort.each do |file|
  require "flipper/expressions/#{File.basename(file, '.rb')}"
end
