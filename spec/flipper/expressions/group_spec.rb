RSpec.describe Flipper::Expressions::Group do
  before { Flipper.unregister_groups }

  it 'matches when the registered group matches the actor' do
    actor = Flipper::Actor.new('User;1', 'plan' => 'basic')
    Flipper.register(:basic) { |check_actor| check_actor.flipper_properties['plan'] == 'basic' }

    result = described_class.call('basic', context: { actor: actor })

    expect(result).to be(true)
  end

  it 'does not match when the actor is absent' do
    result = described_class.call('basic', context: { actor: nil })

    expect(result).to be(false)
  end

  it 'is usable from an expression via Flipper.in_group' do
    actor = Flipper::Actor.new('User;1', 'plan' => 'basic')
    Flipper.register(:basic) { |check_actor| check_actor.flipper_properties['plan'] == 'basic' }
    flipper = Flipper.new(Flipper::Adapters::Memory.new)
    flipper.enable_expression(:search, Flipper.in_group(:basic))

    expect(flipper.enabled?(:search, actor)).to be(true)
  end
end
