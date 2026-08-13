require "lsp/server"
require "../completion_context"
require "../source_mask"
require "./inference"
require "./query"
require "./resolver"

module Crystalline::Lightweight
  class Completion
    def self.complete(source : String, line_number : Int32, context : Crystalline::CompletionContext, query : Query) : Array(LSP::CompletionItem)?
      complete_and_reason(source, line_number, context, query)[0]
    end

    def self.diagnose(source : String, line_number : Int32, context : Crystalline::CompletionContext, query : Query) : String
      complete_and_reason(source, line_number, context, query)[1]
    end

    # Computes the completion items and their miss reason in a single pass,
    # so that workspace logging does not double the cost of a miss.
    def self.complete_and_reason(source : String, line_number : Int32, context : Crystalline::CompletionContext, query : Query) : {Array(LSP::CompletionItem)?, String}
      new(source, line_number, context, query).complete_or_reason
    end

    def initialize(@source : String, @line_number : Int32, @context : Crystalline::CompletionContext, @query : Query)
    end

    def complete_or_reason : {Array(LSP::CompletionItem)?, String}
      if SourceMask.new(@source).comment_or_string?(@line_number, @context.analysis_column)
        return {nil, "cursor inside comment or string"}
      end

      case @context.trigger_character
      when "."
        items = complete_methods
        if items
          {items, items.empty? ? "no matching lightweight methods for receiver '#{receiver_expression}'" : "resolved"}
        else
          {nil, "could not resolve method receiver '#{receiver_expression}'"}
        end
      else
        items = complete_context_items
        if items
          {items, items.empty? ? "no matching context completions" : "resolved"}
        else
          {nil, "could not build context completions"}
        end
      end
    end

    private def complete_methods : Array(LSP::CompletionItem)?
      receiver = receiver_expression
      return if receiver.empty?

      type_names, class_method = resolve_receiver(receiver)
      return if type_names.empty?

      items = [] of LSP::CompletionItem
      seen = Set(String).new
      # One BFS per receiver type, then per-method hash lookups: ranking
      # per method with its own BFS made completion O(methods × scan).
      ranks = method_ranks(type_names)

      type_names.each do |type_name|
        methods = @query.methods_for(type_name, class_method: class_method)
        if Crystalline::Lightweight::Query.subtype_fallback_type?(type_name)
          # Hierarchy roots list the full surface of their subtypes so
          # `node.`-style completions on compiler AST bases offer the
          # accessors the base itself does not declare.
          methods = methods + @query.subtype_methods_for(type_name, class_method: class_method, include_macros: false)
        end
        methods.each do |method|
          # Keep overloads distinct. The key must include the args'
          # names, not just restrictions: `foo()` and `foo(x)` (an
          # untyped arg) both join to the same empty signature string,
          # which would silently drop one overload.
          args_signature = method.args.map { |arg| "#{arg.name}:#{arg.restriction}" }.join(",")
          key = "#{method.owner}:#{method.class_method}:#{method.name}(#{args_signature})"
          next if seen.includes?(key)
          seen << key
          items << method_completion_item(method, hierarchy_rank: ranks[method.owner]?)
        end
      end

      items
    end

    private def complete_context_items : Array(LSP::CompletionItem)?
      fragment = current_fragment
      items = [] of LSP::CompletionItem
      seen = Set(String).new

      if @context.trigger_character == "@"
        # The replace range now includes the sigil, so the fragment does
        # too: strip it before matching against the bare ivar names.
        fragment = fragment.lchop('@').lchop('@')
        inference = Inference.for(@source, @line_number + 1, @context.analysis_column + 1, @query)
        if inference
          inference.instance_var_types.each_key do |name|
            next unless name.lchop('@').starts_with?(fragment)
            next if seen.includes?(name)
            seen << name
            items << variable_completion_item(name, kind: LSP::CompletionItemKind::Field, detail: "#{name} : #{inference.types_for_instance_var(name).uniq.join(" | ")}", insert_text: name)
          end

          inference.class_var_types.each_key do |name|
            next unless name.lchop("@@").starts_with?(fragment)
            next if seen.includes?(name)
            seen << name
            items << variable_completion_item(name, kind: LSP::CompletionItemKind::Field, detail: "#{name} : #{inference.types_for_class_var(name).uniq.join(" | ")}", insert_text: name)
          end

          return items
        end

        # A lone `@` does not parse (the buffer may be mid-edit): fall back
        # to scanning ivar/class-var names in the source.
        return ivar_names_from_source(fragment)
      end

      if @context.trigger_character == ":" || fragment[0]?.try(&.ascii_uppercase?)
        if @context.trigger_character == ":"
          # The fixer may have appended a placeholder name after the `::`;
          # the user has not typed it, so match as if the fragment were empty.
          fragment = "" if fragment == "Placeholder"
          receiver = Resolver.receiver_from_prefix(@context.analysis_prefix).rchop("::")
          resolved = @query.find_type(receiver) || @query.resolve_type_name(receiver, namespace: nil)
          if resolved
            resolved_name = resolved.is_a?(String) ? resolved : resolved.name
            @query.subtypes_for(resolved_name).each do |type_name|
              short_name = type_name.split("::").last
              next unless short_name.starts_with?(fragment)
              next if seen.includes?(type_name)
              seen << type_name
              if type = @query.find_type(type_name)
                items << scoped_type_completion_item(type)
              else
                # Enum members and other constants are subtypes without
                # their own TypeInfo: offer a plain constant item.
                items << LSP::CompletionItem.new(
                  label: short_name,
                  kind: LSP::CompletionItemKind::EnumMember,
                  detail: resolved_name,
                  insert_text: short_name,
                )
              end
            end
            return items
          end
        end

        @query.all_types.each do |type|
          next unless type.name.split("::").last.starts_with?(fragment) || type.name.starts_with?(fragment)
          next if seen.includes?(type.name)
          seen << type.name
          items << type_completion_item(type)
        end
        return items
      end

      inference = Inference.for(@source, @line_number + 1, @context.analysis_column + 1, @query)

      if fragment.empty? || "self".starts_with?(fragment)
        items << variable_completion_item("self", kind: LSP::CompletionItemKind::Variable, detail: self_completion_detail(inference), insert_text: "self")
        seen << "self"
      end

      if inference
        inference.local_types.each do |name, type_names|
          next unless name.starts_with?(fragment)
          next if seen.includes?(name)
          seen << name
          items << variable_completion_item(name, detail: "#{name} : #{type_names.uniq.join(" | ")}")
        end

        # A bare identifier in a def body is a self-call: offer the current
        # type's own methods (class methods when in class context) so
        # `process` completes to `process_result`/`process_type`.
        if current_type = inference.current_type_name
          ranks = method_ranks([current_type])
          @query.methods_for(current_type, class_method: inference.class_method_context?).each do |method|
            next unless method.name.starts_with?(fragment)
            args_signature = method.args.map { |arg| "#{arg.name}:#{arg.restriction}" }.join(",")
            key = "#{method.owner}:#{method.class_method}:#{method.name}(#{args_signature})"
            next if seen.includes?(key)
            seen << key
            items << method_completion_item(method, hierarchy_rank: ranks[method.owner]?)
          end
        end
      end

      @query.top_level_methods.each do |method|
        next unless method.name.starts_with?(fragment)
        next if seen.includes?(method.name)
        seen << method.name
        items << method_completion_item(method)
      end

      items
    end

    private def resolve_receiver(receiver : String) : {Array(String), Bool}
      Resolver.receiver_types(@source, @line_number, @context.analysis_column, receiver, @query)
    end

    private def receiver_expression : String
      # The receiver may span lines: walk back over the whole source when
      # the single-line receiver suggests a block closer or a continuation
      # (see Resolver.receiver_from_line_prefix).
      Resolver.receiver_from_line_prefix(@source, @line_number, @context.analysis_prefix)
    end

    private def method_completion_item(method : MethodInfo, *, hierarchy_rank : Int32? = nil) : LSP::CompletionItem
      LSP::CompletionItem.new(
        label: format_method(method),
        insert_text: method.name,
        filter_text: method.name,
        detail: format_method(method, include_owner: true),
        kind: method.class_method ? LSP::CompletionItemKind::Function : LSP::CompletionItemKind::Method,
        # Closest-type-first: the hierarchy rank (0 = the receiver's own
        # methods) dominates, alphabetical order within the same rank.
        sort_text: hierarchy_rank ? "#{hierarchy_rank.to_s.rjust(3, '0')}:#{method.name}" : method.name,
        text_edit: LSP::TextEdit.new(
          range: @context.completion_range(@line_number),
          new_text: method.name,
        ),
        documentation: method.doc.try { |doc|
          LSP::MarkupContent.new(
            kind: LSP::MarkupKind::MarkDown,
            value: doc,
          )
        },
      )
    end

    # Owner ranks across the receiver types (min distance): own methods
    # rank 0, direct parents 1, and so on; owners that are not ancestors
    # (e.g. subtype-fallback surfaces) stay unranked so they keep the
    # plain-name sort_text and sort after the ranked hierarchy.
    private def method_ranks(type_names : Array(String)) : Hash(String, Int32)
      ranks = {} of String => Int32
      type_names.each do |type_name|
        @query.type_hierarchy_depths(type_name).each do |owner, depth|
          if (existing = ranks[owner]?).nil? || depth < existing
            ranks[owner] = depth
          end
        end
      end
      ranks
    end

    private def variable_completion_item(name : String, *, kind = LSP::CompletionItemKind::Variable, detail : String? = nil, insert_text : String = name) : LSP::CompletionItem
      LSP::CompletionItem.new(
        label: detail || name,
        insert_text: insert_text,
        filter_text: name,
        detail: detail,
        kind: kind,
        sort_text: name,
        text_edit: LSP::TextEdit.new(
          range: @context.completion_range(@line_number),
          new_text: insert_text,
        ),
      )
    end

    private def scoped_type_completion_item(type : TypeInfo) : LSP::CompletionItem
      short_name = type.name.split("::").last
      LSP::CompletionItem.new(
        label: type.name,
        insert_text: short_name,
        filter_text: short_name,
        detail: type.kind.to_s,
        kind: type_completion_kind(type.kind),
        sort_text: short_name,
        text_edit: LSP::TextEdit.new(
          range: @context.completion_range(@line_number),
          new_text: short_name,
        ),
        documentation: type.doc.try { |doc|
          LSP::MarkupContent.new(
            kind: LSP::MarkupKind::MarkDown,
            value: doc,
          )
        },
      )
    end

    private def type_completion_item(type : TypeInfo) : LSP::CompletionItem
      LSP::CompletionItem.new(
        label: type.name,
        insert_text: type.name,
        filter_text: type.name,
        detail: type.kind.to_s,
        kind: type_completion_kind(type.kind),
        sort_text: type.name,
        text_edit: LSP::TextEdit.new(
          range: @context.completion_range(@line_number),
          new_text: type.name,
        ),
        documentation: type.doc.try { |doc|
          LSP::MarkupContent.new(
            kind: LSP::MarkupKind::MarkDown,
            value: doc,
          )
        },
      )
    end

    private def self_completion_detail(inference : Inference?) : String?
      return unless inference

      type_names, class_method = inference.self_types
      return if type_names.empty?

      class_method ? "self : #{type_names.uniq.join(" | ")}.class" : "self : #{type_names.uniq.join(" | ")}"
    end

    # Best-effort ivar/class-var completion when the buffer does not parse.
    private def ivar_names_from_source(fragment : String) : Array(LSP::CompletionItem)
      items = [] of LSP::CompletionItem
      seen = Set(String).new
      @source.scan(/@@?[a-zA-Z_]\w*/).each do |match|
        name = match[0]
        next unless name.lchop('@').starts_with?(fragment) || name.lchop("@@").starts_with?(fragment)
        next if seen.includes?(name)
        seen << name
        items << variable_completion_item(name, kind: LSP::CompletionItemKind::Field, detail: name, insert_text: name)
      end
      items
    end

    private def current_fragment : String
      line = @source.lines(chomp: false)[@line_number]? || ""
      line[@context.replace_start...@context.replace_end]? || ""
    end

    private def format_method(method : MethodInfo, *, include_owner = false) : String
      args = method.args.map do |arg|
        if restriction = arg.restriction
          "#{arg.name} : #{restriction}"
        else
          arg.name
        end
      end.join(", ")

      signature = String.build do |str|
        if include_owner
          str << method.owner
          str << (method.class_method ? "." : "#")
        end

        str << method.name
        str << "(#{args})"
        str << " : #{method.return_type}" if method.return_type
      end

      signature
    end

    private def type_completion_kind(kind : TypeKind)
      case kind
      when .class?
        LSP::CompletionItemKind::Class
      when .module?
        LSP::CompletionItemKind::Module
      when .struct?
        LSP::CompletionItemKind::Struct
      when .enum?
        LSP::CompletionItemKind::Enum
      else
        LSP::CompletionItemKind::Class
      end
    end
  end
end
