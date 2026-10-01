require 'test_helper'

class MemoryTest < MiniTest::Test
  prepend Flipper::Test::SharedAdapterTests

  def setup
    @adapter = Flipper::Adapters::Memory.new
  end

  def test_deny_and_allow_actor
    actor = Flipper::Types::Actor.new(Flipper::Actor.new('1'))

    assert_equal true, @adapter.deny(@feature, actor)
    assert_equal Set['1'], @adapter.get(@feature)[:denied_actors]

    assert_equal true, @adapter.allow(@feature, actor)
    assert_nil @adapter.get(@feature)[:denied_actors]
  end

  def test_deny_and_allow_group
    group = Flipper::Types::Group.new(:admins)

    assert_equal true, @adapter.deny(@feature, group)
    assert_equal Set['admins'], @adapter.get(@feature)[:denied_groups]

    assert_equal true, @adapter.allow(@feature, group)
    assert_nil @adapter.get(@feature)[:denied_groups]
  end

  def test_deny_only_accepts_actors_and_groups
    assert_raises(ArgumentError) do
      @adapter.deny(@feature, Flipper::Types::Boolean.new)
    end
  end

  def test_allow_is_noop_when_nothing_denied
    actor = Flipper::Types::Actor.new(Flipper::Actor.new('1'))
    assert_equal true, @adapter.allow(@feature, actor)
    assert_equal @adapter.default_config, @adapter.get(@feature)
  end

  def test_enable_boolean_preserves_denies
    actor = Flipper::Types::Actor.new(Flipper::Actor.new('1'))
    @adapter.deny(@feature, actor)

    @adapter.enable(@feature, @boolean_gate, Flipper::Types::Boolean.new)
    assert_equal Set['1'], @adapter.get(@feature)[:denied_actors]
    assert_equal 'true', @adapter.get(@feature)[:boolean]
  end

  def test_disable_boolean_preserves_denies
    actor = Flipper::Types::Actor.new(Flipper::Actor.new('1'))
    @adapter.enable(@feature, @boolean_gate, Flipper::Types::Boolean.new)
    @adapter.deny(@feature, actor)

    @adapter.disable(@feature, @boolean_gate, Flipper::Types::Boolean.new(false))
    assert_equal Set['1'], @adapter.get(@feature)[:denied_actors]
    assert_nil @adapter.get(@feature)[:boolean]
  end

  def test_clear_preserves_denies
    actor = Flipper::Types::Actor.new(Flipper::Actor.new('1'))
    @adapter.enable(@feature, @boolean_gate, Flipper::Types::Boolean.new)
    @adapter.deny(@feature, actor)

    @adapter.clear(@feature)
    assert_equal Set['1'], @adapter.get(@feature)[:denied_actors]
    assert_nil @adapter.get(@feature)[:boolean]
  end

  def test_export_and_import_preserve_denies
    actor = Flipper::Types::Actor.new(Flipper::Actor.new('1'))
    group = Flipper::Types::Group.new(:admins)
    @adapter.enable(@feature, @boolean_gate, Flipper::Types::Boolean.new)
    @adapter.deny(@feature, actor)
    @adapter.deny(@feature, group)

    export = @adapter.export

    other = Flipper::Adapters::Memory.new
    other.import(export)

    imported = other.get(@feature)
    assert_equal Set['1'], imported[:denied_actors]
    assert_equal Set['admins'], imported[:denied_groups]
    assert_equal 'true', imported[:boolean]
  end
end
