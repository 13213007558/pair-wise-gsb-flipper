require "flipper/errors"
require "flipper/expression"

module Flipper
  class SQLCompiler
    class Error < Flipper::Error; end

    TRUE_SQL = "(1 = 1)".freeze
    FALSE_SQL = "(1 = 0)".freeze

    COMPARISON_OPERATORS = {
      "Equal" => "=",
      "NotEqual" => "!=",
      "GreaterThan" => ">",
      "GreaterThanOrEqualTo" => ">=",
      "LessThan" => "<",
      "LessThanOrEqualTo" => "<=",
    }.freeze

    REVERSE_OPERATORS = {
      "=" => "=",
      "!=" => "!=",
      ">" => "<",
      ">=" => "<=",
      "<" => ">",
      "<=" => ">=",
    }.freeze

    def initialize(adapter)
      @adapter = adapter
    end

    def compile(feature, columns:)
      feature = feature_for(feature)
      @columns = normalize_columns(columns)
      sql, bindings = compile_feature(feature, [feature.key])
      [sql, bindings]
    end

    private

    def feature_for(feature)
      return feature if feature.is_a?(Feature)
      Feature.new(feature, @adapter)
    end

    def normalize_columns(columns)
      unless columns.is_a?(Hash)
        raise Error, "columns must be a Hash whitelist that maps actor property names to SQL column expressions."
      end

      columns.each_with_object({}) do |(name, column), normalized|
        normalized[name.to_s] = column_spec(column)
      end
    end

    def column_spec(column)
      case column
      when String, Symbol
        { sql: column.to_s, type: nil }
      when Hash
        sql = column[:column] || column["column"]
        type = column[:type] || column["type"]
        if sql.nil?
          raise Error, "column mapping #{column.inspect} must include :column."
        end
        { sql: sql.to_s, type: type && type.to_sym }
      else
        raise Error, "column mapping #{column.inspect} must be a SQL column expression String or a Hash containing :column."
      end
    end

    def compile_feature(feature, path)
      raw_values = @adapter.get(feature)
      values = GateValues.new(raw_values)

      return [TRUE_SQL, []] if values.boolean
      return [FALSE_SQL, []] unless raw_values[:boolean].nil?

      return [TRUE_SQL, []] if [values.percentage_of_actors, values.percentage_of_time].any? { |value| value && value >= 100 }

      conditions = []

      if values.expression && !values.expression.empty?
        expression_fragment = compile_expression(Expression.build(values.expression), path, feature.key)
        return [TRUE_SQL, []] if expression_fragment.first == TRUE_SQL
        conditions << expression_fragment
      end

      unless values.actors.empty?
        conditions << actor_condition(values.actors.to_a.sort)
      end

      if values.groups.any?
        raise Error, "feature #{feature.key.inspect} uses the Ruby group gate #{values.groups.to_a.sort.inspect}, which cannot be evaluated in SQL."
      end

      [[:percentage_of_actors, values.percentage_of_actors],
       [:percentage_of_time, values.percentage_of_time]].each do |gate, percentage|
        next if percentage.nil? || percentage.zero?
        raise Error, "feature #{feature.key.inspect} uses the #{gate} gate at #{percentage}%, which cannot be represented as a static SQL predicate."
      end

      return [FALSE_SQL, []] if conditions.empty?
      combine(conditions, "OR")
    end

    def actor_condition(actors)
      column = column_for("flipper_id")
      placeholders = Array.new(actors.size) { "?" }.join(", ")
      ["(#{column} IN (#{placeholders}))", actors]
    end

    def compile_expression(expression, feature_path, feature_name)
      name = expression.name
      args = expression.args

      case name
      when "All", "Any"
        return [TRUE_SQL, []] if name == "All" && args.empty?
        return [FALSE_SQL, []] if name == "Any" && args.empty?

        combine(args.map { |arg| compile_expression(arg, feature_path, feature_name) },
                name == "All" ? "AND" : "OR")
      when "Equal", "NotEqual", "GreaterThan", "GreaterThanOrEqualTo", "LessThan", "LessThanOrEqualTo"
        compile_comparison(expression, feature_path, feature_name)
      when "FeatureEnabled"
        compile_feature_enabled(expression, feature_path, feature_name)
      when "Boolean"
        static_boolean_expression(expression)
      else
        raise unsupported_expression(name)
      end
    end

    def compile_comparison(expression, feature_path, feature_name)
      name = expression.name
      args = expression.args
      unless args.size == 2
        raise Error, "expression #{name.inspect} requires exactly two operands but received #{args.size}."
      end

      left = static_operand(args.first, feature_path, feature_name)
      right = static_operand(args.last, feature_path, feature_name)

      if left[:kind] == :feature || right[:kind] == :feature
        return compile_feature_comparison(name, left, right)
      end

      if left[:kind] == :value && right[:kind] == :value
        result = ruby_comparison(COMPARISON_OPERATORS.fetch(name), left[:value], right[:value])
        return [result ? TRUE_SQL : FALSE_SQL, []]
      end

      if left[:kind] == :column && right[:kind] == :value
        return typed_comparison(left[:column], left[:type], COMPARISON_OPERATORS.fetch(name), right[:value])
      end

      if left[:kind] == :value && right[:kind] == :column
        operator = REVERSE_OPERATORS.fetch(COMPARISON_OPERATORS.fetch(name))
        return typed_comparison(right[:column], right[:type], operator, left[:value])
      end

      raise Error, "expression #{name.inspect} compares two actor properties, which is not supported by the SQL compiler."
    end

    def compile_feature_comparison(name, left, right)
      feature_operand = left[:kind] == :feature ? left : right
      other = left[:kind] == :feature ? right : left
      raise unsupported_expression("FeatureEnabled") unless other[:kind] == :value

      sql, bindings = feature_operand[:fragment]
      value = other[:value]

      case name
      when "Equal"
        return [sql, bindings] if value == true
        return [negate(sql), bindings] if value == false
      when "NotEqual"
        return [negate(sql), bindings] if value == true
        return [sql, bindings] if value == false
      end

      [FALSE_SQL, []]
    end

    def static_operand(expression, feature_path, feature_name)
      case expression
      when Expression::Constant
        { kind: :value, value: expression.value }
      when Expression
        case expression.name
        when "Property"
          property = static_property_name(expression)
          spec = column_spec_for(property)
          { kind: :column, column: spec.fetch(:sql), type: spec.fetch(:type) }
        when "FeatureEnabled"
          { kind: :feature, fragment: compile_feature_enabled(expression, feature_path, feature_name) }
        when "String"
          static_wrapped_value(expression, :string)
        when "Number"
          static_wrapped_value(expression, :number)
        when "Boolean"
          static_wrapped_value(expression, :boolean)
        else
          raise unsupported_expression(expression.name)
        end
      else
        raise Error, "#{expression.inspect} is not a statically compilable expression operand."
      end
    end

    def static_property_name(expression)
      arg = expression.args.first
      unless expression.args.size == 1 && arg.is_a?(Expression::Constant)
        raise Error, "Property expression requires one constant actor property name."
      end
      arg.value.to_s
    end

    def static_wrapped_value(expression, wrapper)
      unless expression.args.size == 1 && expression.args.first.is_a?(Expression::Constant)
        raise unsupported_expression(expression.name)
      end

      value = expression.args.first.value
      value =
        case wrapper
        when :string then value.to_s
        when :number then Typecast.to_number(value)
        when :boolean then Typecast.to_boolean(value)
        end
      { kind: :value, value: value }
    rescue NoMethodError, ArgumentError
      raise unsupported_expression(expression.name)
    end

    def compile_feature_enabled(expression, feature_path, feature_name)
      unless expression.is_a?(Expression) && expression.name == "FeatureEnabled"
        raise unsupported_expression("FeatureEnabled")
      end
      unless expression.args.size == 1 && expression.args.first.is_a?(Expression::Constant)
        raise Error, "FeatureEnabled expression requires one constant feature name."
      end

      referenced_feature = expression.args.first.value.to_s
      if feature_path.include?(referenced_feature)
        cycle = (feature_path + [referenced_feature]).join(" -> ")
        raise Error, "feature reference cycle detected: #{cycle}."
      end

      compile_feature(Feature.new(referenced_feature, @adapter),
                       feature_path + [referenced_feature])
    end

    def static_boolean_expression(expression)
      static_wrapped_value(expression, :boolean)[:value] ? [TRUE_SQL, []] : [FALSE_SQL, []]
    end

    def typed_comparison(column, declared_type, operator, value)
      return ["(#{column} IS NULL)", []] if value.nil? && operator == "="
      return ["(#{column} IS NOT NULL)", []] if value.nil? && operator == "!="
      return [FALSE_SQL, []] if value.nil? || (operator != "=" && operator != "!=" && boolean_value?(value))

      type_check = type_check(column, declared_type, value)
      return [FALSE_SQL, []] if type_check == false

      comparison = "#{column} #{operator} ?"
      if operator == "!="
        mismatch_result = type_check ? "1" : "0"
        sql = "(CASE WHEN #{column} IS NULL THEN 1 WHEN #{type_check} THEN CASE WHEN #{comparison} THEN 1 ELSE 0 END ELSE #{mismatch_result} END)"
      elsif type_check
        sql = "(CASE WHEN #{type_check} THEN CASE WHEN #{comparison} THEN 1 ELSE 0 END ELSE 0 END)"
      else
        sql = "(CASE WHEN #{comparison} THEN 1 ELSE 0 END)"
      end

      [sql, [bindable_value(value)]]
    end

    def type_check(column, declared_type, value)
      case declared_type
      when :string, :text
        return value.is_a?(String) ? "typeof(#{column}) = 'text'" : false
      when :integer, :float, :numeric, :number
        return numeric_type?(value) ? "typeof(#{column}) IN ('integer', 'real')" : false
      when :boolean
        return boolean_value?(value) ? "typeof(#{column}) = 'integer' AND #{column} IN (0, 1)" : false
      end

      case value
      when String
        "typeof(#{column}) = 'text'"
      when Integer, Float
        "typeof(#{column}) IN ('integer', 'real')"
      when true, false
        "typeof(#{column}) = 'integer' AND #{column} IN (0, 1)"
      end
    end

    def column_spec_for(property)
      spec = @columns[property]
      unless spec
        raise Error, "actor property #{property.inspect} is not included in the SQL column whitelist."
      end
      spec
    end

    def column_for(property)
      column_spec_for(property).fetch(:sql)
    end

    def numeric_type?(value)
      value.is_a?(Integer) || value.is_a?(Float)
    end

    def boolean_value?(value)
      value == true || value == false
    end

    def bindable_value(value)
      return 1 if value == true
      return 0 if value == false
      value
    end

    def ruby_comparison(operator, left, right)
      left.respond_to?(operator) && right.respond_to?(operator) && left.public_send(operator, right)
    rescue ArgumentError
      false
    end

    def combine(fragments, joiner)
      sql = fragments.map { |fragment| fragment.first }.join(" #{joiner} ")
      bindings = fragments.flat_map { |fragment| fragment.last }
      ["(#{sql})", bindings]
    end

    def negate(sql)
      "(CASE WHEN #{sql} THEN 0 ELSE 1 END)"
    end

    def unsupported_expression(name)
      Error.new("expression #{name.inspect} cannot be statically compiled to SQL.")
    end
  end
end
