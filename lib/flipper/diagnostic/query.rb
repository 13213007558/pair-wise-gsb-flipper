module Flipper
  module Diagnostic
    # Internal: Normalized, immutable description of one diagnosis. Owns the
    # attribute domain and the only code path that builds a hypothetical
    # actor and runs it through Feature#enabled?.
    class Query
      FLIPPER_ID = "flipper_id".freeze

      attr_reader :dsl, :feature_name, :target, :budget
      attr_reader :attribute_names, :fixed_values, :base_values, :base_id

      def initialize(dsl:, feature_name:, actor:, changeable:, fixed:, target:, budget:)
        @dsl = dsl
        @feature_name = feature_name
        @target = target
        @budget = budget

        wrapped_actor = Flipper::Types::Actor.wrap(actor)
        @base_id = wrapped_actor.value

        base_properties = {}
        if actor.respond_to?(:flipper_properties)
          actor.flipper_properties.each { |key, value| base_properties[key.to_s] = value }
        end
        base_properties[FLIPPER_ID] = @base_id
        @base_values = base_properties

        fixed_map = {}
        Array(fixed).each { |key, value| fixed_map[key.to_s] = value }

        options_map = {}
        Array(changeable).each do |key, entries|
          name = key.to_s
          if fixed_map.key?(name)
            raise ArgumentError, "#{name.inspect} cannot be both changeable and fixed"
          end

          current = base_values.fetch(name, nil)
          options = []
          Array(entries).each do |entry|
            candidate = entry.is_a?(Candidate) ? entry : Candidate.coerce(entry)
            unless options.any? { |option| option[:value] == candidate.value }
              options << {value: candidate.value, cost: candidate.cost}
            end
          end
          # Keeping the current value is always an implicit option; if the
          # caller declared it, its explicit cost and position win.
          unless options.any? { |option| option[:value] == current }
            options.unshift(value: current, cost: 0)
          end
          options_map[name] = options
        end

        @fixed_values = fixed_map
        @options_by_attribute = options_map
        @attribute_names = options_map.keys
      end

      # Array of candidate option Hashes (:value, :cost) per attribute, in
      # declared attribute order.
      def options
        @options_by_attribute.values
      end

      def option_for(attribute, index)
        @options_by_attribute.fetch(attribute).fetch(index)
      end

      def domain_size
        @domain_size ||= options.reduce(1) { |product, opts| product * opts.size }
      end

      # Internal: Build the full assignment for an option-index vector: the
      # resulting attribute hash (including fixed attributes) and the subset
      # of changeable attributes actually changed.
      def assignment_for(indices)
        values = {}
        fixed_values.each { |name, value| values[name] = value }

        changes = []
        attribute_names.each_with_index do |name, position|
          option = option_for(name, indices[position])
          values[name] = option[:value]

          current = base_values.fetch(name, nil)
          unless current == option[:value]
            changes << Change.new(
              attribute: name,
              from: current,
              to: option[:value],
              cost: option[:cost]
            )
          end
        end

        [values, changes]
      end

      # Internal: Verify an assignment through the real Feature#enabled?
      # evaluation path. Returns true/false, exactly as production would.
      def evaluate(indices)
        values, = assignment_for(indices)
        hypothetical = HypotheticalActor.new(
          flipper_id: values.fetch(FLIPPER_ID, base_id),
          flipper_properties: values.reject { |name,| name == FLIPPER_ID }
        )
        !!dsl.enabled?(feature_name, hypothetical)
      end

      # Internal: Re-verify a completed plan through enabled? so a returned
      # plan is always backed by the actual gate implementation rather than
      # an internal evaluation cache.
      def verify!(indices)
        result = evaluate(indices)
        unless result == target
          raise Flipper::Error, "internal diagnostic verification failed: plan does not evaluate to #{target.inspect}"
        end
        result
      end

      def result_for(changes, indices, status, evaluations)
        values, = assignment_for(indices)
        plan = changes.sort_by(&:attribute)
        Result.new(
          status: status,
          plan: plan,
          attributes: values,
          changed_count: plan.size,
          cost: plan.sum(&:cost),
          evaluations: evaluations,
          budget: budget,
          domain_size: domain_size
        )
      end

      def empty_result(status, evaluations)
        Result.new(
          status: status,
          plan: nil,
          attributes: nil,
          changed_count: nil,
          cost: nil,
          evaluations: evaluations,
          budget: budget,
          domain_size: domain_size
        )
      end
    end
  end
end
