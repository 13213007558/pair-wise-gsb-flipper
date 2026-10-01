require 'bundler/setup'
require 'flipper'

# Emergency rollback: a feature can be fully (100%) enabled while a handful
# of accounts stay explicitly denied. Deny takes precedence over the
# boolean, percentage and expression gates, and removing the deny restores
# normal gate evaluation.

class User
  attr_reader :id

  def initialize(id)
    @id = id
  end

  # Must respond to flipper_id
  alias_method :flipper_id, :id
end

good_user = User.new(1)
bad_account = User.new(666)

# Feature is 100% enabled for everyone.
Flipper.enable_percentage_of_actors(:new_checkout, 100)

puts "new_checkout for good_user:  #{Flipper.enabled?(:new_checkout, good_user)}"
puts "new_checkout for bad_account: #{Flipper.enabled?(:new_checkout, bad_account)}"

# Incident! Explicitly deny the misbehaving account without touching the
# 100% rollout.
puts "\nDenying bad_account...\n\n"
Flipper.deny_actor(:new_checkout, bad_account)

puts "new_checkout for good_user:  #{Flipper.enabled?(:new_checkout, good_user)}"
puts "new_checkout for bad_account: #{Flipper.enabled?(:new_checkout, bad_account)}"

# Deny also wins when checking several actors at once: a single denied
# actor denies the whole check.
puts "new_checkout for both:       #{Flipper.enabled?(:new_checkout, good_user, bad_account)}"

# enable(true) does not clear the deny list.
Flipper.enable(:new_checkout)
puts "\nAfter enable(true), bad_account still denied: #{!Flipper.enabled?(:new_checkout, bad_account)}"

# Removing the deny restores normal evaluation.
puts "\nAllowing bad_account again...\n\n"
Flipper.allow_actor(:new_checkout, bad_account)
puts "new_checkout for bad_account: #{Flipper.enabled?(:new_checkout, bad_account)}"
