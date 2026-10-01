require 'test_helper'
require 'zlib'

class ExperimentTest < MiniTest::Test
  def build(**overrides)
    options = {
      namespace: :search_layout,
      variants: [
        { name: :control, weight: 34 },
        { name: :compact, weight: 33 },
        { name: :expanded, weight: 33 },
      ],
    }
    Flipper::Experiment.new(**options.merge(overrides))
  end

  def actors(count = 1_000)
    (1..count).map { |index| Flipper::Actor.new("User;#{index}") }
  end

  def test_initializes_with_namespace_variants_and_unassigned_result
    experiment = build(unassigned_result: :control)
    assert_equal 'search_layout', experiment.namespace
    assert_equal %w[control compact expanded], experiment.variant_names
    assert_equal 100, experiment.allocated_weight
    assert_equal :control, experiment.unassigned_result
  end

  def test_accepts_percentage_alias_for_weight
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [{ name: :control, percentage: 100 }],
    )
    assert_equal 100, experiment.weight(:control)
  end

  def test_coerces_string_weights
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [{ name: :control, weight: '25' }],
    )
    assert_equal 25, experiment.weight(:control)
  end

  def test_rejects_blank_namespace
    error = assert_raises(Flipper::Experiment::InvalidConfiguration) do
      build(namespace: '   ')
    end
    assert_equal 'namespace cannot be blank', error.message
  end

  def test_rejects_negative_weights
    error = assert_raises(Flipper::Experiment::InvalidConfiguration) do
      build(variants: [{ name: :control, weight: -1 }])
    end
    assert_match(/negative weight/, error.message)
  end

  def test_rejects_duplicate_variant_names
    error = assert_raises(Flipper::Experiment::InvalidConfiguration) do
      build(variants: [
        { name: 'control', weight: 50 },
        { name: :control, weight: 50 },
      ])
    end
    assert_match(/duplicated/, error.message)
  end

  def test_rejects_weights_totaling_more_than_100
    error = assert_raises(Flipper::Experiment::InvalidConfiguration) do
      build(variants: [
        { name: :control, weight: 34 },
        { name: :compact, weight: 34 },
        { name: :expanded, weight: 34 },
      ])
    end
    assert_match(/exceeds 100/, error.message)
  end

  def test_allows_fractional_weights_totaling_100
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [
        { name: :control, weight: 33.34 },
        { name: :compact, weight: 33.33 },
        { name: :expanded, weight: 33.33 },
      ],
    )
    assert_in_delta 100, experiment.allocated_weight, 0.001
  end

  def test_rejects_empty_variant_list
    assert_raises(Flipper::Experiment::InvalidConfiguration) { build(variants: []) }
  end

  def test_each_actor_gets_at_most_one_variant
    experiment = build
    allowed = %w[control compact expanded]
    results = actors.map { |actor| experiment.result_for(actor) }
    assert(results.all? { |result| allowed.include?(result) })
    assert_equal %w[compact control expanded], results.uniq.sort
  end

  def test_distribution_tracks_weights
    experiment = build
    counts = Hash.new(0)
    actors(10_000).each { |actor| counts[experiment.result_for(actor)] += 1 }
    assert_in_delta 3_400, counts['control'], 250
    assert_in_delta 3_300, counts['compact'], 250
    assert_in_delta 3_300, counts['expanded'], 250
  end

  def test_assignment_is_stable_for_repeated_checks
    experiment = build
    actor = Flipper::Actor.new('User;42')
    first = experiment.result_for(actor)
    10.times { assert_equal first, experiment.result_for(actor) }
  end

  def test_assignment_is_stable_across_equal_configurations
    actor = Flipper::Actor.new('User;42')
    assert_equal build.result_for(actor), build.result_for(actor)
  end

  def test_accepts_string_symbol_and_wrapped_actors
    experiment = build
    wrapped = Flipper::Types::Actor.new(Flipper::Actor.new('User;42'))
    assert_equal experiment.result_for('User;42'), experiment.result_for(wrapped)
    assert_equal experiment.result_for('User;42'), experiment.result_for(:'User;42')
  end

  def test_namespaces_assign_independently
    actor = Flipper::Actor.new('User;9')
    results = %i[alpha beta gamma delta epsilon].map do |namespace|
      build(namespace: namespace).result_for(actor)
    end
    assert_operator results.uniq.size, :>, 1
  end

  def test_unassigned_result_when_weights_total_under_100
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [
        { name: :control, weight: 10 },
        { name: :compact, weight: 10 },
        { name: :expanded, weight: 10 },
      ],
      unassigned_result: :off,
    )
    counts = Hash.new(0)
    actors(10_000).each { |actor| counts[experiment.result_for(actor)] += 1 }
    assert_in_delta 7_000, counts[:off], 250
    assert_equal 10_000, counts.values.sum
  end

  def test_unassigned_defaults_to_nil
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [{ name: :control, weight: 0 }],
    )
    assert_nil experiment.result_for(Flipper::Actor.new('User;1'))
    assert experiment.unassigned?(Flipper::Actor.new('User;1'))
  end

  def test_zero_weight_variants_are_never_selected
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [
        { name: :control, weight: 0 },
        { name: :compact, weight: 0 },
        { name: :expanded, weight: 0 },
      ],
    )
    actors.each do |actor|
      assert_nil experiment.result_for(actor)
      assert_nil experiment.variant_for(actor)
      assert experiment.unassigned?(actor)
    end
  end

  def test_zero_weight_variant_before_weighted_variant
    experiment = Flipper::Experiment.new(
      namespace: :search_layout,
      variants: [
        { name: :control, weight: 0 },
        { name: :compact, weight: 100 },
      ],
    )
    actors.each { |actor| assert_equal 'compact', experiment.result_for(actor) }
  end

  def test_bucket_uses_crc32_of_namespace_and_actor_value
    actor = Flipper::Actor.new('User;7')
    assert_equal Zlib.crc32('search_layoutUser;7') % 100_000, build.bucket_for(actor)
  end

  def test_bucketing_is_distinct_from_percentage_of_actors_mapping
    actor = Flipper::Actor.new('User;7')
    gate_bucket = Zlib.crc32('some_featureUser;7') % 100_000
    refute_equal gate_bucket, build.bucket_for(actor)
  end

  def test_hash_round_trip_preserves_assignment
    experiment = build(unassigned_result: :control)
    restored = Flipper::Experiment.from_h(experiment.to_h)
    assert_equal experiment, restored
    actors.each do |actor|
      assert_equal experiment.variant_for(actor), restored.variant_for(actor)
    end
  end

  def test_json_round_trip_preserves_assignment
    experiment = build(unassigned_result: 'off')
    restored = Flipper::Experiment.from_json(experiment.to_json)
    assert_equal experiment, restored
    actors.each do |actor|
      assert_equal experiment.result_for(actor), restored.result_for(actor)
    end
  end

  def test_serialization_preserves_order_and_weights
    assert_equal [
      { 'name' => 'control', 'weight' => 34 },
      { 'name' => 'compact', 'weight' => 33 },
      { 'name' => 'expanded', 'weight' => 33 },
    ], build.to_h['variants']
  end

  def test_flipper_experiment_factory
    experiment = Flipper.experiment(namespace: :x, variants: [{ name: :a, weight: 100 }])
    assert_instance_of Flipper::Experiment, experiment
    assert_equal 'a', experiment.result_for(Flipper::Actor.new('User;1'))
  end

  def test_nil_actor_raises
    assert_raises(ArgumentError) { build.result_for(nil) }
  end
end
