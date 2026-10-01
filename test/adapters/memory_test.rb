require 'test_helper'

class MemoryTest < MiniTest::Test
  prepend Flipper::Test::SharedAdapterTests

  def setup
    @adapter = Flipper::Adapters::Memory.new
  end

  def test_denied_actor_is_blocked_even_when_fully_enabled
    flipper = Flipper.new(@adapter)
    flipper.enable :search
    actor = Flipper::Actor.new('1')
    denied = Flipper::Actor.new('2')
    flipper.enable_deny_actor :search, denied

    assert flipper.enabled?(:search, actor)
    refute flipper.enabled?(:search, denied)
  end

  def test_denied_group_is_blocked_even_when_fully_enabled
    Flipper.register(:banned) { |check_actor| check_actor.respond_to?(:banned?) && check_actor.banned? }
    flipper = Flipper.new(@adapter)
    flipper.enable :search
    flipper.enable_deny_group :search, :banned

    actor = Flipper::Actor.new('1')
    banned_actor = Object.new
    def banned_actor.flipper_id; '2'; end
    def banned_actor.banned?; true; end

    assert flipper.enabled?(:search, actor)
    refute flipper.enabled?(:search, banned_actor)
  end

  def test_deny_takes_precedence_over_percentage_and_expression_gates
    flipper = Flipper.new(@adapter)
    flipper.enable_percentage_of_actors :search, 100
    flipper.enable_deny_actor :search, Flipper::Actor.new('p')
    assert flipper.enabled?(:search, Flipper::Actor.new('q'))
    refute flipper.enabled?(:search, Flipper::Actor.new('p'))
  end

  def test_multi_actor_check_is_denied_if_any_actor_is_denied
    flipper = Flipper.new(@adapter)
    flipper.enable :search
    flipper.enable_deny_actor :search, Flipper::Actor.new('denied')

    refute flipper.enabled?(:search, Flipper::Actor.new('allowed'), Flipper::Actor.new('denied'))
    assert flipper.enabled?(:search, Flipper::Actor.new('allowed1'), Flipper::Actor.new('allowed2'))
  end

  def test_removing_deny_restores_normal_evaluation
    flipper = Flipper.new(@adapter)
    flipper.enable :search
    actor = Flipper::Actor.new('1')
    flipper.enable_deny_actor :search, actor
    refute flipper.enabled?(:search, actor)

    flipper.disable_deny_actor :search, actor
    assert flipper.enabled?(:search, actor)
  end

  def test_deny_records_survive_boolean_enable_and_clear
    flipper = Flipper.new(@adapter)
    actor = Flipper::Actor.new('1')
    flipper.enable_deny_actor :search, actor

    flipper.enable :search
    refute flipper.enabled?(:search, actor)

    flipper.feature(:search).clear
    refute flipper.enabled?(:search, actor)
    assert_includes @adapter.get(flipper.feature(:search))[:deny_actors], '1'
  end

  def test_deny_records_round_trip_through_export_and_import
    source = Flipper::Adapters::Memory.new
    source_flipper = Flipper.new(source)
    source_flipper.enable :search
    source_flipper.enable_deny_actor :search, Flipper::Actor.new('denied')

    destination = Flipper::Adapters::Memory.new
    destination.import(source.export)
    destination_flipper = Flipper.new(destination)

    assert destination_flipper.enabled?(:search, Flipper::Actor.new('allowed'))
    refute destination_flipper.enabled?(:search, Flipper::Actor.new('denied'))
  end

  def test_adapters_without_deny_support_reject_deny_writes
    adapter = Class.new do
      include Flipper::Adapter
      def get(_feature); default_config; end
      def add(_feature); true; end
    end.new
    flipper = Flipper.new(adapter)

    assert_raises(Flipper::DenyNotSupported) do
      flipper.enable_deny_actor :search, Flipper::Actor.new('1')
    end
  end
end
