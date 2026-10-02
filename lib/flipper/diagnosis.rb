require 'flipper/expression'

module Flipper
  # Public: Read-only diagnostic that answers "which property changes would
  # make this feature evaluate to the target state for this actor?".
  #
  # The caller declares a finite set of candidate values for the properties
  # that may change, the properties that must stay fixed, and the target
  # enabled? result. The diagnosis searches for the plan that changes the
  # fewest properties; ties are broken by explicit per-property cost and
  # finally by a stable, deterministic order (property names sorted, values
  # in declared candidate order).
  #
  # Only the boolean gate, the actor list gate and typed property
  # expressions (including feature references) are supported. Ruby groups,
  # time and random gates are reported as unsupported. Every candidate plan
  # is checked by calling Feature#enabled? with a wrapper actor, so circular
  # feature references, missing properties and type coercion behave exactly
  # like a real evaluation, and neither the actor nor the feature is
  # mutated.
  #
  # Examples
  #
  #   result = Flipper::Diagnosis.new(
  #     Flipper[:search],
  #     actor: user,
  #     target: true,
  #     mutable: { "plan" => %w[basic pro], "age" => [18, 30] },
  #     fixed: ["region"],
  #     costs: { "plan" => 5 },
  #     budget: 1_000
  #   ).solve
  #
  #   result.status  # => :optimal, :feasible, :infeasible, :exhausted or :unsupported
  #   result.changes # => { "plan" => "pro" }
  class Diagnosis
    # Public: Default maximum number of enabled? evaluations the search may
    # perform before giving up.
    DEFAULT_BUDGET = 10_000

    # Internal: Expression functions whose result depends on time or
    # randomness and therefore cannot be diagnosed deterministically.
    UNSUPPORTED_EXPRESSIONS = %w[Now Random Time PercentageOfActors].freeze

    # Internal: Property that carries the actor identity. It is not a
    # diagnosable attribute because changing it changes who the actor is.
    IDENTITY_PROPERTY = 'flipper_id'.freeze

    # Public: The outcome of a diagnosis.
    class Result
      # Public: One of :optimal (found and proven minimal), :feasible
      # (found but budget ran out before minimality was proven),
      # :infeasible (search space fully enumerated, no plan exists),
      # :exhausted (budget ran out before any plan was found) or
      # :unsupported (the feature uses gates this diagnostic cannot reason
      # about).
      attr_reader :status

      # Public: Hash of property name => new value for the chosen plan.
      # Empty when no plan was found or no change is needed.
      attr_reader :changes

      # Public: Total explicit cost of the chosen plan, nil when no plan
      # was found.
      attr_reader :cost

      # Public: Number of enabled? evaluations performed.
      attr_reader :evaluations

      # Public: The target enabled? result that was searched for.
      attr_reader :target

      # Public: Human readable reasons when status is :unsupported.
      attr_reader :unsupported_reasons

      def initialize(status:, target:, changes: {}, cost: nil, evaluations: 0,
                     verified: false, unsupported_reasons: [])
        @status = status
        @target = target
        @changes = changes
        @cost = cost
        @evaluations = evaluations
        @verified = verified
        @unsupported_reasons = unsupported_reasons
      end

      # Public: Number of properties the chosen plan changes.
      def change_count
        changes.size
      end

      # Public: True when a plan was found (:optimal or :feasible).
      def found?
        status == :optimal || status == :feasible
      end

      # Public: True when the plan is proven to change the fewest
      # properties possible (and to have the lowest explicit cost among
      # those plans).
      def optimal?
        status == :optimal
      end

      # Public: True when a plan was found but the budget ran out before
      # minimality was proven.
      def feasible?
        status == :feasible
      end

      # Public: True when the whole search space was enumerated and no
      # plan reaches the target.
      def infeasible?
        status == :infeasible
      end

      # Public: True when the budget ran out before any plan was found.
      def exhausted?
        status == :exhausted
      end

      # Public: True when the feature uses gates or expression functions
      # this diagnostic does not support.
      def unsupported?
        status == :unsupported
      end

      # Public: True when the chosen plan was put back through enabled?
      # and produced the target result.
      def verified?
        @verified
      end
    end

    # Internal: Wraps an actor so a candidate property set can be evaluated
    # without mutating the real actor.
    class PropertyOverride
      def initialize(actor, properties)
        @actor = actor
        @properties = properties
      end

      def flipper_id
        @actor.flipper_id
      end

      def flipper_properties
        @properties
      end
    end
    private_constant :PropertyOverride

    def initialize(feature, actor:, target:, mutable:, fixed: [], costs: {}, budget: DEFAULT_BUDGET)
      unless target == true || target == false
        raise ArgumentError, "target must be true or false"
      end
      unless mutable.is_a?(Hash) && !mutable.empty?
        raise ArgumentError, "mutable must be a non-empty Hash of property name => candidate values"
      end
      unless budget.is_a?(Integer) && budget >= 0
        raise ArgumentError, "budget must be a non-negative Integer"
      end

      mutable = mutable.each_with_object({}) do |(name, values), hash|
        name = name.to_s
        values = Array(values)
        if values.empty?
          raise ArgumentError, "mutable[#{name.inspect}] must declare at least one candidate value"
        end
        hash[name] = values
      end

      if mutable.key?(IDENTITY_PROPERTY)
        raise ArgumentError, "#{IDENTITY_PROPERTY.inspect} is the actor identity and cannot be diagnosed"
      end

      fixed = Array(fixed).map(&:to_s)
      overlap = fixed & mutable.keys
      unless overlap.empty?
        raise ArgumentError, "properties cannot be both fixed and mutable: #{overlap.join(', ')}"
      end

      costs = costs.each_with_object({}) do |(name, cost), hash|
        name = name.to_s
        unless mutable.key?(name)
          raise ArgumentError, "cost declared for unknown mutable property #{name.inspect}"
        end
        unless cost.is_a?(Numeric)
          raise ArgumentError, "cost for #{name.inspect} must be Numeric"
        end
        hash[name] = cost
      end

      @feature = feature
      @actor = actor
      @target = target
      @mutable = mutable
      @fixed = fixed
      @costs = costs
      @budget = budget
      @evaluations = 0
    end

    # Public: Runs the diagnosis and returns a Result.
    def solve
      reasons = unsupported_reasons
      unless reasons.empty?
        return Result.new(status: :unsupported, target: @target, unsupported_reasons: reasons)
      end

      current = current_properties

      # A property can only take part in a plan when one of its candidates
      # differs from the current value; otherwise it behaves like a fixed
      # property.
      searchable = {}
      @mutable.keys.sort.each do |name|
        values = @mutable[name].reject { |value| value == current[name] }
        searchable[name] = values unless values.empty?
      end
      attributes = searchable.keys

      best = nil
      best_cost = nil
      halted = false

      (0..attributes.size).each do |level|
        attributes.combination(level).each do |subset|
          tuples_for(subset, searchable).each do |values|
            if @evaluations >= @budget
              halted = true
              break
            end

            assignment = subset.zip(values).to_h
            if evaluate(current, assignment) == @target
              cost = cost_of(assignment)
              if best.nil? || cost < best_cost
                best = assignment
                best_cost = cost
              end
            end
          end
          break if halted
        end
        break if halted

        # A plan found at this level is proven minimal only once every
        # plan changing the same number of properties has been evaluated.
        return finalize(best, best_cost, current, :optimal) if best
      end

      if best
        finalize(best, best_cost, current, :feasible)
      elsif halted
        Result.new(status: :exhausted, target: @target, evaluations: @evaluations)
      else
        Result.new(status: :infeasible, target: @target, evaluations: @evaluations)
      end
    end

    private

    def tuples_for(subset, searchable)
      return [[]] if subset.empty?

      lists = subset.map { |name| searchable[name] }
      lists.first.product(*lists[1..])
    end

    def cost_of(assignment)
      assignment.keys.sum { |name| @costs.fetch(name, 1) }
    end

    def evaluate(current, assignment)
      @evaluations += 1
      @feature.enabled?(PropertyOverride.new(@actor, current.merge(assignment)))
    end

    # Internal: Puts the chosen plan back through enabled? with a fresh
    # wrapper actor. Always runs, even when the search budget is spent,
    # because a returned plan must be verified.
    def finalize(assignment, cost, current, status)
      verified = evaluate(current, assignment) == @target
      Result.new(
        status: status,
        target: @target,
        changes: assignment,
        cost: cost,
        evaluations: @evaluations,
        verified: verified
      )
    end

    def current_properties
      raw = @actor.respond_to?(:flipper_properties) ? @actor.flipper_properties : nil
      (raw || {}).each_with_object({}) do |(key, value), properties|
        properties[key.to_s] = value
      end
    end

    def unsupported_reasons
      reasons = []
      scan_feature(@feature.name.to_s, {}, reasons)
      reasons.uniq
    end

    def scan_feature(name, visited, reasons)
      return if visited[name]
      visited[name] = true

      values = Feature.new(name, @feature.adapter).gate_values
      reasons << "group gate on feature #{name.inspect}" unless values.groups.empty?
      if values.percentage_of_actors != 0
        reasons << "percentage_of_actors gate on feature #{name.inspect}"
      end
      if values.percentage_of_time != 0
        reasons << "percentage_of_time gate on feature #{name.inspect}"
      end

      expression = values.expression
      scan_expression(Expression.build(expression), name, visited, reasons) if expression
    end

    def scan_expression(expression, feature_name, visited, reasons)
      if UNSUPPORTED_EXPRESSIONS.include?(expression.name)
        reasons << "#{expression.name} expression on feature #{feature_name.inspect}"
      end

      if expression.name == 'FeatureEnabled'
        referenced = expression.args.first
        referenced_name = referenced.respond_to?(:value) ? referenced.value : nil
        scan_feature(referenced_name.to_s, visited, reasons) if referenced_name
      end

      expression.args.each do |arg|
        scan_expression(arg, feature_name, visited, reasons) if arg.is_a?(Flipper::Expression)
      end
    end
  end
end
