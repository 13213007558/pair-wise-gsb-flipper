require 'set'
require 'flipper/typecast'
require 'flipper/rollout_schedule'

module Flipper
  class GateValues
    attr_reader :boolean
    attr_reader :actors
    attr_reader :groups
    attr_reader :expression
    attr_reader :percentage_of_actors
    attr_reader :percentage_of_time
    attr_reader :scheduled_rollout

    def initialize(adapter_values)
      @boolean = Typecast.to_boolean(adapter_values[:boolean])
      @actors = Typecast.to_set(adapter_values[:actors])
      @groups = Typecast.to_set(adapter_values[:groups])
      @expression = adapter_values[:expression]
      @percentage_of_actors = Typecast.to_number(adapter_values[:percentage_of_actors])
      @percentage_of_time = Typecast.to_number(adapter_values[:percentage_of_time])
      raw_scheduled_rollout = adapter_values[:scheduled_rollout]
      @scheduled_rollout = case raw_scheduled_rollout
      when nil
        nil
      else
        RolloutSchedule.build(raw_scheduled_rollout)
      end
    end

    def eql?(other)
      self.class.eql?(other.class) &&
        boolean == other.boolean &&
        actors == other.actors &&
        groups == other.groups &&
        expression == other.expression &&
        percentage_of_actors == other.percentage_of_actors &&
        percentage_of_time == other.percentage_of_time &&
        scheduled_rollout == other.scheduled_rollout
    end
    alias_method :==, :eql?
  end
end
