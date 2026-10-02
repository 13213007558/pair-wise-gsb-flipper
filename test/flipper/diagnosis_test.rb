require 'test_helper'

class DiagnosisTest < MiniTest::Test
  # Actor wrapper used by the independent reference implementation below.
  class PropertiesOverride
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

  def setup
    @adapter = Flipper::Adapters::Memory.new
    @flipper = Flipper.new(@adapter)
    Flipper.instance = @flipper

    @feature = @flipper[:search]
    @actor = Flipper::Actor.new('user-1', plan: 'basic', age: 20, region: 'us')
  end

  def teardown
    Flipper.instance = nil
    Flipper.unregister_groups
  end

  # Independent exhaustive reference: enumerates every subset of mutable
  # properties and every candidate combination, returning the minimal plan
  # by (change count, cost, stable order) or nil when unreachable.
  def reference_plan(feature, actor, mutable, costs, target)
    current = actor.flipper_properties.each_with_object({}) do |(key, value), hash|
      hash[key.to_s] = value
    end

    searchable = {}
    mutable.each do |name, values|
      name = name.to_s
      diff = values.reject { |value| value == current[name] }
      searchable[name] = diff unless diff.empty?
    end
    attributes = searchable.keys.sort

    best = nil
    best_cost = nil
    (0..attributes.size).each do |level|
      attributes.combination(level).each do |subset|
        lists = subset.map { |name| searchable[name] }
        tuples = subset.empty? ? [[]] : lists.first.product(*lists[1..])
        tuples.each do |values|
          assignment = subset.zip(values).to_h
          next unless feature.enabled?(PropertiesOverride.new(actor, current.merge(assignment))) == target

          cost = subset.sum { |name| costs.fetch(name, 1) }
          if best.nil? || cost < best_cost
            best = assignment
            best_cost = cost
          end
        end
      end
      return best if best
    end
    nil
  end

  def diagnose(feature, actor, target:, mutable:, fixed: [], costs: {}, budget: 1_000)
    Flipper::Diagnosis.new(
      feature,
      actor: actor,
      target: target,
      mutable: mutable,
      fixed: fixed,
      costs: costs,
      budget: budget
    ).solve
  end

  def test_boolean_gate_target_already_met
    @feature.enable
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.optimal?
    assert_equal({}, result.changes)
    assert_equal 0, result.change_count
    assert_equal 0, result.cost
    assert result.verified?
  end

  def test_boolean_gate_cannot_be_changed_by_properties
    @feature.enable
    result = diagnose(@feature, @actor, target: false, mutable: { 'plan' => %w[basic pro] })
    assert result.infeasible?
    refute result.found?
  end

  def test_actor_gate_target_already_met
    @feature.enable_actor(@actor)
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.optimal?
    assert_equal({}, result.changes)
  end

  def test_actor_gate_cannot_be_changed_by_properties
    @feature.enable_actor(@actor)
    result = diagnose(@feature, @actor, target: false, mutable: { 'plan' => %w[basic pro] })
    assert result.infeasible?

    other = Flipper::Actor.new('user-2', plan: 'basic')
    result = diagnose(@feature, other, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.infeasible?
  end

  def test_expression_single_property_change
    @feature.enable_expression(Flipper.property(:plan).eq('pro'))
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.optimal?
    assert_equal({ 'plan' => 'pro' }, result.changes)
    assert_equal 1, result.change_count
    assert_equal 1, result.cost
    assert result.verified?
  end

  def test_two_properties_must_change_together
    @feature.enable_expression(
      Flipper.all(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(30))
    )
    result = diagnose(
      @feature, @actor,
      target: true,
      mutable: { 'plan' => %w[basic pro], 'age' => [20, 35] }
    )
    assert result.optimal?
    assert_equal({ 'age' => 35, 'plan' => 'pro' }, result.changes)
    assert_equal 2, result.change_count
    assert result.verified?
  end

  def test_fixed_property_makes_target_unreachable
    @feature.enable_expression(Flipper.property(:region).eq('eu'))
    result = diagnose(
      @feature, @actor,
      target: true,
      mutable: { 'plan' => %w[basic pro] },
      fixed: [:region]
    )
    assert result.infeasible?
    refute result.found?
  end

  def test_property_cannot_be_both_fixed_and_mutable
    error = assert_raises(ArgumentError) do
      diagnose(
        @feature, @actor,
        target: true,
        mutable: { 'plan' => %w[basic pro] },
        fixed: [:plan]
      )
    end
    assert_includes error.message, 'plan'
  end

  def test_tie_broken_by_explicit_cost
    @feature.enable_expression(
      Flipper.any(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(30))
    )
    mutable = { 'plan' => %w[basic pro], 'age' => [20, 35] }

    result = diagnose(@feature, @actor, target: true, mutable: mutable,
                      costs: { 'plan' => 5, 'age' => 1 })
    assert result.optimal?
    assert_equal({ 'age' => 35 }, result.changes)
    assert_equal 1, result.cost

    result = diagnose(@feature, @actor, target: true, mutable: mutable,
                      costs: { 'plan' => 1, 'age' => 5 })
    assert result.optimal?
    assert_equal({ 'plan' => 'pro' }, result.changes)
    assert_equal 1, result.cost
  end

  def test_tie_broken_by_stable_order
    @feature.enable_expression(
      Flipper.any(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(30))
    )
    mutable = { 'plan' => %w[basic pro], 'age' => [20, 35] }

    first = diagnose(@feature, @actor, target: true, mutable: mutable)
    second = diagnose(@feature, @actor, target: true, mutable: mutable)
    assert first.optimal?
    # "age" sorts before "plan", so its single-change plan wins the tie.
    assert_equal({ 'age' => 35 }, first.changes)
    assert_equal first.changes, second.changes
  end

  def test_unsupported_group_gate
    Flipper.register(:admins) { |actor| true }
    @feature.enable_group(:admins)
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.unsupported?
    assert result.unsupported_reasons.any? { |reason| reason.include?('group gate') }
  end

  def test_unsupported_percentage_of_actors_gate
    @feature.enable_percentage_of_actors(50)
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.unsupported?
    assert result.unsupported_reasons.any? { |reason| reason.include?('percentage_of_actors') }
  end

  def test_unsupported_percentage_of_time_gate
    @feature.enable_percentage_of_time(50)
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.unsupported?
    assert result.unsupported_reasons.any? { |reason| reason.include?('percentage_of_time') }
  end

  def test_unsupported_random_expression
    @feature.enable_expression(Flipper.property(:age).gt(Flipper.random(100)))
    result = diagnose(@feature, @actor, target: true, mutable: { 'age' => [20, 35] })
    assert result.unsupported?
    assert result.unsupported_reasons.any? { |reason| reason.include?('Random') }
  end

  def test_unsupported_now_expression
    @feature.enable_expression(Flipper.property(:created_at).lt(Flipper.now))
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.unsupported?
    assert result.unsupported_reasons.any? { |reason| reason.include?('Now') }
  end

  def test_unsupported_gate_on_referenced_feature
    @flipper[:backend].enable_percentage_of_time(100)
    @feature.enable_expression(Flipper.feature_enabled(:backend))
    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.unsupported?
    assert result.unsupported_reasons.any? { |reason| reason.include?('backend') }
  end

  def test_feature_reference
    @flipper[:backend].enable
    @feature.enable_expression(Flipper.feature_enabled(:backend))

    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.optimal?
    assert_equal({}, result.changes)

    result = diagnose(@feature, @actor, target: false, mutable: { 'plan' => %w[basic pro] })
    assert result.infeasible?
  end

  def test_feature_reference_property_change_flows_through
    @flipper[:backend].enable_expression(Flipper.property(:plan).eq('pro'))
    @feature.enable_expression(Flipper.feature_enabled(:backend))

    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.optimal?
    assert_equal({ 'plan' => 'pro' }, result.changes)
    assert result.verified?
  end

  def test_circular_feature_reference_terminates
    @flipper[:a].enable_expression(Flipper.feature_enabled(:b))
    @flipper[:b].enable_expression(Flipper.feature_enabled(:a))

    result = diagnose(@flipper[:a], @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    refute result.unsupported?
    # The cycle evaluates to false just like a real enabled? call, and no
    # property change can break it.
    assert result.infeasible?
  end

  def test_missing_property_follows_evaluation_rules
    @feature.enable_expression(Flipper.property(:plan).eq('pro'))
    actor = Flipper::Actor.new('user-2', age: 20)

    result = diagnose(@feature, actor, target: true, mutable: { 'plan' => ['pro'] })
    assert result.optimal?
    assert_equal({ 'plan' => 'pro' }, result.changes)

    result = diagnose(@feature, actor, target: false, mutable: { 'plan' => ['pro'] })
    assert result.optimal?
    assert_equal({}, result.changes)
  end

  def test_type_coercion_follows_evaluation_rules
    @feature.enable_expression(Flipper.property(:age).gt(21))
    # "25" is not comparable with 21, so a real evaluation treats it as
    # false; only the Integer candidate satisfies the expression.
    result = diagnose(@feature, @actor, target: true, mutable: { 'age' => ['25', 25] })
    assert result.optimal?
    assert_equal({ 'age' => 25 }, result.changes)
  end

  def test_budget_exhausted_without_plan
    @feature.enable_expression(
      Flipper.all(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(30))
    )
    result = diagnose(
      @feature, @actor,
      target: true,
      mutable: { 'plan' => %w[basic pro], 'age' => [20, 35] },
      budget: 1
    )
    assert result.exhausted?
    refute result.found?
    refute result.infeasible?
  end

  def test_budget_exhausted_after_plan_is_feasible_not_optimal
    @feature.enable_expression(
      Flipper.any(
        Flipper.property(:plan).eq('pro'),
        Flipper.property(:age).gte(30),
        Flipper.property(:region).eq('eu')
      )
    )
    # Budget allows the no-change check plus the first single-change plan
    # (a match), but not the rest of the level that would prove minimality.
    result = diagnose(
      @feature, @actor,
      target: true,
      mutable: { 'plan' => %w[basic pro], 'age' => [20, 35], 'region' => %w[us eu] },
      budget: 2
    )
    assert result.feasible?
    assert result.found?
    refute result.optimal?
    assert_equal({ 'age' => 35 }, result.changes)
    assert result.verified?
  end

  def test_read_only
    @feature.enable_expression(Flipper.property(:plan).eq('pro'))
    properties_before = @actor.flipper_properties.dup
    gate_values_before = @feature.gate_values
    features_before = @adapter.features

    result = diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[basic pro] })
    assert result.optimal?

    assert_equal properties_before, @actor.flipper_properties
    assert_equal gate_values_before, @feature.gate_values
    assert_equal features_before, @adapter.features
    refute @feature.enabled?(@actor)
  end

  def test_feature_diagnose_convenience
    @feature.enable_expression(Flipper.property(:plan).eq('pro'))
    result = @feature.diagnose(@actor, target: true, mutable: { plan: %w[basic pro] })
    assert result.optimal?
    assert_equal({ 'plan' => 'pro' }, result.changes)
  end

  def test_validation
    assert_raises(ArgumentError) do
      diagnose(@feature, @actor, target: 'yes', mutable: { 'plan' => %w[pro] })
    end
    assert_raises(ArgumentError) do
      diagnose(@feature, @actor, target: true, mutable: {})
    end
    assert_raises(ArgumentError) do
      diagnose(@feature, @actor, target: true, mutable: { 'flipper_id' => %w[other] })
    end
    assert_raises(ArgumentError) do
      diagnose(@feature, @actor, target: true, mutable: { 'plan' => [] })
    end
    assert_raises(ArgumentError) do
      diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[pro] },
               costs: { 'unknown' => 1 })
    end
    assert_raises(ArgumentError) do
      diagnose(@feature, @actor, target: true, mutable: { 'plan' => %w[pro] }, budget: -1)
    end
  end

  def test_exhaustive_reference_small_domains
    scenarios = [
      # Two properties must change together; a third is irrelevant.
      {
        expression: Flipper.all(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(30)),
        mutable: { 'plan' => %w[basic pro], 'age' => [20, 35], 'region' => %w[us eu] },
        costs: {},
        target: true,
      },
      # Either change works alone; explicit cost breaks the tie.
      {
        expression: Flipper.any(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(30)),
        mutable: { 'plan' => %w[basic pro], 'age' => [20, 35], 'region' => %w[us eu] },
        costs: { 'plan' => 3, 'age' => 1 },
        target: true,
      },
      # region is not mutable (fixed), so the target is unreachable.
      {
        expression: Flipper.all(Flipper.property(:region).eq('eu'), Flipper.property(:plan).eq('pro')),
        mutable: { 'plan' => %w[basic pro] },
        costs: {},
        target: true,
      },
      # Only changing all three properties works.
      {
        expression: Flipper.all(
          Flipper.property(:plan).eq('pro'),
          Flipper.property(:age).gte(30),
          Flipper.property(:region).eq('eu')
        ),
        mutable: { 'plan' => %w[basic pro], 'age' => [20, 35], 'region' => %w[us eu] },
        costs: { 'region' => 10 },
        target: true,
      },
      # Single change suffices; stable order picks "age".
      {
        expression: Flipper.any(Flipper.property(:age).gte(30), Flipper.property(:region).eq('eu')),
        mutable: { 'plan' => %w[basic pro], 'age' => [20, 35], 'region' => %w[us eu] },
        costs: {},
        target: true,
      },
      # Target false is already met without changes.
      {
        expression: Flipper.property(:plan).eq('pro'),
        mutable: { 'plan' => %w[basic pro] },
        costs: {},
        target: false,
      },
    ]

    scenarios.each_with_index do |scenario, index|
      feature = @flipper["reference_#{index}"]
      feature.enable_expression(scenario[:expression])

      expected = reference_plan(feature, @actor, scenario[:mutable], scenario[:costs], scenario[:target])
      result = diagnose(
        feature, @actor,
        target: scenario[:target],
        mutable: scenario[:mutable],
        costs: scenario[:costs]
      )

      if expected.nil?
        assert result.infeasible?, "scenario #{index} should be infeasible"
      else
        assert result.optimal?, "scenario #{index} should be optimal, got #{result.status}"
        assert_equal expected, result.changes, "scenario #{index} changes"
        expected_cost = expected.keys.sum { |name| scenario[:costs].fetch(name, 1) }
        assert_equal expected_cost, result.cost, "scenario #{index} cost"
        assert result.verified?, "scenario #{index} should be verified"
      end
    end
  end
end
