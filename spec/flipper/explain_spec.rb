require 'flipper/explain'

RSpec.describe 'Flipper.explain?' do
  let(:flipper) { Flipper.new(Flipper::Adapters::Memory.new) }
  let(:actor) do
    Flipper::Actor.new('User;1', 'plan' => 'basic', 'age' => 30, 'ssn' => 'secret')
  end

  before do
    Flipper.unregister_groups
    Flipper.instance = flipper
  end
  after { Flipper.configuration = nil }

  def gate(result, name)
    result.gates.find { |gate| gate.name == name }
  end

  it 'reports the gates checked in order and marks later gates skipped' do
    flipper.enable(:search)

    result = flipper.explain?(:search, actor)

    expect(result).to be_enabled
    expect(result.reason).to eq(:gate_open)
    expect(result.checked_gates.map(&:name)).to eq([:boolean])
    expect(gate(result, :boolean)).to be_open
    expect(gate(result, :actor).status).to eq(:skipped)
    expect(gate(result, :actor).reason).to eq(:short_circuit_gate)
    expect(result.skipped_gates.map(&:name)).to eq(
      [:expression, :actor, :percentage_of_actors, :percentage_of_time, :group]
    )
  end

  it 'checks every gate when none open and explains why each rejected' do
    flipper.disable(:search)

    result = flipper.explain?(:search, actor)

    expect(result).not_to be_enabled
    expect(result.reason).to eq(:no_open_gate)
    expect(result.gates.map(&:status)).to all(eq(:evaluated))
    expect(gate(result, :boolean).reason).to eq(:boolean_not_enabled)
    expect(gate(result, :expression).reason).to eq(:expression_not_enabled)
    expect(gate(result, :actor).reason).to eq(:no_actors_enabled)
    expect(gate(result, :percentage_of_actors).reason).to eq(:percentage_zero)
    expect(gate(result, :percentage_of_time).reason).to eq(:percentage_zero)
    expect(gate(result, :group).reason).to eq(:no_groups_enabled)
  end

  it 'explains the actor gate per actor' do
    flipper.enable_actor(:search, Flipper::Actor.new('User;2'))

    result = flipper.explain?(:search, actor)
    expect(result).not_to be_enabled
    actor_result = gate(result, :actor).actor_results.first
    expect(actor_result.flipper_id).to eq('User;1')
    expect(actor_result.result).to be(false)
    expect(actor_result.reason).to eq(:actor_not_enabled)
  end

  it 'records the actual random draw for percentage of time' do
    flipper.enable_percentage_of_time(:search, 50)

    result = flipper.explain?(:search, actor)
    pot = gate(result, :percentage_of_time)
    expect(pot.details[:percentage]).to eq(50)
    expect(pot.details[:actual_value]).to be_a(Float)
    expect(pot.details[:threshold]).to eq(0.5)
    expect(pot.result).to eq(pot.details[:actual_value] < 0.5)
  end

  it 'records the deterministic bucket for percentage of actors' do
    flipper.enable_percentage_of_actors(:search, 25)

    result = flipper.explain?(:search, actor)
    poa = gate(result, :percentage_of_actors)
    expect(poa.details[:percentage]).to eq(25)
    expect(poa.details).to include(:bucket, :threshold, :id)
    expect(poa.result).to eq(poa.details[:bucket] < poa.details[:threshold])
  end

  describe 'expression tree' do
    it 'records evaluated nodes and actor property values' do
      flipper.enable_expression(:search, Flipper.property(:plan).eq('basic'))

      result = flipper.explain?(:search, actor)
      tree = gate(result, :expression).actor_results.first.tree

      equal = tree
      expect(equal.name).to eq('Equal')
      expect(equal.result).to be(true)
      property = equal.args.first
      expect(property.name).to eq('Property')
      expect(property.details[:property]).to eq('plan')
      expect(property.details[:value]).to eq('basic')
    end

    it 'marks branches not executed by All short-circuit as skipped' do
      flipper.enable_expression(:search, Flipper.all(
        Flipper.property(:plan).eq('premium'),
        Flipper.property(:age).gt(21)
      ))

      result = flipper.explain?(:search, actor)
      tree = gate(result, :expression).actor_results.first.tree

      expect(tree.result).to be(false)
      expect(tree.args.first.result).to be(false)
      age = tree.args.last
      expect(age.status).to eq(:skipped)
      expect(age.reason).to eq(:short_circuit_all)
    end

    it 'marks branches not executed by Any short-circuit as skipped' do
      flipper.enable_expression(:search, Flipper.any(
        Flipper.property(:plan).eq('basic'),
        Flipper.property(:age).gt(21)
      ))

      result = flipper.explain?(:search, actor)
      tree = gate(result, :expression).actor_results.first.tree

      expect(tree.result).to be(true)
      expect(tree.args.first.result).to be(true)
      expect(tree.args.last.status).to eq(:skipped)
      expect(tree.args.last.reason).to eq(:short_circuit_any)
    end

    it 'records actual Now and Time values used by the check' do
      flipper.enable_expression(:search, Flipper.now.gt(Flipper.time('2020-01-01')))

      result = flipper.explain?(:search, actor)
      tree = gate(result, :expression).actor_results.first.tree
      expect(tree.args.first.details[:actual_value]).to be_a(Time)
      expect(tree.args.last.details[:actual_value]).to be_a(Time)
    end

    it 'records the actual Random value used by the check' do
      flipper.enable_expression(:search, Flipper.random(100).gt(50))

      result = flipper.explain?(:search, actor)
      tree = gate(result, :expression).actor_results.first.tree
      expect(tree.args.first.details[:actual_value]).to be_a(Integer)
      expect(tree.args.first.details[:max]).to eq(100)
    end

    it 'evaluates a group condition inside the expression exactly once' do
      calls = 0
      Flipper.register(:beta) do |check_actor|
        calls += 1
        check_actor.flipper_properties['plan'] == 'basic'
      end
      flipper.enable_expression(:search, Flipper.in_group(:beta))

      result = flipper.explain?(:search, actor)

      expect(result).to be_enabled
      expect(calls).to eq(1)
    end

    it 'does not evaluate a group inside a short-circuited branch' do
      calls = 0
      Flipper.register(:beta) { |_| calls += 1 }
      flipper.enable_expression(:search, Flipper.all(
        Flipper.property(:plan).eq('premium'),
        Flipper.in_group(:beta)
      ))

      flipper.explain?(:search, actor)

      expect(calls).to eq(0)
    end
  end

  describe 'sensitive properties' do
    it 'hides configured properties in the explanation' do
      Flipper.configuration.hidden_actor_properties = [:ssn]
      flipper.enable_expression(:search, Flipper.property(:ssn).eq('secret'))

      result = flipper.explain?(:search, actor)

      expect(result.properties.first['ssn']).to eq(:hidden)
      tree = gate(result, :expression).actor_results.first.tree
      expect(tree.args.first.details[:value]).to eq(:hidden)
    end

    it 'allows per-call hidden_properties override' do
      flipper.enable_expression(:search, Flipper.property(:plan).eq('basic'))

      result = flipper.explain?(:search, actor, hidden_properties: [:plan])

      expect(result.properties.first['plan']).to eq(:hidden)
    end
  end

  describe 'configuration' do
    it 'exposes hidden_actor_properties on configuration' do
      config = Flipper::Configuration.new
      expect(config.hidden_actor_properties).to eq([])
      config.hidden_actor_properties = [:email]
      expect(config.hidden_actor_properties).to eq([:email])
    end
  end

  describe 'FeatureEnabled' do
    it 'includes the nested feature explanation in the same evaluation' do
      flipper.enable_actor(:search_beta, actor)
      flipper.enable_expression(:search, Flipper.feature_enabled(:search_beta))

      result = flipper.explain?(:search, actor)
      tree = gate(result, :expression).actor_results.first.tree

      expect(tree.result).to be(true)
      expect(tree.feature_enabled.feature_name).to eq(:search_beta)
      expect(tree.feature_enabled).to be_enabled
      expect(tree.details[:path]).to eq(%w[search search_beta])
    end

    it 'reports the dependency path for a circular dependency' do
      flipper[:search].enable_expression(Flipper.feature_enabled(:other))
      flipper[:other].enable_expression(Flipper.feature_enabled(:search))

      result = flipper.explain?(:search)
      tree = gate(result, :expression).expression_tree

      expect(result).not_to be_enabled
      expect(tree.reason).to eq(:circular_dependency)
      expect(tree.details[:cycle]).to eq(%w[search other search])
    end

    it 'reports self-reference as a cycle' do
      flipper[:search].enable_expression(Flipper.feature_enabled(:search))

      result = flipper.explain?(:search)
      tree = gate(result, :expression).expression_tree

      expect(tree.reason).to eq(:circular_dependency)
      expect(tree.details[:cycle]).to eq(%w[search search])
    end

    it 'reports the path for a longer circular chain' do
      flipper[:root].enable_expression(Flipper.feature_enabled(:b))
      flipper[:b].enable_expression(Flipper.feature_enabled(:d))
      flipper[:d].enable_expression(Flipper.feature_enabled(:root))

      result = flipper.explain?(:root)
      tree = gate(result, :expression).expression_tree

      expect(tree.reason).to eq(:circular_dependency)
      expect(tree.details[:cycle]).to eq(%w[root b d root])
    end
  end

  it 'produces the result from one evaluation pass' do
    evaluations = 0
    Flipper.register(:check) do |check_actor|
      evaluations += 1
      check_actor.flipper_id == 'User;1'
    end
    flipper.enable_group(:search, :check)

    result = flipper.explain?(:search, actor)

    expect(result).to be_enabled
    expect(evaluations).to eq(1)
  end
end
