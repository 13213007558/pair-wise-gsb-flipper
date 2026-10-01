require 'bundler/setup'
require 'flipper'

# An actor is anything that responds to #flipper_id.
class User
  attr_reader :id

  def initialize(id)
    @id = id
  end

  alias_method :flipper_id, :id
end

# A registered group matches actors that need to be blocked as a cohort.
Flipper.register(:abusive) { |user| user.respond_to?(:abusive?) && user.abusive? }

flipper = Flipper.new(Flipper::Adapters::Memory.new)

# The feature is fully enabled (100%) for everyone.
flipper.enable(:checkout)

normal_user = User.new('user-1')
blocked_user = User.new('user-2')

# Emergency rollback: deny a single account (and/or a whole group) without
# turning the feature off for everyone. Deny takes precedence over the
# boolean, percentage and expression gates.
flipper.enable_deny_actor(:checkout, blocked_user)
# flipper.enable_deny_group(:checkout, :abusive)

puts "normal account hits the feature:  #{flipper.enabled?(:checkout, normal_user)}"   # => true
puts "blocked account is denied:         #{flipper.enabled?(:checkout, blocked_user)}"  # => false

# Multi-actor checks aggregate as: deny wins. If ANY checked actor is denied,
# the whole check is false; otherwise the regular gates apply (any match).
puts "check with a blocked actor present: #{flipper.enabled?(:checkout, normal_user, blocked_user)}" # => false
puts "check with only allowed actors:    #{flipper.enabled?(:checkout, normal_user, User.new('user-3'))}" # => true

# Removing the deny record restores normal evaluation immediately.
flipper.disable_deny_actor(:checkout, blocked_user)
puts "blocked account after un-deny:     #{flipper.enabled?(:checkout, blocked_user)}"  # => true
