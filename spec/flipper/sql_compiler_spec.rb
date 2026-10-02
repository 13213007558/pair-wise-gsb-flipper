require "sqlite3"

RSpec.describe Flipper::SQLCompiler do
  subject(:flipper) { Flipper.new(Flipper::Adapters::Memory.new) }

  let(:columns) do
    {
      "flipper_id" => "flipper_id",
      "plan" => "plan",
      "age" => { column: "age", type: :integer },
      "admin" => { column: "admin", type: :boolean },
    }
  end

  let(:actors) do
    [
      Flipper::Actor.new("1", plan: "basic", age: 25, admin: true),
      Flipper::Actor.new("2", plan: "premium", age: 17, admin: false),
      Flipper::Actor.new("3", plan: "premium' OR '1'='1", age: 30, admin: false),
      Flipper::Actor.new("4", plan: "basic", age: nil, admin: false),
      Flipper::Actor.new("5", plan: "basic", age: "25", admin: false),
    ]
  end

  let(:database) do
    database = SQLite3::Database.new(":memory:")
    database.execute <<~SQL
      CREATE TABLE actors (
        flipper_id TEXT PRIMARY KEY,
        plan TEXT,
        age BLOB,
        admin BLOB
      )
    SQL

    actors.each do |actor|
      database.execute(
        "INSERT INTO actors (flipper_id, plan, age, admin) VALUES (?, ?, ?, ?)",
        [actor.flipper_id, actor.flipper_properties[:plan],
         actor.flipper_properties[:age], actor.flipper_properties[:admin] ? 1 : 0]
      )
    end

    database
  end

  before do
    @original_flipper = Flipper.instance
    Flipper.instance = flipper
  end

  after do
    Flipper.instance = @original_flipper
    Thread.current[:flipper_evaluating_features] = nil
  end

  def compile(name = :search)
    flipper.compile_sql(name, columns: columns)
  end

  def sql_ids(name = :search)
    sql, bindings = compile(name)
    database.execute("SELECT flipper_id FROM actors WHERE #{sql}", bindings).flatten
  end

  def enabled_ids(name = :search)
    actors.select { |actor| flipper.enabled?(name, actor) }.map(&:flipper_id)
  end

  def expect_sql_to_match_enabled(name = :search)
    expect(sql_ids(name)).to match_array(enabled_ids(name))
  end

  it "compiles nested property and explicit actor gates with bound values" do
    quoted_plan = "premium' OR '1'='1"
    flipper.enable_expression(:search, Flipper.all(
      Flipper.any(
        Flipper.property(:plan).eq("basic"),
        Flipper.property(:plan).eq(quoted_plan)
      ),
      Flipper.property(:age).gte(Flipper.number("18"))
    ))
    flipper.enable_actor(:search, Flipper::Actor.new("2"))

    sql, bindings = compile
    expect(sql).not_to include(quoted_plan)
    expect(bindings).to include(quoted_plan)
    expect_sql_to_match_enabled
    expect(enabled_ids).to match_array(%w[1 2 3])
  end

  it "matches Ruby for missing properties, NULL and type mismatches" do
    flipper.enable_expression(:search, Flipper.any(
      Flipper.property(:age).gt(18),
      Flipper.property(:plan).neq("basic"),
      Flipper.property(:age).neq(18),
      Flipper.property(:admin).eq(true)
    ))

    expect_sql_to_match_enabled
    expect(enabled_ids).to match_array(%w[1 2 3 4 5])
  end

  it "compiles boolean gates and explicit actors" do
    flipper.enable_actor(:search, Flipper::Actor.new("2"))
    expect_sql_to_match_enabled
    expect(enabled_ids).to match_array(%w[2])

    flipper.enable(:search)
    expect(sql_ids).to match_array(actors.map(&:flipper_id))
    expect(enabled_ids).to match_array(actors.map(&:flipper_id))

    flipper.disable(:search)
    expect(sql_ids).to eq([])
    expect(enabled_ids).to eq([])
  end

  it "compiles nested and diamond-shaped feature references" do
    flipper.enable_expression(:base, Flipper.property(:age).gte(18))
    flipper.enable_expression(:beta, Flipper.any(
      Flipper.feature_enabled(:base),
      Flipper.property(:admin).eq(true)
    ))
    flipper.enable_expression(:gamma, Flipper.all(
      Flipper.feature_enabled(:base),
      Flipper.property(:plan).neq("basic")
    ))
    flipper.enable_expression(:search, Flipper.any(
      Flipper.feature_enabled(:beta),
      Flipper.feature_enabled(:gamma)
    ))

    expect_sql_to_match_enabled
    expect(enabled_ids).to match_array(%w[1 3])
  end

  it "compiles feature-disabled expressions" do
    flipper.enable_expression(:beta, Flipper.property(:plan).eq("basic"))
    flipper.enable_expression(:search, Flipper.feature_disabled(:beta))

    expect_sql_to_match_enabled
    expect(enabled_ids).to match_array(%w[2 3])
  end

  it "detects feature reference cycles" do
    flipper.enable_expression(:search, Flipper.feature_enabled(:other))
    flipper.enable_expression(:other, Flipper.feature_enabled(:search))

    expect { compile }.to raise_error(
      Flipper::SQLCompiler::Error,
      "feature reference cycle detected: search -> other -> search."
    )
  end

  it "detects a self reference" do
    flipper.enable_expression(:search, Flipper.feature_enabled(:search))

    expect { compile }.to raise_error(
      Flipper::SQLCompiler::Error,
      "feature reference cycle detected: search -> search."
    )
  end

  it "rejects Ruby groups without emitting a partial predicate" do
    Flipper.register(:staff) { |actor| actor.flipper_properties[:admin] }
    flipper.enable_expression(:search, Flipper.property(:plan).eq("basic"))
    flipper.enable_group(:search, :staff)

    expect { compile }.to raise_error(Flipper::SQLCompiler::Error, /Ruby group/)
  end

  it "rejects percentage gates" do
    flipper.enable_percentage_of_actors(:search, 50)
    expect { compile }.to raise_error(Flipper::SQLCompiler::Error, /percentage_of_actors/)

    flipper[:search].clear
    flipper.enable_percentage_of_time(:search, 50)
    expect { compile }.to raise_error(Flipper::SQLCompiler::Error, /percentage_of_time/)
  end

  it "compiles a 100 percent gate as universally enabled" do
    flipper.enable_percentage_of_time(:search, 100)
    expect(sql_ids).to match_array(actors.map(&:flipper_id))
    expect_sql_to_match_enabled
  end

  it "rejects random and other dynamic expressions" do
    flipper.enable_expression(:search, Flipper.property(:age).gt(Flipper.random(100)))
    expect { compile }.to raise_error(Flipper::SQLCompiler::Error, /"Random"/)

    flipper[:search].clear
    flipper.enable_expression(:search, Flipper.now.gte(Flipper.time(Time.now.to_i)))
    expect { compile }.to raise_error(Flipper::SQLCompiler::Error, /"Now"/)
  end

  it "rejects properties absent from the whitelist" do
    flipper.enable_expression(:search, Flipper.property(:missing).eq(true))

    expect { compile }.to raise_error(
      Flipper::SQLCompiler::Error,
      /"missing" is not included in the SQL column whitelist/
    )
  end
end
