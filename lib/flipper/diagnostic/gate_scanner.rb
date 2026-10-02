module Flipper
  module Diagnostic
    # Internal: Statically inspects the target feature and every feature it
    # references (through FeatureEnabled expressions) for gates that make a
    # deterministic, read-only diagnosis impossible:
    #
    #   * Ruby groups run arbitrary registered code;
    #   * percentage of time and Random expressions are non-deterministic;
    #   * Now/Time expressions depend on wall-clock time.
    #
    # Percentage of actors and PercentageOfActors expressions hash the actor
    # id deterministically, so they are evaluated normally (changing
    # flipper_id can move an actor between buckets).
    class GateScanner
      TIME_FUNCTIONS = ["Now", "Time"].freeze
      RANDOM_FUNCTIONS = ["Random"].freeze

      def self.scan!(dsl, feature_name)
        new.scan_feature(dsl, feature_name.to_s, [])
      end

      def scan_feature(dsl, name, chain)
        path = chain + [name]
        feature = dsl.feature(name)
        values = feature.gate_values

        unless values.groups.empty?
          raise Flipper::UnsupportedDiagnostic,
            "feature #{name.inspect} is gated by Ruby group(s) #{values.groups.to_a.sort.inspect}, which are not supported by diagnostics (path: #{path.join(' -> ')})"
        end

        if values.percentage_of_time.to_i > 0
          raise Flipper::UnsupportedDiagnostic,
            "feature #{name.inspect} is gated by percentage of time, which is not supported by diagnostics (path: #{path.join(' -> ')})"
        end

        expression = values.expression
        if expression && !expression.empty?
          scan_expression(Flipper::Expression.build(expression), name, path)
        end
      end

      private

      def scan_expression(node, feature_name, path)
        case node
        when Flipper::Expression::Constant
          # constants carry no gates to scan
        when Flipper::Expression
          name = node.name

          if name == "FeatureEnabled"
            referenced = node.args.first
            referenced_name = referenced.respond_to?(:value) ? referenced.value.to_s : referenced.to_s
            # Circular references evaluate to false at runtime; the scan
            # stops here just like real evaluation would.
            unless path.include?(referenced_name)
              # FeatureEnabled resolves referenced features through the
              # global Flipper instance, matching runtime evaluation.
              scan_feature(Flipper, referenced_name, path)
            end
          elsif TIME_FUNCTIONS.include?(name)
            raise Flipper::UnsupportedDiagnostic,
              "feature #{feature_name.inspect} uses the #{name} expression, which depends on wall-clock time and is not supported by diagnostics (path: #{path.join(' -> ')})"
          elsif RANDOM_FUNCTIONS.include?(name)
            raise Flipper::UnsupportedDiagnostic,
              "feature #{feature_name.inspect} uses the #{name} expression, which is non-deterministic and not supported by diagnostics (path: #{path.join(' -> ')})"
          end

          node.args.each { |arg| scan_expression(arg, feature_name, path) }
        end
      end
    end
  end
end
