module Flipper
  # Public: The result of Feature#explain. Describes, from a single
  # evaluation, why a feature is enabled or disabled: which gates were
  # checked (and which were skipped due to short-circuiting), the actor
  # attributes used, the expression nodes evaluated, and any circular
  # FeatureEnabled dependency paths detected along the way.
  class Explanation
    # Public: Placeholder used in place of hidden actor property values.
    HIDDEN = "[HIDDEN]".freeze

    # Public: The name of the feature that was checked.
    attr_reader :feature_name

    # Public: The gate checks, in the order they were (or would have been)
    # evaluated. Gates after the first open gate are marked short-circuited.
    attr_reader :gates

    # Public: The attributes of the actors the feature was checked for.
    attr_reader :actors

    # Public: Circular FeatureEnabled dependency paths detected during this
    # evaluation, e.g. [["a", "b", "a"]]. Empty when no cycle occurred.
    attr_reader :cycles

    def initialize(feature_name:, result:, gates:, actors:, cycles: [])
      @feature_name = feature_name
      @result = result
      @gates = gates
      @actors = actors
      @cycles = cycles
    end

    # Public: The result of the evaluation this explanation was recorded
    # from. Always consistent with the gates and expression nodes recorded
    # here, because they were captured during the same evaluation.
    def result
      @result
    end
    alias_method :enabled?, :result

    def to_h
      {
        feature: feature_name,
        result: result,
        actors: actors.map(&:to_h),
        gates: gates.map(&:to_h),
        cycles: cycles,
      }
    end

    # Public: The check of a single gate.
    class GateCheck
      attr_reader :name, :value, :reason, :details

      def initialize(name:, value: nil, open: false, evaluated: true, reason: nil, details: {})
        @name = name
        @value = value
        @open = open
        @evaluated = evaluated
        @reason = reason
        @details = details
      end

      def open?
        @open
      end

      def evaluated?
        @evaluated
      end

      # Public: True when this gate was never checked because an earlier
      # gate already opened the feature.
      def short_circuited?
        !@evaluated
      end

      def to_h
        hash = {
          gate: name,
          evaluated: evaluated?,
          open: open?,
          reason: reason,
        }
        hash[:short_circuited] = true if short_circuited?
        hash[:value] = value unless value.nil?
        unless details.empty?
          hash[:details] = details.each_with_object({}) do |(key, detail_value), serialized|
            serialized[key] = self.class.serialize_detail(detail_value)
          end
        end
        hash
      end

      def self.serialize_detail(detail_value)
        case detail_value
        when ExpressionNode
          detail_value.to_h
        when Array
          detail_value.map { |item| serialize_detail(item) }
        else
          detail_value
        end
      end
    end

    # Public: One node of an expression tree as it was evaluated. Nodes
    # that were not executed because an Any/All group short-circuited are
    # included with evaluated? == false so the full shape of the expression
    # is visible.
    class ExpressionNode
      attr_reader :name, :args, :result, :details

      # Internal: Sentinel meaning "no display override; use result".
      UNSET = Object.new.freeze

      def initialize(name:, args: [], result: nil, evaluated: true, details: {}, display_result: UNSET)
        @name = name
        @args = args
        @result = result
        @evaluated = evaluated
        @details = details
        @display_result = display_result.equal?(UNSET) ? result : display_result
      end

      def evaluated?
        @evaluated
      end

      def short_circuited?
        !@evaluated
      end

      # Internal: Builds the structural node for an expression (or constant)
      # that was never evaluated, without evaluating it.
      def self.unevaluated(expression)
        if expression.is_a?(Expression)
          new(
            name: expression.name,
            args: expression.args.map { |arg| unevaluated(arg) },
            evaluated: false
          )
        else
          new(name: "Constant", result: expression.value, evaluated: false)
        end
      end

      def to_h
        hash = {
          name: name,
          evaluated: evaluated?,
          result: @display_result,
        }
        hash[:short_circuited] = true if short_circuited?
        hash[:details] = details unless details.empty?
        hash[:args] = args.map { |arg| arg.is_a?(ExpressionNode) ? arg.to_h : arg }
        hash
      end
    end

    # Public: The attributes of one actor as seen by the evaluation, with
    # configured sensitive properties replaced by HIDDEN.
    class ActorAttributes
      attr_reader :flipper_id, :properties

      def initialize(flipper_id:, properties: {})
        @flipper_id = flipper_id
        @properties = properties
      end

      def to_h
        {
          flipper_id: flipper_id,
          properties: properties,
        }
      end
    end
  end
end
