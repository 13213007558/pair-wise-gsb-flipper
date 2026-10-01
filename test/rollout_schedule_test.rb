require 'test_helper'

class RolloutScheduleTest < MiniTest::Test
  NODES = [
    ['2026-10-01T09:00:00Z', 5],
    ['2026-10-01T12:00:00Z', 30],
    ['2026-10-01T18:00:00Z', 80],
  ].freeze

  def schedule
    Flipper::RolloutSchedule.new(NODES)
  end

  def t(hour, min = 0, sec = 0)
    Time.utc(2026, 10, 1, hour, min, sec)
  end

  def test_percentage_before_start_is_zero
    assert_equal 0, schedule.percentage_at(t(8, 59))
  end

  def test_percentage_at_nodes
    assert_equal 5.0, schedule.percentage_at(t(9))
    assert_equal 30.0, schedule.percentage_at(t(12))
    assert_equal 80.0, schedule.percentage_at(t(18))
  end

  def test_percentage_interpolates
    assert_equal 17.5, schedule.percentage_at(t(10, 30))
    assert_operator schedule.percentage_at(t(9, 0, 1)), :>, 5
  end

  def test_percentage_holds_after_last_node
    assert_equal 80.0, schedule.percentage_at(Time.utc(2026, 10, 2))
  end

  def test_single_node
    single = Flipper::RolloutSchedule.new([['2026-10-01T09:00:00Z', 25]])
    assert_equal 0, single.percentage_at(t(8))
    assert_equal 25.0, single.percentage_at(t(9))
    assert_equal 25.0, single.percentage_at(Time.utc(2026, 10, 2))
  end

  def test_rejects_non_array
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new('x') }
  end

  def test_rejects_empty
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new([]) }
  end

  def test_rejects_malformed_node
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new([['2026-10-01T09:00:00Z']]) }
  end

  def test_rejects_out_of_range_percentage
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new([['2026-10-01T09:00:00Z', 101]]) }
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new([['2026-10-01T09:00:00Z', -1]]) }
  end

  def test_rejects_fractional_percentage
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new([['2026-10-01T09:00:00Z', 5.5]]) }
  end

  def test_rejects_bad_time
    assert_raises(ArgumentError) { Flipper::RolloutSchedule.new([['nope', 5]]) }
  end

  def test_rejects_equal_times
    nodes = [['2026-10-01T09:00:00Z', 5], ['2026-10-01T09:00:00Z', 6]]
    error = assert_raises(ArgumentError) { Flipper::RolloutSchedule.new(nodes) }
    assert_match(/strictly increasing/, error.message)
  end

  def test_rejects_decreasing_times
    nodes = [['2026-10-01T12:00:00Z', 5], ['2026-10-01T09:00:00Z', 6]]
    error = assert_raises(ArgumentError) { Flipper::RolloutSchedule.new(nodes) }
    assert_match(/strictly increasing/, error.message)
  end

  def test_rejects_decreasing_percentages
    nodes = [['2026-10-01T09:00:00Z', 30], ['2026-10-01T12:00:00Z', 5]]
    error = assert_raises(ArgumentError) { Flipper::RolloutSchedule.new(nodes) }
    assert_match(/non-decreasing/, error.message)
  end

  def test_allows_equal_percentages
    nodes = [['2026-10-01T09:00:00Z', 5], ['2026-10-01T12:00:00Z', 5]]
    Flipper::RolloutSchedule.new(nodes)
  end

  def test_json_round_trip_preserves_precision
    json = schedule.to_json
    restored = Flipper::RolloutSchedule.new(Flipper::Typecast.from_json(json))
    assert_equal schedule, restored
    assert_includes json, '2026-10-01T09:00:00.000000000Z'
  end

  def test_build_accepts_hash
    built = Flipper::RolloutSchedule.build('nodes' => NODES)
    assert_equal schedule, built
  end

  def test_build_returns_existing_schedule
    existing = schedule
    assert_same existing, Flipper::RolloutSchedule.build(existing)
  end
end
