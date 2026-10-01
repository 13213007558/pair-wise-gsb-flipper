RSpec.describe Flipper::Experiment do
  let(:variants) do
    [
      { name: :control, weight: 34 },
      { name: :compact, weight: 33 },
      { name: :expanded, weight: 33 },
    ]
  end

  def build(**overrides)
    options = { namespace: :search_layout, variants: variants }
    described_class.new(**options.merge(overrides))
  end

  def actors(count = 1_000)
    (1..count).map { |index| Flipper::Actor.new("User;#{index}") }
  end

  describe '#initialize' do
    it 'accepts a namespace, weighted variants and an unassigned result' do
      experiment = build(unassigned_result: :control)
      expect(experiment.namespace).to eq('search_layout')
      expect(experiment.variant_names).to eq(%w[control compact expanded])
      expect(experiment.allocated_weight).to eq(100)
      expect(experiment.unassigned_result).to eq(:control)
    end

    it 'accepts :percentage as an alias for :weight' do
      experiment = described_class.new(
        namespace: :search_layout,
        variants: [{ name: :control, percentage: 100 }],
      )
      expect(experiment.weight(:control)).to eq(100)
    end

    it 'accepts string weights and converts them to numbers' do
      experiment = described_class.new(
        namespace: :search_layout,
        variants: [{ name: :control, weight: '25' }],
      )
      expect(experiment.weight(:control)).to eq(25)
    end

    it 'rejects a blank namespace' do
      expect { build(namespace: '   ') }
        .to raise_error(described_class::InvalidConfiguration, 'namespace cannot be blank')
    end

    it 'rejects negative weights' do
      variants.first[:weight] = -1
      expect { build }
        .to raise_error(described_class::InvalidConfiguration, /negative weight/)
    end

    it 'rejects duplicate variant names' do
      variants.last[:name] = :control
      expect { build }
        .to raise_error(described_class::InvalidConfiguration, /duplicated/)
    end

    it 'treats symbol and string duplicates as duplicates' do
      variants.first[:name] = 'control'
      variants.last[:name] = 'control'
      expect { build }.to raise_error(described_class::InvalidConfiguration, /duplicated/)
    end

    it 'rejects weights that total more than 100' do
      variants.each { |variant| variant[:weight] = 34 }
      expect { build }
        .to raise_error(described_class::InvalidConfiguration, /exceeds 100/)
    end

    it 'allows fractional weights that total 100' do
      expect do
        described_class.new(
          namespace: :search_layout,
          variants: [
            { name: :control, weight: 33.34 },
            { name: :compact, weight: 33.33 },
            { name: :expanded, weight: 33.33 },
          ],
        )
      end.not_to raise_error
    end

    it 'allows zero weights' do
      experiment = described_class.new(
        namespace: :search_layout,
        variants: [
          { name: :control, weight: 50 },
          { name: :compact, weight: 0 },
          { name: :expanded, weight: 50 },
        ],
      )
      expect(experiment.allocated_weight).to eq(100)
    end

    it 'rejects an empty variant list' do
      expect { build(variants: []) }
        .to raise_error(described_class::InvalidConfiguration, 'variants cannot be empty')
    end

    it 'rejects a non-array variant list' do
      expect { build(variants: { control: 10 }) }
        .to raise_error(described_class::InvalidConfiguration, 'variants must be an Array')
    end

    it 'rejects a blank variant name' do
      expect { build(variants: [{ name: '  ', weight: 100 }]) }
        .to raise_error(described_class::InvalidConfiguration, 'variant name cannot be blank')
    end
  end

  describe '#result_for' do
    it 'assigns each actor to at most one variant' do
      experiment = build
      results = actors.map { |actor| experiment.result_for(actor) }
      expect(results).to all(satisfy { |result| %w[control compact expanded].include?(result) })
      expect(results.uniq.sort).to eq(%w[compact control expanded])
    end

    it 'distributes actors roughly according to the weights' do
      experiment = build
      counts = Hash.new(0)
      actors(10_000).each { |actor| counts[experiment.result_for(actor)] += 1 }

      expect(counts['control']).to be_within(250).of(3_400)
      expect(counts['compact']).to be_within(250).of(3_300)
      expect(counts['expanded']).to be_within(250).of(3_300)
    end

    it 'is stable for the same actor across repeated checks' do
      experiment = build
      actor = Flipper::Actor.new('User;42')
      first = experiment.result_for(actor)
      10.times { expect(experiment.result_for(actor)).to eq(first) }
      expect(experiment.variant_for(actor).name).to eq(first)
    end

    it 'is stable across new instances with identical configuration' do
      actor = Flipper::Actor.new('User;42')
      expect(build.result_for(actor)).to eq(build.result_for(actor))
    end

    it 'accepts plain string and symbol actor ids' do
      experiment = build
      expect(experiment.result_for('User;42')).to eq(experiment.result_for(Flipper::Actor.new('User;42')))
      expect(experiment.result_for(:'User;42')).to eq(experiment.result_for('User;42'))
    end

    it 'accepts actors wrapped in Flipper::Types::Actor' do
      experiment = build
      wrapped = Flipper::Types::Actor.new(Flipper::Actor.new('User;42'))
      expect(experiment.result_for(wrapped)).to eq(experiment.result_for('User;42'))
    end

    it 'assigns independently for different namespaces' do
      actor = Flipper::Actor.new('User;9')
      namespaces = %i[alpha beta gamma delta epsilon]
      results = namespaces.map { |namespace| build(namespace: namespace).result_for(actor) }
      expect(results.uniq.size).to be > 1
    end

    it 'returns the unassigned result when weights do not total 100' do
      experiment = described_class.new(
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
      expect(counts[:off]).to be_within(250).of(7_000)
      expect(counts.values.sum).to eq(10_000)
    end

    it 'returns nil for unassigned actors by default' do
      experiment = described_class.new(
        namespace: :search_layout,
        variants: [{ name: :control, weight: 0 }],
      )
      expect(experiment.result_for(Flipper::Actor.new('User;1'))).to be_nil
      expect(experiment).to be_unassigned(Flipper::Actor.new('User;1'))
    end

    it 'never selects a zero weight variant' do
      experiment = described_class.new(
        namespace: :search_layout,
        variants: [
          { name: :control, weight: 0 },
          { name: :compact, weight: 0 },
          { name: :expanded, weight: 0 },
        ],
      )

      actors.each do |actor|
        expect(experiment.result_for(actor)).to be_nil
        expect(experiment.variant_for(actor)).to be_nil
        expect(experiment).to be_unassigned(actor)
      end
    end

    it 'never selects a zero weight variant even when it precedes weighted variants' do
      experiment = described_class.new(
        namespace: :search_layout,
        variants: [
          { name: :control, weight: 0 },
          { name: :compact, weight: 100 },
        ],
      )

      actors.each { |actor| expect(experiment.result_for(actor)).to eq('compact') }
    end

    it 'supports variant? checks' do
      experiment = build
      actor = Flipper::Actor.new('User;42')
      variant = experiment.result_for(actor)
      expect(experiment.variant?(variant, actor)).to be(true)
      expect(experiment.variant?(:nope, actor)).to be(false)
    end

    it 'raises for a nil actor' do
      expect { build.result_for(nil) }.to raise_error(ArgumentError, 'actor cannot be nil')
    end
  end

  describe 'bucketing' do
    it 'buckets with crc32 of the namespace plus actor value' do
      experiment = build
      actor = Flipper::Actor.new('User;7')
      expected = Zlib.crc32('search_layoutUser;7') % 100_000
      expect(experiment.bucket_for(actor)).to eq(expected)
    end

    it 'uses a mapping distinct from the percentage_of_actors feature mapping' do
      experiment = build
      actor = Flipper::Actor.new('User;7')
      percentage_gate_bucket = Zlib.crc32('some_featureUser;7') % 100_000
      expect(experiment.bucket_for(actor)).not_to eq(percentage_gate_bucket)
    end
  end

  describe 'serialization' do
    it 'round trips through a Hash without changing assignment' do
      experiment = build(unassigned_result: :control)
      restored = described_class.from_h(experiment.to_h)
      expect(restored).to eq(experiment)

      actors.each do |actor|
        expect(restored.variant_for(actor)).to eq(experiment.variant_for(actor))
      end
    end

    it 'round trips through JSON without changing assignment' do
      experiment = build(unassigned_result: 'off')
      restored = described_class.from_json(experiment.to_json)
      expect(restored).to eq(experiment)

      actors.each do |actor|
        expect(restored.result_for(actor)).to eq(experiment.result_for(actor))
      end
    end

    it 'preserves configured order and weights after serialization' do
      hash = build.to_h
      expect(hash['variants']).to eq([
        { 'name' => 'control', 'weight' => 34 },
        { 'name' => 'compact', 'weight' => 33 },
        { 'name' => 'expanded', 'weight' => 33 },
      ])
    end
  end

  describe 'Flipper.experiment' do
    it 'builds an experiment' do
      experiment = Flipper.experiment(
        namespace: :search_layout,
        variants: variants,
        unassigned_result: :control,
      )
      expect(experiment).to be_a(described_class)
      expect(experiment.result_for(Flipper::Actor.new('User;1'))).to be_a(String)
    end
  end
end
