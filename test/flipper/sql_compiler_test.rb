require "sqlite3"
require "test_helper"

class FlipperSQLCompilerTest < Minitest::Test
  COLUMNS = {
    "flipper_id" => "flipper_id",
    "plan" => "plan",
    "age" => { column: "age", type: :integer },
    "admin" => { column: "admin", type: :boolean },
  }.freeze

  ACTORS = [
    Flipper::Actor.new("1", plan: "basic", age: 25, admin: true),
    Flipper::Actor.new("2", plan: "premium", age: 17, admin: false),
    Flipper::Actor.new("3", plan: "premium' OR '1'='1", age: 30, admin: false),
    Flipper::Actor.new("4", plan: "basic", age: nil, admin: false),
    Flipper::Actor.new("5", plan: "basic", age: "25", admin: false),
  ].freeze

  def setup
    @flipper = Flipper.new(Flipper::Adapters::Memory.new)
    @original_flipper = Flipper.instance
    Flipper.instance = @flipper
    @database = SQLite3::Database.new(":memory:")
    @database.execute <<~SQL
      CREATE TABLE actors (
        flipper_id TEXT PRIMARY KEY,
        plan TEXT,
        age BLOB,
        admin BLOB
      )
    SQL
    ACTORS.each do |actor|
      @database.execute(
        "INSERT INTO actors (flipper_id, plan, age, admin) VALUES (?, ?, ?, ?)",
        [actor.flipper_id, actor.flipper_properties[:plan],
         actor.flipper_properties[:age], actor.flipper_properties[:admin] ? 1 : 0]
      )
    end
  end

  def teardown
    Flipper.instance = @original_flipper
    Thread.current[:flipper_evaluating_features] = nil
  end

  def test_nested_rules_and_explicit_actors_match_enabled
    quoted_plan = "premium' OR '1'='1"
    @flipper.enable_expression(:search, Flipper.all(
      Flipper.any(
        Flipper.property(:plan).eq("basic"),
        Flipper.property(:plan).eq(quoted_plan)
      ),
      Flipper.property(:age).gte(Flipper.number("18"))
    ))
    @flipper.enable_actor(:search, Flipper::Actor.new("2"))

    sql, bindings = compile(:search)
    refute_includes sql, quoted_plan
    assert_includes bindings, quoted_plan
    assert_sql_matches_enabled(:search)
    assert_equal %w[1 2 3], sql_ids(:search)
  end

  def test_null_and_type_mismatches_match_ruby
    @flipper.enable_expression(:search, Flipper.any(
      Flipper.property(:age).gt(18),
      Flipper.property(:plan).neq("basic"),
      Flipper.property(:age).neq(18),
      Flipper.property(:admin).eq(true)
    ))

    assert_sql_matches_enabled(:search)
    assert_equal %w[1 2 3 4 5], sql_ids(:search)
  end

  def test_boolean_and_actor_gates
    @flipper.enable_actor(:search, Flipper::Actor.new("2"))
    assert_sql_matches_enabled(:search)
    assert_equal %w[2], sql_ids(:search)

    @flipper.enable(:search)
    assert_sql_matches_enabled(:search)
    assert_equal ACTORS.map(&:flipper_id), sql_ids(:search)

    @flipper.disable(:search)
    assert_sql_matches_enabled(:search)
    assert_empty sql_ids(:search)
  end

  def test_nested_and_diamond_feature_references
    @flipper.enable_expression(:base, Flipper.property(:age).gte(18))
    @flipper.enable_expression(:beta, Flipper.any(
      Flipper.feature_enabled(:base),
      Flipper.property(:admin).eq(true)
    ))
    @flipper.enable_expression(:gamma, Flipper.all(
      Flipper.feature_enabled(:base),
      Flipper.property(:plan).neq("basic")
    ))
    @flipper.enable_expression(:search, Flipper.any(
      Flipper.feature_enabled(:beta),
      Flipper.feature_enabled(:gamma)
    ))

    assert_sql_matches_enabled(:search)
    assert_equal %w[1 3], sql_ids(:search)
  end

  def test_feature_disabled
    @flipper.enable_expression(:beta, Flipper.property(:plan).eq("basic"))
    @flipper.enable_expression(:search, Flipper.feature_disabled(:beta))

    assert_sql_matches_enabled(:search)
    assert_equal %w[2 3], sql_ids(:search)
  end

  def test_feature_cycles_are_rejected
    @flipper.enable_expression(:search, Flipper.feature_enabled(:other))
    @flipper.enable_expression(:other, Flipper.feature_enabled(:search))

    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_equal "feature reference cycle detected: search -> other -> search.", error.message
  end

  def test_self_reference_is_rejected
    @flipper.enable_expression(:search, Flipper.feature_enabled(:search))

    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_equal "feature reference cycle detected: search -> search.", error.message
  end

  def test_ruby_groups_are_rejected
    Flipper.register(:staff) { |actor| actor.flipper_properties[:admin] }
    @flipper.enable_expression(:search, Flipper.property(:plan).eq("basic"))
    @flipper.enable_group(:search, :staff)

    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_match(/Ruby group/, error.message)
  end

  def test_percentage_gates_are_rejected
    @flipper.enable_percentage_of_actors(:search, 50)
    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_match(/percentage_of_actors/, error.message)

    @flipper[:search].clear
    @flipper.enable_percentage_of_time(:search, 50)
    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_match(/percentage_of_time/, error.message)
  end

  def test_one_hundred_percent_time
    @flipper.enable_percentage_of_time(:search, 100)
    assert_sql_matches_enabled(:search)
    assert_equal ACTORS.map(&:flipper_id), sql_ids(:search)
  end

  def test_dynamic_expressions_are_rejected
    @flipper.enable_expression(:search, Flipper.property(:age).gt(Flipper.random(100)))
    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_match(/"Random"/, error.message)

    @flipper[:search].clear
    @flipper.enable_expression(:search, Flipper.now.gte(Flipper.time(Time.now.to_i)))
    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_match(/"Now"/, error.message)
  end

  def test_missing_column_whitelist_entry
    @flipper.enable_expression(:search, Flipper.property(:missing).eq(true))

    error = assert_raises(Flipper::SQLCompiler::Error) { compile(:search) }
    assert_match(/"missing" is not included in the SQL column whitelist/, error.message)
  end

  private

  def compile(feature)
    @flipper.compile_sql(feature, columns: COLUMNS)
  end

  def sql_ids(feature)
    sql, bindings = compile(feature)
    @database.execute("SELECT flipper_id FROM actors WHERE #{sql}", bindings).flatten
  end

  def enabled_ids(feature)
    ACTORS.select { |actor| @flipper.enabled?(feature, actor) }.map(&:flipper_id)
  end

  def assert_sql_matches_enabled(feature)
    assert_equal enabled_ids(feature).sort, sql_ids(feature).sort
  end
end
