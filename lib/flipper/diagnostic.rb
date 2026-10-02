require "flipper/errors"
require "flipper/expression"
require "flipper/diagnostic/candidate"
require "flipper/diagnostic/change"
require "flipper/diagnostic/result"
require "flipper/diagnostic/hypothetical_actor"
require "flipper/diagnostic/query"
require "flipper/diagnostic/gate_scanner"
require "flipper/diagnostic/search"
require "flipper/diagnostic/exhaustive"

module Flipper
  module Diagnostic
    # Public: Read-only search for the smallest set of actor attribute
    # changes that makes a feature evaluate to the requested target.
    #
    # dsl          - The Flipper::DSL instance the target feature belongs to.
    # feature_name - The String or Symbol feature name.
    # actor        - The actor the support person is investigating.
    # changeable   - Hash of attribute name => Array of candidate values
    #                (Flipper::Diagnostic::Candidate or [value, cost] pairs
    #                carry an explicit cost). Keeping the current value is
    #                always an implicit zero-cost option.
    # fixed        - Hash of attribute name => value assumed immutable for
    #                the diagnosis.
    # target       - true to find a plan that enables the feature, false to
    #                find one that disables it (defaults to true).
    # budget       - Maximum number of feature evaluations. nil is
    #                unlimited (default).
    #
    # Returns a Flipper::Diagnostic::Result. Never mutates the actor or any
    # gate value.
    def self.suggest(dsl:, feature_name:, actor:, changeable: {}, fixed: {}, target: true, budget: nil)
      Search.new(
        dsl: dsl,
        feature_name: feature_name,
        actor: actor,
        changeable: changeable,
        fixed: fixed,
        target: target,
        budget: budget
      ).call
    end

    # Public: Reference implementation that brute-forces every assignment in
    # the (small) attribute domain. Intended as an independent oracle for
    # validating the ordered search and for small domains where a proof of
    # optimality or impossibility is required.
    #
    # Returns a Flipper::Diagnostic::Result with :optimal or :impossible
    # status.
    def self.exhaustive(dsl:, feature_name:, actor:, changeable: {}, fixed: {}, target: true)
      Exhaustive.new(
        dsl: dsl,
        feature_name: feature_name,
        actor: actor,
        changeable: changeable,
        fixed: fixed,
        target: target
      ).call
    end
  end
end
