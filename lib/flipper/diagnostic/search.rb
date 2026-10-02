module Flipper
  module Diagnostic
    # Internal: Ordered enumeration of candidate assignments.
    #
    # Assignments are explored by number of changed attributes (ascending);
    # within a layer by total explicit cost (ascending); ties use the
    # declared attribute and candidate order, which is stable. The first
    # layer that contains a matching assignment therefore yields the
    # optimum for the required ordering.
    class Search
      def initialize(dsl:, feature_name:, actor:, changeable:, fixed:, target:, budget:)
        @query = Query.new(
          dsl: dsl,
          feature_name: feature_name,
          actor: actor,
          changeable: changeable,
          fixed: fixed,
          target: target,
          budget: budget
        )
        @feature_name = feature_name
      end

      def call
        GateScanner.scan!(@query.dsl, @feature_name)

        evaluations = 0
        best = nil
        best_indices = nil
        best_layer = nil
        explored = 0
        domain_size = @query.domain_size

        each_layer_with_count do |changed, indices, cost, rank|
          break if @query.budget && evaluations >= @query.budget

          evaluations += 1
          explored += 1
          next unless @query.evaluate(indices) == @query.target

          # Layers are yielded with ascending changed counts; once any
          # layer has a match, deeper layers can never win on count. Within
          # a layer, cost then stable rank decide.
          if best.nil? || (changed == best_layer && better_within_layer?(cost, rank, best))
            best_indices = indices
            best = [cost, rank]
            best_layer = changed
          end
        end

        if best
          # Put the winning plan back through the real enabled? path.
          @query.verify!(best_indices)
          _, changes = @query.assignment_for(best_indices)
          status = explored >= domain_size ? :optimal : :best_effort
          @query.result_for(changes, best_indices, status, evaluations)
        elsif explored >= domain_size
          @query.empty_result(:impossible, evaluations)
        else
          @query.empty_result(:inconclusive, evaluations)
        end
      end

      private

      def better_within_layer?(cost, rank, current)
        cost < current[0] ||
          (cost == current[0] && lexicographic?(rank, current[1]))
      end

      def lexicographic?(left, right)
        size = [left.size, right.size].min
        size.times do |i|
          l = left[i]
          r = right[i]
          return true if l < r
          return false if l > r
        end
        left.size < right.size
      end

      # Yields [changed_count, indices, total_cost, rank] for every
      # assignment, grouped by changed-count and ordered by cost then a
      # stable rank inside each group. The rank is the assignment's change
      # vector (changed attribute positions, then chosen option indices) in
      # lexicographic order, shared with the exhaustive oracle.
      def each_layer_with_count
        option_counts = @query.options.map(&:size)
        total_assignments = option_counts.reduce(1, :*)
        return if total_assignments.zero?

        # Group by the actual number of value changes so that a candidate
        # equal to the actor's current value (wherever it sits in the
        # declared list) is correctly treated as a no-op.
        layers = Hash.new { |hash, key| hash[key] = [] }
        total_assignments.times do |number|
          indices = digits(number, option_counts)
          _, changes = @query.assignment_for(indices)
          layers[changes.size] << indices
        end

        layers.keys.sort.each do |changed|
          ordered = layers[changed].map do |indices|
            cost = @query.assignment_for(indices).last.sum(&:cost)
            [cost, stable_key(indices), indices]
          end.sort_by! { |cost, rank, _| [cost, rank] }

          ordered.each { |cost, rank, indices| yield(changed, indices, cost, rank) }
        end
      end

      # Stable identity of an assignment: positions of changed attributes,
      # followed by the chosen option index at each changed position. Keeping
      # it independent of the global enumeration number makes ties resolve
      # identically regardless of which solver enumerated them.
      def stable_key(indices)
        key = []
        indices.each_with_index do |index, position|
          name = @query.attribute_names[position]
          current = @query.base_values.fetch(name, nil)
          chosen = @query.option_for(name, index)[:value]
          next if current == chosen
          key << position
          key << index
        end
        key
      end

      # Convert an assignment number into mixed-radix option-index digits,
      # most significant (first declared attribute) first.
      def digits(number, radices)
        result = Array.new(radices.size, 0)
        remainder = number
        (radices.size - 1).downto(0) do |position|
          radix = radices[position]
          result[position] = remainder % radix
          remainder /= radix
        end
        result
      end
    end
  end
end
