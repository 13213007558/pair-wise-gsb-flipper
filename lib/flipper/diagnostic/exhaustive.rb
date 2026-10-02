module Flipper
  module Diagnostic
    # Internal: Brute-force reference solver for small attribute domains.
    # Every assignment is evaluated once; the best one uses the same
    # ordering as Search (changed count, then explicit cost, then stable
    # declaration order). Because the entire domain is explored, a found
    # plan is proven :optimal and a miss is proven :impossible.
    class Exhaustive
      def initialize(dsl:, feature_name:, actor:, changeable:, fixed:, target:)
        @query = Query.new(
          dsl: dsl,
          feature_name: feature_name,
          actor: actor,
          changeable: changeable,
          fixed: fixed,
          target: target,
          budget: nil
        )
        @feature_name = feature_name
      end

      def call
        GateScanner.scan!(@query.dsl, @feature_name)

        best = nil
        evaluations = 0

        each_assignment do |indices|
          evaluations += 1
          next unless @query.evaluate(indices) == @query.target

          values, changes = @query.assignment_for(indices)
          score = [changes.size, changes.sum(&:cost), stable_key(indices)]
          best = [score, indices, changes] if best.nil? || better_score?(score, best.first)
        end

        if best
          _, indices, changes = best
          @query.verify!(indices)
          @query.result_for(changes, indices, :optimal, evaluations)
        else
          @query.empty_result(:impossible, evaluations)
        end
      end

      private

      def each_assignment
        radices = @query.options.map(&:size)
        total = radices.reduce(1, :*)
        (0...total).each do |number|
          yield(digits(number, radices))
        end
      end

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

      def better_score?(left, right)
        return true if left[0] < right[0]
        return false if left[0] > right[0]
        return true if left[1] < right[1]
        return false if left[1] > right[1]
        lex_array?(left[2], right[2])
      end

      def lex_array?(left, right)
        size = [left.size, right.size].min
        size.times do |i|
          l = left[i]
          r = right[i]
          return true if l < r
          return false if l > r
        end
        left.size < right.size
      end

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
