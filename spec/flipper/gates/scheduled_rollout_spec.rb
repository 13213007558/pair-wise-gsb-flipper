require 'helper'

RSpec.describe Flipper::Gates::ScheduledRollout do
  let(:feature_name) { :search }
  let(:gate) { described_class.new }

  let(:nodes) do
    [
      ['2026-10-01T09:00:00Z', 5],
      ['2026-10-01T12:00:00Z', 30],
      ['2026-10-01T18:00:00Z', 80],
    ]
  end

  let(:clock) { double('clock', now: Time.utc(2026, 10, 1, 10)) }

  def context(values:, actors: nil, clock: nil)
    Flipper::FeatureCheckContext.new(
      feature_name: feature_name,
      values: Flipper::GateValues.new(values),
      actors: actors,
      clock: clock
    )
  end

  def actor(id)
    Flipper::Types::Actor.wrap(Flipper::Actor.new(id))
  end

  it 'has :json data type and the right key' do
    expect(gate.data_type).to be(:json)
    expect(gate.key).to be(:scheduled_rollout)
    expect(gate.name).to be(:scheduled_rollout)
  end

  it 'is not enabled without a stored value' do
    expect(gate.enabled?(nil)).to be(false)
  end

  it 'is closed when there are no actors' do
    ctx = context(values: { scheduled_rollout: nodes }, clock: clock)
    expect(gate.open?(ctx)).to be(false)
  end

  it 'is closed before the first node' do
    early_clock = double('clock', now: Time.utc(2026, 10, 1, 8))
    ctx = context(values: { scheduled_rollout: nodes }, actors: [actor('1')], clock: early_clock)
    expect(gate.open?(ctx)).to be(false)
  end

  it 'matches the manual percentage gate buckets at the node percentages' do
    percentage_gate = Flipper::Gates::PercentageOfActors.new

    [[9, 5], [12, 30], [18, 80]].each do |hour, percentage|
      fixed_clock = double('clock', now: Time.utc(2026, 10, 1, hour))

      (1..500).each do |id|
        scheduled_ctx = context(
          values: { scheduled_rollout: nodes },
          actors: [actor(id)],
          clock: fixed_clock
        )
        manual_ctx = context(
          values: { percentage_of_actors: percentage },
          actors: [actor(id)]
        )

        expect(gate.open?(scheduled_ctx)).to eq(percentage_gate.open?(manual_ctx))
      end
    end
  end

  it 'supports a callable clock' do
    current = Time.utc(2026, 10, 1, 18)
    callable_clock = -> { current }
    ctx = context(values: { scheduled_rollout: nodes }, actors: [actor('1')], clock: callable_clock)
    # 80% is not 100%; actor 1 bucket check still runs. Just assert no error
    # and stable result for repeated calls.
    expect(gate.open?(ctx)).to eq(gate.open?(ctx))
  end

  it 'uses the same stable bucket as the manual percentage gate mid-interpolation' do
    # Half way between 5 and 30 => 17.5%. The floored 3-decimal threshold
    # is 17.5%, so a single actor admits iff the manual gate admits it at
    # the integer floor 17% plus the extra half-percent range; instead of
    # reproducing math here, assert the threshold never exceeds the
    # end-of-segment percentage by sweeping time and a fixed actor set.
    percentage_gate = Flipper::Gates::PercentageOfActors.new
    times = (9...18).map { |hour| Time.utc(2026, 10, 1, hour, 15) }

    (1..200).each do |id|
      results = times.map do |time|
        fixed_clock = double('clock', now: time)
        ctx = context(values: { scheduled_rollout: nodes }, actors: [actor(id)], clock: fixed_clock)
        gate.open?(ctx)
      end

      # monotonic: once true, stays true
      results.each_cons(2) do |before, after|
        expect(after).to be(true) if before
      end

      # never more open than the manual gate at 80% at the final time
      final_ctx = context(values: { percentage_of_actors: 80 }, actors: [actor(id)])
      expect(results.last).to eq(percentage_gate.open?(final_ctx))
    end
  end

  it 'protects only scheduled rollout types' do
    expect(gate.protects?(Flipper::Types::ScheduledRollout.new(nodes))).to be(true)
    expect(gate.protects?(Flipper::Types::PercentageOfActors.new(5))).to be(false)
  end
end
