require 'test_helper'
require 'flipper/adapters/operation_logger'
require 'flipper/adapters/read_only'

# Behavior tests for explicit deny lists: deny takes precedence over the
# boolean, percentage and expression gates, survives enable(true)/clear/
# import/export, and normal evaluation resumes once the deny is removed.
class DenyTest < MiniTest::Test
  def setup
    @adapter = Flipper::Adapters::Memory.new
    @flipper = Flipper.new(@adapter)
    @feature = @flipper[:new_checkout]
    @good_user = Flipper::Actor.new(1)
    @bad_account = Flipper::Actor.new(666)

    Flipper.register(:blocked_accounts) do |actor|
      actor.flipper_id.to_s == '13'
    end
  end

  def teardown
    Flipper.unregister_groups
  end

  def test_denied_actor_is_disabled_even_when_fully_enabled
    @feature.enable
    @feature.deny_actor(@bad_account)

    refute @feature.enabled?(@bad_account)
    assert @feature.enabled?(@good_user)
  end

  def test_denied_actor_is_disabled_at_100_percent_of_actors
    @feature.enable_percentage_of_actors(100)
    @feature.deny_actor(@bad_account)

    refute @feature.enabled?(@bad_account)
    assert @feature.enabled?(@good_user)
  end

  def test_deny_takes_precedence_over_expression_gate
    @feature.enable_expression(Flipper.any(Flipper.constant(true)))
    @feature.deny_actor(@bad_account)

    refute @feature.enabled?(@bad_account)
    assert @feature.enabled?(@good_user)
  end

  def test_deny_takes_precedence_over_actor_gate
    @feature.enable_actor(@bad_account)
    @feature.deny_actor(@bad_account)

    refute @feature.enabled?(@bad_account)
  end

  def test_multi_actor_check_is_denied_when_any_actor_is_denied
    @feature.enable
    @feature.deny_actor(@bad_account)

    refute @feature.enabled?(@good_user, @bad_account)
    assert @feature.enabled?(@good_user, Flipper::Actor.new(2))
  end

  def test_denied_group_disables_matching_actors
    @feature.enable
    @feature.deny_group(:blocked_accounts)

    refute @feature.enabled?(Flipper::Actor.new(13))
    assert @feature.enabled?(@good_user)
  end

  def test_allow_actor_restores_normal_evaluation
    @feature.enable
    @feature.deny_actor(@bad_account)
    refute @feature.enabled?(@bad_account)

    @feature.allow_actor(@bad_account)
    assert @feature.enabled?(@bad_account)
    assert_empty @feature.denied_actors_value
  end

  def test_allow_group_restores_normal_evaluation
    @feature.enable
    @feature.deny_group(:blocked_accounts)
    refute @feature.enabled?(Flipper::Actor.new(13))

    @feature.allow_group(:blocked_accounts)
    assert @feature.enabled?(Flipper::Actor.new(13))
    assert_empty @feature.denied_groups_value
  end

  def test_enable_true_does_not_drop_denies
    @feature.deny_actor(@bad_account)
    @feature.enable

    assert_equal Set['666'], @feature.denied_actors_value
    refute @feature.enabled?(@bad_account)
  end

  def test_clear_does_not_drop_denies
    @feature.enable
    @feature.deny_actor(@bad_account)
    @feature.clear

    assert_equal Set['666'], @feature.denied_actors_value
  end

  def test_export_import_roundtrip_preserves_denies
    @feature.enable
    @feature.deny_actor(@bad_account)
    @feature.deny_group(:blocked_accounts)

    export = @flipper.export

    other = Flipper.new(Flipper::Adapters::Memory.new)
    other.import(export)

    assert_equal Set['666'], other[:new_checkout].denied_actors_value
    assert_equal Set['blocked_accounts'], other[:new_checkout].denied_groups_value
    refute other.enabled?(:new_checkout, @bad_account)
    assert other.enabled?(:new_checkout, @good_user)
  end

  def test_sync_brings_denies_across_and_removes_them
    remote = Flipper.new(Flipper::Adapters::Memory.new)
    remote[:new_checkout].enable
    remote[:new_checkout].deny_actor(@bad_account)

    Flipper::Adapters::Sync::Synchronizer.new(@adapter, remote.adapter).call
    assert_equal Set['666'], @feature.denied_actors_value
    refute @feature.enabled?(@bad_account)

    remote[:new_checkout].allow_actor(@bad_account)
    Flipper::Adapters::Sync::Synchronizer.new(@adapter, remote.adapter).call
    assert_empty @feature.denied_actors_value
    assert @feature.enabled?(@bad_account)
  end

  def test_dsl_and_top_level_delegation
    Flipper.instance = @flipper

    @flipper.enable(:new_checkout)
    @flipper.deny_actor(:new_checkout, @bad_account)
    refute @flipper.enabled?(:new_checkout, @bad_account)

    Flipper.deny_group(:new_checkout, :blocked_accounts)
    refute Flipper.enabled?(:new_checkout, Flipper::Actor.new(13))

    Flipper.allow_actor(:new_checkout, @bad_account)
    Flipper.allow_group(:new_checkout, :blocked_accounts)
    assert Flipper.enabled?(:new_checkout, @bad_account)
  ensure
    Flipper.instance = nil
  end

  def test_memoized_wrapper_sees_deny_writes
    @flipper.memoize = true
    @feature.enable
    assert @feature.enabled?(@bad_account)

    @feature.deny_actor(@bad_account)
    refute @feature.enabled?(@bad_account)
  end

  def test_operation_logger_records_deny_and_allow
    logger = Flipper::Adapters::OperationLogger.new(@adapter)
    flipper = Flipper.new(logger)

    flipper[:new_checkout].deny_actor(@bad_account)
    flipper[:new_checkout].allow_actor(@bad_account)

    assert_equal 1, logger.count(:deny)
    assert_equal 1, logger.count(:allow)
  end

  def test_read_only_wrapper_rejects_deny_and_allow
    flipper = Flipper.new(Flipper::Adapters::ReadOnly.new(@adapter))

    assert_raises(Flipper::Adapters::ReadOnly::WriteAttempted) do
      flipper[:new_checkout].deny_actor(@bad_account)
    end
    assert_raises(Flipper::Adapters::ReadOnly::WriteAttempted) do
      flipper[:new_checkout].allow_actor(@bad_account)
    end
  end

  def test_adapter_without_deny_support_raises
    stub_class = Class.new { include Flipper::Adapter }
    Object.const_set(:DenyTestStubAdapter, stub_class) unless defined?(DenyTestStubAdapter)
    adapter = DenyTestStubAdapter.new
    feature = Flipper::Feature.new(:new_checkout, adapter)

    error = assert_raises(Flipper::DenyNotSupported) do
      adapter.deny(feature, Flipper::Types::Actor.new(@bad_account))
    end
    assert_includes error.message, 'deny'

    assert_raises(Flipper::DenyNotSupported) do
      adapter.allow(feature, Flipper::Types::Actor.new(@bad_account))
    end
  end
end
