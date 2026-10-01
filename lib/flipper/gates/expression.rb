require "flipper/expression"

module Flipper
  module Gates
    class Expression < Gate
      # Internal: The name of the gate. Used for instrumentation, etc.
      def name
        :expression
      end

      # Internal: Name converted to value safe for adapter.
      def key
        :expression
      end

      def data_type
        :json
      end

      def enabled?(value)
        !value.nil? && !value.empty?
      end

      # Internal: Checks if the gate is open for a thing.
      #
      # Returns true if gate open for thing, false if not.
      def open?(context)
        data = context.values.expression
        return false if data.nil? || data.empty?
        expression = Flipper::Expression.build(data)

        if context.actors.nil? || context.actors.empty?
          !!expression.evaluate(feature_name: context.feature_name, properties: DEFAULT_PROPERTIES, actor: nil)
        else
          context.actors.any? do |actor|
            !!expression.evaluate(feature_name: context.feature_name, properties: properties(actor), actor: actor)
          end
        end
      end

      # Internal: Explain this gate with a single evaluation per actor that
      # records the full expression tree, short-circuited branches, actor
      # properties and concrete time/random values.
      def explain(result, context, session: nil, hidden_properties: [])
        data = context.values.expression

        if data.nil? || data.empty?
          result.complete!(false, reason: :expression_not_enabled)
          return
        end

        expression = Flipper::Expression.build(data)

        if context.actors.nil? || context.actors.empty?
          evaluator = Flipper::Explain::Evaluator.new(
            expression,
            feature_name: context.feature_name,
            properties: DEFAULT_PROPERTIES,
            actor: nil,
            session: session,
            hidden_properties: hidden_properties,
          )
          open = evaluator.call
          result.expression_tree = evaluator.root
          result.complete!(open, reason: open ? :expression_true : :expression_false)
          return
        end

        open = false
        context.actors.each do |actor|
          properties = properties(actor)
          evaluator = Flipper::Explain::Evaluator.new(
            expression,
            feature_name: context.feature_name,
            properties: properties,
            actor: actor,
            session: session,
            hidden_properties: hidden_properties,
          )
          matched = evaluator.call
          result.actor_results << Flipper::Explain::ActorResult.new(
            actor.value, matched,
            reason: matched ? :expression_true : :expression_false,
            tree: evaluator.root
          )
          if matched
            open = true
            break
          end
        end

        result.complete!(open, reason: open ? :expression_true : :expression_false)
      end

      def protects?(thing)
        thing.is_a?(Flipper::Expression) || thing.is_a?(Hash)
      end

      def wrap(thing)
        Flipper::Expression.build(thing)
      end

      private

      # Internal
      DEFAULT_PROPERTIES = {}.freeze

      def properties(actor)
        return DEFAULT_PROPERTIES if actor.nil?

        properties = {}

        if actor.respond_to?(:flipper_properties)
          properties.update(actor.flipper_properties)
        else
          warn "#{actor.inspect} does not respond to `flipper_properties` but should."
        end

        properties.transform_keys!(&:to_s)

        if actor.respond_to?(:flipper_id)
          properties["flipper_id".freeze] = actor.flipper_id
        end

        properties
      end
    end
  end
end
