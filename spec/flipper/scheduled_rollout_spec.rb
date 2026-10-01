require 'helper'

RSpec.describe 'scheduled rollout' do
  let(:current_time) { Time.utc(2026, 10, 1, 8) }
  let(:clock) { -> { current_time } }
  let(:flipper) { Flipper.new(Flipper::Adapters::Memory.new, clock: clock, memoize: false) }

  let(:nodes) do
    [
      ['2026-10-01T09:00:00Z', 5],
      ['2026-10-01T12:00:00Z', 30],
      ['2026-10-01T18:00:00Z', 80],
    ]
  end

  User = Struct.new(:flipper_id)

  before do
    flipper.enable_scheduled_rollout(:search, nodes)
  end

  it 'reports the gate as conditional but off before start' do
    expect(flipper.feature(:search)).to be_conditional
    expect(flipper.feature(:search).enabled_gate_names).to include(:scheduled_rollout)
    expect(flipper.enabled?(:search, User.new('1'))).to be(false)
  end

  it 'rolls out as the injected clock advances and holds at the final node' do
    current_time = Time.utc(2026, 10, 1, 10, 30)
    at_175 = (1..1000).count { |id| flipper.enabled?(:search, User.new('u' + id.to_s)) }
    expect(at_175).to be_between(140, 210)

    current_time = Time.utc(2026, 10, 1, 12)
    at_30 = (1..1000).count { |id| flipper.enabled?(:search, User.new('u' + id.to_s)) }
    expect(at_30).to be_between(260, 340)

    current_time = Time.utc(2026, 10, 2)
    at_80 = (1..1000).count { |id| flipper.enabled?(:search, User.new('u' + id.to_s)) }
    expect(at_80).to be_between(760, 840)
  end

  it 'never drops an admitted actor while the clock advances on a monotonic curve' do
    actors = (1..300).map { |id| User.new('u' + id.to_s) }
    times = (9...18).map { |hour| Time.utc(2026, 10, 1, hour, 10, 0) }

    admitted = Set.new
    times.each do |time|
      current_time = time
      actors.each do |actor|
        enabled = flipper.enabled?(:search, actor)
        if admitted.include?(actor.flipper_id)
          expect(enabled).to be(true), 'actor ' + actor.flipper_id + ' dropped out at ' + time.iso8601
        end
        admitted << actor.flipper_id if enabled
      end
    end
  end

  it 'evaluates the curve against the rolled-back time without crashing' do
    actors = (1..300).map { |id| User.new('u' + id.to_s) }

    current_time = Time.utc(2026, 10, 1, 17, 59)
    late = actors.select { |actor| flipper.enabled?(:search, actor) }

    current_time = Time.utc(2026, 10, 1, 8)
    early = actors.select { |actor| flipper.enabled?(:search, actor) }
    expect(early).to be_empty
    expect(late.size).to be > early.size
  end

  it 'can be disabled and cleared' do
    flipper.disable_scheduled_rollout(:search)
    expect(flipper.feature(:search).scheduled_rollout_value).to be_nil
    expect(flipper.feature(:search)).to be_off

    current_time = Time.utc(2026, 10, 1, 13)
    expect(flipper.enabled?(:search, User.new('1'))).to be(false)
  end

  it 'rejects invalid and non-monotonic curves' do
    expect { flipper.enable_scheduled_rollout(:bad, [['2026-10-01T10:00:00Z', 50], ['2026-10-01T09:00:00Z', 60]]) }
      .to raise_error(ArgumentError, /strictly increasing/)

    expect { flipper.enable_scheduled_rollout(:bad, [['2026-10-01T09:00:00Z', 50], ['2026-10-01T10:00:00Z', 40]]) }
      .to raise_error(ArgumentError, /non-decreasing/)

    expect { flipper.enable_scheduled_rollout(:bad, [['2026-10-01T09:00:00Z', 150]]) }
      .to raise_error(ArgumentError, /between 0 and 100/)
  end

  it 'stores and reads the curve without changing precision' do
    stored = flipper.feature(:search).scheduled_rollout_value
    expect(stored).to be_a(Flipper::RolloutSchedule)
    expect(stored.as_json).to eq([
      ['2026-10-01T09:00:00.000000000Z', 5],
      ['2026-10-01T12:00:00.000000000Z', 30],
      ['2026-10-01T18:00:00.000000000Z', 80],
    ])

    raw = flipper.adapter.get(flipper.feature(:search))[:scheduled_rollout]
    expect(raw).to eq(Flipper::RolloutSchedule.new(nodes).as_json)
  end

  it 'keeps the manual percentage interface working independently' do
    flipper.enable_percentage_of_actors(:other, 25)
    expect(flipper.feature(:other).percentage_of_actors_value).to eq(25)
    flipper.disable_percentage_of_actors(:other)
    expect(flipper.feature(:other).percentage_of_actors_value).to eq(0)
  end

  it 'works with an object clock responding to #now' do
    fake = Class.new do
      attr_accessor :time
      def now
        time
      end
    end.new
    fake.time = Time.utc(2026, 10, 1, 12)
    other = Flipper.new(Flipper::Adapters::Memory.new, clock: fake, memoize: false)
    other.enable_scheduled_rollout(:search, nodes)

    count = (1..500).count { |id| other.enabled?(:search, User.new('u' + id.to_s)) }
    expect(count).to be_between(130, 170)
  end

  it 'defaults to the real clock when no clock is injected' do
    default = Flipper.new(Flipper::Adapters::Memory.new, memoize: false)
    expect(default.feature(:search).clock).to be(Time)
  end
end
