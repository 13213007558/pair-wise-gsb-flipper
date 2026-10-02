require "flipper/diagnostic"

RSpec.describe Flipper::Diagnostic do
  subject(:flipper) { Flipper.new(adapter) }

  let(:adapter) { Flipper::Adapters::Memory.new }
  let(:actor) { Flipper::Actor.new("user-1", actor_properties) }
  let(:actor_properties) { {"plan" => "basic", "age" => 18, "admin" => false} }
  let(:changeable) { {} }
  let(:fixed) { {} }

  def diagnose(feature = :search, **options)
    defaults = {changeable: changeable, fixed: fixed}
    flipper.suggest_attribute_changes(feature, actor, **defaults.merge(options))
  end

  def exhaust(feature = :search, **options)
    defaults = {changeable: changeable, fixed: fixed}
    flipper.exhaustive_attribute_changes(feature, actor, **defaults.merge(options))
  end

  describe "boolean gate" do
    it "reports a zero-change optimal plan when the feature is already on" do
      flipper.enable(:search)

      result = diagnose

      expect(result.status).to eq(:optimal)
      expect(result.plan).to eq([])
      expect(result.changed_count).to eq(0)
      expect(result.cost).to eq(0)
      expect(flipper.enabled?(:search, actor)).to be(true)
    end

    it "returns an impossible result backed by evaluating the whole domain when off" do
      changeable = {"plan" => ["free", "pro"], "age" => [21]}

      result = diagnose(changeable: changeable)

      expect(result.status).to eq(:impossible)
      expect(result.plan).to be_nil
      expect(result.evaluations).to eq(result.domain_size)
      expect(result.domain_size).to eq(6)
      expect(flipper.enabled?(:search, actor)).to be(false)
    end
  end

  describe "actor gate" do
    before { flipper.enable_actor(:search, Flipper::Actor.new("user-2")) }

    it "suggests changing flipper_id to the enabled actor" do
      result = diagnose(changeable: {"flipper_id" => ["user-2", "user-3"]})

      expect(result.status).to eq(:optimal)
      expect(result.changed_count).to eq(1)
      change = result.plan.first
      expect(change.attribute).to eq("flipper_id")
      expect(change.from).to eq("user-1")
      expect(change.to).to eq("user-2")
      # Nothing was actually enabled for the real actor.
      expect(flipper.enabled?(:search, actor)).to be(false)
      expect(flipper[:search].actors_value).to eq(Set["user-2"])
    end

    it "raises when flipper_id is also declared fixed" do
      expect do
        diagnose(
          changeable: {"flipper_id" => ["user-2"]},
          fixed: {"flipper_id" => "user-1"}
        )
      end.to raise_error(ArgumentError, /both changeable and fixed/)
    end

    it "returns impossible when the enabled id is not among the candidates" do
      result = diagnose(changeable: {"flipper_id" => ["user-3", "user-4"]})
      expect(result.status).to eq(:impossible)
      expect(result.evaluations).to eq(result.domain_size)
    end
  end

  describe "expression gate" do
    before do
      flipper.enable_expression(:search, Flipper.property(:plan).eq("pro"))
    end

    let(:changeable) { {"plan" => ["free", "pro", "enterprise"]} }

    it "changes the single property that matches" do
      result = diagnose

      expect(result.status).to eq(:optimal)
      expect(result.changed_count).to eq(1)
      expect(result.plan.first.to).to eq("pro")
      expect(result.cost).to eq(0)
    end

    it "picks the lowest explicit cost among same-count plans" do
      changeable = {"plan" => [["enterprise", 1], ["pro", 3]]}

      result = diagnose(changeable: changeable)

      expect(result.plan.first.to).to eq("enterprise")
      expect(result.cost).to eq(1)
    end

    describe "#two properties together" do
      before do
        flipper.enable_expression(:search, Flipper.all(
          Flipper.property(:plan).eq("pro"),
          Flipper.property(:age).gte(21)
        ))
      end

      let(:changeable) do
        {"plan" => ["free", ["pro", 5]], "age" => [18, [21, 1], [30, 2]]}
      end

      it "requires both attributes to change and picks the cheapest tie" do
        result = diagnose

        expect(result.status).to eq(:optimal)
        expect(result.changed_count).to eq(2)
        expect(result.plan.map(&:attribute)).to eq(["age", "plan"])
        expect(result.plan.map(&:to)).to eq([21, "pro"])
        expect(result.cost).to eq(6)
        # A change to neither attribute alone is ever enough.
        expect(result.evaluations).to eq(result.domain_size)
      end

      it "keeps explicit cost ordering even when change counts tie" do
        changeable = {
          "plan" => [["pro", 5]],
          "age" => [[21, 9], [30, 1]],
        }

        result = diagnose(changeable: changeable)

        expect(result.changed_count).to eq(2)
        expect(result.cost).to eq(6)
        expect(result.plan.map(&:to)).to eq([30, "pro"])
      end
    end
  end

  describe "unsupported gates" do
    it "rejects registered Ruby groups" do
      Flipper.register(:staff) { |actor| actor.flipper_properties["staff"] == true }
      flipper.enable_group(:search, :staff)

      expect { diagnose }.to raise_error(
        Flipper::UnsupportedDiagnostic, /group/i
      )
    end

    it "rejects percentage of time" do
      flipper.enable_percentage_of_time(:search, 50)
      expect { diagnose }.to raise_error(
        Flipper::UnsupportedDiagnostic, /percentage of time/
      )
    end

    it "rejects Now expressions" do
      flipper.enable_expression(:search,
        Flipper.time(Flipper.now).eq(Flipper.time(Flipper.now)))

      expect { diagnose }.to raise_error(
        Flipper::UnsupportedDiagnostic, /Now/
      )
    end

    it "rejects Random expressions" do
      flipper.enable_expression(:search,
        Flipper.random(100).eq(0))

      expect { diagnose }.to raise_error(
        Flipper::UnsupportedDiagnostic, /Random/
      )
    end

    it "allows deterministic percentage of actors" do
      flipper.enable_percentage_of_actors(:search, 100)

      result = diagnose(changeable: {"plan" => ["pro"]})
      expect(result.status).to eq(:optimal)
      expect(result.plan).to eq([])
    end

    it "detects an unsupported gate behind a feature reference" do
      Flipper.instance = flipper
      flipper.enable_percentage_of_time(:upstream, 50)
      flipper.enable_expression(:search, Flipper.feature_enabled(:upstream))

      expect { diagnose }.to raise_error(
        Flipper::UnsupportedDiagnostic, /upstream.*percentage of time/
      )
    ensure
      Flipper.instance = nil
    end
  end

  describe "references and evaluation rules" do
    it "follows FeatureEnabled references and passes the hypothetical actor" do
      Flipper.instance = flipper
      flipper.enable_actor(:upstream, Flipper::Actor.new("vip"))
      flipper.enable_expression(:search, Flipper.feature_enabled(:upstream))

      result = diagnose(changeable: {"flipper_id" => ["vip"]})

      expect(result.status).to eq(:optimal)
      expect(result.plan.first.to).to eq("vip")
    ensure
      Flipper.instance = nil
    end

    it "treats circular references as false, exactly like enabled?" do
      Flipper.instance = flipper
      flipper.enable_expression(:search, Flipper.feature_enabled(:other))
      flipper.enable_expression(:other, Flipper.feature_enabled(:search))

      result = diagnose(changeable: {"plan" => ["pro"]})

      expect(result.status).to eq(:impossible)
      expect(flipper.enabled?(:search, actor)).to be(false)
    ensure
      Flipper.instance = nil
    end

    it "follows real missing-property rules (missing reads as nil)" do
      flipper.enable_expression(:search,
        Flipper.property(:beta).eq(true))

      plain_actor = Object.new
      def plain_actor.flipper_id; "user-9"; end
      def plain_actor.flipper_properties; {}; end

      result = flipper.suggest_attribute_changes(
        :search, plain_actor,
        changeable: {"beta" => [true, false]}
      )

      expect(result.status).to eq(:optimal)
      expect(result.plan.first.from).to be_nil
      expect(result.plan.first.to).to be(true)
    end

    it "follows real type-coercion rules (Number/Boolean casts)" do
      flipper.enable_expression(:search, Flipper.all(
        Flipper.number(Flipper.property(:age)).gte(21),
        Flipper.boolean(Flipper.property(:beta)).eq(true)
      ))
      string_actor = Flipper::Actor.new("user-1", "age" => "25", "beta" => "1")

      # Already enabled because "25" casts to 25 and "1" casts to true.
      expect(flipper.enabled?(:search, string_actor)).to be(true)
      result = flipper.suggest_attribute_changes(
        :search, string_actor,
        changeable: {"age" => ["18", "25"], "beta" => ["0", "1"]}
      )
      expect(result.status).to eq(:optimal)
      expect(result.plan).to eq([])
    end

    it "treats type-incompatible comparisons as false like Comparable does" do
      flipper.enable_expression(:search, Flipper.property(:age).gt(21))
      string_actor = Flipper::Actor.new("user-1", "age" => "25")

      expect(flipper.enabled?(:search, string_actor)).to be(false)
      result = flipper.suggest_attribute_changes(
        :search, string_actor,
        changeable: {"age" => [25, "25"]}
      )
      expect(result.status).to eq(:optimal)
      expect(result.plan.first.to).to eq(25)
    end

    it "does not mutate the actor or any gate values" do
      flipper.enable_expression(:search, Flipper.property(:plan).eq("pro"))
      before = flipper[:search].gate_values
      actor_props = actor.flipper_properties.dup

      diagnose(changeable: {"plan" => ["pro"]})

      expect(actor.flipper_properties).to eq(actor_props)
      expect(flipper[:search].gate_values).to eq(before)
      expect(flipper.enabled?(:search, actor)).to be(false)
    end
  end

  describe "budget" do
    before do
      flipper.enable_expression(:search, Flipper.all(
        Flipper.property(:plan).eq("pro"),
        Flipper.property(:age).gte(21)
      ))
    end

    let(:changeable) do
      {"plan" => ["free", "pro"], "age" => [18, 21, 30]}
    end

    it "returns best_effort when a feasible plan is found but optimality is unproven" do
      # The only feasible assignment (pro + 21) is the 8th of 9 evaluated.
      result = diagnose(budget: 8)

      expect(result.status).to eq(:best_effort)
      expect(result.feasible?).to be(true)
      expect(result.evaluations).to eq(8)
      expect(result.budget).to eq(8)
    end

    it "returns optimal when the budget covers the whole domain" do
      result = diagnose(budget: 9)

      expect(result.status).to eq(:optimal)
      expect(result.evaluations).to eq(9)
      expect(result.changed_count).to eq(2)
    end

    it "returns inconclusive when the budget runs out before any plan" do
      result = diagnose(budget: 3)

      expect(result.status).to eq(:inconclusive)
      expect(result.feasible?).to be(false)
      expect(result.evaluations).to eq(3)
    end
  end

  describe "fixed attributes" do
    before do
      flipper.enable_expression(:search, Flipper.all(
        Flipper.property(:plan).eq("pro"),
        Flipper.property(:region).eq("cn")
      ))
    end

    it "makes a reachable target impossible when the needed value is fixed away" do
      result = diagnose(
        changeable: {"plan" => ["pro", "free"]},
        fixed: {"region" => "us"}
      )

      expect(result.status).to eq(:impossible)
      expect(result.evaluations).to eq(result.domain_size)
    end

    it "keeps fixed attributes present in the resulting attributes and unchanged" do
      result = diagnose(
        changeable: {"plan" => ["pro", "free"]},
        fixed: {"region" => "cn"}
      )

      expect(result.status).to eq(:optimal)
      expect(result.changed_count).to eq(0)
      expect(result.attributes["region"]).to eq("cn")
      expect(result.plan.map(&:attribute)).not_to include("region")
    end
  end

  describe "target: false" do
    it "finds a plan that disables an otherwise enabled expression" do
      flipper.enable_expression(:search, Flipper.property(:plan).eq("pro"))
      pro_actor = Flipper::Actor.new("user-1", "plan" => "pro")

      result = flipper.suggest_attribute_changes(
        :search, pro_actor,
        changeable: {"plan" => ["basic", "free"]},
        target: false
      )

      expect(result.status).to eq(:optimal)
      expect(result.changed_count).to eq(1)
      expect(result.plan.first.to).to eq("basic")
    end
  end

  describe "exhaustive oracle" do
    it "agrees with the ordered search across randomized small domains" do
      expressions = [
        Flipper.property(:plan).eq("pro"),
        Flipper.property(:age).gte(21),
        Flipper.all(
          Flipper.property(:plan).eq("pro"),
          Flipper.property(:age).gte(21)
        ),
        Flipper.any(
          Flipper.property(:plan).eq("pro"),
          Flipper.property(:admin).eq(true)
        ),
      ]
      domains = {
        "plan" => ["free", ["pro", 3], ["enterprise", 7]],
        "age" => [[18, 0], [21, 2], [30, 1]],
        "admin" => [true, false],
      }

      expressions.each do |expression|
        flipper[:search].clear
        flipper.enable_expression(:search, expression)
        actor = Flipper::Actor.new("user-1", "plan" => "basic", "age" => 18, "admin" => false)
        search = flipper.suggest_attribute_changes(:search, actor, changeable: domains)
        oracle = flipper.exhaustive_attribute_changes(:search, actor, changeable: domains)

        expect(search.status).to eq(oracle.status)
        expect(search.plan&.map(&:to_h)).to eq(oracle.plan&.map(&:to_h))
        expect(search.changed_count).to eq(oracle.changed_count)
        expect(search.cost).to eq(oracle.cost)
      end
    end
  end
end
