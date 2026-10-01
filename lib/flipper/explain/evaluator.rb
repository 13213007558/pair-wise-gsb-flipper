require 'flipper/explain/node'

module Flipper
  class Explain
    # Internal: Evaluates an Flipper::Expression tree exactly once while
    # recording every function node that ran, the value it produced, and the
    # branches short-circuited by Any/All. Also captures the concrete values
    # used by time and random conditions and the dependency path traversed
    # through FeatureEnabled conditions.
    class Evaluator
      # Internal: function names whose result depends on wall clock time.
      TIME_FUNCTIONS = %w[Now Time].freeze

      attr_reader :root

      def initialize(expression, feature_name:, properties:, actor:, session: nil, hidden_properties: [])
        @expression = expression
        @feature_name = feature_name
        @properties = properties
        @actor = actor
        @session = session
        @hidden_properties = hidden_properties.map(&:to_s)
      end

      # Internal: Evaluate the whole tree once, returning the boolean result
      # and leaving #root populated with the recorded Node tree.
      def call
        @root = evaluate(@expression)
        !!@root.result
      end

      private

      def evaluate(node)
        case node
        when Expression::Constant
          node.value
        when Expression
          evaluate_expression(node)
        else
          node
        end
      end

      def evaluate_expression(expression)
        record = Node.new(expression.name, expression.args.dup)
        function = expression.function

        record_property_lookup!(record) if function == Expressions::Property

        if function == Expressions::FeatureEnabled
          evaluate_feature_enabled!(record)
          return record
        end

        child_records = []

        if expression.group?
          evaluate_group_args!(record, expression, child_records)
        else
          expression.args.each { |arg| child_records << evaluate(arg) }
        end

        record.args = child_records

        # Skipped branches never execute, so their values are not passed to
        # the function; All/Any results are already determined. Constants are
        # raw values and always participate.
        evaluated_args = []
        child_records.each do |child|
          case child
          when Node
            evaluated_args << child.result if child.evaluated?
          else
            evaluated_args << child
          end
        end

        result = invoke(function, record, evaluated_args)
        record.complete!(result)
        record
      end

      # Internal: Evaluate group children with short-circuiting, marking the
      # children that never ran as skipped.
      def evaluate_group_args!(_record, expression, child_records)
        all = expression.all?

        expression.args.each do |arg|
          decided = child_records.any? do |value|
            value = value.result if value.is_a?(Node)
            all ? !value : !!value
          end

          if decided
            child_records << skipped_tree(arg, all ? :short_circuit_all : :short_circuit_any)
            next
          end

          child_records << evaluate(arg)
        end
      end

      # Internal: Build a node tree whose every node is marked skipped, so
      # branches short-circuited away remain visible in the explanation.
      def skipped_tree(arg, reason)
        if arg.is_a?(Expression)
          Node.new(arg.name, arg.args.map { |child| skipped_tree(child, reason) }).skipped!(reason)
        elsif arg.is_a?(Expression::Constant)
          arg.value
        else
          arg
        end
      end

      # Internal: Property conditions look up actor properties; record the
      # concrete value (or that it was hidden/missing).
      def record_property_lookup!(record)
        key = record.args.first
        key = key.value if key.is_a?(Expression::Constant)
        key = key.to_s

        if @hidden_properties.include?(key)
          record.details[:property] = key
          record.details[:value] = :hidden
        else
          record.details[:property] = key
          record.details[:value] = @properties[key]
        end
      end

      # Internal: FeatureEnabled is evaluated through the shared Explain
      # session so the nested feature is explained as part of this same pass
      # and a circular dependency can be reported with its full path. It must
      # not have its argument evaluated by the generic context path.
      def evaluate_feature_enabled!(record)
        target = record.args.first
        target = target.value if target.is_a?(Expression::Constant)
        target = target.to_s
        record.args = [target]

        if @session.nil?
          result = Expressions::FeatureEnabled.call(target, context: {
            feature_name: @feature_name,
            properties: @properties,
            actor: @actor,
          })
          record.complete!(result)
        elsif (cycle = @session.cycle_for(target))
          record.details[:path] = cycle
          record.details[:cycle] = cycle
          record.complete!(false, reason: :circular_dependency)
        else
          explanation = @session.feature_enabled(target, @actor, hidden_properties: @hidden_properties)
          record.feature_enabled = explanation
          record.details[:path] = [*@session.stack, target]
          if (cycle = cycle_from(explanation))
            record.details[:cycle] = cycle
            record.complete!(false, reason: :circular_dependency)
          else
            record.complete!(explanation.enabled?)
          end
        end
      end

      def cycle_from(result)
        result.gates.each do |gate|
          next unless gate.name == :expression

          tree = gate.expression_tree || gate.actor_results.map(&:tree).compact.first
          cycle = find_cycle(tree)
          return cycle if cycle
        end
        nil
      end

      def find_cycle(node)
        return nil unless node.is_a?(Node)
        return node.details[:cycle] if node.reason == :circular_dependency

        node.args.each do |arg|
          cycle = find_cycle(arg)
          return cycle if cycle
        end
        nil
      end

      # Internal: Call an expression function, threading the shared context
      # through for functions that ask for it and recording the concrete
      # values used by time and random conditions.
      def invoke(function, _record, evaluated_args)
        context = {
          feature_name: @feature_name,
          properties: @properties,
          actor: @actor,
        }

        result =
          if requires_context?(function)
            function.call(*evaluated_args, context: context)
          else
            function.call(*evaluated_args)
          end

        _record.details.merge!(dynamic_details(function, evaluated_args, result, context))
        result
      end

      # Internal: Record the concrete values this check actually used for
      # time, random and percentage-of-actors conditions.
      def dynamic_details(function, args, result, context)
        details = {}
        name = function.name.split('::').last

        if TIME_FUNCTIONS.include?(name)
          details[:actual_value] = result
        end

        if function == Expressions::Random
          details[:max] = args.first
          details[:actual_value] = result
        end

        if function == Expressions::PercentageOfActors
          details[:percentage] = args.last
          details[:actual_value] = result
          details[:bucket] = percentage_bucket(args.first, context[:feature_name])
        end

        details
      end

      def percentage_bucket(text, feature_name)
        require 'zlib'
        Zlib.crc32("#{feature_name}#{text}") % (100 * 1_000)
      end

      def requires_context?(function)
        function.method(:call).parameters.any? do |type, name|
          name == :context && [:key, :keyreq].include?(type)
        end
      end
    end
  end
end
