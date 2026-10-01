require 'test_helper'

User = Struct.new(:flipper_id)

class ScheduledRolloutFeatureTest < MiniTest::Test
  NODES = [
    ['2026-10-01T09:00:00Z', 5],
    ['2026-10-01T12:00:00Z', 30],
    ['2026-10-01T18:00:00Z', 80],
  ].freeze

  def setup
    @now = Time.utc(2026, 10, 1, 8)
    clock = -> { @now }
    @flipper = Flipper.new(Flipper::Adapters::Memory.new, clock: clock, memoize: false)
    @flipper.enable_scheduled_rollout(:search, NODES)
    @feature = @flipper.feature(:search)
  end

  def test_conditional_before_start_but_closed
    assert @feature.conditional?
    assert_includes @feature.enabled_gate_names, :scheduled_rollout
    refute @flipper.enabled?(:search, User.new('1'))
  end

  def test_percentages_track_curve
    [[10, 30, 140, 210], [12, 0, 260, 340]].each do |hour, min, low, high|
      @now = Time.utc(2026, 10, 1, hour, min)
      count = (1..1000).count { |id| @flipper.enabled?(:search, User.new('u' + id.to_s)) }
      assert(count >= low && count <= high, "count=#{count} not in #{low}..#{high} at #{hour}:#{min}")
    end
  end

  def test_holds_final_percentage_after_last_node
    @now = Time.utc(2026, 10, 2)
    count = (1..1000).count { |id| @flipper.enabled?(:search, User.new('u' + id.to_s)) }
    assert count >= 760 && count <= 840
  end

  def test_admitted_actor_never_drops_under_advancing_clock
    actors = (1..300).map { |id| User.new('u' + id.to_s) }
    admitted = Set.new
    (9...18).each do |hour|
      @now = Time.utc(2026, 10, 1, hour, 10)
      actors.each do |actor|
        enabled = @flipper.enabled?(:search, actor)
        if admitted.include?(actor.flipper_id)
          assert enabled, "actor #{actor.flipper_id} dropped out at #{hour}"
        end
        admitted << actor.flipper_id if enabled
      end
    end
    assert_operator admitted.size, :>, 0
  end

  def test_clock_rollback_reevaluates_lower_percentage
    actors = (1..300).map { |id| User.new('u' + id.to_s) }
    @now = Time.utc(2026, 10, 1, 17, 59)
    late = actors.count { |actor| @flipper.enabled?(:search, actor) }
    @now = Time.utc(2026, 10, 1, 8)
    early = actors.count { |actor| @flipper.enabled?(:search, actor) }
    assert_equal 0, early
    assert_operator late, :>, early
  end

  def test_disable_clears_curve
    @flipper.disable_scheduled_rollout(:search)
    assert_nil @feature.scheduled_rollout_value
    assert @feature.off?
    @now = Time.utc(2026, 10, 1, 13)
    refute @flipper.enabled?(:search, User.new('1'))
  end

  def test_rejects_non_monotonic_time
    error = assert_raises(ArgumentError) do
      @flipper.enable_scheduled_rollout(:bad, [['2026-10-01T10:00:00Z', 50], ['2026-10-01T09:00:00Z', 60]])
    end
    assert_match(/strictly increasing/, error.message)
  end

  def test_rejects_decreasing_percentage
    error = assert_raises(ArgumentError) do
      @flipper.enable_scheduled_rollout(:bad, [['2026-10-01T09:00:00Z', 50], ['2026-10-01T10:00:00Z', 40]])
    end
    assert_match(/non-decreasing/, error.message)
  end

  def test_stored_value_is_json_native_nodes
    raw = @flipper.adapter.get(@feature)[:scheduled_rollout]
    assert_equal Flipper::RolloutSchedule.new(NODES).as_json, raw
    assert_kind_of Flipper::RolloutSchedule, @feature.scheduled_rollout_value
  end

  def test_manual_percentage_api_unchanged
    @flipper.enable_percentage_of_actors(:other, 25)
    assert_equal 25, @flipper.feature(:other).percentage_of_actors_value
    @flipper.disable_percentage_of_actors(:other)
    assert_equal 0, @flipper.feature(:other).percentage_of_actors_value
  end

  def test_object_clock_responding_to_now
    fake = Object.new
    def fake.now; @time; end
    def fake.time=(v); @time = v; end
    fake.time = Time.utc(2026, 10, 1, 12)
    other = Flipper.new(Flipper::Adapters::Memory.new, clock: fake, memoize: false)
    other.enable_scheduled_rollout(:search, NODES)
    count = (1..500).count { |id| other.enabled?(:search, User.new('u' + id.to_s)) }
    assert count >= 130 && count <= 170
  end

  def test_default_clock_is_time
    default = Flipper.new(Flipper::Adapters::Memory.new, memoize: false)
    assert_same Time, default.feature(:search).clock
  end

  def test_closed_without_actor_even_when_rolled_out
    @now = Time.utc(2026, 10, 1, 20)
    refute @flipper.enabled?(:search)
  end
end
