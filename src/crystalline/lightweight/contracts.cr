require "./index"
require "./type_utils"

module Crystalline::Lightweight
  enum MethodContractKind
    YieldSelf
    YieldElement
    YieldElementWithIndex
    YieldKey
    YieldValue
    YieldKeyValue
    YieldAccumulatorAndElement
    PreserveReceiver
    ReturnElement
    ReturnElementOrNil
    ReturnValue
    ReturnValueOrNil
  end

  enum MethodContractResultShape
    ArrayOfBlockResult
    ArrayOfCompactBlockResult
    ArrayOfFlattenedBlockResult
    HashOfBlockResultToReceiverElement
    HashOfBlockResultToReceiverElementArray
    BlockResultOrNil
  end

  record MethodContract,
    kind : MethodContractKind,
    types : Array(String) = [] of String,
    block_args : Array(Array(String)) = [] of Array(String),
    result_shape : MethodContractResultShape? = nil,
    class_method : Bool = false

  module Contracts
    extend self

    # Derives a method's contracts from its own declaration — the block
    # restriction and the return type — instead of a per-method-name
    # table. `map(& : T -> U) : Array(U)` yields the element and returns
    # an array of the block result; `index_by(& : T -> U) : Hash(U, T)`
    # yields the element and returns a hash of block result to element.
    # The declaration is the spec, so stdlib changes cannot drift.
    def derive(owner_name : String, method : MethodInfo) : Array(MethodContract)
      contracts = [] of MethodContract
      # `T?` to_s-es as `T | ::Nil`: strip the absolute-path marker so
      # the structural comparisons see plain names.
      normalized_return_types = method.return_type.try { |return_type| TypeUtils.expand_type_names(return_type).map(&.lchop("::")) }

      if normalized_return_types
        if normalized_return_types == [owner_name] || normalized_return_types == ["self"]
          contracts << MethodContract.new(kind: MethodContractKind::PreserveReceiver, types: [owner_name], class_method: method.class_method)
        elsif normalized_return_types.sort == [owner_name, "Nil"].sort
          contracts << MethodContract.new(kind: MethodContractKind::ReturnValueOrNil, types: [owner_name], class_method: method.class_method)
        elsif normalized_return_types.includes?("Nil")
          contracts << MethodContract.new(kind: MethodContractKind::ReturnValueOrNil, types: normalized_return_types.reject(&.==("Nil")), class_method: method.class_method)
        else
          contracts << MethodContract.new(kind: MethodContractKind::ReturnValue, types: normalized_return_types, class_method: method.class_method)
        end
      end

      if block_restriction = method.block_restriction
        if split = split_proc_restriction(block_restriction)
          proc_inputs, proc_output = split
          element_types = TypeUtils.enumerable_element_types(owner_name) || [] of String
          element_var = element_types.first? || generic_element_var(owner_name)

          if yield_contract = yield_contract_for(proc_inputs, owner_name, element_types, method)
            contracts << yield_contract
          end

          if shape = block_result_shape_for(proc_output, method.return_type, element_types, owner_name)
            contracts << MethodContract.new(kind: MethodContractKind::ReturnValue, result_shape: shape, class_method: method.class_method)
          end
        end
      end

      # A bare-& method that yields the receiver (`OptionParser.parse do
      # |parser|`, `File.open(path) do |file|`): the declaration cannot
      # express the yield target, so the known receiver-yielders are
      # name-keyed. `String.build` declares the same shape but yields its
      # builder, not the receiver — deliberately absent.
      if method.block_restriction.nil? && method.return_type == "self"
        case "#{owner_name}.#{method.name}"
        when "OptionParser.parse", "File.open", "IO.open"
          contracts << MethodContract.new(kind: MethodContractKind::YieldSelf, types: [owner_name], class_method: method.class_method)
        end
      end

      # Residual computed shapes: the stdlib declares these with an
      # untyped block and no return type — `flat_map(& : T -> _)`,
      # `compact_map(& : T -> _)`, `group_by(& : T -> U)` — the result
      # only exists in the method body, which the structural derivation
      # deliberately does not evaluate.
      case method.name
      when "flat_map"
        contracts << MethodContract.new(kind: MethodContractKind::ReturnValue, result_shape: MethodContractResultShape::ArrayOfFlattenedBlockResult, class_method: method.class_method)
      when "compact_map"
        contracts << MethodContract.new(kind: MethodContractKind::ReturnValue, result_shape: MethodContractResultShape::ArrayOfCompactBlockResult, class_method: method.class_method)
      when "group_by"
        contracts << MethodContract.new(kind: MethodContractKind::ReturnValue, result_shape: MethodContractResultShape::HashOfBlockResultToReceiverElementArray, class_method: method.class_method)
      when "find_value"
        contracts << MethodContract.new(kind: MethodContractKind::ReturnValueOrNil, result_shape: MethodContractResultShape::BlockResultOrNil, class_method: method.class_method)
      end

      # Language intrinsics with no block restriction in the declaration:
      # `tap(&)` yields the receiver and returns `self`; `try(&)` yields
      # the non-nil receiver and returns the block result or nil. The
      # block-arg seeding for both happens at the call site (receiver
      # types), only the return contracts live here.
      if method.name == "tap" && normalized_return_types == [owner_name]
        contracts << MethodContract.new(kind: MethodContractKind::YieldSelf, types: [owner_name], class_method: method.class_method)
      end
      if method.name == "try" && !method.class_method
        contracts << MethodContract.new(kind: MethodContractKind::ReturnValueOrNil, result_shape: MethodContractResultShape::BlockResultOrNil, class_method: method.class_method)
      end

      # Element-return contracts: the declared return matches the owner's
      # element/key/value types (`first : T` on `Array(T)`).
      if element_types = TypeUtils.enumerable_element_types(owner_name)
        if normalized_return_types
          if normalized_return_types.sort == element_types.sort
            contracts << MethodContract.new(kind: MethodContractKind::ReturnElement, types: element_types, class_method: method.class_method)
          elsif normalized_return_types.sort == (element_types + ["Nil"]).uniq.sort!
            contracts << MethodContract.new(kind: MethodContractKind::ReturnElementOrNil, types: element_types, class_method: method.class_method)
          end
        end
      end

      if key_types = TypeUtils.hash_key_types(owner_name)
        if value_types = TypeUtils.hash_value_types(owner_name)
          if normalized_return_types
            if normalized_return_types.sort == value_types.sort
              contracts << MethodContract.new(kind: MethodContractKind::ReturnValue, types: value_types, class_method: method.class_method)
            elsif normalized_return_types.sort == (value_types + ["Nil"]).uniq.sort!
              contracts << MethodContract.new(kind: MethodContractKind::ReturnValueOrNil, types: value_types, class_method: method.class_method)
            end
          end
        end
      end

      # `reduce`'s accumulator type depends on the memo argument at the
      # call site: the declaration (`& : (U, T) -> U`) cannot express it,
      # so it stays name-keyed.
      if method.name == "reduce"
        if element_types = TypeUtils.enumerable_element_types(owner_name)
          contracts << MethodContract.new(kind: MethodContractKind::YieldAccumulatorAndElement, block_args: [element_types, element_types], class_method: method.class_method)
        end
      end

      contracts
    end

    # `(T -> U)` / `(T, Int32 ->)` / `(T -> U | ::Nil)` → {inputs, output}.
    private def split_proc_restriction(restriction : String) : {Array(String), String}
      normalized = restriction.strip
      if normalized.starts_with?('(') && normalized.ends_with?(')')
        normalized = normalized[1...-1]
      end

      # The last ` ->` separates the inputs from the output (a nested
      # Proc type could contain an earlier arrow).
      arrow = normalized.rindex(" ->")
      if arrow
        inputs = TypeUtils.split_top_level(normalized[0...arrow], ',').map(&.strip)
        output = normalized[arrow + 3..].strip
        {inputs, output}
      else
        {[] of String, normalized}
      end
    end

    # Matches the block's input vars against the owner's element/key/value
    # types: `& : T -> ` on `Array(T)` yields the element, `& : K, V -> `
    # on `Hash(K, V)` yields key and value. The semantic form of a
    # multi-arg block is a single tuple input (`::Tuple(K, V) ->`).
    private def yield_contract_for(proc_inputs : Array(String), owner_name : String, element_types : Array(String), method : MethodInfo) : MethodContract?
      return nil if proc_inputs == ["self"]

      inputs = if proc_inputs.size == 1
                 if tuple_parts = TypeUtils.tuple_element_types(proc_inputs.first)
                   # The block destructures a single tuple element into multiple
                   # params (`map { |k, v| ... }` on `Array(Tuple(K, V))`):
                   # compare against the element tuple's parts, not the whole
                   # tuple.
                   if element_types.size == 1
                     if element_parts = TypeUtils.tuple_element_types(element_types.first)
                       element_types = element_parts.map(&.join(" | "))
                     end
                   end
                   tuple_parts.map(&.join(" | "))
                 else
                   proc_inputs
                 end
               else
                 proc_inputs
               end

      if !element_types.empty?
        # A single input may be a union string (`& : (A | B ->)` on a
        # compiled instantiation): compare the expanded parts too.
        expanded_inputs = inputs.flat_map { |input| TypeUtils.expand_type_names(input) }
        if expanded_inputs == element_types || inputs == element_types
          return MethodContract.new(kind: MethodContractKind::YieldElement, types: element_types, class_method: method.class_method)
        end
        if inputs.size == 2 && inputs[1] == "Int32" && TypeUtils.expand_type_names(inputs[0]) == element_types
          return MethodContract.new(kind: MethodContractKind::YieldElementWithIndex, types: element_types + ["Int32"], class_method: method.class_method)
        end
      elsif element_var = generic_element_var(owner_name)
        # A generic module owner (`Enumerable(T)`): its single type var is
        # the element var. The call site substitutes the receiver's types.
        if inputs == [element_var]
          return MethodContract.new(kind: MethodContractKind::YieldElement, types: [element_var], class_method: method.class_method)
        end
        if inputs == [element_var, "Int32"]
          return MethodContract.new(kind: MethodContractKind::YieldElementWithIndex, types: [element_var, "Int32"], class_method: method.class_method)
        end
      end

      if key_types = TypeUtils.hash_key_types(owner_name)
        if inputs == key_types
          return MethodContract.new(kind: MethodContractKind::YieldKey, types: key_types, class_method: method.class_method)
        end
        if value_types = TypeUtils.hash_value_types(owner_name)
          if inputs == value_types
            return MethodContract.new(kind: MethodContractKind::YieldValue, types: value_types, class_method: method.class_method)
          end
          if inputs == key_types + value_types
            return MethodContract.new(kind: MethodContractKind::YieldKeyValue, types: key_types + value_types, class_method: method.class_method)
          end
        end
      end

      # A helper with a typed block restriction on a non-enumerable owner
      # (`each_direct_def(node, & : Crystal::Def ->)`): the restriction's
      # input types ARE the block-arg types. Only concrete names qualify
      # — a bare single-letter var (`T`) means a generic element handled
      # by the caller's substitution.
      if inputs.all? { |input| input.size > 1 || input != input.upcase }
        return MethodContract.new(kind: MethodContractKind::YieldSelf, types: inputs, class_method: method.class_method)
      end

      nil
    end

    # Matches the block's output var against the return type's pattern:
    # `Array(U)` → array of block result, `U | ::Nil` → block result or
    # nil, `Hash(U, T)` → hash of block result to element, ...
    private def block_result_shape_for(proc_output : String, return_type : String?, element_types : Array(String), owner_name : String) : MethodContractResultShape?
      return nil unless return_type
      output = proc_output.strip
      return nil if output.empty?

      # `U?` parses (and to_s-es) as `U | ::Nil`.
      if output.ends_with?("| ::Nil") || output.ends_with?("| Nil")
        base = output.rchop("| ::Nil").rchop("| Nil").rstrip
        return MethodContractResultShape::BlockResultOrNil if return_type == output
        return MethodContractResultShape::ArrayOfCompactBlockResult if return_type == "Array(#{base})"
        return nil
      end

      if output.starts_with?("Array(") && output.ends_with?(')')
        # `flat_map(& : T -> Array(U)) : Array(U)` splices the block's
        # array; a map with an array block yields Array(Array(U)).
        return MethodContractResultShape::ArrayOfFlattenedBlockResult if return_type == output
        return MethodContractResultShape::ArrayOfBlockResult if return_type == "Array(#{output})"
        return nil
      end

      if return_type == "Array(#{output})"
        return MethodContractResultShape::ArrayOfBlockResult
      end
      if return_type == "#{output} | Nil" || return_type == "#{output} | ::Nil"
        return MethodContractResultShape::BlockResultOrNil
      end
      if element_var = element_types.first? || generic_element_var(owner_name)
        if return_type == "Hash(#{output}, #{element_var})"
          return MethodContractResultShape::HashOfBlockResultToReceiverElement
        end
        if return_type == "Hash(#{output}, Array(#{element_var}))"
          return MethodContractResultShape::HashOfBlockResultToReceiverElementArray
        end
      end

      nil
    end

    # `Enumerable(T)` → `T`; the single bare type var of a generic owner
    # is its element var.
    private def generic_element_var(owner_name : String) : String?
      open = owner_name.index('(')
      return nil unless open && owner_name.ends_with?(')')

      args = TypeUtils.split_top_level(owner_name[open + 1...-1], ',')
      return nil unless args.size == 1

      var = args.first.strip
      var.size == 1 && var == var.upcase ? var : nil
    end
  end
end
