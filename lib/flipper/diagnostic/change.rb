module Flipper
  module Diagnostic
    # Public: A single attribute change within a suggested plan.
    Change = Struct.new(:attribute, :from, :to, :cost, keyword_init: true) do
      def to_h
        {
          attribute: attribute,
          from: from,
          to: to,
          cost: cost,
        }
      end
    end
  end
end
