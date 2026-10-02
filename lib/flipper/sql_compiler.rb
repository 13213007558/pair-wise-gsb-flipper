require "flipper/errors"
require "flipper/expression"

module Flipper
  # Public: Compiles a feature's gates into a SQL WHERE fragment and bind
  # values, so a database can pre-select the actors for which
  # Feature#enabled? would return true without instantiating every actor in
  # Ruby.
  #
  # Supported gates:
  #
  # * boolean    - compiles to a constant true/false condition.
  # * actor      - compiles to "<actor_column> IN (?, ...)".
  # * expression - compiles All/Any groups, comparisons (Equal, NotEqual,
  #   GreaterThan, GreaterThanOrEqualTo, LessThan, LessThanOrEqualTo) between
  #   a Property (optionally coerced with Number/String) and a constant,
  #   Boolean(Property), constant sub-expressions, and FeatureEnabled
  #   references to other compilable features.
  #
  # Anything that cannot be represented statically raises NotCompilable with
  # a reason instead of returning a partial, seemingly valid condition. That
  # includes the group gate (Ruby procs), percentage gates (hashing/random),
  # Random/Now/PercentageOfActors expressions, properties missing from the
  # caller-provided attribute whitelist, and comparisons between two
  # properties.
  #
  # Rule values are always returned as bind values; only caller-provided
  # column names are interpolated (and those are validated as identifiers),
  # so values like "O'Brien" or "x'); DROP TABLE users;--" cannot inject SQL.
  #
  # Missing properties (NULL columns) behave like Ruby: Equal and ordering
  # comparisons are false, NotEqual is true, Number coercion yields 0 and
  # String coercion yields "".
  #
  # Example:
  #
  #   result = Flipper::SqlCompiler.compile(
  #     Flipper[:reports],
  #     attributes: { "plan" => "plan", "age" => "age" },
  #     actor_column: "flipper_id",
  #     flipper: Flipper.instance,
  #   )
  #   Actor.where(result.sql, *result.binds)
  #
  class SqlCompiler
    # Public: Raised when a feature or expression cannot be compiled to SQL.
    # The message explains which gate or expression is not statically
    # representable. No partial SQL is produced in this case.
    class NotCompilable < Flipper::Error; end

    # Public: The result of a successful compilation.
    class Result
      # Public: The SQL WHERE fragment. Values are placeholders ("?").
      attr_reader :sql

      # Public: The bind values for the placeholders, in order.
      attr_reader :binds

      def initialize(sql, binds)
        @sql = sql
        @binds = binds
      end

      def to_a
        [sql, binds]
      end
    end

    Fragment = Struct.new(:sql, :binds)
    private_constant :Fragment

    COMPARISONS = {
      "Equal" => "=",
      "NotEqual" => "!=",
      "GreaterThan" => ">",
      "GreaterThanOrEqualTo" => ">=",
      "LessThan" => "<",
      "LessThanOrEqualTo" => "<=",
    }.freeze

    # Comparison names with the operands swapped (property on the right).
    FLIPPED_COMPARISONS = {
      "Equal" => "Equal",
      "NotEqual" => "NotEqual",
      "GreaterThan" => "LessThan",
      "GreaterThanOrEqualTo" => "LessThanOrEqualTo",
      "LessThan" => "GreaterThan",
      "LessThanOrEqualTo" => "GreaterThanOrEqualTo",
    }.freeze

    # Expression functions whose value cannot be known at compile time.
    VOLATILE_EXPRESSIONS = {
      "Random" => "Random(...) is non-deterministic",
      "Now" => "Now() depends on the current time",
      "PercentageOfActors" => "PercentageOfActors(...) hashes each actor id",
    }.freeze

    IDENTIFIER = /\A[A-Za-z_][A-Za-z0-9_]*\z/
    private_constant :IDENTIFIER

    TRUE_FRAGMENT = Fragment.new("1 = 1", []).freeze
    FALSE_FRAGMENT = Fragment.new("1 = 0", []).freeze
    private_constant :TRUE_FRAGMENT, :FALSE_FRAGMENT

    def self.compile(feature, **options)
      new(feature, **options).compile
    end

    # Internal: Initializes a compiler for a feature.
    #
    # feature      - The Flipper::Feature to compile.
    # attributes   - Hash whitelisting flipper property names (Strings) to
    #                the database columns holding them. Properties without a
    #                mapping make compilation fail.
    # actor_column - Name of the column holding flipper ids, used to compile
    #                the actor gate.
    # flipper      - The Flipper::DSL used to resolve FeatureEnabled
    #                references. Defaults to Flipper.instance, matching how
    #                Flipper::Expressions::FeatureEnabled evaluates.
    def initialize(feature, attributes: {}, actor_column: nil, flipper: nil)
      @feature = feature
      @attributes = attributes.each_with_object({}) do |(name, column), hash|
        hash[name.to_s] = validate_column(column)
      end
      @actor_column = actor_column && validate_column(actor_column)
      @flipper = flipper
    end

    # Public: Compiles the feature to a Result of SQL and bind values.
    #
    # Raises NotCompilable when any part of the feature cannot be
    # represented statically.
    def compile
      fragment = compile_feature(@feature, [])
      Result.new(fragment.sql, fragment.binds.dup)
    end

    private

    # Internal: Compiles all gates of a feature, OR-ed together like
    # Feature#enabled? does. +compiling+ tracks the chain of feature names
    # being compiled so circular FeatureEnabled references are detected.
    def compile_feature(feature, compiling)
      name = feature.name.to_s

      # A circular reference evaluates to false in Ruby (see
      # Flipper::Expressions::FeatureEnabled), so compile it as false.
      return FALSE_FRAGMENT if compiling.include?(name)

      compiling = compiling + [name]
      values = feature.gate_values

      # A fully enabled feature matches every actor, so any other gate is
      # irrelevant, exactly like Feature#enabled? short-circuiting on the
      # boolean gate.
      return TRUE_FRAGMENT if values.boolean

      unless values.groups.empty?
        raise NotCompilable,
          "feature #{name.inspect} enables groups #{values.groups.to_a.inspect}; Ruby groups cannot be compiled to SQL"
      end

      if values.percentage_of_actors != 0
        raise NotCompilable,
          "feature #{name.inspect} enables percentage_of_actors #{values.percentage_of_actors}; percentage rollouts cannot be compiled to SQL"
      end

      if values.percentage_of_time != 0
        raise NotCompilable,
          "feature #{name.inspect} enables percentage_of_time #{values.percentage_of_time}; random percentage gates cannot be compiled to SQL"
      end

      fragments = []
      fragments << compile_actor_gate(values.actors) unless values.actors.empty?

      if values.expression && !values.expression.empty?
        expression = Flipper::Expression.build(values.expression)
        fragments << compile_condition(expression, compiling)
      end

      return FALSE_FRAGMENT if fragments.empty?
      return TRUE_FRAGMENT if fragments.any? { |fragment| fragment.sql == TRUE_FRAGMENT.sql }

      combine("OR", fragments)
    end

    def compile_actor_gate(actors)
      unless @actor_column
        raise NotCompilable,
          "actor gate requires the :actor_column option to compile to SQL"
      end

      ids = actors.to_a.sort
      placeholders = (["?"] * ids.size).join(", ")
      Fragment.new("#{@actor_column} IN (#{placeholders})", ids)
    end

    # Internal: Compiles an expression used as a boolean condition.
    def compile_condition(expression, compiling)
      unless expression.is_a?(Flipper::Expression)
        return constant_fragment(expression.evaluate)
      end

      case expression.name
      when "All", "Any"
        compile_group(expression, compiling)
      when *COMPARISONS.keys
        compile_comparison(expression)
      when "FeatureEnabled"
        compile_feature_enabled(expression, compiling)
      when "Boolean"
        compile_boolean_expression(expression)
      when "Property"
        raise NotCompilable,
          "bare Property(...) has no SQL equivalent for Ruby truthiness; wrap it in a comparison or Boolean(...)"
      else
        if (reason = VOLATILE_EXPRESSIONS[expression.name])
          raise NotCompilable, reason
        elsif foldable?(expression)
          constant_fragment(expression.evaluate({}))
        else
          raise NotCompilable, offender_reason(expression)
        end
      end
    end

    def compile_group(expression, compiling)
      fragments = expression.args.map { |arg| compile_condition(arg, compiling) }

      # An empty All matches every actor and an empty Any matches none, just
      # like [].all? and [].any? in Ruby.
      return expression.name == "All" ? TRUE_FRAGMENT : FALSE_FRAGMENT if fragments.empty?

      combine(expression.name == "All" ? "AND" : "OR", fragments)
    end

    def compile_comparison(expression)
      left, right = expression.args

      if (typed = typed_property(left))
        compile_property_comparison(expression.name, typed, right)
      elsif (typed = typed_property(right))
        compile_property_comparison(FLIPPED_COMPARISONS.fetch(expression.name), typed, left)
      elsif contains_expression?(left, "Property") || contains_expression?(right, "Property")
        raise NotCompilable,
          "comparisons between two properties cannot be compiled to SQL"
      elsif foldable?(expression)
        constant_fragment(expression.evaluate({}))
      else
        raise NotCompilable, offender_reason(expression)
      end
    end

    def compile_feature_enabled(expression, compiling)
      feature_name = static_constant(expression.args[0])

      unless feature_name.is_a?(String) || feature_name.is_a?(Symbol)
        raise NotCompilable,
          "FeatureEnabled(...) must reference a constant feature name"
      end

      compile_feature(feature_for(feature_name), compiling)
    end

    def compile_boolean_expression(expression)
      typed = typed_property(expression.args[0])

      if typed && typed[1] == :none
        # Mirrors Typecast.to_boolean: only true, 1, "true" and "1" are true.
        Fragment.new("#{column_for(typed[0])} IN (1, '1', 'true')", [])
      elsif foldable?(expression)
        constant_fragment(expression.evaluate({}))
      else
        raise NotCompilable, offender_reason(expression)
      end
    end

    # Internal: Compiles a comparison between a property (with an optional
    # Number/String coercion) and a constant value.
    def compile_property_comparison(name, typed, constant_expression)
      property_name, coercion = typed

      if contains_expression?(constant_expression, "Property")
        raise NotCompilable,
          "comparisons between two properties cannot be compiled to SQL"
      end

      if contains_expression?(constant_expression, "FeatureEnabled")
        raise NotCompilable,
          "FeatureEnabled(...) cannot be used as a comparison operand"
      end

      column = column_for(property_name)
      value = static_value(constant_expression)

      unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
        raise NotCompilable,
          "cannot bind #{value.class} values in SQL comparisons"
      end

      case coercion
      when :number
        compile_number_comparison(column, name, value)
      when :string
        compile_string_comparison(column, name, value)
      else
        compile_untyped_comparison(column, name, value)
      end
    end

    # Internal: Number(Property) always evaluates to a Numeric in Ruby
    # (Typecast.to_number maps nil to 0 and non-numeric strings to 0, which
    # COALESCE + CAST mirrors). Note: Ruby's String#to_i/to_f and SQLite's
    # CAST differ for exotic strings like "1e5".
    def compile_number_comparison(column, name, value)
      unless value.is_a?(Numeric)
        # Comparing a Numeric with a non-Numeric is false in Ruby (true for
        # NotEqual), and ordering comparisons raise, which Comparable
        # rescues as false.
        return name == "NotEqual" ? TRUE_FRAGMENT : FALSE_FRAGMENT
      end

      Fragment.new(
        "COALESCE(CAST(#{column} AS REAL), 0) #{COMPARISONS.fetch(name)} ?",
        [value]
      )
    end

    # Internal: String(Property) always evaluates to a String in Ruby
    # (nil.to_s is "", which COALESCE + CAST mirrors).
    def compile_string_comparison(column, name, value)
      unless value.is_a?(String)
        return name == "NotEqual" ? TRUE_FRAGMENT : FALSE_FRAGMENT
      end

      Fragment.new(
        "COALESCE(CAST(#{column} AS TEXT), '') #{COMPARISONS.fetch(name)} ?",
        [value]
      )
    end

    # Internal: An untyped Property compares the raw values. Ruby compares
    # with type awareness ("21" == 21 is false and "21" > 21 raises, which
    # Comparable rescues as false), while SQLite would silently apply column
    # affinity. Guarding on the storage class keeps text comparing with text
    # and numbers with numbers, like Ruby. A missing property (NULL) is not
    # equal to anything and fails ordering comparisons, but is always
    # "not equal", exactly like nil in Ruby.
    def compile_untyped_comparison(column, name, value)
      parity = "(typeof(#{column}) = 'text') = (typeof(?) = 'text')"

      case name
      when "Equal"
        Fragment.new("(#{column} = ? AND #{parity})", [value, value])
      when "NotEqual"
        Fragment.new("(#{column} IS NULL OR #{column} != ? OR NOT #{parity})", [value, value])
      else
        Fragment.new("(#{parity} AND #{column} #{COMPARISONS.fetch(name)} ?)", [value, value])
      end
    end

    # Internal: Returns [property_name, coercion] when the expression is a
    # Property with a constant key, optionally wrapped in a single
    # Number/String coercion. coercion is :none, :number or :string.
    # Returns nil otherwise.
    def typed_property(expression)
      return nil unless expression.is_a?(Flipper::Expression)

      coercion = :none
      if expression.name == "Number" || expression.name == "String"
        coercion = expression.name == "Number" ? :number : :string
        expression = expression.args[0]
        return nil unless expression.is_a?(Flipper::Expression)
      end

      return nil unless expression.name == "Property"

      key = static_constant(expression.args[0])
      key.nil? ? nil : [key.to_s, coercion]
    end

    # Internal: Evaluates an expression that must reduce to a constant.
    def static_value(expression)
      case expression
      when Flipper::Expression::Constant
        expression.value
      when Flipper::Expression
        if foldable?(expression)
          expression.evaluate({})
        else
          raise NotCompilable, offender_reason(expression)
        end
      else
        expression
      end
    end

    # Internal: Returns the constant value of an expression, or nil when it
    # is not statically known.
    def static_constant(expression)
      case expression
      when Flipper::Expression::Constant
        expression.value
      when Flipper::Expression
        foldable?(expression) ? expression.evaluate({}) : nil
      else
        expression
      end
    end

    # Internal: True when the expression only contains constants and pure
    # functions, so Ruby can evaluate it once at compile time with the exact
    # same result every actor would get.
    def foldable?(expression)
      return true unless expression.is_a?(Flipper::Expression)
      return false if VOLATILE_EXPRESSIONS.key?(expression.name)
      return false if expression.name == "Property" || expression.name == "FeatureEnabled"

      expression.args.all? { |arg| foldable?(arg) }
    end

    def contains_expression?(expression, name)
      return false unless expression.is_a?(Flipper::Expression)
      return true if expression.name == name

      expression.args.any? { |arg| contains_expression?(arg, name) }
    end

    # Internal: Explains why an expression cannot be compiled, based on the
    # first offending node found.
    def offender_reason(expression)
      return "cannot be compiled to SQL" unless expression.is_a?(Flipper::Expression)

      if (reason = VOLATILE_EXPRESSIONS[expression.name])
        return reason
      end

      if expression.name == "FeatureEnabled"
        return "FeatureEnabled(...) must reference a constant feature name"
      end

      if expression.name == "Property"
        return "Property(...) is only supported as a comparison operand or inside Boolean(...)"
      end

      expression.args.each do |arg|
        reason = offender_reason(arg)
        return reason if reason
      end

      nil
    end

    def constant_fragment(value)
      value ? TRUE_FRAGMENT : FALSE_FRAGMENT
    end

    def combine(operator, fragments)
      return fragments.first if fragments.size == 1

      sql = fragments.map { |fragment| "(#{fragment.sql})" }.join(" #{operator} ")
      Fragment.new(sql, fragments.flat_map(&:binds))
    end

    def column_for(property_name)
      @attributes.fetch(property_name) do
        raise NotCompilable,
          "no column mapping for property #{property_name.inspect}; add it to the :attributes whitelist to compile"
      end
    end

    def feature_for(name)
      (@flipper || Flipper.instance)[name]
    end

    # Internal: Column names come from the caller, not from rule data, but
    # they are interpolated into SQL, so only plain (optionally
    # table-qualified) identifiers are allowed.
    def validate_column(column)
      column = column.to_s

      unless column.split(".").all? { |part| part.match?(IDENTIFIER) }
        raise ArgumentError, "#{column.inspect} is not a valid column identifier"
      end

      column
    end
  end
end
