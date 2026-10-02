require 'test_helper'
require 'sqlite3'

class SqlCompilerTest < Minitest::Test
  class FakeActor
    attr_reader :flipper_id, :flipper_properties

    def initialize(flipper_id, flipper_properties = {})
      @flipper_id = flipper_id
      @flipper_properties = flipper_properties
    end
  end

  ATTRIBUTES = {
    "plan" => "plan",
    "age" => "age",
    "name" => "name",
    "admin" => "admin",
  }.freeze

  # id, plan, age, name, admin. The age and admin columns have no type
  # affinity on purpose so text and integer values coexist, like real
  # actor property hashes.
  ROWS = [
    ["1", "pro", 30, "O'Brien", 1],
    ["2", "free", 17, 'say "hi"', 0],
    ["3", "pro", "25", "string age", "true"],
    ["4", "enterprise", 40, "null plan", nil],
    ["5", nil, 0, nil, "1"],
    ["6", "pro", nil, "no age", "yes"],
    ["7", "x'); DROP TABLE actors;--", 21, "injector", 0],
  ].freeze

  def setup
    @adapter = Flipper::Adapters::Memory.new
    @flipper = Flipper.new(@adapter)
    @previous_instance = Flipper.instance
    Flipper.instance = @flipper

    @db = SQLite3::Database.new(":memory:")
    @db.execute("CREATE TABLE actors (flipper_id TEXT PRIMARY KEY, plan TEXT, age, name TEXT, admin)")
    ROWS.each do |row|
      @db.execute("INSERT INTO actors (flipper_id, plan, age, name, admin) VALUES (?, ?, ?, ?, ?)", row)
    end

    @actors = ROWS.map do |id, plan, age, name, admin|
      properties = {}
      properties["plan"] = plan unless plan.nil?
      properties["age"] = age unless age.nil?
      properties["name"] = name unless name.nil?
      properties["admin"] = admin unless admin.nil?
      FakeActor.new(id, properties)
    end
  end

  def teardown
    Flipper.instance = @previous_instance
    @db.close
  end

  def compile(feature, attributes: ATTRIBUTES, actor_column: "flipper_id")
    Flipper::SqlCompiler.compile(
      feature,
      attributes: attributes,
      actor_column: actor_column,
      flipper: @flipper
    )
  end

  def matching_ids(feature, **options)
    result = compile(feature, **options)
    @db.execute("SELECT flipper_id FROM actors WHERE #{result.sql}", result.binds).flatten.sort
  end

  # The core guarantee: the compiled SQL selects exactly the actors for
  # which enabled? returns true.
  def assert_matches_ruby(feature, **options)
    expected = @actors.select { |actor| feature.enabled?(actor) }.map(&:flipper_id).sort
    assert_equal expected, matching_ids(feature, **options)
  end

  def set_expression(feature, hash)
    gate = feature.gate(:expression)
    @adapter.enable(feature, gate, gate.wrap(hash))
  end

  def test_boolean_gate_matches_everyone_when_on
    feature = @flipper[:all_on]
    feature.enable
    assert_equal "1 = 1", compile(feature).sql
    assert_matches_ruby(feature)
  end

  def test_feature_without_gates_matches_nobody
    feature = @flipper[:untouched]
    assert_equal "1 = 0", compile(feature).sql
    assert_matches_ruby(feature)
  end

  def test_actor_gate_compiles_to_in_list_with_binds
    feature = @flipper[:actors_only]
    feature.enable_actor(FakeActor.new("3"))
    feature.enable_actor(FakeActor.new("1"))

    result = compile(feature)
    assert_equal "flipper_id IN (?, ?)", result.sql
    assert_equal ["1", "3"], result.binds
    assert_matches_ruby(feature)
  end

  def test_actor_gate_requires_actor_column
    feature = @flipper[:actors_only]
    feature.enable_actor(FakeActor.new("1"))

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) do
      compile(feature, actor_column: nil)
    end
    assert_includes error.message, "actor_column"
  end

  def test_equal_with_quoted_value_is_bound_not_interpolated
    feature = @flipper[:quoted]
    feature.enable_expression({ "Equal" => [{ "Property" => ["name"] }, "O'Brien"] })

    result = compile(feature)
    refute_includes result.sql, "O'Brien"
    assert_includes result.binds, "O'Brien"
    assert_equal ["1"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_double_quoted_value_is_bound
    feature = @flipper[:double_quoted]
    feature.enable_expression({ "Equal" => [{ "Property" => ["name"] }, 'say "hi"'] })

    assert_equal ["2"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_sql_injection_attempt_in_rule_value_matches_nothing_and_preserves_table
    feature = @flipper[:injection]
    feature.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, "x' OR '1'='1' --"] })

    assert_equal [], matching_ids(feature)
    assert_matches_ruby(feature)
    assert_equal ROWS.size, @db.get_first_value("SELECT COUNT(*) FROM actors")
  end

  def test_injection_attempt_matching_existing_value_only_matches_that_actor
    feature = @flipper[:injector_plan]
    feature.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, "x'); DROP TABLE actors;--"] })

    assert_equal ["7"], matching_ids(feature)
    assert_matches_ruby(feature)
    assert_equal ROWS.size, @db.get_first_value("SELECT COUNT(*) FROM actors")
  end

  def test_malicious_column_names_are_rejected
    feature = @flipper[:any]
    feature.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, "pro"] })

    assert_raises(ArgumentError) do
      compile(feature, attributes: { "plan" => "plan; DROP TABLE actors" })
    end
    assert_raises(ArgumentError) do
      compile(feature, actor_column: "flipper_id OR 1=1")
    end
  end

  def test_missing_property_is_not_equal_and_not_ordered_but_is_not_equal
    feature = @flipper[:neq]
    feature.enable_expression({ "NotEqual" => [{ "Property" => ["plan"] }, "pro"] })

    # Ruby: nil != "pro" is true, so actors 5 (NULL plan) matches.
    assert_equal ["2", "4", "5", "7"], matching_ids(feature)
    assert_matches_ruby(feature)

    feature = @flipper[:eq]
    feature.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, "pro"] })
    assert_equal ["1", "3", "6"], matching_ids(feature)
    assert_matches_ruby(feature)

    feature = @flipper[:gt]
    feature.enable_expression({ "GreaterThan" => [{ "Property" => ["age"] }, 20] })
    # NULL age (actor 6) and text age (actor 3, "25" > 20 raises in Ruby) are false.
    assert_equal ["1", "4", "7"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_untyped_comparison_respects_ruby_type_rules
    feature = @flipper[:eq_int]
    feature.enable_expression({ "Equal" => [{ "Property" => ["age"] }, 30] })
    # Actor 1 (30) matches; actor 3 ("25") is text and never equals a number.
    assert_equal ["1"], matching_ids(feature)
    assert_matches_ruby(feature)

    feature = @flipper[:eq_text]
    feature.enable_expression({ "Equal" => [{ "Property" => ["age"] }, "25"] })
    assert_equal ["3"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_number_coercion_casts_and_treats_missing_as_zero
    feature = @flipper[:adult]
    feature.enable_expression({ "GreaterThanOrEqualTo" => [{ "Number" => [{ "Property" => ["age"] }] }, 21] })

    # 30, "25" (coerced), 40, 21 match; 17, 0 and NULL (coerced to 0) do not.
    assert_equal ["1", "3", "4", "7"], matching_ids(feature)
    assert_matches_ruby(feature)

    feature = @flipper[:zero]
    feature.enable_expression({ "Equal" => [{ "Number" => [{ "Property" => ["age"] }] }, 0] })
    # NULL coerces to 0 in Ruby (Typecast.to_number(nil) == 0).
    assert_equal ["5", "6"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_string_coercion_matches_ruby_to_s
    feature = @flipper[:stringy]
    feature.enable_expression({ "Equal" => [{ "String" => [{ "Property" => ["age"] }] }, "30"] })
    assert_equal ["1"], matching_ids(feature)
    assert_matches_ruby(feature)

    feature = @flipper[:stringy_neq]
    feature.enable_expression({ "NotEqual" => [{ "String" => [{ "Property" => ["age"] }] }, ""] })
    # NULL (actor 6) coerces to "" and is excluded.
    assert_equal ["1", "2", "3", "4", "5", "7"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_boolean_property_mirrors_typecast
    feature = @flipper[:admins]
    feature.enable_expression({ "Boolean" => [{ "Property" => ["admin"] }] })

    # 1, "true" and "1" are true; 0, "yes" and NULL are not.
    assert_equal ["1", "3", "5"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_nested_all_any
    feature = @flipper[:nested]
    feature.enable_expression({
      "All" => [
        { "Any" => [
          { "Equal" => [{ "Property" => ["plan"] }, "pro"] },
          { "Equal" => [{ "Property" => ["plan"] }, "enterprise"] },
        ] },
        { "Any" => [
          { "GreaterThan" => [{ "Number" => [{ "Property" => ["age"] }] }, 39] },
          { "LessThan" => [{ "Number" => [{ "Property" => ["age"] }] }, 18] },
        ] },
      ],
    })

    # pro/enterprise and (age > 39 or age < 18): actor 2 (free) is out,
    # actor 4 (enterprise, 40) is in, actors 1/3 (pro, 30/"25") are out,
    # actor 6 (pro, NULL age) is in because NULL coerces to 0 and 0 < 18.
    assert_equal ["4", "6"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_property_on_the_right_flips_ordering_operators
    feature = @flipper[:flipped]
    feature.enable_expression({ "LessThan" => [21, { "Number" => [{ "Property" => ["age"] }] }] })

    assert_equal ["1", "3", "4"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_constant_sub_expressions_are_folded
    feature = @flipper[:folded]
    feature.enable_expression({ "Equal" => [{ "Number" => ["5"] }, 5] })
    assert_equal "1 = 1", compile(feature).sql
    assert_matches_ruby(feature)

    feature = @flipper[:folded_false]
    feature.enable_expression({ "Equal" => [1, 2] })
    assert_equal "1 = 0", compile(feature).sql
    assert_matches_ruby(feature)
  end

  def test_empty_groups_match_ruby_semantics
    feature = @flipper[:empty_all]
    set_expression(feature, { "All" => [] })
    assert_matches_ruby(feature)

    feature = @flipper[:empty_any]
    set_expression(feature, { "Any" => [] })
    assert_matches_ruby(feature)

    feature = @flipper[:all_with_empty_any]
    set_expression(feature, { "All" => [{ "Any" => [] }, { "Equal" => [{ "Property" => ["plan"] }, "pro"] }] })
    assert_matches_ruby(feature)

    feature = @flipper[:any_with_empty_all]
    set_expression(feature, { "Any" => [{ "All" => [] }, { "Equal" => [{ "Property" => ["plan"] }, "pro"] }] })
    assert_matches_ruby(feature)
  end

  def test_combined_gates_are_union
    feature = @flipper[:combined]
    feature.enable_actor(FakeActor.new("2"))
    feature.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, "enterprise"] })

    assert_equal ["2", "4"], matching_ids(feature)
    assert_matches_ruby(feature)
  end

  def test_feature_reference_inlines_referenced_feature
    child = @flipper[:child]
    child.enable_actor(FakeActor.new("5"))
    child.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, "pro"] })

    parent = @flipper[:parent]
    parent.enable_expression({ "FeatureEnabled" => ["child"] })

    assert_equal ["1", "3", "5", "6"], matching_ids(parent)
    assert_matches_ruby(parent)
  end

  def test_nested_feature_references
    c = @flipper[:c]
    c.enable
    b = @flipper[:b]
    b.enable_expression({ "FeatureEnabled" => ["c"] })
    a = @flipper[:a]
    a.enable_expression({ "All" => [{ "FeatureEnabled" => ["b"] }, { "Equal" => [{ "Property" => ["plan"] }, "free"] }] })

    assert_equal ["2"], matching_ids(a)
    assert_matches_ruby(a)
  end

  def test_circular_feature_reference_compiles_to_false_like_ruby
    ping = @flipper[:ping]
    ping.enable_expression({ "FeatureEnabled" => ["pong"] })
    pong = @flipper[:pong]
    pong.enable_expression({ "Any" => [{ "FeatureEnabled" => ["ping"] }, { "Equal" => [{ "Property" => ["plan"] }, "pro"] }] })

    # The circular edge is false, so only pong's own condition remains.
    assert_equal ["1", "3", "6"], matching_ids(pong)
    assert_matches_ruby(pong)
    assert_matches_ruby(ping)
  end

  def test_group_gate_is_not_compilable
    feature = @flipper[:grouped]
    feature.enable(Flipper::Types::Group.new(:admins))

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "group"
  end

  def test_boolean_gate_short_circuits_other_gates_like_ruby
    feature = @flipper[:fully_on_with_stale_gates]
    @adapter.enable(feature, feature.gate(:boolean), Flipper::Types::Boolean.new(true))
    @adapter.enable(feature, feature.gate(:group), Flipper::Types::Group.new(:admins))

    assert_equal "1 = 1", compile(feature).sql
    assert_matches_ruby(feature)
  end

  def test_percentage_of_actors_gate_is_not_compilable
    feature = @flipper[:poa]
    feature.enable_percentage_of_actors(10)

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "percentage_of_actors"
  end

  def test_percentage_of_time_gate_is_not_compilable
    feature = @flipper[:pot]
    feature.enable_percentage_of_time(10)

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "percentage_of_time"
  end

  def test_volatile_expressions_are_not_compilable
    feature = @flipper[:random]
    feature.enable_expression({ "LessThan" => [{ "Random" => [100] }, 50] })
    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "Random"

    feature = @flipper[:now]
    feature.enable_expression({ "LessThan" => [{ "Now" => [] }, { "Time" => ["2030-01-01"] }] })
    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "Now"

    feature = @flipper[:poa_expr]
    feature.enable_expression({ "PercentageOfActors" => [{ "Property" => ["flipper_id"] }, 10] })
    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "PercentageOfActors"
  end

  def test_unmapped_property_is_not_compilable
    feature = @flipper[:unmapped]
    feature.enable_expression({ "Equal" => [{ "Property" => ["secret"] }, "x"] })

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "secret"
  end

  def test_bare_property_is_not_compilable
    feature = @flipper[:bare]
    feature.enable_expression({ "Property" => ["plan"] })

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "Property"
  end

  def test_comparison_between_two_properties_is_not_compilable
    feature = @flipper[:two_props]
    feature.enable_expression({ "Equal" => [{ "Property" => ["plan"] }, { "Property" => ["name"] }] })

    error = assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
    assert_includes error.message, "two properties"
  end

  def test_not_compilable_feature_produces_no_partial_sql
    feature = @flipper[:partial]
    feature.enable_actor(FakeActor.new("1"))
    feature.enable_percentage_of_time(5)

    assert_raises(Flipper::SqlCompiler::NotCompilable) { compile(feature) }
  end

  def test_result_to_a
    feature = @flipper[:boolean_true]
    feature.enable
    assert_equal ["1 = 1", []], compile(feature).to_a
  end
end
