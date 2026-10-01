require 'flipper/explanation'

RSpec.describe Flipper::Explanation do
  let(:adapter) { Flipper::Adapters::Memory.new }
  let(:flipper) { Flipper.new(adapter) }
  let(:actor) { Flipper::Actor.new("1", "email" => "user@example.com", "plan" => "pro") }

  def gate_check(explanation, name)
    explanation.gates.find { |gate| gate.name == name }
  end

  def expression_node(explanation)
    gate_check(explanation, :expression).details[:nodes].first
  end

  describe "result" do
    it "matches enabled? when the feature is disabled" do
      explanation = flipper[:search].explain(actor)

      expect(explanation.result).to be(false)
      expect(explanation.enabled?).to be(false)
      expect(explanation.result).to eq(flipper[:search].enabled?(actor))
    end

    it "matches enabled? when the feature is enabled" do
      flipper.enable(:search)

      explanation = flipper[:search].explain(actor)

      expect(explanation.result).to be(true)
      expect(explanation.result).to eq(flipper[:search].enabled?(actor))
    end
  end

  describe "gates" do
    it "records every gate checked with its value and reason" do
      explanation = flipper[:search].explain(actor)

      expect(explanation.gates.map(&:name)).to eq([
        :boolean, :expression, :actor, :percentage_of_actors, :percentage_of_time, :group,
      ])
      expect(explanation.gates).to all(be_evaluated)
      expect(explanation.gates).to all(satisfy { |gate| !gate.reason.nil? })
      expect(gate_check(explanation, :boolean).reason).to eq("boolean gate is disabled")
    end

    it "marks gates after the first open gate as short-circuited" do
      flipper.enable(:search)

      explanation = flipper[:search].explain(actor)

      expect(gate_check(explanation, :boolean)).to be_open
      skipped = explanation.gates - [gate_check(explanation, :boolean)]
      expect(skipped).to all(be_short_circuited)
      expect(skipped).to all(satisfy { |gate| gate.reason.include?("boolean gate already opened") })
    end

    it "records the actor gate miss reason" do
      flipper.enable_actor(:search, Flipper::Actor.new("2"))

      explanation = flipper[:search].explain(actor)

      actor_gate = gate_check(explanation, :actor)
      expect(actor_gate).not_to be_open
      expect(actor_gate.reason).to eq("no actor is in the enabled actors set")
    end

    it "records the actor gate hit" do
      flipper.enable_actor(:search, actor)

      explanation = flipper[:search].explain(actor)

      actor_gate = gate_check(explanation, :actor)
      expect(actor_gate).to be_open
      expect(actor_gate.reason).to include("1")
      expect(actor_gate.details[:matching_actors]).to eq(["1"])
    end

    it "records the random value used by the percentage of time gate" do
      flipper.enable_percentage_of_time(:search, 50)

      explanation = flipper[:search].explain(actor)

      gate = gate_check(explanation, :percentage_of_time)
      random = gate.details[:random]
      expect(random).to be_a(Float)
      expect(gate.open?).to eq(random < 0.5)
      expect(explanation.result).to eq(random < 0.5)
    end

    it "records the bucket used by the percentage of actors gate" do
      flipper.enable_percentage_of_actors(:search, 50)

      explanation = flipper[:search].explain(actor)

      gate = gate_check(explanation, :percentage_of_actors)
      expect(gate.details[:bucket]).to be_a(Integer)
      expect(gate.open?).to eq(gate.details[:bucket] < 50_000)
    end
  end

  describe "expression nodes" do
    it "records the node tree with hit and miss reasons" do
      flipper.enable_expression(:search, Flipper.property(:plan).eq("pro"))

      explanation = flipper[:search].explain(actor)

      expect(explanation.result).to be(true)
      gate = gate_check(explanation, :expression)
      expect(gate).to be_open
      expect(gate.reason).to eq("expression evaluated to true")

      node = expression_node(explanation)
      expect(node.name).to eq("Equal")
      expect(node.result).to be(true)
      expect(node.args.map(&:name)).to eq(["Property", "Constant"])
      expect(node.args.first.result).to eq("pro")
    end

    it "records why the expression rejected the actor" do
      flipper.enable_expression(:search, Flipper.property(:plan).eq("enterprise"))

      explanation = flipper[:search].explain(actor)

      expect(explanation.result).to be(false)
      gate = gate_check(explanation, :expression)
      expect(gate).not_to be_open
      expect(gate.reason).to eq("expression evaluated to false")
      expect(expression_node(explanation).result).to be(false)
    end

    it "marks Any branches after the first match as short-circuited" do
      flipper.enable_expression(:search, Flipper.any(
        Flipper.boolean(true),
        Flipper.property(:plan).eq("enterprise")
      ))

      node = expression_node(flipper[:search].explain(actor))

      expect(node.name).to eq("Any")
      expect(node.result).to be(true)
      expect(node.args[0]).to be_evaluated
      expect(node.args[1]).to be_short_circuited
      expect(node.args[1].name).to eq("Equal")
      expect(node.args[1].args.map(&:name)).to eq(["Property", "Constant"])
    end

    it "marks All branches after the first miss as short-circuited" do
      flipper.enable_expression(:search, Flipper.all(
        Flipper.boolean(false),
        Flipper.property(:plan).eq("pro")
      ))

      node = expression_node(flipper[:search].explain(actor))

      expect(node.name).to eq("All")
      expect(node.result).to be(false)
      expect(node.args[0]).to be_evaluated
      expect(node.args[1]).to be_short_circuited
    end

    it "records the actual time used by Now" do
      flipper.enable_expression(:search, Flipper.now.gte(Flipper.time("2020-01-01")))

      before = Time.now.utc
      node = expression_node(flipper[:search].explain(actor))
      after = Time.now.utc

      now_node = node.args[0]
      expect(now_node.name).to eq("Now")
      expect(now_node.result).to be_a(Time)
      expect(now_node.result).to be >= before
      expect(now_node.result).to be <= after
      expect(node.result).to be(true)
    end

    it "records the actual value used by Random" do
      flipper.enable_expression(:search, Flipper.random(10).lt(5))

      explanation = flipper[:search].explain(actor)
      node = expression_node(explanation)

      random_node = node.args[0]
      expect(random_node.name).to eq("Random")
      expect(random_node.result).to be_a(Integer)
      expect(random_node.result).to be >= 0
      expect(random_node.result).to be < 10
      expect(explanation.result).to eq(random_node.result < 5)
    end
  end

  describe "actor attributes" do
    it "includes the actor id and properties" do
      explanation = flipper[:search].explain(actor)

      expect(explanation.actors.size).to eq(1)
      expect(explanation.actors.first.flipper_id).to eq("1")
      expect(explanation.actors.first.properties).to eq(
        "email" => "user@example.com",
        "plan" => "pro"
      )
    end

    it "hides configured sensitive properties" do
      Flipper.configuration.explain_hidden_properties = [:email]

      explanation = flipper[:search].explain(actor)

      expect(explanation.actors.first.properties).to eq(
        "email" => "[HIDDEN]",
        "plan" => "pro"
      )
    end

    it "hides sensitive properties in Property expression nodes" do
      flipper.enable_expression(:search, Flipper.property(:email).eq("user@example.com"))

      explanation = flipper[:search].explain(actor, hidden_properties: [:email])

      expect(explanation.result).to be(true)
      property_node = expression_node(explanation).args[0]
      expect(property_node.result).to eq("user@example.com")
      expect(property_node.details[:hidden]).to be(true)
      expect(property_node.to_h[:result]).to eq("[HIDDEN]")
    end

    it "accepts hidden_properties per call" do
      explanation = flipper[:search].explain(actor, hidden_properties: ["plan"])

      expect(explanation.actors.first.properties).to eq(
        "email" => "user@example.com",
        "plan" => "[HIDDEN]"
      )
    end
  end

  describe "FeatureEnabled cycles" do
    it "records the dependency path of a circular reference" do
      # FeatureEnabled resolves nested features through the global instance.
      Flipper.enable_expression(:a, { "FeatureEnabled" => "b" })
      Flipper.enable_expression(:b, { "FeatureEnabled" => "a" })

      explanation = Flipper[:a].explain

      expect(explanation.result).to be(false)
      expect(explanation.cycles).to eq([["a", "b", "a"]])

      node = expression_node(explanation)
      expect(node.name).to eq("FeatureEnabled")
      expect(node.details[:feature]).to eq("b")
      expect(node.details[:cycle]).to eq(["a", "b", "a"])
    end

    it "records a self-referencing cycle" do
      Flipper.enable_expression(:a, { "FeatureEnabled" => "a" })

      explanation = Flipper[:a].explain

      expect(explanation.result).to be(false)
      expect(explanation.cycles).to eq([["a", "a"]])
    end
  end

  describe "single evaluation" do
    it "calls a counting group exactly once" do
      count = 0
      Flipper.register(:counting) { |*| count += 1 }
      flipper.enable_group(:search, :counting)

      explanation = flipper[:search].explain(actor)

      expect(explanation.result).to be(true)
      expect(count).to eq(1)
      expect(gate_check(explanation, :group).reason).to include("counting")
    end
  end

  describe "DSL" do
    it "is exposed through the DSL and Flipper module" do
      flipper.enable(:search)

      expect(flipper.explain(:search, actor)).to be_a(described_class)
      expect(flipper.explain(:search, actor).result).to be(true)
      expect(Flipper.explain(:search)).to be_a(described_class)
    end
  end

  describe "#to_h" do
    it "serializes the full explanation" do
      flipper.enable_expression(:search, Flipper.property(:plan).eq("pro"))

      hash = flipper[:search].explain(actor).to_h

      expect(hash[:feature]).to eq(:search)
      expect(hash[:result]).to be(true)
      expect(hash[:actors]).to eq([
        { flipper_id: "1", properties: { "email" => "user@example.com", "plan" => "pro" } },
      ])
      expect(hash[:cycles]).to eq([])

      expression_gate = hash[:gates].find { |gate| gate[:gate] == :expression }
      expect(expression_gate[:open]).to be(true)
      node = expression_gate[:details][:nodes].first
      expect(node[:name]).to eq("Equal")
      expect(node[:result]).to be(true)
      expect(node[:args].map { |arg| arg[:name] }).to eq(["Property", "Constant"])
    end
  end
end
