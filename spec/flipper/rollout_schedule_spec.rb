require 'helper'

RSpec.describe Flipper::RolloutSchedule do
  let(:nodes) do
    [
      ['2026-10-01T09:00:00Z', 5],
      ['2026-10-01T12:00:00Z', 30],
      ['2026-10-01T18:00:00Z', 80],
    ]
  end

  subject(:schedule) { described_class.new(nodes) }

  it 'accepts an existing schedule in build' do
    expect(described_class.build(schedule)).to be(schedule)
  end

  it 'accepts a hash with nodes key' do
    built = described_class.build('nodes' => nodes)
    expect(built).to eq(schedule)
  end

  it 'accepts Time nodes' do
    time_nodes = nodes.map { |time, percentage| [Time.iso8601(time), percentage] }
    expect(described_class.new(time_nodes)).to eq(schedule)
  end

  describe '#percentage_at' do
    it 'is 0 before the first node' do
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 8, 59, 59))).to eq(0)
    end

    it 'is exactly the node percentage on the node time' do
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 9))).to eq(5.0)
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 12))).to eq(30.0)
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 18))).to eq(80.0)
    end

    it 'linearly interpolates between nodes' do
      # half way through the 5 -> 30 segment over 3 hours
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 10, 30))).to eq(17.5)
      # flat interpolation at segment start
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 9, 0, 1))).to be > 5
    end

    it 'holds the final percentage at and after the last node' do
      expect(schedule.percentage_at(Time.utc(2026, 10, 1, 18))).to eq(80.0)
      expect(schedule.percentage_at(Time.utc(2026, 10, 2))).to eq(80.0)
    end

    it 'is 0 at midnight before a single-node schedule' do
      single = described_class.new([['2026-10-01T09:00:00Z', 25]])
      expect(single.percentage_at(Time.utc(2026, 10, 1, 8))).to eq(0)
      expect(single.percentage_at(Time.utc(2026, 10, 1, 9))).to eq(25.0)
      expect(single.percentage_at(Time.utc(2026, 10, 2))).to eq(25.0)
    end
  end

  describe 'validation' do
    it 'rejects a non-array' do
      expect { described_class.new('nope') }.to raise_error(ArgumentError, /must be an Array/)
    end

    it 'rejects an empty curve' do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /at least one node/)
    end

    it 'rejects malformed nodes' do
      expect { described_class.new([['2026-10-01T09:00:00Z']]) }
        .to raise_error(ArgumentError, /\[time, percentage\]/)
    end

    it 'rejects out-of-range percentages' do
      expect { described_class.new([['2026-10-01T09:00:00Z', 101]]) }
        .to raise_error(ArgumentError, /between 0 and 100/)
      expect { described_class.new([['2026-10-01T09:00:00Z', -1]]) }
        .to raise_error(ArgumentError, /between 0 and 100/)
    end

    it 'rejects fractional node percentages' do
      expect { described_class.new([['2026-10-01T09:00:00Z', 5.5]]) }
        .to raise_error(ArgumentError, /integer/)
    end

    it 'rejects unparseable times' do
      expect { described_class.new([['not a time', 5]]) }
        .to raise_error(ArgumentError)
    end

    it 'rejects equal node times' do
      expect do
        described_class.new([
          ['2026-10-01T09:00:00Z', 5],
          ['2026-10-01T09:00:00Z', 30],
        ])
      end.to raise_error(ArgumentError, /strictly increasing/)
    end

    it 'rejects decreasing node times' do
      expect do
        described_class.new([
          ['2026-10-01T12:00:00Z', 5],
          ['2026-10-01T09:00:00Z', 30],
        ])
      end.to raise_error(ArgumentError, /strictly increasing/)
    end

    it 'rejects decreasing percentages' do
      expect do
        described_class.new([
          ['2026-10-01T09:00:00Z', 30],
          ['2026-10-01T12:00:00Z', 5],
        ])
      end.to raise_error(ArgumentError, /non-decreasing/)
    end

    it 'allows flat (equal) percentages' do
      expect do
        described_class.new([
          ['2026-10-01T09:00:00Z', 5],
          ['2026-10-01T12:00:00Z', 5],
        ])
      end.not_to raise_error
    end
  end

  describe 'serialization' do
    it 'round-trips through JSON without precision loss' do
      json = schedule.to_json
      restored = described_class.new(Flipper::Typecast.from_json(json))
      expect(restored).to eq(schedule)
      expect(json).to include('2026-10-01T09:00:00.000000000Z')
    end

    it 'as_json uses integer percentages and ISO8601 times' do
      expect(schedule.as_json).to eq([
        ['2026-10-01T09:00:00.000000000Z', 5],
        ['2026-10-01T12:00:00.000000000Z', 30],
        ['2026-10-01T18:00:00.000000000Z', 80],
      ])
    end
  end

  it 'is comparable by value and usable as hash key' do
    expect(schedule).to eq(described_class.new(nodes))
    expect(schedule.hash).to eq(described_class.new(nodes).hash)
    expect({ schedule => true }[described_class.new(nodes)]).to be(true)
  end
end
