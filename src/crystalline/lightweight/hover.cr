require "lsp/server"
require "../source_mask"
require "./query"
require "./resolver"

module Crystalline::Lightweight
  class Hover
    def self.hover(source : String, line_number : Int32, column_number : Int32, query : Query) : LSP::Hover?
      hover_and_reason(source, line_number, column_number, query)[0]
    end

    def self.diagnose(source : String, line_number : Int32, column_number : Int32, query : Query) : String
      hover_and_reason(source, line_number, column_number, query)[1]
    end

    # Computes the hover and its miss reason in a single pass, so that
    # workspace logging does not double the cost of a miss.
    def self.hover_and_reason(source : String, line_number : Int32, column_number : Int32, query : Query) : {LSP::Hover?, String}
      new(source, line_number, column_number, query).hover_or_reason
    end

    def initialize(@source : String, @line_number : Int32, @column_number : Int32, @query : Query)
    end

    def hover_or_reason : {LSP::Hover?, String}
      line = @source.lines(chomp: false)[@line_number]?
      return {nil, "no line at cursor"} unless line

      span = Resolver.token_span(line, @column_number)
      return {nil, "no token at cursor"} unless span

      start_index, end_index = span
      if SourceMask.new(@source).comment_or_string?(@line_number, start_index)
        return {nil, "token inside comment or string"}
      end

      token = line[start_index, end_index - start_index]?
      return {nil, "empty token at cursor"} unless token && !token.empty?

      if start_index > 0 && line[start_index - 1] == '.' && !(start_index > 1 && line[start_index - 2] == '.')
        # The receiver may span lines: walk back over the whole source
        # when the single-line receiver suggests a block closer or a
        # continuation (see Resolver.receiver_from_line_prefix).
        # A token preceded by `..`/`...` is a range bound (`a..b`,
        # `c...d`), not a method call: fall through to the local/type
        # hovers instead of building a bogus receiver.
        line_prefix = line[0, start_index - 1]
        receiver = Resolver.receiver_from_line_prefix(@source, @line_number, line_prefix)
        return {nil, "empty method receiver"} if receiver.empty?

        hover = hover_for_method(receiver, token, start_index - 1)
        return {hover, hover ? "resolved" : "no lightweight method hover for receiver '#{receiver}' and method '#{token}'"}
      end

      if token == "self"
        hover = hover_for_self
        return {hover, hover ? "resolved" : "could not infer self type"}
      end

      if Resolver.type_name?(token)
        hover = hover_for_type(token)
        return {hover, hover ? "resolved" : "unknown lightweight type '#{token}'"}
      end

      if Resolver.instance_var_name?(token)
        hover = hover_for_instance_var(token)
        return {hover, hover ? "resolved" : "could not infer instance var '#{token}'"}
      end

      if Resolver.class_var_name?(token)
        hover = hover_for_class_var(token)
        return {hover, hover ? "resolved" : "could not infer class var '#{token}'"}
      end

      if Resolver.local_name?(token)
        # A bare name may be a self-call (e.g. a `getter!` used without an
        # explicit receiver): resolve it as a method on the enclosing type.
        hover = hover_for_local(token) || hover_for_method("self", token, start_index) || hover_for_top_level_method(token)
        return {hover, hover ? "resolved" : "could not infer local or top-level method '#{token}'"}
      end

      {nil, "unsupported hover token '#{token}'"}
    end

    # Compiler-intrinsic predicates lexed as token keywords (`nil?`,
    # `is_a?`, `as?`, `responds_to?`): they exist on every type but are
    # never real defs in the compiled program, so the index cannot contain
    # them. Hover with their known signatures instead of a miss.
    SPECIAL_METHOD_HOVERS = {
      "nil?"         => "nil? : Bool",
      "is_a?"        => "is_a?(type : T.class) : Bool",
      "responds_to?" => "responds_to?(name : String) : Bool",
      "as"           => "as(type : T.class) : T",
      "as?"          => "as?(type : T.class) : T | Nil",
    }

    private def hover_for_method(receiver : String, method_name : String, analysis_column : Int32) : LSP::Hover?
      type_names, class_method = Resolver.receiver_types(@source, @line_number, analysis_column, receiver, @query)
      if type_names.empty?
        # The receiver may be untyped (e.g. a local whose stdlib receiver
        # type is not in the prelude index): the intrinsic predicates still
        # exist on every type.
        if signature = SPECIAL_METHOD_HOVERS[method_name]?
          return build_hover([signature], nil)
        end
        return
      end

      methods = type_names.flat_map do |type_name|
        # `parser.wants_doc = true` hovers the base name: also match the
        # setter form (`wants_doc=`) so assignment targets resolve.
        # methods_named falls back to the subtypes of compiler hierarchy
        # roots (`Crystal::ASTNode#name` resolves through `Var`), the
        # same fallback completion applies.
        @query.methods_named(type_name, method_name, class_method: class_method) +
          @query.methods_named(type_name, "#{method_name}=", class_method: class_method)
      end
      if methods.empty?
        if signature = SPECIAL_METHOD_HOVERS[method_name]?
          return build_hover([signature], nil)
        end
        return
      end

      build_hover(
        methods.map { |method| format_method(method, include_owner: true) },
        methods.compact_map(&.doc).first?,
      )
    end

    private def hover_for_type(type_name : String) : LSP::Hover?
      # Resolve against the enclosing namespace so a bare type name (e.g.
      # `Workspace` inside `Crystalline::Controller`) finds its full name.
      if inference = Inference.for(@source, @line_number + 1, @column_number + 1, @query)
        if resolved = @query.resolve_type_name(type_name, namespace: inference.current_type_name)
          if type = @query.find_type(resolved)
            return build_hover([type.name], type.doc)
          end
        end
      end

      type = @query.find_type(type_name)
      return unless type

      build_hover([type.name], type.doc)
    end

    private def hover_for_self : LSP::Hover?
      inference = Inference.for(@source, @line_number + 1, @column_number + 1, @query)
      return unless inference

      type_names, class_method = inference.self_types
      return if type_names.empty?

      label = class_method ? "self : #{type_names.uniq.join(" | ")}.class" : "self : #{type_names.uniq.join(" | ")}"
      doc = type_names.size == 1 ? @query.find_type(type_names.first).try(&.doc) : nil
      build_hover([label], doc)
    end

    private def hover_for_local(name : String) : LSP::Hover?
      inference = Inference.for(@source, @line_number + 1, @column_number + 1, @query)
      return unless inference

      type_names = inference.types_for(name)
      return if type_names.empty?

      doc = type_names.size == 1 ? @query.find_type(type_names.first).try(&.doc) : nil
      build_hover(["#{name} : #{type_names.uniq.join(" | ")}"], doc)
    end

    private def hover_for_instance_var(name : String) : LSP::Hover?
      inference = Inference.for(@source, @line_number + 1, @column_number + 1, @query)
      return unless inference

      type_names = inference.types_for_instance_var(name)
      return if type_names.empty?

      doc = type_names.size == 1 ? @query.find_type(type_names.first).try(&.doc) : nil
      build_hover(["#{name} : #{type_names.uniq.join(" | ")}"], doc)
    end

    private def hover_for_class_var(name : String) : LSP::Hover?
      inference = Inference.for(@source, @line_number + 1, @column_number + 1, @query)
      return unless inference

      type_names = inference.types_for_class_var(name)
      return if type_names.empty?

      doc = type_names.size == 1 ? @query.find_type(type_names.first).try(&.doc) : nil
      build_hover(["#{name} : #{type_names.uniq.join(" | ")}"], doc)
    end

    private def hover_for_top_level_method(method_name : String) : LSP::Hover?
      methods = @query.top_level_methods.select { |method| method.name == method_name }
      return if methods.empty?

      build_hover(
        methods.map { |method| format_method(method, include_owner: true) },
        methods.compact_map(&.doc).first?,
      )
    end

    private def build_hover(signatures : Array(String), doc : String?) : LSP::Hover
      contents = [] of String
      contents << code_markdown(signatures.uniq.join("\n"), language: "crystal")

      if doc
        contents << "----------"
        contents << doc
      end

      LSP::Hover.new(
        contents: LSP::MarkupContent.new(
          kind: LSP::MarkupKind::MarkDown,
          value: contents.join("\n"),
        ),
      )
    end

    private def code_markdown(str : String, *, language = "") : String
      <<-MARKDOWN
      ```#{language}
      #{str}
      ```
      MARKDOWN
    end

    private def format_method(method : MethodInfo, *, include_owner = false) : String
      args = method.args.map do |arg|
        if restriction = arg.restriction
          "#{arg.name} : #{restriction}"
        else
          arg.name
        end
      end.join(", ")

      String.build do |str|
        if include_owner
          str << method.owner
          str << (method.class_method ? "." : "#")
        end

        str << method.name
        str << "(#{args})"
        str << " : #{method.return_type}" if method.return_type
      end
    end
  end
end
