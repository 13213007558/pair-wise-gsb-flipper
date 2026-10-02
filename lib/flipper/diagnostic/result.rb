module Flipper
  module Diagnostic
    # Public: Outcome of a diagnostic search.
    #
    # status      - One of:
    #   :optimal      - a plan was found and proven optimal for the ordering
    #                   (fewest changes, then lowest explicit cost), or the
    #                   full domain was explored and a plan was impossible.
    #   :best_effort  - a feasible plan was found before the budget ran out
    #                   but a better one may still exist.
    #   :inconclusive - the budget ran out before any feasible plan was
    #                   found, so neither feasibility nor impossibility is
    #                   established.
    #   :impossible   - every assignment in the domain was evaluated and
    #                   none produced the target; :evaluations is the
    #                   exhaustive evidence.
    # plan        - Array of Change (empty when the actor already matches).
    # attributes  - Hash of attribute name => resulting value for the plan.
    # changed_count - Integer number of changed attributes.
    # cost        - Numeric sum of explicit candidate costs.
    # evaluations - Integer feature evaluations performed.
    # budget      - The Integer budget or nil.
    # domain_size - Integer number of assignments in the candidate domain.
    Result = Struct.new(
      :status, :plan, :attributes, :changed_count, :cost,
      :evaluations, :budget, :domain_size,
      keyword_init: true
    ) do
      def feasible?
        !plan.nil?
      end

      def optimal?
        status == :optimal
      end

      def to_h
        {
          status: status,
          plan: plan.nil? ? nil : plan.map(&:to_h),
          attributes: attributes,
          changed_count: changed_count,
          cost: cost,
          evaluations: evaluations,
          budget: budget,
          domain_size: domain_size,
        }
      end
    end
  end
end
