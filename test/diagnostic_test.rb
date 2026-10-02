require 'test_helper'
require 'flipper/diagnostic'

class DiagnosticTest < MiniTest::Test
  def setup
    @flipper = Flipper.new(Flipper::Adapters::Memory.new)
    @actor = Flipper::Actor.new('user-1', 'plan' => 'basic', 'age' => 18, 'admin' => false)
  end

  def suggest(feature = :search, actor = @actor, **options)
    @flipper.suggest_attribute_changes(feature, actor, **options)
  end

  def exhaust(feature = :search, actor = @actor, **options)
    @flipper.exhaustive_attribute_changes(feature, actor, **options)
  end

  def test_boolean_on_returns_zero_change_optimal_plan
    @flipper.enable(:search)

    result = suggest

    assert_equal :optimal, result.status
    assert_equal [], result.plan
    assert_equal 0, result.changed_count
  end

  def test_boolean_off_is_impossible_with_full_domain_evidence
    result = suggest(changeable: { 'plan' => ['free', 'pro'], 'age' => [21] })

    assert_equal :impossible, result.status
    assert_nil result.plan
    assert_equal result.domain_size, result.evaluations
    assert_equal 6, result.domain_size
  end

  def test_actor_gate_suggests_flipper_id_change_without_mutation
    @flipper.enable_actor(:search, Flipper::Actor.new('user-2'))

    result = suggest(changeable: { 'flipper_id' => ['user-2', 'user-3'] })

    assert_equal :optimal, result.status
    assert_equal 1, result.changed_count
    assert_equal 'user-2', result.plan.first.to
    refute @flipper.enabled?(:search, @actor)
    assert_equal Set['user-2'], @flipper[:search].actors_value
  end

  def test_flipper_id_cannot_be_both_changeable_and_fixed
    error = assert_raises(ArgumentError) do
      suggest(
        changeable: { 'flipper_id' => ['user-2'] },
        fixed: { 'flipper_id' => 'user-1' }
      )
    end
    assert_match(/both changeable and fixed/, error.message)
  end

  def test_two_attributes_must_change_together
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:age).gte(21)
    ))

    result = suggest(changeable: {
      'plan' => ['free', ['pro', 5]],
      'age' => [18, [21, 1], [30, 2]],
    })

    assert_equal :optimal, result.status
    assert_equal 2, result.changed_count
    assert_equal ['age', 'plan'], result.plan.map(&:attribute)
    assert_equal [21, 'pro'], result.plan.map(&:to)
    assert_equal 6, result.cost
    assert_equal result.domain_size, result.evaluations
  end

  def test_explicit_cost_breaks_same_count_ties
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:age).gte(21)
    ))

    result = suggest(changeable: {
      'plan' => [['pro', 5]],
      'age' => [[21, 9], [30, 1]],
    })

    assert_equal 2, result.changed_count
    assert_equal 6, result.cost
    assert_equal [30, 'pro'], result.plan.map(&:to)
  end

  def test_stable_order_breaks_cost_ties
    @flipper.enable_expression(:search, Flipper.property(:plan).eq('pro'))

    result = suggest(changeable: { 'plan' => [['pro', 2], ['pro', 2]] })

    assert_equal 1, result.changed_count
    assert_equal 'pro', result.plan.first.to
  end

  def test_zero_change_plan_when_already_enabled
    @flipper.enable_expression(:search, Flipper.property(:plan).eq('basic'))

    result = suggest(changeable: { 'plan' => ['free', 'pro'] })

    assert_equal :optimal, result.status
    assert_equal [], result.plan
  end

  def test_ruby_groups_are_unsupported
    Flipper.register(:staff) { |a| a.flipper_properties['staff'] == true }
    @flipper.enable_group(:search, :staff)

    error = assert_raises(Flipper::UnsupportedDiagnostic) { suggest }
    assert_match(/group/i, error.message)
  ensure
    Flipper.unregister_groups
  end

  def test_percentage_of_time_is_unsupported
    @flipper.enable_percentage_of_time(:search, 50)

    error = assert_raises(Flipper::UnsupportedDiagnostic) { suggest }
    assert_match(/percentage of time/, error.message)
  end

  def test_now_expression_is_unsupported
    @flipper.enable_expression(:search,
      Flipper.time(Flipper.now).eq(Flipper.time(Flipper.now)))

    error = assert_raises(Flipper::UnsupportedDiagnostic) { suggest }
    assert_match(/Time|Now/, error.message)
  end

  def test_random_expression_is_unsupported
    @flipper.enable_expression(:search, Flipper.random(100).eq(0))

    error = assert_raises(Flipper::UnsupportedDiagnostic) { suggest }
    assert_match(/Random/, error.message)
  end

  def test_percentage_of_actors_is_supported
    @flipper.enable_percentage_of_actors(:search, 100)

    result = suggest(changeable: { 'plan' => ['pro'] })
    assert_equal :optimal, result.status
    assert_equal [], result.plan
  end

  def test_unsupported_gate_is_detected_behind_feature_reference
    with_global_instance(@flipper) do
      @flipper.enable_percentage_of_time(:upstream, 50)
      @flipper.enable_expression(:search, Flipper.feature_enabled(:upstream))

      error = assert_raises(Flipper::UnsupportedDiagnostic) { suggest }
      assert_match(%r{upstream.*percentage of time}, error.message)
    end
  end

  def test_feature_enabled_reference_passes_hypothetical_actor
    with_global_instance(@flipper) do
      @flipper.enable_actor(:upstream, Flipper::Actor.new('vip'))
      @flipper.enable_expression(:search, Flipper.feature_enabled(:upstream))

      result = suggest(changeable: { 'flipper_id' => ['vip'] })

      assert_equal :optimal, result.status
      assert_equal 'vip', result.plan.first.to
    end
  end

  def test_circular_references_evaluate_false
    with_global_instance(@flipper) do
      @flipper.enable_expression(:search, Flipper.feature_enabled(:other))
      @flipper.enable_expression(:other, Flipper.feature_enabled(:search))

      result = suggest(changeable: { 'plan' => ['pro'] })

      assert_equal :impossible, result.status
      refute @flipper.enabled?(:search, @actor)
    end
  end

  def test_missing_property_reads_as_nil_like_real_evaluation
    @flipper.enable_expression(:search, Flipper.property(:beta).eq(true))
    plain_actor = Object.new
    def plain_actor.flipper_id; 'user-9'; end
    def plain_actor.flipper_properties; {}; end

    result = suggest(:search, plain_actor, changeable: { 'beta' => [true, false] })

    assert_equal :optimal, result.status
    assert_nil result.plan.first.from
    assert_equal true, result.plan.first.to
  end

  def test_type_coercion_follows_real_evaluation
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.number(Flipper.property(:age)).gte(21),
      Flipper.boolean(Flipper.property(:beta)).eq(true)
    ))
    coerced = Flipper::Actor.new('user-1', 'age' => '25', 'beta' => '1')
    assert @flipper.enabled?(:search, coerced)

    result = suggest(:search, coerced, changeable: { 'age' => ['18', '25'], 'beta' => ['0', '1'] })
    assert_equal :optimal, result.status
    assert_equal [], result.plan
  end

  def test_incompatible_comparison_is_false_like_comparable
    @flipper.enable_expression(:search, Flipper.property(:age).gt(21))
    string_actor = Flipper::Actor.new('user-1', 'age' => '25')
    refute @flipper.enabled?(:search, string_actor)

    result = suggest(:search, string_actor, changeable: { 'age' => [25, '25'] })
    assert_equal :optimal, result.status
    assert_equal 25, result.plan.first.to
  end

  def test_no_mutation_of_actor_or_gates
    @flipper.enable_expression(:search, Flipper.property(:plan).eq('pro'))
    gate_before = @flipper[:search].gate_values
    props_before = @actor.flipper_properties.dup

    suggest(changeable: { 'plan' => ['pro'] })

    assert_equal props_before, @actor.flipper_properties
    assert_equal gate_before, @flipper[:search].gate_values
    refute @flipper.enabled?(:search, @actor)
  end

  def test_budget_best_effort_after_finding_feasible_plan
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:age).gte(21)
    ))

    # The only feasible assignment (pro + 21) is the 8th of 9 evaluated.
    result = suggest(budget: 8, changeable: {
      'plan' => ['free', 'pro'], 'age' => [18, 21, 30]
    })

    assert_equal :best_effort, result.status
    assert result.feasible?
    assert_equal 8, result.evaluations
  end

  def test_budget_inconclusive_before_any_plan
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:age).gte(21)
    ))

    result = suggest(budget: 3, changeable: {
      'plan' => ['free', 'pro'], 'age' => [18, 21, 30]
    })

    assert_equal :inconclusive, result.status
    refute result.feasible?
  end

  def test_full_budget_is_optimal
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:age).gte(21)
    ))

    result = suggest(budget: 9, changeable: {
      'plan' => ['free', 'pro'], 'age' => [18, 21, 30]
    })

    assert_equal :optimal, result.status
    assert_equal 2, result.changed_count
  end

  def test_fixed_attribute_makes_target_unreachable
    actor = Flipper::Actor.new('user-1', 'plan' => 'basic', 'region' => 'us')
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:region).eq('cn')
    ))

    result = suggest(:search, actor,
      changeable: { 'plan' => ['pro', 'free'] },
      fixed: { 'region' => 'us' }
    )

    assert_equal :impossible, result.status
    assert_equal result.domain_size, result.evaluations
  end

  def test_fixed_attribute_is_kept_in_plan_attributes
    @flipper.enable_expression(:search, Flipper.property(:region).eq('cn'))

    result = suggest(
      changeable: { 'plan' => ['pro', 'free'] },
      fixed: { 'region' => 'cn' }
    )

    assert_equal :optimal, result.status
    assert_equal [], result.plan
    assert_equal 'cn', result.attributes['region']
  end

  def test_target_false_finds_a_disabling_plan
    @flipper.enable_expression(:search, Flipper.property(:plan).eq('pro'))
    pro_actor = Flipper::Actor.new('user-1', 'plan' => 'pro')

    result = suggest(:search, pro_actor,
      changeable: { 'plan' => ['basic', 'free'] }, target: false)

    assert_equal :optimal, result.status
    assert_equal 1, result.changed_count
    assert_equal 'basic', result.plan.first.to
  end

  def test_exhaustive_oracle_matches_ordered_search
    expressions = [
      Flipper.property(:plan).eq('pro'),
      Flipper.property(:age).gte(21),
      Flipper.all(Flipper.property(:plan).eq('pro'), Flipper.property(:age).gte(21)),
      Flipper.any(Flipper.property(:plan).eq('pro'), Flipper.property(:admin).eq(true)),
    ]
    domains = {
      'plan' => ['free', ['pro', 3], ['enterprise', 7]],
      'age' => [[18, 0], [21, 2], [30, 1]],
      'admin' => [true, false],
    }

    expressions.each do |expression|
      @flipper[:search].clear
      @flipper.enable_expression(:search, expression)
      actor = Flipper::Actor.new('user-1', 'plan' => 'basic', 'age' => 18, 'admin' => false)
      search = suggest(:search, actor, changeable: domains)
      oracle = exhaust(:search, actor, changeable: domains)

      assert_equal oracle.status, search.status
      assert_equal oracle.plan&.map(&:to_h), search.plan&.map(&:to_h)
      assert_equal oracle.cost, search.cost
    end
  end

  private

  def with_global_instance(flipper)
    original = Flipper.instance
    Flipper.instance = flipper
    yield
  ensure
    Flipper.instance = original
    Thread.current[:flipper_evaluating_features] = nil
  end
end
