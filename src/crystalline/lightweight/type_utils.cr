module Crystalline::Lightweight::TypeUtils
  extend self

  def substitute_generic_params(value : String, mapping : Hash(String, String)) : String
    return value if mapping.empty?

    String.build do |result|
      index = 0
      while index < value.size
        char = value[index]

        if char == '*' && (next_char = value[index + 1]?) && token_start_char?(next_char)
          token_end = token_end_index(value, index + 1)
          token = value[index..token_end]
          result << (mapping[token]? || token)
          index = token_end + 1
        elsif token_start_char?(char)
          token_end = token_end_index(value, index)
          token = value[index..token_end]
          result << (mapping[token]? || token)
          index = token_end + 1
        else
          result << char
          index += 1
        end
      end
    end
  end

  def expand_type_names(type_name : String) : Array(String)
    normalized = unwrap_outer_parens(type_name.strip)
    parts = split_top_level(normalized, '|')
    # `T?` is shorthand for `T | ::Nil`: split it so lookups on nilable
    # receivers (`t.try`, `node_type.doc`) reach the base type.
    if parts.size == 1 && normalized.ends_with?('?') && normalized.size > 1
      base = normalized[0...-1].rstrip
      unless base.empty? || base.ends_with?('?')
        return [strip_virtual_suffix(base), "::Nil"]
      end
    end
    (parts.empty? ? [normalized] : parts).map { |part| strip_virtual_suffix(part) }
  end

  # Compiled semantic return types use the virtual-type notation
  # (`Crystal::Def+` for the hierarchy root): the index keys the plain
  # name, so strip the suffix before any lookup.
  private def strip_virtual_suffix(name : String) : String
    name.ends_with?('+') ? name[0...-1].rstrip : name
  end

  def split_top_level(value : String, delimiter : Char) : Array(String)
    parts = [] of String
    paren_depth = 0
    brace_depth = 0
    bracket_depth = 0
    start = 0

    value.each_char_with_index do |char, index|
      case char
      when '('
        paren_depth += 1
      when ')'
        paren_depth -= 1 if paren_depth > 0
      when '{'
        brace_depth += 1
      when '}'
        brace_depth -= 1 if brace_depth > 0
      when '['
        bracket_depth += 1
      when ']'
        bracket_depth -= 1 if bracket_depth > 0
      when delimiter
        next unless paren_depth == 0 && brace_depth == 0 && bracket_depth == 0

        parts << value[start...index].strip
        start = index + 1
      end
    end

    parts << value[start..].to_s.strip
    parts.reject(&.empty?)
  end

  private def token_start_char?(char : Char) : Bool
    char.ascii_letter? || char == '_'
  end

  private def token_end_index(value : String, start_index : Int32) : Int32
    index = start_index
    while (char = value[index + 1]?) && (char.ascii_alphanumeric? || char.in?('_', '?', '!'))
      index += 1
    end
    index
  end

  private def unwrap_outer_parens(value : String) : String
    return value unless value.starts_with?('(') && value.ends_with?(')')
    return value unless wraps_whole_expression?(value)

    value[1...-1]
  end

  private def wraps_whole_expression?(value : String) : Bool
    depth = 0

    value.each_char_with_index do |char, index|
      case char
      when '('
        depth += 1
      when ')'
        depth -= 1
        return false if depth == 0 && index < value.size - 1
      end
    end

    depth == 0
  end

  # Extracts the top-level type arguments of a generic type string, e.g.
  # `Array(Int32)` for ("Array(Int32)", "Array", 1). Returns nil when the
  # name does not match *generic_name* or the arity differs.
  def generic_type_arguments(type_name : String, generic_name : String, arity : Int32?) : Array(String)?
    normalized = type_name.strip
    # An absolute path marker (`::Tuple(...)`) must not defeat the match.
    normalized = normalized.lchop("::")
    prefix = "#{generic_name}("
    return unless normalized.starts_with?(prefix) && normalized.ends_with?(')')

    parts = split_top_level(normalized[prefix.size...-1], ',')
    return unless arity.nil? || parts.size == arity

    parts
  end

  def array_element_types(type_name : String) : Array(String)?
    generic_type_arguments(type_name, "Array", 1).try { |parts| expand_type_names(parts[0]) }
  end

  def hash_key_types(type_name : String) : Array(String)?
    generic_type_arguments(type_name, "Hash", 2).try { |parts| expand_type_names(parts[0]) }
  end

  def hash_value_types(type_name : String) : Array(String)?
    generic_type_arguments(type_name, "Hash", 2).try { |parts| expand_type_names(parts[1]) }
  end

  def tuple_element_types(type_name : String) : Array(Array(String))?
    if parts = generic_type_arguments(type_name, "Tuple", nil)
      return parts.map { |part| expand_type_names(part) }
    end

    normalized = type_name.strip
    if normalized.starts_with?('{') && normalized.ends_with?('}')
      return split_top_level(normalized[1...-1], ',').map { |part| expand_type_names(part) }
    end

    nil
  end

  def named_tuple_type?(type_name : String) : Bool
    normalized = type_name.strip
    normalized.starts_with?("NamedTuple(") && normalized.ends_with?(')')
  end

  def named_tuple_value_types(type_name : String, field_name : String) : Array(String)?
    return unless named_tuple_type?(type_name)

    normalized = type_name.strip
    split_top_level(normalized["NamedTuple(".size...-1], ',').each do |part|
      key, value = part.split(":", 2)
      next unless value
      return expand_type_names(value.strip) if key.strip == field_name
    end

    nil
  end

  def named_tuple_all_value_types(type_name : String) : Array(String)?
    return unless named_tuple_type?(type_name)

    normalized = type_name.strip
    value_types = split_top_level(normalized["NamedTuple(".size...-1], ',').flat_map do |part|
      _, value = part.split(":", 2)
      next [] of String unless value
      expand_type_names(value.strip)
    end.uniq!

    value_types.empty? ? nil : value_types
  end

  # The element type of an enumerable receiver (Array, Tuple, ...), or nil
  # when the type string is not an enumerable.
  def enumerable_element_types(type_name : String) : Array(String)?
    array_element_types(type_name) || tuple_element_types(type_name).try(&.flatten.uniq!)
  end

  # Compiler-semantic accessors whose indexed form carries no usable
  # return type: `ASTNode#type?` is synthesized by the semantic pass (the
  # source carries no def), and the base `Type#parents`/`types?`/`remove_alias`
  # return nil on the base class while subclasses return real values. The
  # lightweight cannot run the semantic pass, so these carry the
  # compiler-level signatures, applied only when the index records no
  # return for a method that exists on a `Crystal::*` receiver.
  SEMANTIC_ACCESSOR_RETURNS = {
    "type?"        => "Crystal::Type | ::Nil",
    "parents"      => "Array(Crystal::Type) | ::Nil",
    "types?"       => "Hash(String, Crystal::Type) | ::Nil",
    "remove_alias" => "Crystal::Type",
    # `Parser#parse` has no declared return in the compiler source and is
    # never instantiated by the prelude driver program, so the index
    # records no type for it; the parsed node is the AST root.
    "parse" => "Crystal::ASTNode",
  }

  def semantic_accessor_return(method_name : String) : String?
    SEMANTIC_ACCESSOR_RETURNS[method_name]?
  end

  # Substitutes a method's generic free vars (`Array(T)#+` returning
  # `Array(T)`) with the receiver's concrete element types (`Array(X)`
  # yields `Array(X)`), so chains keep the real element type instead of
  # a bare `T` that no lookup can resolve. Class-level vars (`T` in
  # `Array(T | U)` where only `U` is recorded as a free var) are mapped
  # from the receiver's elements as well. Returns the original return
  # type when nothing can be substituted.
  def substitute_free_vars(return_type : String?, free_vars : Array(String), receiver_type_name : String) : String?
    return return_type if return_type.nil? || free_vars.empty?

    substitutions = {} of String => String
    if elements = array_element_types(receiver_type_name)
      free_vars.each_with_index do |var, index|
        substitutions[var] = elements[index]? || elements.first? || var
      end
    elsif (keys = hash_key_types(receiver_type_name)) && (values = hash_value_types(receiver_type_name))
      if (key_var = free_vars[0]?) && (key_type = keys.first?)
        substitutions[key_var] = key_type
      end
      if (value_var = free_vars[1]?) && (value_type = values.first?)
        substitutions[value_var] = value_type
      end
    elsif tuples = tuple_element_types(receiver_type_name)
      free_vars.each_with_index do |var, index|
        substitutions[var] = tuples[index]?.try(&.join(" | ")) || var
      end
    end

    # Class-level vars are not listed in the method's free vars: map any
    # remaining single-letter var in the return to the receiver's
    # elements (by order of appearance).
    element_pool = array_element_types(receiver_type_name) ||
                   hash_key_types(receiver_type_name) ||
                   hash_value_types(receiver_type_name) ||
                   tuple_element_types(receiver_type_name).try(&.flatten)
    if element_pool && !element_pool.empty?
      pool_index = 0
      return_type.scan(/\b([A-Z])\b/) do |match|
        var = match[1]
        next if var.nil? || substitutions.has_key?(var)
        substitutions[var] = element_pool[pool_index % element_pool.size]
        pool_index += 1
      end
    end
    return return_type if substitutions.empty?

    pattern = substitutions.keys.map { |var| Regex.escape(var) }.join("|")
    substituted = return_type.gsub(/\b(#{pattern})\b/) { |match| substitutions[match] }
    return return_type if substituted == return_type

    deduplicate_substituted_unions(substituted)
  end

  # Substitution can collapse a union (`T | U` both mapping to the same
  # element): collapse the duplicate members so the result stays
  # resolvable (`Array(MethodInfo | MethodInfo)` -> `Array(MethodInfo)`).
  private def deduplicate_substituted_unions(type_name : String) : String
    if (parts = generic_type_arguments(type_name, "Array", 1)) && (element = parts[0]?)
      expanded = expand_type_names(element)
      if expanded.size > 1
        deduped = expanded.uniq
        return "Array(#{deduped.join(" | ")})" if deduped.size < expanded.size
      end
    end

    expanded = expand_type_names(type_name)
    if expanded.size > 1
      deduped = expanded.uniq
      return deduped.join(" | ") if deduped.size < expanded.size
    end

    type_name
  end
end
