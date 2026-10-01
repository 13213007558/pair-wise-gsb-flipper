RSpec.describe Flipper::Experiment do
  subject(:experiment) do
    described_class.new(
      namespace: :search_redesign,
      variants: [
        { name: :control, weight: 10 },
        { name: :compact, weight: 20 },
        { name: :expanded, weight: 30 },
      ],
      unassigned: 'off'
    )
  end

  let(:actors) do
    (1..10_000).map { |id| Flipper::Actor.new("User;#{id}") }
  end

  describe '#initialize' do
    it 'accepts symbol configuration and exposes string values' do
      expect(experiment.namespace).to eq('search_redesign')
      expect(experiment.variant_names).to eq(%w[control compact expanded])
      expect(experiment.unassigned).to eq('off')
    end

    it 'accepts variant structs' do
      variant = described_class::Variant.new(name: :control, weight: 10)
      rebuilt = described_class.new(namespace: :x, variants: [variant], unassigned: nil)

      expect(rebuilt.weight_for(:control)).to eq(10)
    end

    it 'accepts names as keys and weights as values' do
      experiment = described_class.new(
        namespace: :x,
        variants: { control: 10, compact: 20 },
        unassigned: nil
      )

      expect(experiment.variant_names).to eq(%w[control compact])
      expect(experiment.weight_for(:compact)).to eq(20)
    end

    it 'rejects negative weights' do
      expect do
        described_class.new(
          namespace: :x,
          variants: [{ name: :control, weight: -1 }],
          unassigned: nil
        )
      end.to raise_error(ArgumentError, 'variant weights cannot be negative: control')
    end

    it 'rejects duplicate variant names' do
      variants = [
        { name: :control, weight: 10 },
        { name: 'control', weight: 20 },
      ]

      expect do
        described_class.new(namespace: :x, variants: variants, unassigned: nil)
      end.to raise_error(ArgumentError, 'duplicate variant names: control')
    end

    it 'rejects total weights over 100' do
      variants = [
        { name: :control, weight: 50 },
        { name: :compact, weight: 51 },
      ]

      expect do
        described_class.new(namespace: :x, variants: variants, unassigned: nil)
      end.to raise_error(ArgumentError, 'total variant weight cannot exceed 100, but was 101')
    end

    it 'allows zero-weight variants and unallocated capacity' do
      variants = [
        { name: :control, weight: 0 },
        { name: :compact, weight: 1 },
      ]

      experiment = described_class.new(namespace: :x, variants: variants, unassigned: nil)

      expect(experiment.total_weight).to eq(1)
    end

    it 'supports up to three decimal places in weights' do
      experiment = described_class.new(
        namespace: :x,
        variants: [{ name: :control, weight: 0.125 }],
        unassigned: nil
      )

      expect(experiment.weight_for(:control)).to eq(0.125)
    end

    it 'rejects weights with more than three decimal places' do
      expect do
        described_class.new(
          namespace: :x,
          variants: [{ name: :control, weight: 0.1234 }],
          unassigned: nil
        )
      end.to raise_error(ArgumentError, 'variant weight cannot have more than 3 decimal places: control')
    end
  end

  describe '#result_for' do
    it 'returns one configured result for every actor' do
      results = actors.map { |actor| experiment.result_for(actor) }

      expect(results.uniq).to match_array(%w[control compact expanded off])
    end

    it 'is stable for the same actor and configuration' do
      actor = Flipper::Actor.new('User;123')
      first = 10.times.map { experiment.result_for(actor) }

      expect(first.uniq).to eq([first.first])
    end

    it 'uses the namespace in bucketing' do
      other = described_class.new(
        namespace: :other,
        variants: experiment.variants.map(&:to_h),
        unassigned: experiment.unassigned
      )

      results_a = actors.first(1_000).map { |actor| experiment.result_for(actor) }
      results_b = actors.first(1_000).map { |actor| other.result_for(actor) }

      expect(results_a).not_to eq(results_b)
    end

    it 'assigns each actor in a fixed vector to at most one variant' do
      actor_vector = Array.new(500) { |index| Flipper::Actor.new("User;#{index + 1}") }
      selected = actor_vector.each_with_object({}) do |actor, groups|
        variant = experiment.variant_for(actor)
        (groups[variant] ||= []) << actor if variant
      end

      groups = selected.values
      groups.combination(2) do |group, other|
        expect(group & other).to be_empty
      end
      expect(groups.sum(&:size)).to be <= actor_vector.size
    end

    it 'never selects a zero-weight variant' do
      variants = [
        { name: :control, weight: 0 },
        { name: :compact, weight: 50 },
        { name: :expanded, weight: 50 },
      ]
      experiment = described_class.new(namespace: :x, variants: variants, unassigned: nil)

      results = actors.map { |actor| experiment.result_for(actor) }

      expect(results).not_to include('control')
    end

    it 'allocates contiguous ranges according to configured weights' do
      counts = actors.group_by { |actor| experiment.result_for(actor) }.transform_values(&:size)

      expect(counts['control']).to be_within(120).of(1_000)
      expect(counts['compact']).to be_within(160).of(2_000)
      expect(counts['expanded']).to be_within(200).of(3_000)
      expect(counts['off']).to be_within(220).of(4_000)
    end

    it 'supports flipper actors, wrapped actors, and plain actor ids' do
      actor = Flipper::Actor.new('User;123')
      wrapped = Flipper::Types::Actor.new(actor)

      expect(experiment.result_for(wrapped)).to eq(experiment.result_for(actor))
      expect(experiment.result_for('User;123')).to eq(experiment.result_for(actor))
    end

    it 'accepts numeric strings as weights' do
      experiment = described_class.new(
        namespace: :x,
        variants: [{ name: :control, weight: '10' }],
        unassigned: nil
      )

      expect(experiment.weight_for(:control)).to eq(10)
    end

    it 'rejects a nil actor' do
      expect { experiment.result_for(nil) }.to raise_error(ArgumentError, 'actor cannot be nil')
    end
  end

  describe 'serialization' do
    it 'can be built from a hash payload' do
      restored = described_class.from_payload(experiment.to_payload)

      expect(restored).to eq(experiment)
    end

    it 'preserves assignments after JSON serialization' do
      restored = described_class.from_payload(Typecast.to_json(experiment.to_payload))
      before = actors.first(1_000).map { |actor| experiment.result_for(actor) }
      after = actors.first(1_000).map { |actor| restored.result_for(actor) }

      expect(after).to eq(before)
    end

    it 'serializes a stable payload' do
      expect(experiment.to_payload).to eq(
        'namespace' => 'search_redesign',
        'variants' => [
          { 'name' => 'control', 'weight' => 10 },
          { 'name' => 'compact', 'weight' => 20 },
          { 'name' => 'expanded', 'weight' => 30 },
        ],
        'unassigned' => 'off'
      )
    end

    it 'works with the standard JSON serializer' do
      expect(JSON.parse(JSON.generate(experiment))).to eq(experiment.to_payload)
    end

    it 'compares equal for equivalent configurations' do
      restored = described_class.from_payload(Typecast.to_json(experiment.to_payload))

      expect(restored).to eq(experiment)
    end
  end

  describe 'independent experiments' do
    it 'can assign the same actor to a variant in each experiment' do
      one = described_class.new(
        namespace: :one,
        variants: [{ name: :control, weight: 100 }],
        unassigned: nil
      )
      two = described_class.new(
        namespace: :two,
        variants: [{ name: :control, weight: 100 }],
        unassigned: nil
      )
      actor = Flipper::Actor.new('User;1')

      expect(one.variant_for(actor)).to eq('control')
      expect(two.variant_for(actor)).to eq('control')
    end
  end

  describe 'Flipper.experiment' do
    it 'returns a configured experiment' do
      configured = Flipper.experiment(
        namespace: :x,
        variants: [{ name: :control, weight: 1 }],
        unassigned: false
      )

      expect(configured).to be_a(described_class)
      expect(configured.unassigned).to be(false)
    end
  end
end
