require "compiler/crystal/syntax"
require "./type_utils"
require "./query"

module Crystalline::Lightweight
  class Inference
    getter local_types = {} of String => Array(String)
    getter instance_var_types = {} of String => Array(String)
    getter class_var_types = {} of String => Array(String)
    getter current_def : Crystal::Def?
    getter current_type_name : String?
    getter? class_method_context = false
    @current_type_body : Crystal::ASTNode? = nil
    @ast : Crystal::ASTNode? = nil
    # Call sites whose untyped-arg values need the caller's locals: one
    # bounded walk of each caller infers them all (see
    # collect_pending_call_site_types).
    @pending_call_sites : Hash(Crystal::Def, Array(Crystal::Call))? = nil
    @pending_caller : Crystal::Def? = nil
    @pending_definition : Crystal::Def? = nil
    @pending_untyped : Array(Crystal::Arg)? = nil
    @pending_types : Hash(String, Array(String))? = nil

    def self.for(source : String, line : Int32, column : Int32, query : Query) : self?
      new(source, line, column, query).run
    end

    def initialize(@source : String, @line : Int32, @column : Int32, @query : Query)
    end

    def run : self?
      parser = Crystal::Parser.new(@source)
      parser.wants_doc = false
      ast = parser.parse
      @ast = ast

      locate_context(ast)
      if current_def = @current_def
        seed_arg_types(current_def, ast)
        seed_type_vars_from_summary
        seed_indexed_ivar_types
        process_initialize_defs(ast) unless class_method_context? || current_def.name == "initialize"
        # Class-level statements before the cursor's def (constants like
        # `ACCESSOR_MACROS = %w[...]`, ivar assignments) also seed the
        # visible state: walk the type body without entering other defs.
        if type_body = @current_type_body
          process_node(type_body, apply_cursor_bounds: true)
        end
        process_node(current_def.body)
      elsif @current_type_name
        # The cursor sits directly in a type body, not inside a def: seed
        # ivar types from the index (and from initialize arguments) so
        # `@ivar.` receivers resolve before any method is entered.
        seed_type_vars_from_summary
        process_initialize_defs(ast) unless class_method_context?
        process_node(@current_type_body.not_nil!, apply_cursor_bounds: true)
      else
        # Top-level code with no enclosing def: infer from the expressions
        # that appear before the cursor.
        process_node(ast)
      end
      self
    rescue Crystal::SyntaxException
      nil
    end

    def types_for(name : String) : Array(String)
      # Recorded types may carry unions (`TokenSpan?`, `X | ::Nil`): expand
      # them so receiver lookups see plain, known type names.
      (@local_types[name]? || [] of String).flat_map { |type_name| TypeUtils.expand_type_names(type_name) }.map { |type_name| type_name.lchop("::") }.uniq
    end

    def types_for_instance_var(name : String) : Array(String)
      # Recorded types may carry unions (`URI?`, `URI | ::Nil`): expand
      # them so receiver lookups see plain, known type names.
      (@instance_var_types[name]? || [] of String).flat_map { |type_name| TypeUtils.expand_type_names(type_name) }.map { |type_name| type_name.lchop("::") }.uniq
    end

    # Ivar reads without a recorded assignment still resolve when the
    # enclosing type declares the ivar through an accessor-with-initializer
    # (`getter local_types = {} of String => Array(String)`): the index
    # records the getter method, so fall back to its return type.
    def instance_var_types_for(name : String) : Array(String)
      local_types = types_for_instance_var(name)
      return local_types unless local_types.empty?

      if type_name = @current_type_name
        @query.methods_for(type_name, class_method: class_method_context?).each do |method|
          if method.name == name.lchop('@') && (return_type = method.return_type)
            return resolve_type_names(TypeUtils.expand_type_names(return_type))
          end
        end
      end
      [] of String
    end

    def class_var_types_for(name : String) : Array(String)
      local_types = types_for_class_var(name)
      return local_types unless local_types.empty?

      if type_name = @current_type_name
        @query.methods_for(type_name, class_method: true).each do |method|
          if method.name == name.lchop("@@") && (return_type = method.return_type)
            return resolve_type_names(TypeUtils.expand_type_names(return_type))
          end
        end
      end
      [] of String
    end

    def types_for_class_var(name : String) : Array(String)
      (@class_var_types[name]? || [] of String).flat_map { |type_name| TypeUtils.expand_type_names(type_name) }.map { |type_name| type_name.lchop("::") }.uniq
    end

    def self_types : {Array(String), Bool}
      if type_name = @current_type_name
        {[type_name], class_method_context?}
      else
        {[] of String, false}
      end
    end

    private def record_assignment_types(target : Crystal::ASTNode, types : Array(String))
      case target
      when Crystal::Var
        @local_types[target.name] = types
      when Crystal::Path
        # A constant (`CAST_SEGMENT = "__lightweight_cast__"`): record
        # it like a local so receivers resolve to the literal's type.
        @local_types[target.to_s] = types
      when Crystal::InstanceVar
        @instance_var_types[target.name] = types
      when Crystal::ClassVar
        @class_var_types[target.name] = types
      end
    end

    private def process_node(node : Crystal::ASTNode, *, apply_cursor_bounds = true)
      case node
      when Crystal::Expressions
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        node.expressions.each do |expression|
          break if apply_cursor_bounds && !starts_before_or_at_cursor?(expression)
          process_node(expression, apply_cursor_bounds: apply_cursor_bounds)
        end
      when Crystal::Assign
        if contains_cursor?(node.value)
          # The cursor sits inside the value (e.g. a proc literal whose
          # body is being edited): record the assignment like the plain
          # path would, then descend so the inner blocks seed.
          types = infer_types(node.value)
          record_assignment_types(node.target, types) unless types.empty?
          process_node(node.value, apply_cursor_bounds: apply_cursor_bounds)
          return
        end

        return unless !apply_cursor_bounds || before_cursor?(node)

        types = infer_types(node.value)
        return if types.empty?

        record_assignment_types(node.target, types)
      when Crystal::And, Crystal::Or
        # `cond && (x = expr)` assigns inside the condition: process both
        # operands so the assignment is recorded like any other statement.
        # (Parenthesized expressions are plain `Expressions` nodes.)
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_node(node.left, apply_cursor_bounds: apply_cursor_bounds)
        process_node(node.right, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::OpAssign
        # `x ||= expr` (often a `||= begin ... end` block): record the
        # assignment like a plain one, and walk the value so locals
        # assigned inside the begin-block are typed.
        if contains_cursor?(node.value)
          process_node(node.value, apply_cursor_bounds: apply_cursor_bounds)
          return
        end

        return unless !apply_cursor_bounds || before_cursor?(node)

        process_node(node.value, apply_cursor_bounds: apply_cursor_bounds)
        types = infer_types(node.value)
        return if types.empty?

        case target = node.target
        when Crystal::Var
          @local_types[target.name] = types
        when Crystal::InstanceVar
          @instance_var_types[target.name] = types
        when Crystal::ClassVar
          @class_var_types[target.name] = types
        end
      when Crystal::TypeDeclaration
        # `@pending : Array({String, Int32}) = ...` — an ivar/cvar declared
        # with a restriction (and often an initializer). Type it from the
        # initializer when present, falling back to the restriction. A
        # nil-only initializer (`@cache : Hash(...)? = nil`) still carries
        # the restriction's real type.
        if apply_cursor_bounds
          if value = node.value
            if contains_cursor?(value)
              # The cursor sits inside the initializer (e.g. a block value
              # like `Thread.new do ... end`): descend so locals assigned
              # in the block type, then record the declaration itself.
              process_node(value, apply_cursor_bounds: apply_cursor_bounds)
            end
          end
        end
        types = node.value.try { |value| infer_types(value) } || [] of String
        if node.declared_type
          restriction_types = resolve_type_names(node.declared_type.to_s)
          if types.empty? || (types.all?(&.==("Nil")) && restriction_types.any?)
            types = restriction_types
          end
        end
        return if types.empty?

        case var = node.var
        when Crystal::Var
          # A local type declaration (`t : Crystal::Type?`): type it from
          # the restriction so later receivers resolve.
          @local_types[var.name] = types
        when Crystal::InstanceVar
          @instance_var_types[var.name] = types
        when Crystal::ClassVar
          @class_var_types[var.name] = types
        end
      when Crystal::MultiAssign
        if apply_cursor_bounds && node.values.any? { |value| contains_cursor?(value) }
          node.values.each do |value|
            process_node(value, apply_cursor_bounds: true) if contains_cursor?(value)
          end
          return
        end

        return unless !apply_cursor_bounds || before_cursor?(node)

        assign_multi_types(node)
      when Crystal::TupleLiteral
        # A tuple literal as a statement (`{ query.top_level_methods.select
        # {...}.flat_map {...}, false }`): descend into the elements so a
        # cursor inside a chain nested in the tuple still seeds block args.
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        node.elements.each do |element|
          break if apply_cursor_bounds && !starts_before_or_at_cursor?(element)
          process_node(element, apply_cursor_bounds: apply_cursor_bounds)
        end
      when Crystal::Call
        # The untyped-arg seed's pending call sites live inside this
        # caller: infer their values with the state at the call (one
        # bounded walk per caller instead of one per call site).
        if pending = @pending_call_sites
          if (current_caller = @pending_caller) && (pending_calls = pending[current_caller]?)
            if pending_calls.includes?(node) && (definition_p = @pending_definition) && (untyped_p = @pending_untyped) && (types_p = @pending_types)
              collect_call_site_value_types(node, definition_p, untyped_p, types_p)
            end
          end
        end
        # Descend when the cursor sits anywhere inside the call: its
        # block (whose `&.`-chained form may lack an end location), its
        # `&->` proc pointer, its object (`x.join { ... }` wraps the
        # block-carrying receiver), or one of its arguments.
        return unless !apply_cursor_bounds || before_cursor?(node) ||
                      node.block.try { |block| block_contains_cursor?(block) } ||
                      node.block_arg.try { |block_arg| contains_cursor?(block_arg) } ||
                      node.obj.try { |object| contains_cursor?(object) } ||
                      (node.args + (node.named_args || [] of Crystal::NamedArgument)).any? { |arg| contains_cursor?(arg) }

        process_call(node, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::NamedArgument
        # `foo(name: expr)` — the walk descends into the value like a
        # positional argument.
        return unless !apply_cursor_bounds || contains_cursor?(node.value)

        process_node(node.value, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::Return
        # `return unless (x = expr)` still assigns x before returning:
        # process the returned expression like any other statement.
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        node.exp.try { |exp| process_node(exp, apply_cursor_bounds: apply_cursor_bounds) }
      when Crystal::If
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_if(node, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::Unless
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_unless(node, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::Case
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_case(node, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::ProcLiteral
        # `walker = ->(current : Crystal::ASTNode, ...) do ... end`:
        # seed the parameter restrictions and walk the body like a def.
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        proc_def = node.def
        proc_def.args.each do |arg|
          next unless restriction = arg.restriction
          @local_types[arg.name] = resolve_type_names(restriction.to_s)
        end
        process_node(proc_def.body, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::UninitializedVar
        # `walker = uninitialized Proc(...)` parses directly as an
        # UninitializedVar statement (no Assign wrapper): type the
        # declared local so proc-typed receivers resolve.
        return unless !apply_cursor_bounds || before_cursor?(node)

        if var = node.var.as?(Crystal::Var)
          @local_types[var.name] = [node.declared_type.to_s]
        end
      when Crystal::While
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_loop(node.cond, node.body, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::Until
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_loop(node.cond, node.body, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::Select
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        node.whens.each do |when_node|
          when_node.conds.each { |cond| process_node(cond, apply_cursor_bounds: apply_cursor_bounds) }
          process_node(when_node.body, apply_cursor_bounds: apply_cursor_bounds)
        end
        node.else.try { |else_node| process_node(else_node, apply_cursor_bounds: apply_cursor_bounds) }
      when Crystal::ExceptionHandler
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_exception_handler(node, apply_cursor_bounds: apply_cursor_bounds)
      when Crystal::MacroIf
        # `{% if %}` / `{% else %}` branches are raw macro text: reparse
        # and walk both so locals assigned behind a compile-time flag
        # (`{% if flag?(:preview_mt) %}` scheduler/fiber code) type the
        # same as plain statements.
        return unless !apply_cursor_bounds || starts_before_or_at_cursor?(node)

        process_macro_if(node, apply_cursor_bounds: apply_cursor_bounds)
      else
        return unless !apply_cursor_bounds || before_cursor?(node)
      end
    end

    private def infer_types(node : Crystal::ASTNode) : Array(String)
      case node
      when Crystal::Expressions
        # Parenthesized expressions: the value is the last expression.
        node.expressions.last?.try { |last| infer_expression_result_types(last) } || [] of String
      when Crystal::ExceptionHandler
        # `x = begin ... rescue ... end` types from the body's value.
        infer_expression_result_types(node.body)
      when Crystal::UninitializedVar
        # `x = uninitialized Proc(A, B, R)` declares the variable's
        # type: use the declared type name so proc-typed locals
        # (`walker.call`) resolve.
        [node.declared_type.to_s]
      when Crystal::ProcLiteral
        # `x = ->(a : T, b : U) do ... end` — the literal's signature
        # names the proc type, so proc-typed locals resolve. The params
        # and body are proc-local: derive the body's value on a saved
        # state so nothing leaks into the enclosing scope.
        proc_def = node.def
        inputs = proc_def.args.compact_map do |arg|
          arg.restriction.try(&.to_s)
        end
        output = proc_literal_output_types(node).first? || "Nil"
        ["Proc(#{inputs.join(", ")}, #{output})"]
      when Crystal::ProcPointer
        # `x.try &->URI.parse(String)` — the `&->` form passes a proc
        # pointer (not a block): its value is the pointed-to method's
        # return type (`URI.parse` returns `URI`).
        if (object = node.obj) && (type_name = type_expression_name(object))
          if resolved = @query.resolve_type_name(type_name, namespace: @current_type_name)
            @query.methods_named(resolved, node.name, class_method: true).each do |method|
              if (return_type = method.return_type)
                expanded = TypeUtils.expand_type_names(return_type).map { |t| t == "self" ? method.owner : t }
                return resolve_type_names(expanded, method.owner).uniq
              end
            end
          end
        end
        [] of String
      when Crystal::Var
        if node.name == "self"
          self_types[0]
        else
          local_types = types_for(node.name)
          if local_types.empty? && (type_name = @current_type_name)
            # A bare name may be a getter/method on the enclosing type
            # (`handlers.each` where `handlers` is a `getter`).
            @query.methods_for(type_name, class_method: class_method_context?).each do |method|
              if method.name == node.name && (return_type = method.return_type)
                local_types = resolve_type_names(TypeUtils.expand_type_names(return_type))
                break
              end
            end
          end
          local_types
        end
      when Crystal::InstanceVar
        instance_var_types_for(node.name)
      when Crystal::ClassVar
        class_var_types_for(node.name)
      when Crystal::Self
        self_types[0]
      when Crystal::Path, Crystal::Generic
        if type_name = @query.resolve_type_name(node.to_s, namespace: @current_type_name)
          [type_name]
        else
          [] of String
        end
      when Crystal::NilLiteral
        ["Nil"]
      when Crystal::BoolLiteral
        ["Bool"]
      when Crystal::CharLiteral
        ["Char"]
      when Crystal::StringLiteral
        ["String"]
      when Crystal::NumberLiteral
        [number_kind_name(node.kind)]
      when Crystal::ArrayLiteral
        infer_array_literal_types(node)
      when Crystal::HashLiteral
        infer_hash_literal_types(node)
      when Crystal::NamedTupleLiteral
        infer_named_tuple_literal_types(node)
      when Crystal::Call
        infer_call_types(node)
      when Crystal::Cast, Crystal::NilableCast
        # `x.as(T)` / `x.as?(T)` are compiler specials that parse as
        # dedicated nodes: the target type names the result.
        target_name = node.to.to_s
        base = TypeUtils.split_top_level(target_name, '|').reject(&.==("Nil")).reject(&.==("::Nil")).first?
        if base
          resolved = @query.resolve_type_name(base, namespace: @current_type_name) || @query.find_type(base).try(&.name)
          if resolved
            nilable = node.is_a?(Crystal::NilableCast) || target_name.includes?("::Nil")
            return nilable ? ["#{resolved} | Nil"] : [resolved]
          end
        end
        [] of String
      when Crystal::If, Crystal::Unless
        # `x = if cond then a else b end` — the value is the branches' merge.
        branch_types = [] of String
        branch_types.concat(node.then.try { |branch| infer_expression_result_types(branch) } || [] of String)
        branch_types.concat(node.else.try { |branch| infer_expression_result_types(branch) } || [] of String)
        branch_types.uniq
      when Crystal::Case
        branch_types = [] of String
        node.whens.each do |when_node|
          branch_types.concat(when_node.body.try { |branch| infer_expression_result_types(branch) } || [] of String)
        end
        branch_types.concat(node.else.try { |branch| infer_expression_result_types(branch) } || [] of String)
        branch_types.uniq
      when Crystal::Or
        infer_or_types(node)
      when Crystal::And
        infer_and_types(node)
      when Crystal::TupleLiteral
        tuple_part_types = node.elements.map do |element|
          element_types = infer_types(element)
          next nil if element_types.empty?
          join_union_types(element_types)
        end
        resolved_parts = tuple_part_types.compact
        return ["Tuple"] if resolved_parts.empty?

        # An unresolvable element drops out of the tuple type rather than
        # collapsing the whole literal: `{a, b, c}` keeps typing `t[0]`
        # when only `b` is unknown.
        ["Tuple(#{resolved_parts.join(", ")})"]
      else
        [] of String
      end
    end

    # The value a proc literal produces when called — its body's last
    # expression on a saved state (the params and body are proc-local and
    # must not leak into the enclosing scope). Used by the `Proc(...)`
    # literal typing and by `x.try &->...` call sites, which yield the
    # proc's result rather than the proc itself.
    private def proc_literal_output_types(node : Crystal::ProcLiteral) : Array(String)
      saved_state = current_state
      begin
        node.def.args.each do |arg|
          next unless restriction = arg.restriction
          @local_types[arg.name] = resolve_type_names(restriction.to_s)
        end
        infer_expression_result_types(node.def.body)
      ensure
        restore_state(saved_state)
      end
    end

    private def assign_multi_types(node : Crystal::MultiAssign)
      value_types = if node.values.size == 1
                      destructured_value_types(node.values.first)
                    else
                      node.values.flat_map { |value| [infer_types(value)] }
                    end

      node.targets.each_with_index do |target, index|
        next unless types = value_types[index]?
        next if types.empty?

        case target
        when Crystal::Var
          # Tuple parts are bare names (`TypeInfo`): resolve them against
          # the enclosing namespace so receiver lookups hit the
          # fully-qualified index entry.
          @local_types[target.name] = types.map { |type_name|
            @query.resolve_type_name(type_name, namespace: @current_type_name) || type_name
          }.uniq
        when Crystal::InstanceVar
          @instance_var_types[target.name] = types
        when Crystal::ClassVar
          @class_var_types[target.name] = types
        end
      end
    end

    private def process_call(node : Crystal::Call, *, apply_cursor_bounds : Bool)
      # Indexed ivar assignment (`@cache[key] = value`) parses as a `[]=`
      # call: the ivar itself is still typed by the assigned value.
      if node.name == "[]=" && (obj = node.obj).is_a?(Crystal::InstanceVar)
        if value = node.args.last?
          types = infer_types(value)
          @instance_var_types[obj.name] = types unless types.empty?
        end
      end

      if apply_cursor_bounds
        if object = node.obj
          if contains_cursor?(object)
            process_node(object, apply_cursor_bounds: true)
            return
          end
        end

        (node.args + (node.named_args || [] of Crystal::NamedArgument)).each do |arg|
          if contains_cursor?(arg)
            process_node(arg, apply_cursor_bounds: true)
            return
          end
        end
      end

      block = node.block
      return unless block
      # A block before the cursor still assigns locals/ivars the cursor can
      # see; only a block *after* the cursor is out of scope.
      return unless block_contains_cursor?(block) || before_cursor?(node)

      saved_local_types = @local_types.dup
      begin
        seeded_arg_names = seed_block_arg_types(node, block)
        process_node(block.body, apply_cursor_bounds: apply_cursor_bounds)
      ensure
        # Block args are block-local: when the cursor is not inside this
        # block, keep them out of the outer scope (only the body's effects
        # on ivars and pre-existing locals survive).
        merged = @local_types
        unless contains_cursor?(block)
          # The assignment sits in the begin block: if it raised before
          # assigning, the variable is nil — guard with try.
          merged = merged.reject { |name, _| seeded_arg_names.try(&.includes?(name)) == true }
        end
        @local_types = saved_local_types.merge(merged) { |_, old_value, new_value| (old_value + new_value).uniq }
      end
    end

    private def seed_block_arg_types(node : Crystal::Call, block : Crystal::Block, object_types : Array(String)? = nil) : Array(String)
      return [] of String if block.args.empty?

      arg_types = block_argument_types(node, object_types)
      return [] of String if arg_types.empty?

      # A single tuple element destructured into multiple block params
      # (`map { |k, v| ... }` on `Array(Tuple(K, V))`): split the tuple's
      # elements across the params.
      if block.args.size > arg_types.size
        if first = arg_types.first?
          if first.size == 1
            if tuple_parts = TypeUtils.tuple_element_types(first.first)
              arg_types = tuple_parts
            end
          elsif first.size == block.args.size
            # A destructured element delivered as one entry holding the
            # per-arg types: split it across the params.
            arg_types = first.map { |type_name| [type_name] }
          end
        end
      end

      names = [] of String
      block.args.each_with_index do |arg, index|
        types = arg_types[index]? || [] of String
        if arg.name.empty?
          # `|(a, b)|` — a destructured block param: the parser gives it
          # an empty name and keeps the sub-vars in `block.unpacks`.
          # Split the tuple element types across the sub-params.
          if unpacked = block.unpacks.try(&.[index]?)
            sub_names = unpacked.expressions.compact_map { |exp| exp.as?(Crystal::Var).try(&.name) }
            element_types = types.flat_map { |type_name| TypeUtils.tuple_element_types(type_name) || [] of Array(String) }
            if !sub_names.empty? && sub_names.size == element_types.size
              sub_names.each_with_index do |sub_name, sub_index|
                @local_types[sub_name] = element_types[sub_index]
                names << sub_name
              end
            end
          end
        elsif !types.empty?
          @local_types[arg.name] = types.map { |type_name|
            @query.resolve_type_name(type_name, namespace: @current_type_name) || type_name
          }.uniq
          names << arg.name
        end
      end
      names
    end

    private def block_argument_types(node : Crystal::Call, object_types : Array(String)? = nil) : Array(Array(String))
      # A bare call (`each_direct_def(...) do |definition|`) resolves on
      # the enclosing type: fall back to the self types as the receiver.
      # The caller usually already typed the receiver (chains re-enter the
      # sub-chain here otherwise): reuse it when passed.
      object_types = object_types || (node.obj.try { |object| infer_types(object) } || self_types[0])
      # The receiver type may be a union string (`Array(T) | ::Nil`):
      # split it so each branch is matched structurally below.
      object_types = object_types.flat_map { |t| TypeUtils.expand_type_names(t) }.uniq

      # The accumulator/object types depend on the call arguments, not
      # just the receiver: these two stay name-keyed (the declaration
      # `& : (U, T) -> U` cannot express the memo's type).
      if node.name == "reduce"
        return reduce_block_argument_types(node, object_types)
      end

      if node.name == "each_with_object"
        element_types = array_block_argument_types(object_types).first?
        memo_types = node.args.first?.try { |arg| infer_types(arg) } || [] of String
        return [] of Array(String) if element_types.nil? || memo_types.empty?
        return [element_types, memo_types]
      end

      # `try`/`tap` yield the receiver itself (non-nil): only the call
      # site knows the receiver's type.
      if node.name == "try" || node.name == "tap"
        return [] of Array(String) if object_types.empty?
        non_nil_types = object_types.reject(&.==("Nil")).uniq
        return non_nil_types.empty? ? [] of Array(String) : [non_nil_types]
      end

      # `each_with_index(offset = 0, &)` / `each_char_with_index(offset = 0, &)`
      # are declared without a block restriction: their shape cannot be
      # derived, so they stay name-keyed.
      if node.name == "each_with_index" || node.name == "each_char_with_index"
        element_types = if node.name == "each_char_with_index"
                          char_types_for(object_types)
                        else
                          array_block_argument_types(object_types).first?
                        end
        return [] of Array(String) unless element_types
        return [element_types, ["Int32"]]
      end

      # `each_char(&)` on String yields Char.
      if node.name == "each_char"
        char_types = char_types_for(object_types)
        return [] of Array(String) unless char_types
        return [char_types]
      end

      # Structural: yield contracts derived from the method's own block
      # restriction (`map(& : T -> U)` on an element receiver yields the
      # element). Covers each/map/select/reject/find/compact_map/flat_map/
      # index_by/group_by/map_with_index/each_key/each_value and any
      # other stdlib method whose declaration carries the shape.
      object_types.flat_map { |type_name| summary_block_argument_types(type_name, node.name) }
    end

    private def summary_block_argument_types(type_name : String, method_name : String) : Array(Array(String))
      # A class-method call (`OptionParser.parse do |parser|`) records its
      # contracts under class_method=true: query both views.
      contracts = (@query.method_contracts_for(type_name, method_name, class_method: false) +
                   @query.method_contracts_for(type_name, method_name, class_method: true)).uniq
      return [] of Array(String) if contracts.empty?

      block_types = [] of Array(String)
      contracts.each do |contract|
        if contract.block_args.any?
          block_types.concat(contract.block_args.map(&.dup))
          next
        end

        # The receiver's own types substitute the declaration's vars
        # (`Array(T)#map` yields the receiver's element, whatever T is).
        case contract.kind
        when .yield_self?
          block_types << contract.types unless contract.types.empty?
        when .yield_element?
          if element_types = TypeUtils.enumerable_element_types(type_name)
            block_types << element_types
          end
        when .yield_element_with_index?
          if element_types = TypeUtils.enumerable_element_types(type_name)
            block_types << element_types
            block_types << ["Int32"]
          end
        when .yield_key?
          if key_types = TypeUtils.hash_key_types(type_name)
            block_types << key_types
          end
        when .yield_value?
          if value_types = TypeUtils.hash_value_types(type_name)
            block_types << value_types
          end
        when .yield_key_value?
          if key_types = TypeUtils.hash_key_types(type_name)
            if value_types = TypeUtils.hash_value_types(type_name)
              block_types << key_types
              block_types << value_types
            end
          end
        end
      end
      block_types
    end

    private def array_block_argument_types(object_types : Array(String)) : Array(Array(String))
      return [] of Array(String) if object_types.empty?

      element_types = object_types.flat_map { |type_name| TypeUtils.array_element_types(type_name) || [] of String }.uniq
      element_types.empty? ? [] of Array(String) : [element_types]
    end

    # `each_char`-family methods on a String receiver yield Char (and
    # Int32 for the indexed forms): the declarations use a bare `&`, so
    # the yield shape is name-keyed.
    private def char_types_for(object_types : Array(String)) : Array(String)?
      return nil unless object_types.any?(&.==("String"))
      ["Char"]
    end

    private def reduce_block_argument_types(node : Crystal::Call, object_types : Array(String)) : Array(Array(String))
      element_types = object_types.flat_map { |type_name| TypeUtils.array_element_types(type_name) || [] of String }.uniq
      return [] of Array(String) if element_types.empty?

      accumulator_types = if memo = node.args.first?
                            memo_types = infer_types(memo)
                            memo_types.empty? ? element_types : memo_types
                          else
                            element_types
                          end
      return [] of Array(String) if accumulator_types.empty?

      [accumulator_types.uniq, element_types]
    end

    private def destructured_value_types(node : Crystal::ASTNode) : Array(Array(String))
      case node
      when Crystal::TupleLiteral
        node.elements.map { |element| infer_types(element) }
      else
        infer_types(node).flat_map do |type_name|
          if tuple_types = TypeUtils.tuple_element_types(type_name)
            tuple_types
          else
            [] of Array(String)
          end
        end
      end
    end

    private def infer_or_types(node : Crystal::Or) : Array(String)
      left_types = infer_types(node.left)
      right_types = infer_types(node.right)

      (left_types.reject(&.==("Nil")) + right_types).uniq
    end

    private def infer_and_types(node : Crystal::And) : Array(String)
      left_types = infer_types(node.left)
      right_types = infer_types(node.right)
      nil_types = left_types.select(&.==("Nil"))

      (nil_types + right_types).uniq
    end

    private def infer_call_types(node : Crystal::Call) : Array(String)
      infer_call_types_inner(node)
    end

    private def infer_call_types_inner(node : Crystal::Call) : Array(String)
      if node.name == "new"
        if object = node.obj
          if type_name = type_expression_name(object)
            return [type_name] if @query.find_type(type_name)
          end
        elsif class_method_context?
          # A bare `new` in a class method (`def self.from_program`):
          # instantiates the enclosing type.
          if (type_name = @current_type_name) && @query.find_type(type_name)
            return [type_name]
          end
        end
      end

      # The receiver's types are the base of every path below: compute
      # them once. Re-inferring per path made long block-carrying chains
      # (`a.map {...}.reject {...}.select {...}`) re-type the whole
      # sub-chain at every level — quadratic-to-exponential per request.
      object_types = node.obj.try { |object| infer_types(object) } || [] of String

      # `x.try { ... }` / `x.try &->URI.parse(String)`: the receiver is
      # yielded to the block (or proc) and the call evaluates to the
      # block's value or nil. The index records no return for Object#try,
      # and Nil#try returns `self` (nil) — neither carries the block's
      # value, so the call site derives it: non-nil receiver branches
      # yield the block/proc result, the nil branch stays nil.
      if node.name == "try" && !object_types.empty?
        non_nil_types = object_types.reject(&.==("Nil")).uniq
        # `nil.try { ... }` never runs the block: the value is always nil.
        return ["Nil"] if non_nil_types.empty?
        block_types = if (block = node.block)
                        infer_block_result_types(node, block, object_types)
                      elsif (block_arg = node.block_arg)
                        case block_arg
                        when Crystal::ProcLiteral
                          proc_literal_output_types(block_arg)
                        else
                          infer_types(block_arg)
                        end
                      else
                        [] of String
                      end
        # `try` is declared `: U?` — the block's value or nil even when
        # the receiver itself is non-nil.
        return (block_types + ["Nil"]).uniq unless block_types.empty?
      end

      # `File.open(..., &)`-style methods declare a bare `&` (no typed
      # block restriction) and the no-block overload's `: self` return
      # wins the index merge — but with a block they yield and return
      # the block's value (`shards_yaml = File.open(path) do |file| ... end`
      # is the opened file's parse, not the File itself). When the call
      # has a block, no overload carries a typed block restriction, and
      # the recorded return is the receiver itself, the block result is
      # the value.
      if (block = node.block) && node.name != "new"
        unless object_types.empty?
          methods = object_types.flat_map do |type_name|
            @query.methods_named(type_name, node.name, class_method: false) +
              @query.methods_named(type_name, node.name, class_method: true)
          end
          if methods.any? && methods.none?(&.block_restriction)
            # Only `open`-style methods (`File.open`, `IO.open`) declare
            # a bare `&` and return the block's value; other bare-&
            # methods with a `: self`-annotated return (`String.build`)
            # ignore the block's value and are structurally identical
            # in the index, so the name is the discriminator.
            if node.name == "open" && methods.any? { |method| method.return_type == "self" }
              block_types = infer_block_result_types(node, block, object_types)
              return block_types unless block_types.empty?
            end
          end
        end
      end

      # A class-method call on a type path (`Inference.for(...)`,
      # `Project.best_fit_for_file`): resolve the type against the
      # enclosing namespace and look up the class method's return type.
      if node.name != "new"
        if object = node.obj
          if type_name = type_expression_name(object)
            if resolved = @query.resolve_type_name(type_name, namespace: @current_type_name)
              @query.methods_named(resolved, node.name, class_method: true).each do |method|
                if (return_type = method.return_type)
                  # `: self?`-style returns resolve to the method's owner.
                  return_types = TypeUtils.expand_type_names(return_type).map { |t| t == "self" ? method.owner : t }
                  return resolve_type_names(return_types, method.owner).uniq
                end
              end
            end
          end
        end
      end

      if object = node.obj
        block_types = infer_block_call_types(node, object_types)
        return block_types unless block_types.empty?

        special_types = infer_special_call_types(node, object_types)
        return special_types unless special_types.empty?
      end

      return_types = [] of String

      if object = node.obj
        object_types.each do |type_name|
          # A constant receiver (`Project.best_fit_for_file`) resolves to a
          # class: look up class methods alongside instance methods.
          methods = @query.methods_named(type_name, node.name, class_method: false) +
                    @query.methods_named(type_name, node.name, class_method: true)
          # Prefer overloads whose arity matches the call (`shift` vs
          # `shift(n)` on a delegated array): the exact match names the
          # value, the other overloads would type the local as the array
          # itself. Falls back to all methods when no arity matches
          # (optional/default args).
          call_arg_count = node.args.size + (node.named_args || [] of Crystal::NamedArgument).size
          if methods.any? { |method| method.args.size == call_arg_count }
            methods = methods.select { |method| method.args.size == call_arg_count }
          end
          methods.each do |method|
            if (return_type = method.return_type)
              # `Array(T)#+` returns `Array(T)`: substitute the receiver's
              # concrete element types for the free vars so the local keeps
              # `Array(X)` instead of an unresolvable `T`.
              return_type = TypeUtils.substitute_free_vars(return_type, method.free_vars, type_name)
              # `: self?`-style returns resolve to the method's owner.
              expanded = TypeUtils.expand_type_names(return_type).map { |t| t == "self" ? method.owner : t }
              # Bare names (`Block`) resolve against the method's own
              # namespace, the way the compiler would.
              return_types.concat(resolve_type_names(expanded, method.owner))
            end
          end
        end
      else
        # A bare call resolves against the enclosing type first (self call),
        # then against top-level methods.
        if type_name = @current_type_name
          @query.methods_named(type_name, node.name, class_method: class_method_context?).each do |method|
            if (return_type = method.return_type)
              return_types.concat(resolve_type_names(TypeUtils.expand_type_names(return_type), method.owner))
            end
          end
        end

        @query.top_level_methods.each do |method|
          if method.name == node.name && (return_type = method.return_type)
            return_types.concat(resolve_type_names(TypeUtils.expand_type_names(return_type)))
          end
        end

        # A same-file self-call whose def declares no return type
        # (`operator = preceding_period(...)` ending in a `find`): infer
        # the def body's last expression.
        if return_types.empty?
          if def_node = find_same_file_def(node.name)
            return_types.concat(same_file_def_last_expression_types(def_node))
          end
        end
      end

      # Compiler-semantic accessors (`ASTNode#type?`, base
      # `Type#parents`/`types?`/`remove_alias`) exist in the index without
      # a usable return (synthesized by the semantic pass, or base-class
      # dummies returning nil): apply the known compiler signature so
      # receivers of AST/type values keep their chains (`node_type.doc`,
      # `type.parents.try &.each`).
      if (return_types.empty? || return_types.all?(&.==("Nil"))) && node.obj
        if object_types.any? { |type_name| type_name.starts_with?("Crystal::") }
          if semantic_return = TypeUtils.semantic_accessor_return(node.name)
            return_types = [semantic_return]
          end
        end
      end

      # Unknown block-taking method (`@mutex.synchronize { ... }`): Crystal
      # yields return the block's value, so when the index records no
      # return type at all, fall back to the block's inferred result.
      if return_types.empty? && (block = node.block)
        return_types.concat(infer_block_result_types(node, block))
      end

      return_types.uniq
    end

    # The def body's last expression's types, after processing the preceding
    # statements so locals (a `spans` accumulator) are typed. The callee's
    # locals must not leak into the caller's scope: the whole walk runs on a
    # saved state that is restored before returning.
    private def same_file_def_last_expression_types(def_node : Crystal::Def) : Array(String)
      body = def_node.body
      # `begin ... rescue ... ensure` bodies (compile's channel dance):
      # the value is the body's last expression.
      body = body.body if body.is_a?(Crystal::ExceptionHandler)
      saved_state = current_state
      begin
        if body.is_a?(Crystal::Expressions) && body.expressions.any?
          body.expressions[0...-1].each do |expression|
            process_node(expression, apply_cursor_bounds: false)
          end
          infer_expression_result_types(body.expressions.last)
        else
          infer_expression_result_types(body)
        end
      ensure
        restore_state(saved_state)
      end
    end

    # Finds the first same-file def matching `name` (any enclosing type):
    # used to infer the return of self-calls whose defs omit the return
    # type restriction.
    private def find_same_file_def(name : String) : Crystal::Def?
      return nil unless ast = @ast

      found = nil.as(Crystal::Def?)
      finder = uninitialized Proc(Crystal::ASTNode, Nil)
      finder = ->(node : Crystal::ASTNode) do
        case node
        when Crystal::Def
          # The last overload wins: `compile`'s first overload just
          # delegates to the second, whose body carries the value.
          found = node if node.name == name && !node.receiver
        when Crystal::Expressions
          node.expressions.each { |expression| finder.call(expression) }
        when Crystal::ClassDef, Crystal::ModuleDef
          finder.call(node.body)
        when Crystal::VisibilityModifier
          finder.call(node.exp)
        end
      end
      finder.call(ast)
      found
    end

    private def resolve_type_names(type_names : Array(String), namespace : String? = @current_type_name) : Array(String)
      type_names.map do |type_name|
        resolve_type_name_deep(type_name, namespace)
      end
    end

    # Resolves a type name against the enclosing type, descending into
    # generic arguments: `Array(MethodInfo)` with bare nested names
    # becomes `Array(Crystalline::Lightweight::MethodInfo)` so receiver
    # lookups hit the fully-qualified index entry.
    private def resolve_type_name_deep(type_name : String, namespace : String? = @current_type_name) : String
      if (parts = TypeUtils.generic_type_arguments(type_name, "Array", 1)) && (element = parts[0]?)
        resolved_element = resolve_type_name_deep(element, namespace)
        return "Array(#{resolved_element})" if resolved_element != element
      end
      if (parts = TypeUtils.generic_type_arguments(type_name, "Hash", 2)) && parts.size == 2
        resolved_key = resolve_type_name_deep(parts[0], namespace)
        resolved_value = resolve_type_name_deep(parts[1], namespace)
        if resolved_key != parts[0] || resolved_value != parts[1]
          return "Hash(#{resolved_key}, #{resolved_value})"
        end
      end

      @query.resolve_type_name(type_name, namespace: namespace) || type_name
    end

    private def type_expression_name(node : Crystal::ASTNode) : String?
      case node
      when Crystal::Path, Crystal::Generic
        @query.resolve_type_name(node.to_s, namespace: @current_type_name)
      else
        nil
      end
    end

    private def infer_block_call_types(node : Crystal::Call, object_types : Array(String)) : Array(String)
      block = node.block
      return [] of String unless block

      block_result_types = infer_block_result_types(node, block, object_types)
      return [] of String if block_result_types.empty?

      contracts = object_types.flat_map { |type_name| @query.method_contracts_for(type_name, node.name) }.uniq
      contract_result_types = apply_block_result_contracts(contracts, block_result_types, object_types)
      return contract_result_types unless contract_result_types.empty?

      [] of String
    end

    private def apply_block_result_contracts(contracts : Array(MethodContract), block_result_types : Array(String), object_types : Array(String)) : Array(String)
      receiver_element_types = enumerable_element_types_for(object_types)
      result_types = [] of String

      contracts.each do |contract|
        next unless result_shape = contract.result_shape

        case result_shape
        when .array_of_block_result?
          result_types << "Array(#{join_union_types(block_result_types)})"
        when .array_of_compact_block_result?
          compact_types = block_result_types.reject(&.==("Nil")).uniq
          result_types << "Array(#{join_union_types(compact_types)})" unless compact_types.empty?
        when .array_of_flattened_block_result?
          flattened_types = block_result_types.flat_map do |type_name|
            TypeUtils.array_element_types(type_name) || [type_name]
          end.uniq
          result_types << "Array(#{join_union_types(flattened_types)})" unless flattened_types.empty?
        when .hash_of_block_result_to_receiver_element?
          next if receiver_element_types.empty?
          result_types << "Hash(#{join_union_types(block_result_types)}, #{join_union_types(receiver_element_types)})"
        when .hash_of_block_result_to_receiver_element_array?
          next if receiver_element_types.empty?
          result_types << "Hash(#{join_union_types(block_result_types)}, Array(#{join_union_types(receiver_element_types)}))"
        when .block_result_or_nil?
          result_types.concat((block_result_types + ["Nil"]).uniq)
        end
      end

      result_types.uniq
    end

    private def enumerable_element_types_for(object_types : Array(String)) : Array(String)
      object_types.flat_map do |type_name|
        TypeUtils.enumerable_element_types(type_name) || [] of String
      end.uniq
    end

    private def infer_block_result_types(node : Crystal::Call, block : Crystal::Block, object_types : Array(String)? = nil) : Array(String)
      saved_state = current_state
      begin
        seed_block_arg_types(node, block, object_types)
        infer_expression_result_types(block.body)
      ensure
        restore_state(saved_state)
      end
    end

    private def infer_expression_result_types(node : Crystal::ASTNode) : Array(String)
      case node
      when Crystal::Assign
        # `x = expr` / `x ||= expr` evaluate to the assigned value.
        infer_types(node.value)
      when Crystal::OpAssign
        # `x ||= expr` parses as an OpAssign: same value semantics.
        infer_types(node.value)
      when Crystal::Expressions
        return [] of String if node.expressions.empty?

        node.expressions[0...-1].each do |expression|
          process_node(expression, apply_cursor_bounds: false)
        end
        infer_types(node.expressions.last)
      else
        infer_types(node)
      end
    end

    private def infer_special_call_types(node : Crystal::Call, object_types : Array(String)) : Array(String)
      case node.name
      when "not_nil!"
        # The receiver type may itself be a union string (`Location | ::Nil`):
        # split it so the nil branch is actually removed.
        return object_types.flat_map { |t| TypeUtils.expand_type_names(t) }
          .reject { |t| t == "Nil" || t == "::Nil" }.uniq
      when "tap", "each", "each_with_index"
        return object_types.uniq
      when "reverse_each"
        # `arr.reverse_each.find { ... }` chains on the enumerator; the
        # indexed overload is the block form (`: Nil`).
        return object_types.uniq if node.block.nil?
      when "[]"
        # `arr[1..]` slices (returns the array), `arr[1]` indexes (element).
        return object_types.uniq if node.args.first?.is_a?(Crystal::RangeLiteral)
      when "each_with_object"
        return node.args.first?.try { |arg| infer_types(arg) } || [] of String
      when "select", "reject"
        return object_types.uniq
      when "flatten"
        # `Array(T)#flatten` is compiler-inferred (no indexed return):
        # the chain still flows through the array; a tuple flattens into
        # an array of its elements' union.
        return object_types.flat_map do |type_name|
          if TypeUtils.array_element_types(type_name)
            [type_name]
          elsif tuple_types = TypeUtils.tuple_element_types(type_name)
            ["Array(#{tuple_types.join(" | ")})"]
          else
            [] of String
          end
        end.uniq
      end

      return_types = [] of String
      object_types.each do |type_name|
        return_types.concat(container_call_types(type_name, node.name))
      end
      return_types.uniq
    end

    private def infer_array_literal_types(node : Crystal::ArrayLiteral) : Array(String)
      if node.elements.empty?
        if of_type = node.of
          resolved_types = resolve_type_names(of_type.to_s)
          return ["Array(#{join_union_types(resolved_types)})"] unless resolved_types.empty?
        end
        return ["Array"]
      end

      element_types = node.elements.flat_map { |element| infer_types(element) }.uniq
      return ["Array"] if element_types.empty?

      ["Array(#{join_union_types(element_types)})"]
    end

    private def infer_hash_literal_types(node : Crystal::HashLiteral) : Array(String)
      key_types = node.entries.flat_map { |entry| infer_types(entry.key) }.uniq
      value_types = node.entries.flat_map { |entry| infer_types(entry.value) }.uniq
      if key_types.empty? || value_types.empty?
        # `{} of String => Array(String)` declares the shape on an empty
        # literal: use it so indexed lookups keep the element types.
        if of = node.of
          return ["Hash(#{of.key}, #{of.value})"]
        end
        return ["Hash"]
      end

      ["Hash(#{join_union_types(key_types)}, #{join_union_types(value_types)})"]
    end

    private def infer_named_tuple_literal_types(node : Crystal::NamedTupleLiteral) : Array(String)
      parts = node.entries.map do |entry|
        value_types = infer_types(entry.value)
        next unless value_types.present?
        "#{entry.key}: #{join_union_types(value_types)}"
      end.compact
      return ["NamedTuple"] if parts.empty?

      ["NamedTuple(#{parts.join(", ")})"]
    end

    private def container_call_types(type_name : String, method_name : String) : Array(String)
      if element_types = TypeUtils.array_element_types(type_name)
        case method_name
        when "first", "last", "[]", "find!", "reduce"
          return element_types
        when "first?", "last?", "[]?", "find", "dig"
          return (element_types + ["Nil"]).uniq
        when "select", "reject", "each", "each_with_index"
          return [type_name]
        end
      end

      if value_types = TypeUtils.hash_value_types(type_name)
        case method_name
        when "[]", "fetch"
          return value_types
        when "[]?", "dig"
          return (value_types + ["Nil"]).uniq
        when "select", "reject", "each"
          return [type_name]
        end
      end

      if method_name == "dig"
        if tuple_types = TypeUtils.tuple_element_types(type_name)
          return (tuple_types.flatten + ["Nil"]).uniq
        end

        if value_types = TypeUtils.named_tuple_all_value_types(type_name)
          return (value_types + ["Nil"]).uniq
        end
      end

      if tuple_types = TypeUtils.tuple_element_types(type_name)
        case method_name
        when "first"
          return tuple_types.first? || [] of String
        when "last"
          return tuple_types.last? || [] of String
        when "[]"
          # `Tuple#[]`/`[]?` have no indexed return (compiler-inferred):
          # approximate with the union of all elements (+ Nil).
          return tuple_types.flatten.uniq
        when "[]?"
          return (tuple_types.flatten.uniq + ["Nil"]).uniq
        when "first?"
          return ((tuple_types.first? || [] of String) + ["Nil"]).uniq
        when "last?"
          return ((tuple_types.last? || [] of String) + ["Nil"]).uniq
        end
      end

      if value_types = TypeUtils.named_tuple_value_types(type_name, method_name)
        return value_types
      end

      [] of String
    end

    private def join_union_types(type_names : Array(String)) : String
      type_names.uniq.join(" | ")
    end

    private def number_kind_name(kind : Crystal::NumberKind) : String
      case kind
      when .i8?   then "Int8"
      when .i16?  then "Int16"
      when .i32?  then "Int32"
      when .i64?  then "Int64"
      when .i128? then "Int128"
      when .u8?   then "UInt8"
      when .u16?  then "UInt16"
      when .u32?  then "UInt32"
      when .u64?  then "UInt64"
      when .u128? then "UInt128"
      when .f32?  then "Float32"
      when .f64?  then "Float64"
      else             "Int32"
      end
    end

    private def locate_context(node : Crystal::ASTNode) : Bool
      found = false
      walker = uninitialized Proc(Crystal::ASTNode, String?, Crystal::ASTNode?, Nil)
      walker = ->(current : Crystal::ASTNode, type_name : String?, type_body : Crystal::ASTNode?) do
        case current
        when Crystal::ClassDef
          qualified_name = qualify_type_name(current.name.to_s, type_name)
          if contains_cursor?(current.body) || starts_before_or_at_cursor?(current.body)
            # The cursor may sit directly in the type body (not inside a
            # def): remember the enclosing type so ivars still resolve.
            # Only when the cursor is truly inside the body: top-level code
            # after the type must stay in the top-level context.
            if contains_cursor?(current.body)
              @current_type_name = qualified_name
              @current_type_body = current.body
            end
            walker.call(current.body, qualified_name, current.body)
          end
        when Crystal::ModuleDef
          qualified_name = qualify_type_name(current.name.to_s, type_name)
          if contains_cursor?(current.body) || starts_before_or_at_cursor?(current.body)
            if contains_cursor?(current.body)
              @current_type_name = qualified_name
              @current_type_body = current.body
            end
            walker.call(current.body, qualified_name, current.body)
          end
        when Crystal::EnumDef
          qualified_name = qualify_type_name(current.name.to_s, type_name)
          current.members.each do |member|
            walker.call(member, qualified_name, type_body) if contains_cursor?(member) || starts_before_or_at_cursor?(member)
          end
        when Crystal::Expressions
          current.expressions.each do |expression|
            walker.call(expression, type_name, type_body) if contains_cursor?(expression) || starts_before_or_at_cursor?(expression)
          end
        when Crystal::Def
          if contains_cursor?(current)
            @current_def = current
            @current_type_name = type_name
            @class_method_context = !current.receiver.nil?
            @current_type_body = type_body
            found = true
          end
        when Crystal::VisibilityModifier
          # `private def` / `protected def` wrap the def in a VisibilityModifier.
          walker.call(current.exp, type_name, type_body) if contains_cursor?(current.exp) || starts_before_or_at_cursor?(current.exp)
        when Crystal::If
          walker.call(current.then, type_name, type_body) if contains_cursor?(current.then) || starts_before_or_at_cursor?(current.then)
          walker.call(current.else, type_name, type_body) if contains_cursor?(current.else) || starts_before_or_at_cursor?(current.else)
        when Crystal::Unless
          walker.call(current.then, type_name, type_body) if contains_cursor?(current.then) || starts_before_or_at_cursor?(current.then)
          walker.call(current.else, type_name, type_body) if contains_cursor?(current.else) || starts_before_or_at_cursor?(current.else)
        when Crystal::MacroIf
          # `{% if %}` / `{% elsif %}` / `{% else %}` branches hold raw
          # macro text with real code (defs, class vars) that only exists
          # behind a compile-time flag: reparse each branch and descend so
          # the cursor still locates its enclosing def.
          walk_macro_if_branch(current.then, type_name, type_body, walker)
          walk_macro_if_branch(current.else, type_name, type_body, walker)
        end
      end

      walker.call(node, nil, nil)
      found
    end

    # Walks one macro branch during locate_context. An `{% elsif %}` chain
    # nests as a MacroIf in the else slot: recurse directly on it. A plain
    # branch is raw macro text whose reparse restarts at 1:1, so the cursor
    # is translated into the branch text's coordinates first (the branch
    # node's own location still points at the original file).
    private def walk_macro_if_branch(branch : Crystal::ASTNode?, type_name : String?, type_body : Crystal::ASTNode?, walker : Proc(Crystal::ASTNode, String?, Crystal::ASTNode?, Nil))
      return unless branch
      if branch.is_a?(Crystal::MacroIf)
        walker.call(branch, type_name, type_body)
        return
      end
      return unless contains_cursor?(branch) || starts_before_or_at_cursor?(branch)
      text = macro_branch_text(branch)
      return unless text
      saved_line = @line
      saved_column = @column
      begin
        if location = branch.location
          if @line == location.line_number
            @column = @column - location.column_number + 1
          end
          @line = @line - location.line_number + 1
        end
        walker.call(Crystal::Parser.new(text).parse, type_name, type_body)
      rescue Crystal::SyntaxException
        # A branch may not parse on its own (spliced interpolation): skip.
      ensure
        @line = saved_line
        @column = saved_column
      end
    end

    # The raw code text of a macro branch (its body parses as MacroLiteral
    # nodes, with MacroExpressions for `{{ ... }}` interpolations): the
    # concatenation mirrors the indexer's index_macro_branch so a def or
    # class var spanning several literals reparses as one unit.
    private def macro_branch_text(branch : Crystal::ASTNode) : String?
      text = String.build do |io|
        case branch
        when Crystal::Expressions
          branch.expressions.each do |expression|
            case expression
            when Crystal::MacroLiteral    then io << expression.value
            when Crystal::MacroExpression then io << expression.to_s
            end
          end
        when Crystal::MacroLiteral
          io << branch.value
        when Crystal::MacroExpression
          io << branch.to_s
        end
      end
      text.strip.empty? ? nil : text
    end

    # Processes a loop body. The body may not have run at all, so after the
    # loop the types are the union of the pre-loop state and the assignments
    # made inside the body (mirroring branch merging).
    private def process_loop(cond : Crystal::ASTNode, body : Crystal::ASTNode, *, apply_cursor_bounds : Bool)
      base_state = current_state

      process_node(cond, apply_cursor_bounds: false)
      process_node(body, apply_cursor_bounds: apply_cursor_bounds)
      body_state = current_state

      restore_state(base_state)
      @local_types = merge_branch_types(base_state[0], base_state[0], body_state[0])
      @instance_var_types = merge_branch_types(base_state[1], base_state[1], body_state[1])
      @class_var_types = merge_branch_types(base_state[2], base_state[2], body_state[2])
    end

    private def process_macro_if(node : Crystal::MacroIf, *, apply_cursor_bounds : Bool)
      process_macro_branch(node.then, apply_cursor_bounds: apply_cursor_bounds)
      process_macro_branch(node.else, apply_cursor_bounds: apply_cursor_bounds)
    end

    # Walks one macro branch's reparsed code. An `{% elsif %}` chain nests
    # as a MacroIf in the else slot: recurse directly on it. The reparse
    # restarts at 1:1 while the cursor is in file coordinates, so it is
    # translated into the branch text's coordinates per branch (the branch
    # node's own location still points at the original file).
    private def process_macro_branch(branch : Crystal::ASTNode?, *, apply_cursor_bounds : Bool)
      return unless branch
      if branch.is_a?(Crystal::MacroIf)
        process_macro_if(branch, apply_cursor_bounds: apply_cursor_bounds)
        return
      end
      text = macro_branch_text(branch)
      return unless text
      saved_line = @line
      saved_column = @column
      begin
        if location = branch.location
          if @line == location.line_number
            @column = @column - location.column_number + 1
          end
          @line = @line - location.line_number + 1
        end
        process_node(Crystal::Parser.new(text).parse, apply_cursor_bounds: apply_cursor_bounds)
      rescue Crystal::SyntaxException
        # A branch may not parse on its own (spliced interpolation): skip.
      ensure
        @line = saved_line
        @column = saved_column
      end
    end

    private def process_exception_handler(node : Crystal::ExceptionHandler, *, apply_cursor_bounds : Bool)
      if !apply_cursor_bounds || contains_cursor?(node.body) || starts_before_or_at_cursor?(node.body)
        process_node(node.body, apply_cursor_bounds: apply_cursor_bounds)
        return if apply_cursor_bounds && contains_cursor?(node.body)
      end

      node.rescues.try &.each do |rescue_clause|
        next unless !apply_cursor_bounds || contains_cursor?(rescue_clause.body)

        saved_local_types = @local_types.dup
        begin
          seed_rescue_types(rescue_clause)
          process_node(rescue_clause.body, apply_cursor_bounds: apply_cursor_bounds)
        ensure
          @local_types = saved_local_types.merge(@local_types) { |_, old_value, new_value| (old_value + new_value).uniq }
        end
        return if apply_cursor_bounds
      end

      if rescue_else = node.else
        if !apply_cursor_bounds || contains_cursor?(rescue_else)
          process_node(rescue_else, apply_cursor_bounds: apply_cursor_bounds)
          return if apply_cursor_bounds
        end
      end

      if ensure_clause = node.ensure
        if !apply_cursor_bounds || contains_cursor?(ensure_clause)
          process_node(ensure_clause, apply_cursor_bounds: apply_cursor_bounds)
        end
      end
    end

    private def seed_rescue_types(rescue_clause : Crystal::Rescue)
      return unless name = rescue_clause.name

      type_names = if types = rescue_clause.types
                     types.flat_map { |type| resolve_type_names(type.to_s) }.uniq
                   else
                     [@query.resolve_type_name("Exception", namespace: @current_type_name) || "Exception"]
                   end
      @local_types[name] = type_names unless type_names.empty?
    end

    private def process_if(node : Crystal::If, *, apply_cursor_bounds : Bool)
      if apply_cursor_bounds
        if contains_cursor?(node.then)
          process_node(node.cond, apply_cursor_bounds: false)
          apply_condition_refinement(node.cond, truthy: true)
          process_node(node.then, apply_cursor_bounds: true)
          return
        elsif contains_cursor?(node.else)
          process_node(node.cond, apply_cursor_bounds: false)
          apply_condition_refinement(node.cond, truthy: false)
          process_node(node.else, apply_cursor_bounds: true)
          return
        end
      end

      process_conditional(node.cond, node.then, node.else, then_truthy: true, else_truthy: false, apply_cursor_bounds: apply_cursor_bounds)
    end

    private def process_unless(node : Crystal::Unless, *, apply_cursor_bounds : Bool)
      if apply_cursor_bounds
        if contains_cursor?(node.then)
          process_node(node.cond, apply_cursor_bounds: false)
          apply_condition_refinement(node.cond, truthy: false)
          process_node(node.then, apply_cursor_bounds: true)
          return
        elsif contains_cursor?(node.else)
          process_node(node.cond, apply_cursor_bounds: false)
          apply_condition_refinement(node.cond, truthy: true)
          process_node(node.else, apply_cursor_bounds: true)
          return
        end
      end

      process_conditional(node.cond, node.then, node.else, then_truthy: false, else_truthy: true, apply_cursor_bounds: apply_cursor_bounds)
    end

    private def process_conditional(cond : Crystal::ASTNode, then_branch : Crystal::ASTNode, else_branch : Crystal::ASTNode, *, then_truthy : Bool, else_truthy : Bool, apply_cursor_bounds : Bool)
      base_state = current_state

      restore_state(base_state)
      process_node(cond, apply_cursor_bounds: false)
      apply_condition_refinement(cond, truthy: then_truthy)
      process_node(then_branch, apply_cursor_bounds: apply_cursor_bounds)
      then_state = current_state

      restore_state(base_state)
      process_node(cond, apply_cursor_bounds: false)
      apply_condition_refinement(cond, truthy: else_truthy)
      process_node(else_branch, apply_cursor_bounds: apply_cursor_bounds)
      else_state = current_state

      restore_state(base_state)
      @local_types = merge_branch_types(base_state[0], then_state[0], else_state[0])
      @instance_var_types = merge_branch_types(base_state[1], then_state[1], else_state[1])
      @class_var_types = merge_branch_types(base_state[2], then_state[2], else_state[2])
    end

    # A subject-based `case expr when TypeA, TypeB` narrows the subject
    # to the when-types inside each branch (`case node when Crystal::Def`
    # types `node` as `Crystal::Def` in the branch body), mirroring the
    # if/unless branch merge for the remaining locals.
    private def process_case(node : Crystal::Case, *, apply_cursor_bounds : Bool)
      subject = node.cond
      # `case target = node.target` executes the subject assignment once
      # before any branch: record it so the when-branch narrowing has
      # base types to intersect (and the merged state keeps the local).
      process_node(subject, apply_cursor_bounds: false) if subject.is_a?(Crystal::Assign)
      base_state = current_state

      # When the cursor sits inside one branch, keep that branch's
      # narrowed state (like process_if does for the taken branch):
      # the merge below is only for statements after the case.
      if apply_cursor_bounds
        node.whens.each do |when_node|
          if contains_cursor?(when_node.body)
            restore_state(base_state)
            if subject
              if narrowed = narrow_case_subject(subject, when_node)
                apply_case_subject_narrowing(subject, narrowed)
              end
            end
            process_node(when_node.body, apply_cursor_bounds: true)
            return
          end
        end
        if else_branch = node.else
          if contains_cursor?(else_branch)
            restore_state(base_state)
            process_node(else_branch, apply_cursor_bounds: true)
            return
          end
        end
      end

      branch_states = [] of typeof(current_state)
      node.whens.each do |when_node|
        restore_state(base_state)
        if subject
          if narrowed = narrow_case_subject(subject, when_node)
            apply_case_subject_narrowing(subject, narrowed)
          end
        end
        process_node(when_node.body, apply_cursor_bounds: apply_cursor_bounds)
        branch_states << current_state
      end

      if else_branch = node.else
        restore_state(base_state)
        # The else branch matches none of the when-types: the complement
        # is not expressible from the index, so the subject keeps its
        # pre-case types.
        process_node(else_branch, apply_cursor_bounds: apply_cursor_bounds)
        branch_states << current_state
      end

      restore_state(base_state)
      merged_local = base_state[0]
      merged_ivar = base_state[1]
      merged_cvar = base_state[2]
      branch_states.each do |branch_state|
        merged_local = merge_branch_types(base_state[0], merged_local, branch_state[0])
        merged_ivar = merge_branch_types(base_state[1], merged_ivar, branch_state[1])
        merged_cvar = merge_branch_types(base_state[2], merged_cvar, branch_state[2])
      end
      @local_types = merged_local
      @instance_var_types = merged_ivar
      @class_var_types = merged_cvar
    end

    private def narrow_case_subject(subject : Crystal::ASTNode, when_node : Crystal::When) : Array(String)?
      # `case target = node.target` assigns inside the subject: narrow the
      # assigned local the same way a plain `case node` subject narrows.
      subject = subject.target if subject.is_a?(Crystal::Assign)
      return nil unless subject.is_a?(Crystal::Var)

      current_types = @local_types[subject.name]?
      return nil if current_types.nil? || current_types.empty?

      when_types = [] of String
      when_node.conds.each do |cond|
        case cond
        when Crystal::Path, Crystal::Generic
          if resolved = @query.resolve_type_name(cond.to_s, namespace: @current_type_name)
            when_types << resolved
          end
        end
      end
      return nil if when_types.empty?

      # The subject's own types intersect first (`A | B` matched by
      # `when A` narrows to `A`); when the when-type is a subtype of the
      # subject (`ASTNode` matched by `when Def`), the branch simply
      # adopts the when-type.
      intersection = current_types & when_types
      intersection.empty? ? when_types : intersection
    end

    private def apply_case_subject_narrowing(subject : Crystal::ASTNode, narrowed : Array(String))
      # `case target = node.target` narrows the assigned local; a plain
      # `case node` narrows the local variable itself.
      var = subject.is_a?(Crystal::Assign) ? subject.target : subject
      return unless var.is_a?(Crystal::Var)
      @local_types[var.name] = narrowed
    end

    private def current_state
      {@local_types.dup, @instance_var_types.dup, @class_var_types.dup}
    end

    private def restore_state(state)
      @local_types = state[0].dup
      @instance_var_types = state[1].dup
      @class_var_types = state[2].dup
    end

    private def apply_condition_refinement(node : Crystal::ASTNode, *, truthy : Bool)
      case node
      when Crystal::Expressions
        if expression = node.expressions.first?
          apply_condition_refinement(expression, truthy: truthy)
        end
      when Crystal::Not
        apply_condition_refinement(node.exp, truthy: !truthy)
      when Crystal::And
        if truthy
          apply_condition_refinement(node.left, truthy: true)
          apply_condition_refinement(node.right, truthy: true)
        end
      when Crystal::Or
        if truthy
          # `x.is_a?(A) || x.is_a?(B)` narrows x to A | B.
          if (left_is_a = node.left.as?(Crystal::IsA)) && (right_is_a = node.right.as?(Crystal::IsA))
            if left_is_a.obj.to_s == right_is_a.obj.to_s && left_is_a.obj.class == right_is_a.obj.class
              target_types = [left_is_a, right_is_a].compact_map do |is_a_node|
                TypeUtils.expand_type_names(is_a_node.const.to_s).map { |name|
                  @query.resolve_type_name(name, namespace: @current_type_name) || name
                }
              end.flatten.uniq
              set_reference_types(left_is_a.obj, target_types) unless target_types.empty?
            end
          end
        else
          apply_condition_refinement(node.left, truthy: false)
          apply_condition_refinement(node.right, truthy: false)
        end
      when Crystal::IsA
        refine_is_a(node, truthy: truthy)
      when Crystal::Call
        if node.name == "nil?" && node.args.empty?
          refine_nil_check(node.obj, truthy: truthy)
        end
      when Crystal::Assign
        refine_condition_assignment(node, truthy: truthy)
      when Crystal::Var, Crystal::InstanceVar, Crystal::ClassVar
        refine_truthiness(node, truthy: truthy)
      end
    end

    private def refine_condition_assignment(node : Crystal::Assign, *, truthy : Bool)
      type_names = infer_types(node.value)
      return if type_names.empty?

      refined_types = if truthy
                        type_names.reject(&.==("Nil"))
                      elsif type_names.includes?("Nil")
                        ["Nil"]
                      else
                        type_names
                      end
      return if refined_types.empty?

      set_reference_types(node.target, refined_types.map { |type_name|
        @query.resolve_type_name(type_name, namespace: @current_type_name) || type_name
      }.uniq)
    end

    private def refine_is_a(node : Crystal::IsA, *, truthy : Bool)
      target_type_names = TypeUtils.expand_type_names(node.const.to_s).map { |name|
        @query.resolve_type_name(name, namespace: @current_type_name) || name
      }.uniq
      return if target_type_names.empty?

      if truthy
        set_reference_types(node.obj, target_type_names)
      else
        remove_reference_types(node.obj, target_type_names)
      end
    end

    private def refine_nil_check(node : Crystal::ASTNode?, *, truthy : Bool)
      return unless node

      if truthy
        set_reference_types(node, ["Nil"])
      else
        remove_reference_types(node, ["Nil"])
      end
    end

    private def refine_truthiness(node : Crystal::ASTNode, *, truthy : Bool)
      if truthy
        remove_reference_types(node, ["Nil"])
      else
        set_reference_types(node, ["Nil"])
      end
    end

    private def reference_types(node : Crystal::ASTNode) : Array(String)?
      case node
      when Crystal::Expressions
        # `(target = node.target).is_a?(Var)` — the parenthesized assign
        # wraps the subject; look through to the assigned local.
        node.expressions.first?.try { |expression| reference_types(expression) }
      when Crystal::Assign
        reference_types(node.target)
      when Crystal::Var
        node.name == "self" ? self_types[0] : @local_types[node.name]?
      when Crystal::InstanceVar
        @instance_var_types[node.name]?
      when Crystal::ClassVar
        @class_var_types[node.name]?
      when Crystal::Self
        self_types[0]
      end
    end

    private def set_reference_types(node : Crystal::ASTNode, type_names : Array(String))
      normalized = type_names.uniq
      return if normalized.empty?

      case node
      when Crystal::Expressions
        if expression = node.expressions.first?
          set_reference_types(expression, normalized)
        end
      when Crystal::Assign
        set_reference_types(node.target, normalized)
      when Crystal::Var
        @local_types[node.name] = normalized unless node.name == "self"
      when Crystal::InstanceVar
        @instance_var_types[node.name] = normalized
      when Crystal::ClassVar
        @class_var_types[node.name] = normalized
      end
    end

    private def remove_reference_types(node : Crystal::ASTNode, excluded_type_names : Array(String))
      current_types = reference_types(node)
      return unless current_types

      remaining_types = current_types.reject { |type_name| excluded_type_names.includes?(type_name) }
      return if remaining_types == current_types

      if remaining_types.empty?
        remaining_types = excluded_type_names.includes?("Nil") ? current_types.reject(&.==("Nil")) : current_types
      end

      set_reference_types(node, remaining_types)
    end

    private def merge_branch_types(base : Hash(String, Array(String)), left : Hash(String, Array(String)), right : Hash(String, Array(String)))
      merged = {} of String => Array(String)

      (base.keys | left.keys | right.keys).each do |name|
        candidates = [] of String
        candidates.concat(left[name]? || base[name]? || [] of String)
        candidates.concat(right[name]? || base[name]? || [] of String)
        merged[name] = candidates.uniq unless candidates.empty?
      end

      merged
    end

    private def seed_arg_types(definition : Crystal::Def, ast : Crystal::ASTNode)
      definition.args.each do |arg|
        seed_arg_restriction(arg)
      end
      # The block param (`&block : -> T`) is not part of `args`: seed it
      # separately so `block.call`-style receivers resolve.
      definition.block_arg.try { |arg| seed_arg_restriction(arg) }

      # Untyped args with default values (`accumulator = [] of T`): the
      # default names the type when no call site provides a value.
      # Caller-derived types overwrite these below.
      definition.args.each do |arg|
        next unless arg.restriction.nil? && (default = arg.default_value)
        default_types = infer_types(default)
        @local_types[arg.name] = default_types unless default_types.empty?
      end

      untyped = definition.args.select { |arg| arg.restriction.nil? && !arg.name.empty? }
      return if untyped.empty?

      # The call-site scan is cursor-independent: a def seeded once on
      # this buffer is seeded for every later request (hover after hover,
      # completion after completion) — reuse the cached result instead of
      # re-walking every caller.
      if cache_key = definition.location.try(&.to_s)
        if cached = @query.cached_untyped_arg_types(cache_key)
          cached.each { |name, types| @local_types[name] = types }
          return
        end
      end

      # Untyped args (`def recalculate_dependencies(server, project)`):
      # infer their types from call sites in this file, falling back to
      # other defs that declare the same argument name with a restriction.
      arg_types = {} of String => Array(String)
      collect_call_site_arg_types(ast, definition, untyped, arg_types)
      collect_pending_call_site_types(definition, untyped, arg_types)
      collect_same_name_arg_types(ast, untyped, arg_types) if arg_types.empty?
      @query.cache_untyped_arg_types(cache_key, arg_types) if cache_key

      untyped.each do |arg|
        next unless types = arg_types[arg.name]?
        @local_types[arg.name] = types.uniq
      end
    end

    private def seed_arg_restriction(arg : Crystal::Arg)
      return unless restriction = arg.restriction
      restriction_text = restriction.to_s
      if restriction.is_a?(Crystal::ProcNotation)
        # `&block : -> T` — a Proc-typed block param: render it in the
        # indexed `Proc(...)` form (the declaration text `-> T` is not
        # a type name) so generic fallback resolves it.
        parts = (restriction.inputs || [] of Crystal::ASTNode).map(&.to_s) + [restriction.output.to_s]
        restriction_text = "Proc(#{parts.join(", ")})"
      end
      resolved = resolve_type_names(restriction_text)
      if resolved.empty? && restriction.is_a?(Crystal::ProcNotation)
        # `-> T` with a free type var renders `Proc(T)`, which does not
        # resolve: fall back to the generic `Proc` so `block.call`-style
        # receivers still find the indexed `Proc#call`.
        resolved = resolve_type_names("Proc")
      end
      @local_types[arg.name] = resolved
    end

    private def collect_call_site_arg_types(node : Crystal::ASTNode, definition : Crystal::Def, untyped : Array(Crystal::Arg), types : Hash(String, Array(String)), enclosing_def : Crystal::Def? = nil)
      case node
      when Crystal::Call
        if node.name == definition.name
          untyped.each do |arg|
            # Match the untyped argument by NAME: a call may pass it
            # positionally (`foo(x)`) or as a named argument
            # (`process_node(node, apply_cursor_bounds: true)`). Matching
            # by position alone would type the WRONG value whenever the
            # call omits or reorders arguments.
            value = call_arg_value(node, definition, arg)
            next unless value
            if caller = enclosing_def
              if caller == definition
                inferred = infer_types(value)
              elsif literal_value?(value)
                # A literal's type does not depend on the caller's
                # locals: no caller walk needed.
                inferred = infer_types(value)
              else
                # The value's type depends on the caller's locals: defer
                # to one bounded walk of the caller per call site (see
                # collect_pending_call_site_types), not a full caller
                # body walk per site.
                pending_sites = (@pending_call_sites ||= {} of Crystal::Def => Array(Crystal::Call))
                (pending_sites[caller] ||= [] of Crystal::Call) << node
                next
              end
            else
              inferred = infer_types(value)
            end
            next if inferred.empty?
            types[arg.name] = (types[arg.name]? || [] of String) + inferred
          end
        end
        if (obj = node.obj)
          collect_call_site_arg_types(obj, definition, untyped, types, enclosing_def)
        end
        node.args.each { |arg| collect_call_site_arg_types(arg, definition, untyped, types, enclosing_def) }
        node.block.try { |block| collect_call_site_arg_types(block, definition, untyped, types, enclosing_def) }
      when Crystal::Expressions
        node.expressions.each { |exp| collect_call_site_arg_types(exp, definition, untyped, types, enclosing_def) }
      when Crystal::Def
        collect_call_site_arg_types(node.body, definition, untyped, types, node)
      when Crystal::ClassDef, Crystal::ModuleDef
        collect_call_site_arg_types(node.body, definition, untyped, types, enclosing_def)
      when Crystal::VisibilityModifier
        collect_call_site_arg_types(node.exp, definition, untyped, types, enclosing_def)
      when Crystal::If, Crystal::Unless
        collect_call_site_arg_types(node.cond, definition, untyped, types, enclosing_def)
        collect_call_site_arg_types(node.then, definition, untyped, types, enclosing_def)
        node.else.try { |e| collect_call_site_arg_types(e, definition, untyped, types, enclosing_def) }
      when Crystal::While, Crystal::Until
        collect_call_site_arg_types(node.cond, definition, untyped, types, enclosing_def)
        collect_call_site_arg_types(node.body, definition, untyped, types, enclosing_def)
      when Crystal::Case
        node.cond.try { |cond| collect_call_site_arg_types(cond, definition, untyped, types, enclosing_def) }
        node.whens.each { |w| collect_call_site_arg_types(w, definition, untyped, types, enclosing_def) }
        node.else.try { |e| collect_call_site_arg_types(e, definition, untyped, types, enclosing_def) }
      when Crystal::ExceptionHandler
        node.body.try { |body| collect_call_site_arg_types(body, definition, untyped, types, enclosing_def) }
        node.rescues.try { |rescues| rescues.each { |r| collect_call_site_arg_types(r, definition, untyped, types, enclosing_def) } }
      when Crystal::Block
        collect_call_site_arg_types(node.body, definition, untyped, types, enclosing_def)
      when Crystal::Assign
        collect_call_site_arg_types(node.value, definition, untyped, types, enclosing_def)
      end
    end

    # The deferred call-site values (`@pending_call_sites`): one bounded
    # walk of each caller def infers them all. The walk stops at the
    # caller's deepest target call, and the hook in `process_node`
    # records each call's values with the caller's state at that point.
    private def collect_pending_call_site_types(definition : Crystal::Def, untyped : Array(Crystal::Arg), types : Hash(String, Array(String)))
      pending = @pending_call_sites
      return unless pending
      pending.each do |caller, calls|
        deepest = calls.max_by { |call| call.location.try(&.line_number) || 0 }
        location = deepest.location
        next unless location

        saved_line = @line
        saved_column = @column
        saved_state = current_state
        @line = location.line_number
        @column = location.column_number
        @pending_caller = caller
        @pending_definition = definition
        @pending_untyped = untyped
        @pending_types = types
        begin
          process_node(caller.body, apply_cursor_bounds: true)
        ensure
          @pending_caller = nil
          @pending_definition = nil
          @pending_untyped = nil
          @pending_types = nil
          @line = saved_line
          @column = saved_column
          restore_state(saved_state)
        end
      end
      @pending_call_sites = nil
    end

    # The value a call passes for *arg*: the named argument when the
    # call passes it by name, else the positional argument at the arg's
    # signature index (nil when the call omits it).
    private def call_arg_value(call : Crystal::Call, definition : Crystal::Def, arg : Crystal::Arg) : Crystal::ASTNode?
      if named = call.named_args.try(&.find { |named_arg| named_arg.name == arg.name })
        named.value
      elsif arg_index = definition.args.index(arg)
        call.args[arg_index]?
      end
    end

    # Infers one deferred call's untyped-arg values with the CURRENT
    # state (the caller's locals at the call site during the pending
    # walk).
    private def collect_call_site_value_types(call : Crystal::Call, definition : Crystal::Def, untyped : Array(Crystal::Arg), types : Hash(String, Array(String)))
      untyped.each do |arg|
        value = call_arg_value(call, definition, arg)
        next unless value
        inferred = infer_types(value)
        next if inferred.empty?
        types[arg.name] = (types[arg.name]? || [] of String) + inferred
      end
    end

    # Whether the value's type is independent of the caller's locals:
    # literal nodes need no caller-context walk in the call-site scan.
    private def literal_value?(node : Crystal::ASTNode) : Bool
      node.is_a?(Crystal::BoolLiteral) || node.is_a?(Crystal::NumberLiteral) ||
        node.is_a?(Crystal::StringLiteral) || node.is_a?(Crystal::CharLiteral) ||
        node.is_a?(Crystal::SymbolLiteral) || node.is_a?(Crystal::NilLiteral)
    end

    private def collect_same_name_arg_types(node : Crystal::ASTNode, untyped : Array(Crystal::Arg), types : Hash(String, Array(String)))
      case node
      when Crystal::Def
        node.args.each do |arg|
          next unless untyped.any? { |u| u.name == arg.name }
          next unless restriction = arg.restriction
          types[arg.name] = (types[arg.name]? || [] of String) + resolve_type_names(restriction.to_s)
        end
        collect_same_name_arg_types(node.body, untyped, types)
      when Crystal::Expressions
        node.expressions.each { |exp| collect_same_name_arg_types(exp, untyped, types) }
      when Crystal::ClassDef, Crystal::ModuleDef
        collect_same_name_arg_types(node.body, untyped, types)
      when Crystal::If, Crystal::Unless
        collect_same_name_arg_types(node.cond, untyped, types)
        collect_same_name_arg_types(node.then, untyped, types)
        node.else.try { |e| collect_same_name_arg_types(e, untyped, types) }
      when Crystal::Assign
        # A same-name local in another def is a good hint too
        # (`project = Project.best_fit_for_file(...)`).
        if (target = node.target).is_a?(Crystal::Var) && untyped.any? { |u| u.name == target.name }
          inferred = infer_types(node.value)
          types[target.name] = (types[target.name]? || [] of String) + inferred unless inferred.empty?
        end
        collect_same_name_arg_types(node.value, untyped, types)
      end
    end

    private def resolve_type_names(type_name : String, namespace : String? = @current_type_name) : Array(String)
      TypeUtils.expand_type_names(type_name).map { |name|
        resolve_type_name_deep(name, namespace)
      }.uniq
    end

    private def seed_type_vars_from_summary
      return unless type_name = @current_type_name

      if class_method_context?
        @class_var_types = merge_branch_types(@class_var_types, @class_var_types, query_class_var_types(type_name))
      else
        @instance_var_types = merge_branch_types(@instance_var_types, @instance_var_types, query_instance_var_types(type_name))
        @class_var_types = merge_branch_types(@class_var_types, @class_var_types, query_class_var_types(type_name))
      end
    end

    private def query_instance_var_types(type_name : String)
      @query.instance_vars_for(type_name)
    end

    private def query_class_var_types(type_name : String)
      @query.class_vars_for(type_name)
    end

    # Seeds ivar types from the enclosing type's indexed declarations
    # (`@x : T` class-body lines and `@x = value` assignments), which the
    # def-body walk never sees.
    private def seed_indexed_ivar_types
      type_name = @current_type_name
      return unless type_name
      return unless type = @query.find_type_info(type_name)

      type.ivars.each do |name, type_names|
        next if @instance_var_types.has_key?(name)
        # Raw declarations carry unions (`URI?`, `URI | ::Nil`): expand and
        # namespace-resolve them so receiver lookups see plain type names.
        @instance_var_types[name] = type_names.flat_map { |type_name| resolve_type_names(TypeUtils.expand_type_names(type_name)) }.uniq
      end
      type.class_vars.each do |name, type_names|
        next if @class_var_types.has_key?(name)
        @class_var_types[name] = type_names.flat_map { |type_name| resolve_type_names(TypeUtils.expand_type_names(type_name)) }.uniq
      end
    end

    private def process_initialize_defs(ast : Crystal::ASTNode)
      type_body = @current_type_body
      return unless type_body

      each_direct_def(type_body) do |definition|
        next unless definition.name == "initialize"
        next if definition.receiver

        saved_local_types = @local_types.dup
        begin
          @local_types.clear
          seed_arg_types(definition, ast)
          process_node(definition.body, apply_cursor_bounds: false)
        ensure
          @local_types = saved_local_types
        end
      end
    end

    private def each_direct_def(node : Crystal::ASTNode, & : Crystal::Def ->)
      case node
      when Crystal::Expressions
        node.expressions.each do |expression|
          yield expression if expression.is_a?(Crystal::Def)
        end
      when Crystal::Def
        yield node
      end
    end

    private def qualify_type_name(name : String, parent_type_name : String?) : String
      return name if name.includes?("::") || parent_type_name.nil?
      "#{parent_type_name}::#{name}"
    end

    private def contains_cursor?(node : Crystal::ASTNode)
      # A named argument's location covers its name only (`args: expr`):
      # the value's span decides containment.
      if node.is_a?(Crystal::Arg)
        if value = node.default_value
          return contains_cursor?(value)
        end
      elsif node.is_a?(Crystal::NamedArgument)
        return contains_cursor?(node.value)
      end

      start_loc = node.location
      end_loc = node.end_location || start_loc
      return false unless start_loc && end_loc

      compare_position(start_loc.line_number, start_loc.column_number, @line, @column) <= 0 &&
        compare_position(end_loc.line_number, end_loc.column_number, @line, @column) >= 0
    end

    # `&.map { ... }` chains parse as a call whose block has no end
    # location (the nested call carries it): fall back to the block's
    # body so cursor containment still descends into the chain.
    private def block_contains_cursor?(block : Crystal::Block)
      contains_cursor?(block) || contains_cursor?(block.body)
    end

    private def before_cursor?(node : Crystal::ASTNode)
      end_loc = node.end_location || node.location
      return false unless end_loc

      compare_position(end_loc.line_number, end_loc.column_number, @line, @column) < 0
    end

    private def starts_before_or_at_cursor?(node : Crystal::ASTNode)
      start_loc = node.location
      return false unless start_loc

      compare_position(start_loc.line_number, start_loc.column_number, @line, @column) <= 0
    end

    private def compare_position(line_a : Int32, col_a : Int32, line_b : Int32, col_b : Int32)
      return line_a <=> line_b unless line_a == line_b
      col_a <=> col_b
    end
  end
end
