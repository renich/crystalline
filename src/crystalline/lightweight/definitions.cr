require "lsp/server"
require "compiler/crystal/syntax"
require "../source_mask"
require "./query"
require "./resolver"

module Crystalline::Lightweight
  class Definitions
    record TypeDefInfo, name : String, location : Crystal::Location?, name_location : Crystal::Location?, name_size : Int32
    record DefInfo, owner : String?, definition : Crystal::Def, class_method : Bool

    def self.definitions(source : String, file_uri : URI, line_number : Int32, column_number : Int32, query : Query?) : Array(LSP::Location)?
      definitions_and_reason(source, file_uri, line_number, column_number, query)[0]
    end

    def self.diagnose(source : String, file_uri : URI, line_number : Int32, column_number : Int32, query : Query?) : String
      definitions_and_reason(source, file_uri, line_number, column_number, query)[1]
    end

    # Computes the definitions and their miss reason in a single pass, so
    # that workspace logging does not double the cost of a miss.
    def self.definitions_and_reason(source : String, file_uri : URI, line_number : Int32, column_number : Int32, query : Query?) : {Array(LSP::Location)?, String}
      new(source, file_uri, line_number, column_number, query).definitions_or_reason
    end

    def initialize(@source : String, @file_uri : URI, @line_number : Int32, @column_number : Int32, @query : Query?)
    end

    def definitions_or_reason : {Array(LSP::Location)?, String}
      line = @source.lines(chomp: false)[@line_number]?
      return {nil, "no line at cursor"} unless line

      # `require "uri"` — jump to the required file.
      if (require_match = line.match(/\A\s*require\s+["']([^"']+)["']/))
        string_start = line.index(require_match[1]).not_nil!
        string_end = string_start + require_match[1].size
        if @column_number >= string_start && @column_number <= string_end
          if locations = locations_for_require(require_match[1])
            return {locations, "resolved require"}
          end
          return {nil, "no lightweight require definition for '#{require_match[1]}'"}
        end
      end

      span = Resolver.token_span(line, @column_number)
      return {nil, "no token at cursor"} unless span

      start_index, end_index = span
      if SourceMask.new(@source).comment_or_string?(@line_number, start_index)
        return {nil, "token inside comment or string"}
      end

      token = line[start_index, end_index - start_index]?
      return {nil, "empty token at cursor"} unless token && !token.empty?

      if start_index > 0 && line[start_index - 1] == '.'
        receiver = Resolver.receiver_from_line_prefix(@source, @line_number, line[0, start_index - 1])
        return {nil, "missing query for method definitions"} unless query = @query
        definitions = locations_for_method(receiver, token, start_index - 1, query)
        return {definitions, definitions ? "resolved" : "no lightweight method definitions for receiver '#{receiver}' and method '#{token}'"}
      end

      if Resolver.type_name?(token)
        definitions = locations_for_type(token)
        return {definitions, definitions ? "resolved" : "no lightweight type definition for '#{token}'"}
      end

      if Resolver.instance_var_name?(token) || Resolver.class_var_name?(token)
        definitions = locations_for_instance_var(token)
        return {definitions, definitions ? "resolved" : "no lightweight ivar definition for '#{token}'"}
      end

      if Resolver.local_name?(token)
        # A local jumps to its declaration (the enclosing def's argument
        # or the assignment that defines it), which is what hover types
        # for the same token.
        if location = visit_local_declarations(parsed_ast, token, @line_number)
          end_location = Crystal::Location.new(
            location.filename,
            location.line_number,
            location.column_number + token.size - 1,
          )
          return {[lsp_location(location, end_location)], "resolved local"}
        end

        # A bare method name may be a self-call: resolve it against the
        # enclosing type before falling back to top-level methods.
        if query = @query
          if inference = Inference.for(@source, @line_number + 1, @column_number + 1, query)
            if type_names = inference.self_types[0]?
              unless type_names.empty?
                method_infos = type_names.flat_map do |type_name|
                  query.methods_for(type_name, class_method: inference.class_method_context?).select(&.name.==(token))
                end
                if locations = build_method_locations(method_infos)
                  return {locations, "resolved self-call"}
                end
              end
            end
          end
        end

        definitions = locations_for_top_level_method(token)
        return {definitions, definitions ? "resolved" : "no lightweight top-level method definition for '#{token}'"}
      end

      {nil, "unsupported definitions token '#{token}'"}
    end

    private def locations_for_method(receiver : String, method_name : String, analysis_column : Int32, query : Query) : Array(LSP::Location)?
      type_names, class_method = Resolver.receiver_types(@source, @line_number, analysis_column, receiver, query)
      return if type_names.empty?

      method_infos = type_names.flat_map do |type_name|
        # methods_named falls back to the subtypes of compiler hierarchy
        # roots, so `node.name` on an `ASTNode` receiver jumps to `Var#name`.
        found = query.methods_named(type_name, method_name, class_method: class_method)
        if found.empty? && !method_name.ends_with?("=")
          # Assignment targets hover the setter (`parser.filename` matches
          # the `filename=` def): jump to it the same way.
          found = query.methods_named(type_name, "#{method_name}=", class_method: class_method)
        end
        found
      end
      locations = build_method_locations(method_infos)
      return locations if locations

      matches = def_infos.select do |info|
        type_names.includes?(info.owner) && info.class_method == class_method && info.definition.name == method_name
      end
      build_locations(matches.map(&.definition))
    end

    private def locations_for_type(type_name : String) : Array(LSP::Location)?
      # Resolve the token against the enclosing namespace first, so a bare
      # `Workspace` inside `Crystalline::Controller` jumps to the type's
      # indexed definition in another file.
      if query = @query
        if inference = Inference.for(@source, @line_number + 1, @column_number + 1, query)
          if resolved = query.resolve_type_name(type_name, namespace: inference.current_type_name)
            if type_info = query.find_type(resolved)
              if start_location = type_info.location
                infos = [
                  TypeDefInfo.new(
                    resolved,
                    start_location,
                    type_info.name_location || start_location,
                    resolved.split("::").last.size,
                  ),
                ]
                return build_type_locations(infos)
              end
            end
          end
        end
      end

      matches = type_defs.select do |info|
        info.name == type_name || info.name.split("::").last == type_name
      end
      build_type_locations(matches)
    end

    # Jumps to the ivar/class-var declaration in this file (`@server : T`,
    # or the `@server` shorthand argument of initialize). When the variable
    # is never declared, falls back to the definition of its type, which is
    # what hover shows.
    private def locations_for_instance_var(var_name : String) : Array(LSP::Location)?
      if location = visit_ivar_declarations(parsed_ast, var_name)
        end_location = Crystal::Location.new(
          location.filename,
          location.line_number,
          location.column_number + var_name.size - 1,
        )
        return [lsp_location(location, end_location)]
      end

      if query = @query
        if inference = Inference.for(@source, @line_number + 1, @column_number + 1, query)
          type_names = if Resolver.class_var_name?(var_name)
                         inference.types_for_class_var(var_name)
                       else
                         inference.types_for_instance_var(var_name)
                       end
          type_names = type_names.reject(&.==("Nil"))
          if type_names.size == 1
            if locations = locations_for_type(type_names.first)
              return locations
            end
          end
        end
      end

      nil
    end

    private def visit_ivar_declarations(node : Crystal::ASTNode, var_name : String) : Crystal::Location?
      case node
      when Crystal::Expressions
        node.expressions.each do |expression|
          if location = visit_ivar_declarations(expression, var_name)
            return location
          end
        end
      when Crystal::ClassDef, Crystal::ModuleDef
        return visit_ivar_declarations(node.body, var_name)
      when Crystal::Def
        # The `@server` shorthand in `def initialize(@server : T)` parses as
        # an arg named "server" plus a leading `@server = server` assignment
        # in the body; the declaration is the signature argument itself.
        if var_name.starts_with?('@')
          body = node.body
          body_expressions = case body
                             when Crystal::Expressions then body.expressions
                             else                           [body]
                             end
          body_expressions.each do |expression|
            next unless expression.is_a?(Crystal::Assign)
            target = expression.target
            next unless target.is_a?(Crystal::InstanceVar) && target.name == var_name
            if arg = node.args.find(&.name.==(var_name.lchop('@')))
              return arg.location
            end
          end
        end
        return visit_ivar_declarations(node.body, var_name)
      when Crystal::TypeDeclaration
        case var = node.var
        when Crystal::InstanceVar, Crystal::ClassVar
          return node.location if var.name == var_name
        end
      when Crystal::Assign
        # An ivar that is never declared (e.g. `@workspace = Workspace.new`)
        # is defined by its first assignment.
        case target = node.target
        when Crystal::InstanceVar, Crystal::ClassVar
          return target.location if target.name == var_name
        end
      end
      nil
    end

    private def locations_for_top_level_method(method_name : String) : Array(LSP::Location)?
      if query = @query
        method_locations = build_method_locations(query.top_level_methods.select(&.name.==(method_name)))
        return method_locations if method_locations
      end

      matches = def_infos.select do |info|
        info.owner.nil? && info.definition.name == method_name
      end
      build_locations(matches.map(&.definition))
    end

    # Resolves a `require "path"` to the required file, relative to the
    # requiring file first, then through the crystal path (lib + stdlib).
    private def locations_for_require(require_name : String) : Array(LSP::Location)?
      candidates = [] of String
      file_dir = File.dirname(@file_uri.decoded_path)
      if require_name.starts_with?("./") || require_name.starts_with?("../")
        candidates << File.expand_path(require_name, file_dir)
        candidates << File.join(File.expand_path(File.dirname(require_name), file_dir), "#{File.basename(require_name)}.cr")
      else
        (Crystal::CrystalPath.default_paths + [file_dir]).each do |base|
          candidates << File.join(base, "#{require_name}.cr")
          candidates << File.join(base, require_name, "#{File.basename(require_name)}.cr")
          # Shard layout: `require "foo"` resolves to `lib/foo/src/foo.cr`.
          candidates << File.join(base, require_name, "src", "#{File.basename(require_name)}.cr")
        end
      end

      if path = candidates.find { |candidate| File.exists?(candidate) }
        location = Crystal::Location.new(File.expand_path(path), 1, 1)
        return [lsp_location(location, location)]
      end
      nil
    end

    # The declaration of a local: the enclosing def's argument, or a
    # block parameter whose block contains the cursor, else the first
    # assignment to it in the def's body. Top-level code has no enclosing
    # def — assignments anywhere qualify.
    private def visit_local_declarations(node : Crystal::ASTNode, name : String, line : Int32) : Crystal::Location?
      if definition = enclosing_def(node, line)
        # Body first: a block parameter shadows the def's argument when
        # the cursor sits inside the block.
        if location = visit_local_assignments(definition.body, name, line)
          return location
        end
        return definition.args.find(&.name.==(name)).try(&.location)
      end
      visit_local_assignments(node, name, line)
    end

    private def enclosing_def(node : Crystal::ASTNode, line : Int32) : Crystal::Def?
      case node
      when Crystal::Expressions
        node.expressions.each do |expression|
          if found = enclosing_def(expression, line)
            return found
          end
        end
      when Crystal::ClassDef, Crystal::ModuleDef
        return enclosing_def(node.body, line)
      when Crystal::Def
        return node if span_contains_line?(node, line)
      end
      nil
    end

    private def span_contains_line?(node : Crystal::ASTNode, line : Int32) : Bool
      start_line = node.location.try(&.line_number)
      return false unless start_line && start_line <= line
      end_line = node.end_location.try(&.line_number)
      end_line.nil? || line <= end_line
    end

    private def visit_local_assignments(node : Crystal::ASTNode?, name : String, line : Int32) : Crystal::Location?
      node || return
      case node
      when Crystal::Expressions
        node.expressions.each do |expression|
          if location = visit_local_assignments(expression, name, line)
            return location
          end
        end
      when Crystal::If
        if location = visit_local_assignments(node.then, name, line)
          return location
        end
        visit_local_assignments(node.else, name, line)
      when Crystal::Unless
        if location = visit_local_assignments(node.then, name, line)
          return location
        end
        visit_local_assignments(node.else, name, line)
      when Crystal::While, Crystal::Until
        visit_local_assignments(node.body, name, line)
      when Crystal::Case
        node.whens.each do |when_node|
          if location = visit_local_assignments(when_node.body, name, line)
            return location
          end
        end
        visit_local_assignments(node.else, name, line)
      when Crystal::ExceptionHandler
        if location = visit_local_assignments(node.body, name, line)
          return location
        end
        if node.rescues
          node.rescues.not_nil!.each do |rescue_node|
            if location = visit_local_assignments(rescue_node.body, name, line)
              return location
            end
          end
        end
        visit_local_assignments(node.else, name, line)
      when Crystal::Block
        # A block parameter is a declaration only when the block contains
        # the cursor — otherwise the name refers to an outer local.
        if span_contains_line?(node, line)
          if arg = node.args.find(&.name.==(name))
            return arg.location
          end
        end
        visit_local_assignments(node.body, name, line)
      when Crystal::Call
        if block = node.block
          if location = visit_local_assignments(block, name, line)
            return location
          end
        end
        node.args.each do |arg|
          if location = visit_local_assignments(arg, name, line)
            return location
          end
        end
        nil
      when Crystal::Assign
        if target_location = assignment_target_location(node.target, name)
          return target_location
        end
        visit_local_assignments(node.value, name, line)
      when Crystal::OpAssign
        assignment_target_location(node.target, name)
      when Crystal::MultiAssign
        node.targets.each do |target|
          if target_location = assignment_target_location(target, name)
            return target_location
          end
        end
        nil
      when Crystal::TypeDeclaration
        assignment_target_location(node.var, name)
      else
        nil
      end
    end

    private def assignment_target_location(target : Crystal::ASTNode, name : String) : Crystal::Location?
      case target
      when Crystal::Var
        target.location if target.name == name
      when Crystal::TupleLiteral
        # `(a, b) = tuple` destructures into a tuple of Vars.
        target.elements.each do |element|
          if location = assignment_target_location(element, name)
            return location
          end
        end
        nil
      else
        nil
      end
    end

    private def build_method_locations(methods : Array(MethodInfo)) : Array(LSP::Location)?
      locations = methods.compact_map do |method|
        start_location = method.name_location || method.location
        next unless start_location

        name_size = method.name_size.zero? ? method.name.size : method.name_size
        end_location = Crystal::Location.new(
          start_location.filename,
          start_location.line_number,
          start_location.column_number + name_size - 1,
        )

        lsp_location(start_location, end_location)
      end

      locations.empty? ? nil : locations
    end

    private def build_locations(definitions : Array(Crystal::Def)) : Array(LSP::Location)?
      locations = definitions.compact_map do |definition|
        name_location = definition.name_location || definition.location
        next unless name_location

        end_location = Crystal::Location.new(
          name_location.filename,
          name_location.line_number,
          name_location.column_number + definition.name.size - 1,
        )

        lsp_location(name_location, end_location)
      end

      locations.empty? ? nil : locations
    end

    private def build_type_locations(type_infos : Array(TypeDefInfo)) : Array(LSP::Location)?
      locations = type_infos.compact_map do |info|
        start_location = info.name_location || info.location
        next unless start_location

        end_location = Crystal::Location.new(
          start_location.filename,
          start_location.line_number,
          start_location.column_number + info.name_size - 1,
        )

        lsp_location(start_location, end_location)
      end

      locations.empty? ? nil : locations
    end

    private def lsp_location(start_location : Crystal::Location, end_location : Crystal::Location) : LSP::Location
      LSP::Location.new(
        uri: "file://#{start_location.original_filename}",
        range: LSP::Range.new(
          start: LSP::Position.new(line: start_location.line_number - 1, character: start_location.column_number - 1),
          end: LSP::Position.new(line: end_location.line_number - 1, character: end_location.column_number),
        ),
      )
    end

    private def def_infos : Array(DefInfo)
      infos = [] of DefInfo
      visit_defs(parsed_ast, infos)
      infos
    end

    private def visit_defs(node : Crystal::ASTNode, infos : Array(DefInfo), namespace : String? = nil)
      case node
      when Crystal::Expressions
        node.expressions.each { |expression| visit_defs(expression, infos, namespace) }
      when Crystal::ClassDef
        visit_defs(node.body, infos, qualify_type_name(node.name.to_s, namespace))
      when Crystal::ModuleDef
        visit_defs(node.body, infos, qualify_type_name(node.name.to_s, namespace))
      when Crystal::Def
        infos << DefInfo.new(owner: namespace, definition: node, class_method: !node.receiver.nil?)
      end
    end

    private def type_defs : Array(TypeDefInfo)
      infos = [] of TypeDefInfo
      visit_type_defs(parsed_ast, infos)
      infos
    end

    private def visit_type_defs(node : Crystal::ASTNode, infos : Array(TypeDefInfo), namespace : String? = nil)
      case node
      when Crystal::Expressions
        node.expressions.each { |expression| visit_type_defs(expression, infos, namespace) }
      when Crystal::ClassDef
        type_name = qualify_type_name(node.name.to_s, namespace)
        infos << TypeDefInfo.new(type_name, node.location, node.name_location, node.name.to_s.size)
        visit_type_defs(node.body, infos, type_name)
      when Crystal::ModuleDef
        type_name = qualify_type_name(node.name.to_s, namespace)
        infos << TypeDefInfo.new(type_name, node.location, node.name_location, node.name.to_s.size)
        visit_type_defs(node.body, infos, type_name)
      when Crystal::EnumDef
        type_name = qualify_type_name(node.name.to_s, namespace)
        infos << TypeDefInfo.new(type_name, node.location, node.name_location, node.name.to_s.size)
      when Crystal::AnnotationDef
        type_name = qualify_type_name(node.name.to_s, namespace)
        infos << TypeDefInfo.new(type_name, node.location, node.name_location, node.name.to_s.size)
      end
    end

    # A single definitions request can walk defs, type defs and ivar
    # declarations: parse the source once and reuse the AST.
    @parsed_ast : Crystal::ASTNode? = nil

    private def parsed_ast : Crystal::ASTNode
      @parsed_ast ||= begin
        parser = Crystal::Parser.new(@source)
        parser.wants_doc = false
        parser.filename = @file_uri.decoded_path
        parser.parse
      end
    end

    private def qualify_type_name(name : String, namespace : String?) : String
      return name if namespace.nil? || name.includes?("::")
      "#{namespace}::#{name}"
    end
  end
end
