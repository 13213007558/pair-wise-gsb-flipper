require 'time'
require 'set'
require 'flipper/typecast'

module Flipper
  # Public: A piecewise-linear rollout curve saved once and evaluated
  # against an injected clock, instead of rewriting a scalar percentage
  # every minute.
  #
  # A schedule is an ordered list of nodes. Each node is a [time, percentage]
  # pair where percentage is an Integer 0..100 (interpreted like the manual
  # "percentage of actors" gate). Between two adjacent nodes the effective
  # percentage is linearly interpolated. Node times must be strictly
  # increasing and percentages must be monotonically non-decreasing.
  #
  # Example (5% -> 30% in the morning, then 30% -> 80% in the afternoon):
  #
  #   schedule = Flipper::RolloutSchedule.new([
  #     ['2026-10-01T09:00:00Z', 5],
  #     ['2026-10-01T12:00:00Z', 30],
  #     ['2026-10-01T18:00:00Z', 80],
  #   ])
  #
  # Serialization is JSON (an Array of [iso8601 time, integer percentage]
  # pairs); save/read round-trips preserve stored times and percentages
  # exactly, with no float or precision loss.
  class RolloutSchedule
    # Internal: Buckets use 3 decimal places, matching
    # Gates::PercentageOfActors.
    SCALING_FACTOR = 1_000

    # Public: Coerce nodes, a Hash with a :nodes key, or an existing
    # schedule into a RolloutSchedule.
    def self.build(nodes)
      return nodes if nodes.is_a?(self)

      if nodes.is_a?(Hash)
        nodes = nodes['nodes'] || nodes[:nodes]
      end

      new(nodes)
    end

    # Public: Initializes a new schedule.
    #
    # nodes - Array of [time, percentage] pairs. time is anything
    #         Typecast.to_time understands (ISO8601 String, Time, etc.);
    #         percentage must be an Integer between 0 and 100 inclusive.
    def initialize(nodes)
      nodes = nodes.to_a if nodes.is_a?(Set)

      raise ArgumentError, "rollout schedule nodes must be an Array, but was #{nodes.class}" unless nodes.is_a?(Array)
      raise ArgumentError, "rollout schedule needs at least one node, but was empty" if nodes.empty?

      normalized = nodes.map do |node|
        unless node.is_a?(Array) && node.size == 2
          raise ArgumentError, "rollout schedule node must be a [time, percentage] pair, but was #{node.inspect}"
        end

        time, percentage = node
        normalized_time = Typecast.to_time(time)
        normalized_percentage = Typecast.to_number(percentage)

        unless normalized_percentage.is_a?(Integer) && normalized_percentage >= 0 && normalized_percentage <= 100
          raise ArgumentError,
                "rollout schedule percentage must be an integer between 0 and 100, but was #{percentage.inspect}"
        end

        [normalized_time, normalized_percentage]
      end

      validate_monotonic!(normalized)
      @nodes = normalized.freeze
    end

    # Public: The frozen Array of [Time, Integer] nodes.
    attr_reader :nodes

    # Public: Effective percentage (0..100, possibly fractional) at time.
    #
    # Before the first node the schedule has not started and is 0%. At or
    # after the last node the schedule holds its final percentage. Nodes are
    # inclusive of their exact time; interpolation is right-open
    # ([start, end)) so every time maps to exactly one segment.
    def percentage_at(time)
      time = Typecast.to_time(time)

      first_time, first_percentage = @nodes.first
      last_time, last_percentage = @nodes.last

      return 0 if time < first_time
      return last_percentage if time >= last_time

      @nodes.each_cons(2) do |(start_time, start_percentage), (end_time, end_percentage)|
        next if time < start_time || time >= end_time
        return start_percentage.to_f if end_percentage == start_percentage

        fraction = (time - start_time).to_r / (end_time - start_time)
        return (start_percentage + (end_percentage - start_percentage) * fraction).to_f
      end
    end

    # Internal: Bucket threshold (0..100 * SCALING_FACTOR) at a time. The
    # threshold is the floor of the interpolated percentage scaled to 3
    # decimal places. Flooring (rather than rounding) guarantees the
    # threshold never decreases as time advances along a non-decreasing
    # curve, so an actor already admitted can never be kicked out merely by
    # the clock advancing (independently of how clock rollback is handled
    # by the gate).
    def bucket_threshold_at(time)
      (percentage_at(time) * SCALING_FACTOR).floor
    end

    # Public: JSON-safe representation: Array of [String, Integer] pairs.
    def as_json(*)
      @nodes.map { |time, percentage| [time.utc.iso8601(9), percentage] }
    end

    # Public: JSON String. Round-tripping through it preserves node times
    # and percentages exactly.
    def to_json(*args)
      Typecast.to_json(as_json, *args)
    end

    def eql?(other)
      other.is_a?(self.class) && @nodes == other.nodes
    end
    alias_method :==, :eql?

    def hash
      @nodes.hash
    end

    def inspect
      "#<#{self.class.name} nodes=#{as_json.inspect}>"
    end

    private

    def validate_monotonic!(nodes)
      nodes.each_cons(2) do |(previous_time, previous_percentage), (current_time, current_percentage)|
        if current_time <= previous_time
          raise ArgumentError,
                "rollout schedule node times must be strictly increasing, but #{current_time.iso8601(9)} is not after #{previous_time.iso8601(9)}"
        end

        if current_percentage < previous_percentage
          raise ArgumentError,
                "rollout schedule percentages must be monotonically non-decreasing, but percentage drops from #{previous_percentage} to #{current_percentage} at #{current_time.iso8601(9)}"
        end
      end
    end
  end
end
