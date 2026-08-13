require "./inference"
require "./type_utils"
require "./query"
require "../position_utils"

module Crystalline::Lightweight
  module Resolver
    extend self

    SAFE_TRY_SEGMENT = "__lightweight_try__"
    INDEX_SEGMENT = "__lightweight_index__"
    RANGE_SEGMENT = "__lightweight_range__"
    CAST_SEGMENT = "__lightweight_cast__"

    def receiver_types(source : String, line_number : Int32, analysis_column : Int32, receiver : String, query : Query) : {Array(String), Bool}
      # A quoted-string root (`"= #{a.b}".colorize`) contains dots inside
      # the interpolation: split on dots only outside quotes so the root
      # stays the whole literal.
      segments = [] of String
      if receiver.starts_with?('"')
        start = 0
        in_quote = false
        receiver.each_char_with_index do |char, index|
          if char == '"'
            in_quote = !in_quote
          elsif char == '.' && !in_quote
            segments << receiver[start...index]
            start = index + 1
          end
        end
        tail = receiver[start..]
        segments << tail unless tail.empty?
      else
        segments = receiver.split('.').reject(&.empty?)
      end
      return {[] of String, false} if segments.empty?

      type_names, class_method = root_receiver_types(source, line_number, analysis_column, segments.shift, query)
      return {[] of String, class_method} if type_names.empty?

      index = 0
      while index < segments.size
        segment = segments[index]
        if segment == SAFE_TRY_SEGMENT
          safe_method = segments[index + 1]?
          unless safe_method
            safe_receiver_types = type_names.reject(&.==("Nil")).uniq
            return {safe_receiver_types, false}
          end

          # `x.try(&.foo[1]?)` — the nilable index after the try.
          safe_method = "[]" if safe_method == INDEX_SEGMENT
          safe_method = "[]?" if safe_method == "#{INDEX_SEGMENT}?"
          type_names, class_method = safe_chained_call_types(type_names, class_method, safe_method, query)
          return {[] of String, class_method} if type_names.empty?
          index += 2
        else
          segment = "[]" if segment == INDEX_SEGMENT
          # `types[type_name]?` — a nilable index — normalizes to the
          # index segment with a `?` suffix: resolve it like `[]?`.
          segment = "[]?" if segment == "#{INDEX_SEGMENT}?"
          if segment == RANGE_SEGMENT
            # `arr[1..]` / `arr[1...]` — a range index returns the
            # array itself (a slice), not an element: keep the receiver
            # types flowing through the chain.
            type_names = type_names.reject(&.==("Nil")).uniq
            class_method = false
          elsif segment == "#{RANGE_SEGMENT}?"
            # `arr[1..]?` — the nilable slice: the array or nil.
            type_names = (type_names.reject(&.==("Nil")).uniq + ["Nil"]).uniq
            class_method = false
          elsif segment == "as" || segment == "as?"
            # `as`/`as?` casts are compiler specials: this segment is the
            # method-name half of a preserved cast call, and the cast-target
            # segment that follows overrides the receiver types.
          elsif segment.starts_with?(CAST_SEGMENT)
            # `as`/`as?` casts are compiler specials, not indexed methods:
            # the normalizer kept the target type in this segment, and the
            # target names the cast result.
            if target = segment[CAST_SEGMENT.size + 1..]?
              target = target.rchop(')')
              type_names = [target]
              class_method = false
            else
              return {[] of String, class_method}
            end
          else
            # A call segment with args (`Crystal::Parser.new(text)` splits
            # on '.' into `Crystal::Parser` + `new(text)`): the args group
            # is not part of the method name.
            segment = segment.split('(').first? || segment
            type_names, class_method = chained_call_types(type_names, class_method, segment, query)
            return {[] of String, class_method} if type_names.empty?
          end
          index += 1
        end
      end

      {type_names, class_method}
    end

    def receiver_from_prefix(prefix : String) : String
      # `rstrip` also clears trailing whitespace: a chain continuation
      # (`greeter\n    .method`) leaves only whitespace between the
      # previous line's receiver and the trigger dot, and without the
      # strip the walk-back stops at the whitespace, producing an empty
      # receiver (or one that drags the whitespace along).
      normalized_prefix = normalize_receiver_prefix(prefix).rstrip('.').rstrip

      start = normalized_prefix.size
      while start > 0 && receiver_expression_char?(normalized_prefix[start - 1])
        start -= 1
      end

      # A quoted-string receiver (`"✅ #{project_name}".colorize`): the
      # closing quote stops the expression-char scan, so extend back to
      # the opening quote (the last one before it). Applies both when the
      # prefix ends at the quote (first hop) and mid-chain (`"x".foo.bar`:
      # the scan stops at the quote after the leading dot).
      if start > 0 && normalized_prefix[start - 1] == '"'
        if open_quote = normalized_prefix.rindex('"', start - 2)
          start = open_quote
        end
      end

      # A `do ... end` block tail (`flat_map do |x| ... end.uniq`, with
      # the `end` possibly followed by a chain suffix: `... end.flatten.`):
      # the trailing call's receiver starts at the block's `end`, so cut
      # the block text at the matching `do` and keep any suffix.
      receiver = normalized_prefix[start..]? || ""
      if receiver.size >= 3 && receiver.starts_with?("end") && (receiver.size == 3 || receiver[3]? == '.')
        # Scan backward from just before the closer: the closer itself is
        # the anchor and must not be counted (its matching `do` is the one
        # that brings the depth back to zero).
        # `String#[](index : Int)` is O(n) (a character-index scan), so
        # index the char array instead of the raw string.
        chars = normalized_prefix.chars
        depth = 1
        index = start - 1
        do_index = -1
        # An `end` followed (going back) by `else`/`elsif` closes an
        # `if`/`case`, not a `do` block: undo its depth contribution.
        else_seen = false
        while index >= 0 && depth > 0
          if token_char?(chars[index])
            token_end = index + 1
            token_start = index
            while token_start > 0 && token_char?(chars[token_start - 1])
              token_start -= 1
            end
            # `String#[](start, count)` is O(start): build the token from
            # the char array (the same reason the loops index `chars`).
            token = String.build(token_end - token_start) do |io|
              (token_start...token_end).each { |i| io << chars[i] }
            end
            if token == "end"
              depth += 1
              else_seen = false
            elsif token == "do"
              depth -= 1
              do_index = token_start if depth == 0
            elsif (token == "else" || token == "elsif") && !else_seen
              depth -= 1
              else_seen = true
            end
            index = token_start - 1
          else
            index -= 1
          end
        end
        if do_index >= 0
          suffix = normalized_prefix[start + 3..]? || ""
          normalized_prefix = normalized_prefix[0, do_index].rstrip + suffix
          start = normalized_prefix.size
          while start > 0 && receiver_expression_char?(normalized_prefix[start - 1])
            start -= 1
          end
        end
      end

      # A cast segment (`.__lightweight_cast__(T)`) ends with a balanced
      # group. Walk back through it so the receiver keeps the cast target
      # instead of stopping at the closing paren. Only cast segments leave
      # a `)` in the normalized prefix — other groups are dropped — so the
      # segment marker must be present, otherwise the paren is an orphan
      # (e.g. a `try(&...)` call nested in a dropped group) and the
      # receiver stays empty.
      if start > 0 && normalized_prefix[start - 1] == ')' && normalized_prefix[0, start]?.try(&.includes?(CAST_SEGMENT))
        depth = 0
        while start > 0
          char = normalized_prefix[start - 1]
          start -= 1
          depth += 1 if char == ')'
          depth -= 1 if char == '('
          break if depth == 0
        end
        while start > 0 && receiver_expression_char?(normalized_prefix[start - 1])
          start -= 1
        end
      end

      receiver = normalized_prefix[start..]? || ""
      # A range operator inside the receiver (`range.start.line..range.end`)
      # is not a method call: the receiver of the trailing call is the
      # part after the last `..` (`a..b.foo` parses as `a..(b.foo)`, so
      # `foo`'s receiver is `b`). Skipped when a quote is present (a
      # `..` inside a string literal must stay intact).
      if !receiver.includes?('"') && !receiver.includes?('\'') && (range_index = receiver.rindex(".."))
        receiver = receiver[range_index + 2..]? || ""
      end

      receiver
    end

    # The receiver may span lines (`... end.uniq` with the `end` on its
    # own line after a do-block): walk back over the whole source up to
    # the cursor when the single-line receiver suggests a block closer
    # (`end...`) or a continuation (`.foo` on its own line); otherwise
    # the current line's prefix is enough.
    def receiver_from_line_prefix(source : String, line_number : Int32, prefix : String) : String
      single = receiver_from_prefix(prefix)
      if single.empty? || (single.starts_with?("end") && (single.size == 3 || single[3]? == '.')) || single.starts_with?('.')
        full_prefix = String.build do |io|
          source.lines(chomp: false)[0...line_number].each { |l| io << l }
          io << prefix
        end
        receiver_from_prefix(full_prefix)
      else
        single
      end
    end

    def receiver_expression_char?(char : Char)
      token_char?(char) || char == '.'
    end

    private def normalize_receiver_prefix(prefix : String) : String
      normalized_prefix = prefix
        # `try(&.x)` / `try &.x` / mid-edit `try(&` — the `&.`-form block
        # is not a parseable group, so it gets a dedicated segment (the
        # block receiver of try is the call's own receiver).
        .gsub(/\.try\s*(?:\(\s*)?&\s*\./, ".#{SAFE_TRY_SEGMENT}.")
        .gsub(/\.try\s*(?:\(\s*)?&\s*$/, ".#{SAFE_TRY_SEGMENT}.")
        .gsub(/[ \t]+\(/, "(")

      result = String.build do |str|
        # `String#[](index : Int)` is O(n) (a character-index scan), so
        # indexing the raw string inside these loops would be quadratic
        # on multi-line prefixes: index the char array instead.
        chars = normalized_prefix.chars
        index = 0
        quote = nil.as(Char?)
        while index < chars.size
          char = chars[index]
          if quote
            # Inside a string: copy verbatim — a paren or bracket in the
            # text (`"Array(#{...})"`) is not code and must not open a group.
            str << char
            if char == '\\'
              if escaped = chars[index + 1]?
                str << escaped
                index += 2
                next
              end
            elsif char == quote
              quote = nil
            end
            index += 1
          elsif char.in?('"', '\'')
            quote = char
            str << char
            index += 1
          elsif char == '#'
            # A comment is not code: copy it verbatim so a paren or
            # bracket inside it (e.g. `(only the body's effects`) never
            # opens a group that swallows the rest of the prefix.
            comment_start = index
            index += 1
            while index < chars.size && chars[index] != '\n'
              index += 1
            end
            str << normalized_prefix[comment_start...index]
          elsif char == '['
            group_start = index
            depth = 1
            quote = nil.as(Char?)
            index += 1
            while index < chars.size && depth > 0
              current = chars[index]
              if quote
                if current == '\\'
                  index += 2
                  next
                elsif current == quote
                  quote = nil
                end
              elsif current.in?('"', '\'')
                quote = current
              elsif current == '['
                depth += 1
              elsif current == ']'
                depth -= 1
              elsif current == '#'
                # Skip comment text inside the group (e.g. a `# [note`
                # between call args): it must not affect group balance.
                # Strings are handled by the quote branch above, so an
                # interpolation `#{...}` never reaches here.
                index += 1
                while index < chars.size && chars[index] != '\n'
                  index += 1
                end
              end
              index += 1
            end
            if depth > 0
              # Unclosed bracket (mid-edit, e.g. `@local_types[target.`):
              # keep the remainder (the `[` stops the receiver walk-back)
              # so the receiver inside the brackets is still found.
              (group_start...chars.size).each { |i| str << chars[i] }
              index = chars.size
            else
              # `arr[1..]` / `arr[i..j]` — a range index slices the
              # array, so the chain continues on the array itself (the
              # resolver treats the range segment as identity). String
              # literals inside the brackets (`arr[".."]`) are not ranges.
              inner = String.build(index - group_start - 2) do |io|
                (group_start + 1...index - 1).each { |i| io << chars[i] }
              end
              str << if inner.gsub(/"[^"]*"|'[^']*'/, "").includes?("..")
                       ".#{RANGE_SEGMENT}"
                     else
                       ".#{INDEX_SEGMENT}"
                     end
              # `[] of String` — an array literal's of-clause: consume it
              # so the walk-back lands on the index segment (the receiver
              # root resolves it to `Array(T)`), not on the element type.
              if chars[index]? == ' ' && chars[index + 1]? == 'o' && chars[index + 2]? == 'f' && (chars[index + 3]? == ' ' || chars[index + 3]? == nil)
                index += 3
                while chars[index]? == ' '
                  index += 1
                end
                while chars[index]? && token_char?(chars[index])
                  index += 1
                end
              end
            end
          elsif char == '('
            # Call arguments are dropped from the receiver expression so that
            # chains like `factory.build("hi").sh` resolve through `build`.
            # `as`/`as?` casts are the exception: the target type names the
            # result, so it survives in a special segment.
            group_start = index
            depth = 1
            index += 1
            quote = nil.as(Char?)
            while index < chars.size && depth > 0
              current = chars[index]
              if quote
                if current == '\\'
                  index += 2
                  next
                elsif current == quote
                  quote = nil
                end
              elsif current.in?('"', '\'')
                quote = current
              elsif current == '#'
                # Skip comment text inside the group: an apostrophe in a
                # comment (e.g. `(only the body's effects`) must not be
                # mistaken for a quote that swallows the rest of the file.
                index += 1
                while index < chars.size && chars[index] != '\n'
                  index += 1
                end
              elsif current == '('
                depth += 1
              elsif current == ')'
                depth -= 1
              end
              index += 1
            end
            if depth > 0
              # Unclosed group (mid-edit, e.g. `unless (x = foo.b`): keep
              # the remainder so the receiver inside the parens is still found.
              (group_start...chars.size).each { |i| str << chars[i] }
              index = chars.size
            else
              method_end = group_start
              method_start = method_end
              while method_start > 0 && token_char?(chars[method_start - 1])
                method_start -= 1
              end
              # `String#[](start, count)` is O(start) (a character-index
              # scan), so a slice near the end of a multi-line prefix
              # would be quadratic across all groups: build from chars.
              method_name = String.build(method_end - method_start) do |io|
                (method_start...method_end).each { |i| io << chars[i] }
              end
              if method_name == "as" || method_name == "as?"
                target = String.build(index - group_start - 2) do |io|
                  (group_start + 1...index - 1).each { |i| io << chars[i] }
                end
                str << ".#{CAST_SEGMENT}(#{target})"
              elsif method_name.empty? || method_name.in?("if", "unless", "while", "until", "return", "case", "?") || method_name.ends_with?(':')
                # A parenthesized expression as receiver — `(expr).m`, or
                # `(expr).try(&.m)` where the parens group the try receiver
                # itself, or a control-flow condition `if (x = y).m` (the
                # keyword is not a call, so the group is not its args):
                # keep the inner expression so the chain still resolves.
                # A bare `?` is the ternary operator (`x ? (a || b).m : c`)
                # and a trailing `:` a keyword-arg label (`sort_text:
                # (nesting + 1).chr`): neither is a call, so the group is
                # the value, not call arguments.
                # For a multi-expression inner (`a || b`) the walk-back
                # keeps its last sub-expression, the usual approximation.
                # The inner may itself contain groups and brackets
                # (`(a || b[1]?).try(&.x)`): normalize it recursively so
                # the walk-back does not stop at a raw `[`/`(`.
                inner = String.build(index - group_start - 2) do |io|
                  (group_start + 1...index - 1).each { |i| io << chars[i] }
                end
                str << normalize_receiver_prefix(inner)
              end
            end
          elsif char == ')'
            # A stray closer left by the `try(&.x)` rewrite above (it
            # consumes the opening paren but not its match): a `)` that
            # reaches the top level is never part of a receiver.
            index += 1
          else
            str << char
            index += 1
          end
        end
      end

      result
    end

    def token_char?(char : Char)
      char.ascii_alphanumeric? || char.in?('_', '?', '!', '@', ':')
    end

    # The token span around the cursor column (character-based), or nil
    # when the cursor is not on a token.
    def token_span(line : String, column_number : Int32) : {Int32, Int32}?
      index = normalized_column(line, column_number)
      return unless index
      return unless token_char?(line[index])

      start_index = index
      while start_index > 0 && token_char?(line[start_index - 1])
        start_index -= 1
      end

      end_index = index + 1
      while (char = line[end_index]?) && token_char?(char)
        end_index += 1
      end

      {start_index, end_index}
    end

    # The character index under the cursor, snapping to the token when the
    # cursor sits just past it (end-of-token hovers), or nil when the
    # cursor is on whitespace/punctuation.
    def normalized_column(line : String, column_number : Int32) : Int32?
      return if line.empty?

      index = PositionUtils.utf16_to_char_index(line, column_number)
      index = line.size - 1 if index >= line.size
      return if index < 0

      return index if token_char?(line[index])
      return index - 1 if index > 0 && token_char?(line[index - 1])

      nil
    end

    def instance_var_name?(name : String)
      !!(name =~ /\A@[a-zA-Z_][a-zA-Z0-9_?!]*\z/)
    end

    def class_var_name?(name : String)
      !!(name =~ /\A@@[a-zA-Z_][a-zA-Z0-9_?!]*\z/)
    end

    def local_name?(name : String)
      !!(name =~ /\A[a-z_][a-zA-Z0-9_?!]*\z/)
    end

    def type_name?(name : String)
      !!(name =~ /\A[A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*\z/)
    end

    private def root_receiver_types(source : String, line_number : Int32, analysis_column : Int32, receiver : String, query : Query) : {Array(String), Bool}
      # A negation receiver (`!@result_cache`) resolves like the operand.
      receiver = receiver.lchop('!')

      if receiver == "__lightweight_index__" || receiver == "[]"
        # An array literal receiver (`[a, b].compact_map`): the normalizer
        # turned the bracket group into the index segment. The element
        # type is not recoverable from the string, so fall back to the
        # generic array — the chain still flows through `Array(T)`.
        return {["Array(T)"], false}
      end

      if receiver == "nil"
        return {["Nil"], false}
      end

      # Literal receivers (`120.seconds`, `"x".size`, `'c'.ord`, `true`):
      # type them from the literal form so stdlib methods resolve.
      if receiver == "true" || receiver == "false"
        return {["Bool"], false}
      end
      if receiver =~ /\A-?\d+_\d+\z/ || receiver =~ /\A-?\d+\z/
        return {["Int32"], false}
      end
      if receiver =~ /\A-?\d+\.\d+\z/ || receiver =~ /\A-?\d+[eE][+-]?\d+\z/
        return {["Float64"], false}
      end
      if receiver =~ /\A"[^"]*"\z/
        return {["String"], false}
      end
      if receiver =~ /\A'[^']*'\z/
        return {["Char"], false}
      end

      inference = Inference.for(
        source,
        line_number + 1,
        analysis_column + 1,
        query,
      )

      if type_name?(receiver)
        resolved_name = query.resolve_type_name(receiver, namespace: inference.try(&.current_type_name))
        if resolved_name
          # A compiled constant (`LSP::Log = ::Log.for(self)`) is recorded
          # as a Constant-kind shell whose parent is the value's type: the
          # constant holds an instance, so its methods are the value type's
          # instance methods (`LSP::Log.info`).
          if constant_types = constant_value_types(resolved_name, query)
            return {constant_types, false}
          end
          # The compiled index records constants (`CAST_SEGMENT = "..."`)
          # as bare type entries with no methods and no parents: a
          # capitalized receiver resolving to such a shell is a constant
          # value, not a type — fall through to the constant-type path.
          return {[resolved_name], true} unless constant_shell_type?(resolved_name, query)
        end
        # A capitalized name can also be a constant
        # (`CAST_SEGMENT = "__lightweight_cast__"`): when it is not a
        # type, fall back to the recorded constant type.
        if inference
          constant_types = inference.types_for(receiver).reject(&.==("Nil")).select { |type_name| receiver_type_known?(type_name, query) }
          return {constant_types, false} unless constant_types.empty?
        end
        return {[] of String, true}
      end

      if receiver == "self"
        return inference.try(&.self_types) || {[] of String, false}
      end

      if instance_var_name?(receiver)
        return {
          (inference ? inference.types_for_instance_var(receiver) : [] of String).reject(&.==("Nil")).select { |type_name| receiver_type_known?(type_name, query) },
          false,
        }
      end

      if class_var_name?(receiver)
        # A class var holds an instance value (`@@compilation_lock =
        # Mutex.new`), so its methods are instance methods — unlike a
        # type-path receiver.
        return {
          (inference ? inference.types_for_class_var(receiver) : [] of String).reject(&.==("Nil")).select { |type_name| receiver_type_known?(type_name, query) },
          false,
        }
      end

      return {[] of String, false} unless local_name?(receiver)

      if inference
        namespace = inference.current_type_name
        local_types = inference.types_for(receiver).reject(&.==("Nil")).flat_map { |type_name|
          if receiver_type_known?(type_name, query)
            [type_name]
          elsif resolved = query.resolve_type_name(type_name, namespace: namespace)
            [resolved]
          else
            [] of String
          end
        }.uniq
        return {local_types, false} unless local_types.empty?
      end

      # The receiver may be a self-call (e.g. a `getter!` used without an
      # explicit receiver): resolve the method on the enclosing type. The
      # return type is resolved against that type's namespace, so a bare
      # `Workspace` in `Crystalline::Controller` picks the project type even
      # when another `::Workspace` exists elsewhere.
      if inference
        if self_type_names = inference.self_types[0]?
          return_types = self_type_names.flat_map do |type_name|
            query.methods_for(type_name, class_method: inference.class_method_context?).select(&.name.==(receiver)).flat_map { |method|
              return_type_names(method.return_type, query, namespace: type_name)
            }
          end.reject(&.==("Nil")).uniq
          return {return_types, false} unless return_types.empty?
        end
      end

      {
        query.top_level_methods.select { |method| method.name == receiver }.flat_map { |method|
          return_type_names(method.return_type, query)
        }.reject(&.==("Nil")).uniq,
        false,
      }
    end

    private def safe_chained_call_types(type_names : Array(String), class_method : Bool, method_name : String, query : Query) : {Array(String), Bool}
      non_nil_types = type_names.reject(&.==("Nil")).uniq
      return {type_names.includes?("Nil") ? ["Nil"] : [] of String, false} if non_nil_types.empty?

      resolved_types, _ = chained_call_types(non_nil_types, class_method, method_name, query)
      resolved_types = (resolved_types + ["Nil"]).uniq if type_names.includes?("Nil")
      {resolved_types, false}
    end

    private def chained_call_types(type_names : Array(String), class_method : Bool, method_name : String, query : Query) : {Array(String), Bool}
      if class_method
        valid_types = type_names.select { |type_name| receiver_type_known?(type_name, query) }.uniq
        return {valid_types, false} if method_name == "new"
        return {valid_types, true} if method_name == "class"
      elsif method_name == "class"
        return {type_names.select { |type_name| receiver_type_known?(type_name, query) }.uniq, true}
      end

      special_types = type_names.flat_map { |type_name| special_return_type_names(type_name, method_name, query) }.uniq
      return {special_types, false} unless special_types.empty?

      return_types = type_names.flat_map do |type_name|
        query.methods_named(type_name, method_name, class_method: class_method).flat_map do |method|
          # `Array(T)#+` returns `Array(T)`: substitute the receiver's
          # concrete element types for the free vars so the chain keeps
          # `Array(X)` instead of an unresolvable `T`.
          return_type = TypeUtils.substitute_free_vars(method.return_type, method.free_vars, type_name)
          # A `def ...; self; end` return (Colorize's macro-generated
          # style setters) names the owner type.
          return_type = method.owner if return_type == "self"
          # Resolve bare return types (e.g. `ASTNode`) against the method's
          # own namespace, the way the compiler would.
          return_type_names(return_type, query, namespace: method.owner)
        end
      end

      # Compiler-semantic accessors (`ASTNode#type?`, base
      # `Type#parents`/`types?`/`remove_alias`) carry no usable indexed
      # return: apply the known compiler signature so chains through them
      # keep resolving (`n.type?.to_s`, `type.parents.try &.each`).
      if (return_types.empty? || return_types.all?(&.==("Nil"))) && type_names.any? { |t| t.starts_with?("Crystal::") }
        if semantic_return = TypeUtils.semantic_accessor_return(method_name)
          return_types = TypeUtils.expand_type_names(semantic_return)
        end
      end

      {return_types.uniq, false}
    end

    private def receiver_type_known?(type_name : String, query : Query) : Bool
      # find_type_info falls back to the first generic specialization
      # (`Dispatcher` → `Dispatcher(T)`), so generic-class receivers like
      # `LSP::RequestMessage` resolve even though the index keys them
      # with their type vars.
      query.find_type_info(type_name) != nil ||
        TypeUtils.array_element_types(type_name) != nil ||
        TypeUtils.hash_value_types(type_name) != nil ||
        TypeUtils.tuple_element_types(type_name) != nil ||
        TypeUtils.named_tuple_type?(type_name)
    end

    # A recorded type entry that carries no methods and no parents is a
    # constant shell (the compiled index stores constants that way), not
    # a real type.
    private def constant_shell_type?(resolved_name : String, query : Query) : Bool
      type = query.find_type_info(resolved_name)
      return false unless type
      type.methods.empty? && type.parent_types.empty?
    end

    # A Constant-kind entry (`LSP::Log = ::Log.for(self)`) carries the
    # value's type as its single parent: the constant is an instance
    # value, so the receiver resolves to the value type's instance
    # methods.
    private def constant_value_types(resolved_name : String, query : Query) : Array(String)?
      type = query.find_type_info(resolved_name)
      return nil unless type && type.kind == TypeKind::Constant
      return nil if type.parent_types.empty?
      [type.parent_types.first]
    end

    # Container element/value types can be bare names (`Array(ArgInfo)`):
    # resolve them against the receiver's namespace so the chain keeps
    # fully-qualified entries. Bare elements from compiler generics
    # (`Array(Arg)` → `Arg`) fail the ambiguous-name tie-break, so fall
    # back to the `Crystal::`-prefixed name when it exists.
    private def resolve_types(types : Array(String), type_name : String, query : Query) : Array(String)
      types.map do |t|
        query.resolve_type_name(t, namespace: type_name) ||
          (query.find_type_info("Crystal::#{t}") ? "Crystal::#{t}" : nil) ||
          t
      end
    end

    private def special_return_type_names(type_name : String, method_name : String, query : Query) : Array(String)
      case method_name
      when "not_nil!"
        return TypeUtils.expand_type_names(type_name).reject(&.==("Nil"))
      when "tap", "each", "each_with_index", "select", "reject", "reverse_each"
        # `reverse_each` chains on the enumerator; the indexed overload is
        # the block form (`: Nil`), so treat it as identity like `each`.
        return [type_name]
      when "compact_map"
        # The indexed overload's return (`Array(U)` with U from the block)
        # is unresolvable: the chain still flows through an array, so keep
        # the receiver's array shape.
        return [type_name] if TypeUtils.array_element_types(type_name)
      when "flat_map"
        # `Enumerable#flat_map(& : T -> _)` declares no return restriction
        # (`Array(U)` is compiler-inferred), so the index records none:
        # the chain still flows through an array of the block's flattened
        # results, so approximate with an array of the receiver's elements.
        if element_types = TypeUtils.enumerable_element_types(type_name)
          return ["Array(#{resolve_types(element_types, type_name, query).join(" | ")})"]
        end
      when "flatten"
        if TypeUtils.array_element_types(type_name)
          # `arr.flatten` is still the array.
          return [type_name]
        elsif tuple_types = TypeUtils.tuple_element_types(type_name)
          # `tuple.flatten` becomes an array of the elements' union.
          return ["Array(#{resolve_types(tuple_types.flatten.uniq, type_name, query).join(" | ")})"]
        end
      when "first", "last", "[]", "find!", "reduce"
        if element_types = TypeUtils.array_element_types(type_name)
          return resolve_types(element_types, type_name, query).select { |item| receiver_type_known?(item, query) || query.find_type(item) != nil }
        elsif tuple_types = TypeUtils.tuple_element_types(type_name)
          if method_name == "first"
            return resolve_types(tuple_types.first? || [] of String, type_name, query)
          elsif method_name == "last"
            return resolve_types(tuple_types.last? || [] of String, type_name, query)
          end
          return resolve_types(tuple_types.flatten.uniq, type_name, query)
        elsif value_types = TypeUtils.hash_value_types(type_name)
          return resolve_types(value_types, type_name, query).select { |item| receiver_type_known?(item, query) || query.find_type(item) != nil }
        end
      when "first?", "last?", "[]?", "find", "dig"
        if element_types = TypeUtils.array_element_types(type_name)
          return (resolve_types(element_types, type_name, query) + ["Nil"]).uniq
        elsif tuple_types = TypeUtils.tuple_element_types(type_name)
          selected = if method_name == "first?"
                       tuple_types.first? || [] of String
                     elsif method_name == "last?"
                       tuple_types.last? || [] of String
                     else
                       tuple_types.flatten.uniq
                     end
          return (resolve_types(selected, type_name, query) + ["Nil"]).uniq
        elsif value_types = TypeUtils.hash_value_types(type_name)
          return (resolve_types(value_types, type_name, query) + ["Nil"]).uniq
        elsif value_types = TypeUtils.named_tuple_all_value_types(type_name)
          return (resolve_types(value_types, type_name, query) + ["Nil"]).uniq
        end
      when "fetch"
        if value_types = TypeUtils.hash_value_types(type_name)
          return resolve_types(value_types, type_name, query)
        end
      else
        if value_types = TypeUtils.named_tuple_value_types(type_name, method_name)
          return resolve_types(value_types, type_name, query).select { |item| receiver_type_known?(item, query) || query.find_type(item) != nil }
        end
      end

      if contracts = query.method_contracts_for(type_name, method_name)
        contract_types = [] of String
        contracts.each do |contract|
          case contract.kind
          when .preserve_receiver?
            contract_types.concat(contract.types)
          when .return_element?, .return_value?
            contract_types.concat(contract.types)
          when .return_element_or_nil?, .return_value_or_nil?
            contract_types.concat(contract.types)
            contract_types << "Nil"
          end
        end
        contract_types = contract_types.uniq
        unless contract_types.empty?
          # A Nil-only contract on a compiler accessor (`Crystal::Type#parents`
          # returns nil on the base class) is not the real signature: fall
          # through so chained_call_types applies the semantic one.
          unless contract_types.all?(&.==("Nil")) && type_name.starts_with?("Crystal::") && TypeUtils.semantic_accessor_return(method_name)
            # Contracts come from the compiled program, whose return types
            # are bare (e.g. `ASTNode`): resolve them against the receiver's
            # namespace before returning.
            return contract_types.flat_map { |contract_type| return_type_names(contract_type, query, namespace: type_name) }.uniq
          end
        end
      end

      [] of String
    end

    private def return_type_names(return_type : String?, query : Query, namespace : String? = nil) : Array(String)
      return [] of String unless return_type

      TypeUtils.expand_type_names(return_type).compact_map do |type_name|
        # `: self?`-style returns resolve to the method's owner.
        if type_name == "self"
          next namespace ? namespace : nil
        end
        # Resolve plain names against the query (and the enclosing namespace
        # when known, e.g. a getter's `Workspace` in `Crystalline::Controller`);
        # generic/structured names (Array(T), Tuple(...)) are known as-is.
        resolved = query.resolve_type_name(type_name, namespace) || type_name
        next unless receiver_type_known?(resolved, query)
        resolved
      end
    end
  end
end
