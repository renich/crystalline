require "spec"
require "file_utils"
require "../src/crystalline/requires"
require "../src/crystalline/main"

private def with_workspace_document(source : String, &)
  root = File.join(Dir.tempdir, "crystalline-workspace-interactive-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)
  path = File.join(root, "src", "main.cr")
  Dir.mkdir_p(File.dirname(path))
  File.write(File.join(root, "shard.yml"), <<-YAML)
    name: workspace_interactive
    targets:
      workspace_interactive:
        main: src/main.cr
  YAML
  File.write(path, source)

  begin
    Crystalline::EnvironmentConfig.run
    server = LSP::Server.new(IO::Memory.new, IO::Memory.new)
    workspace = Crystalline::Workspace.new(server, "file://#{root}")
    uri = URI.parse("file://#{path}")
    workspace.opened_documents[uri.to_s] = Crystalline::TextDocument.new(uri, workspace.projects.first?, source)
    yield server, workspace, uri
  ensure
    FileUtils.rm_rf(root)
  end
end

class Crystalline::Workspace
  def send_lightweight_query_for_test(document : Crystalline::TextDocument)
    lightweight_query_for(document)
  end

  def semantic_cache_has_key?(key : String) : Bool
    @semantic_cache.has_key?(key)
  end

  def seed_semantic_result(key : String, result : Crystal::Compiler::Result)
    @semantic_cache[key] = result
  end

  def seed_compiled_source_mtime(path : String, time : Time)
    @compiled_source_mtimes[path] = time
  end

  def seed_result_cache(key : String, result : Crystal::Compiler::Result?)
    @result_cache.set(key, result)
  end

  def result_cache_invalidated?(key : String) : Bool
    @result_cache.invalidated?(key)
  end
end

module Crystalline::Analysis
  def self.stdlib_llvm_error_for_test?(e : Crystal::CodeError)
    stdlib_llvm_error?(e)
  end
end

private def mark_workspace_document_dirty(document : Crystalline::TextDocument, contents : String, version : Int32 = 1)
  document.update_contents([{contents, nil}], version: version)
end

describe Crystalline::Workspace do
  it "does not compile unsupported completion requests without a semantic cache" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      class Factory
        def build(name : String) : Greeter
          Greeter.new
        end
      end

      def demo(factory : Factory)
        factory.build("hi").unknown.sh
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      lines = source.lines(chomp: false)
      line_number = lines.index! { |line| line.includes?("factory.build(\"hi\").unknown.sh") }
      position = LSP::Position.new(line: line_number, character: lines[line_number].size - 1)

      workspace.completion(server, uri, position, nil).should be_nil
    end
  end

  it "does not compile unsupported hover requests without a semantic cache" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      class Factory
        def build(name : String) : Greeter
          Greeter.new
        end
      end

      def demo(factory : Factory)
        factory.build("hi").unknown.shout
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      lines = source.lines(chomp: false)
      line_number = lines.index! { |line| line.includes?("factory.build(\"hi\").unknown.shout") }
      character = lines[line_number].rindex!("shout") + 2
      position = LSP::Position.new(line: line_number, character: character)

      workspace.hover(server, uri, position).should be_nil
    end
  end

  it "uses lightweight definitions without a semantic cache" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(greeter : Greeter)
        greeter.shout
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      lines = source.lines(chomp: false)
      line_number = lines.index!(&.includes?("greeter.shout"))
      character = lines[line_number].rindex!("shout") + 2
      position = LSP::Position.new(line: line_number, character: character)

      definitions = workspace.definitions(server, uri, position)
      definitions.should_not be_nil
      definitions.not_nil!.size.should be > 0
    end
  end

  it "completes methods of project types before the first compile" do
    source = <<-CRYSTAL
      def demo
        helper = LocalHelper.new
        helper.
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      # A second project file that is only ever parsed, never compiled.
      root = workspace.projects.first?.not_nil!.root_uri.decoded_path
      File.write(Path[root, "src", "helper.cr"], <<-CRYSTAL)
        class LocalHelper
          def shout : String
            "!"
          end
        end
      CRYSTAL

      position = LSP::Position.new(line: 2, character: 15)
      items = workspace.completion(server, uri, position, nil)
      items.should_not be_nil
      items.not_nil!.items.map(&.insert_text).compact.should contain("shout")
    end
  end

  it "does not use stale semantic cache for dirty buffers" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(greeter : Greeter)
        greeter.shout
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      workspace.seed_semantic_result(project.entry_point?.not_nil!.to_s, result.not_nil!)

      workspace.opened_documents[uri.to_s].not_nil!.update_contents([
        {"sh", LSP::Range.new(
          start: LSP::Position.new(line: 6, character: 16),
          end: LSP::Position.new(line: 6, character: 21),
        )},
      ], version: 1)

      position = LSP::Position.new(line: 6, character: 18)
      workspace.hover(server, uri, position).should be_nil
      workspace.definitions(server, uri, position).should be_nil
      # Completion resolves the dirty buffer through the lightweight engine
      # (the "h" fragment matches nothing in the buffer's `gsh` parameter),
      # instead of falling back to the stale semantic cache.
      completion = workspace.completion(server, uri, position, nil).should_not be_nil
      completion.as(LSP::CompletionList).items.should be_empty
    end
  end

  it "uses summary-backed lightweight hover on dirty generic receiver chains" do
    source = <<-CRYSTAL
      def demo
        reply_channel = Channel(String).new
        reply_channel.receive.upcase
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      project.semantic_summary = Crystalline::Lightweight::Summary.from_result(result.not_nil!)

      mark_workspace_document_dirty(workspace.opened_documents[uri.to_s].not_nil!, source)

      lines = source.lines(chomp: false)
      line_number = lines.index! { |line| line.includes?("reply_channel.receive.upcase") }
      character = lines[line_number].rindex!("upcase") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil
      hover.not_nil!.contents.as(LSP::MarkupContent).value.should contain("String#upcase")
    end
  end

  it "uses current-source lightweight overlays for dirty file method hovers" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo
        greeter = Greeter.new
        greeter.shout
      end
    CRYSTAL

    dirty_source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end

        def whisper : String
          "."
        end
      end

      def demo
        greeter = Greeter.new
        greeter.whisper
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      project.semantic_summary = Crystalline::Lightweight::Summary.from_result(result.not_nil!)

      mark_workspace_document_dirty(workspace.opened_documents[uri.to_s].not_nil!, dirty_source)

      lines = dirty_source.lines(chomp: false)
      line_number = lines.index!(&.includes?("greeter.whisper"))
      character = lines[line_number].rindex!("whisper") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil
      hover.not_nil!.contents.as(LSP::MarkupContent).value.should contain("Greeter#whisper() : String")
    end
  end

  it "uses dirty-buffer hover for relative namespace tuple and try chains" do
    source = <<-CRYSTAL
      module Outer
        class Visitor
          def process : Tuple(Array(String), Hash(String, Tuple(String | Nil, Int32 | Nil)))
            {["hello"], {"key" => {nil, 1}}}
          end
        end

        def self.demo
          nodes, context = Visitor.new.process
          nodes.last?.try do |node|
            node.upcase
          end
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      project.semantic_summary = Crystalline::Lightweight::Summary.from_result(result.not_nil!)

      mark_workspace_document_dirty(workspace.opened_documents[uri.to_s].not_nil!, source)

      lines = source.lines(chomp: false)
      line_number = lines.index!(&.includes?("node.upcase"))
      character = lines[line_number].rindex!("upcase") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil
      hover.not_nil!.contents.as(LSP::MarkupContent).value.should contain("String#upcase")
    end
  end

  it "uses dirty-buffer hover through is_a? and conditional-assignment helper chains" do
    source = <<-CRYSTAL
      module Outer
        class Location
          def expanded_location : String
            "x"
          end
        end

        class Item
          def location : Outer::Location | Nil
            Outer::Location.new
          end
        end

        class Node
          def target_defs : Array(Outer::Item) | Nil
            [Outer::Item.new]
          end
        end

        def self.demo(node : Outer::Node | String)
          if node.is_a?(Outer::Node)
            if (defs = node.target_defs)
              defs.compact_map do |d|
                d.location.try do |loc|
                  loc.expanded_location.upcase
                end
              end
            end
          end
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      project.semantic_summary = Crystalline::Lightweight::Summary.from_result(result.not_nil!)

      mark_workspace_document_dirty(workspace.opened_documents[uri.to_s].not_nil!, source)

      lines = source.lines(chomp: false)
      line_number = lines.index! { |line| line.includes?("loc.expanded_location.upcase") }
      character = lines[line_number].rindex!("upcase") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil
      hover.not_nil!.contents.as(LSP::MarkupContent).value.should contain("String#upcase")
    end
  end

  it "uses dirty-buffer hover inside exception-handler bodies" do
    source = <<-CRYSTAL
      def demo
        reply_channel = Channel(String).new

        begin
          reply_channel.receive.upcase
        rescue error : Exception
          error.message
        ensure
          1
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      project.semantic_summary = Crystalline::Lightweight::Summary.from_result(result.not_nil!)

      mark_workspace_document_dirty(workspace.opened_documents[uri.to_s].not_nil!, source)

      lines = source.lines(chomp: false)
      line_number = lines.index! { |line| line.includes?("reply_channel.receive.upcase") }
      character = lines[line_number].rindex!("receive") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil
      hover.not_nil!.contents.as(LSP::MarkupContent).value.should contain("Channel(String)#receive()")
    end
  end

  it "uses dirty-buffer hover inside assigned begin-style value bodies" do
    source = <<-CRYSTAL
      def demo(items : Array(String))
        value = begin
          items.each do |item|
            item.upcase
          end
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      project.semantic_summary = Crystalline::Lightweight::Summary.from_result(result.not_nil!)

      mark_workspace_document_dirty(workspace.opened_documents[uri.to_s].not_nil!, source)

      lines = source.lines(chomp: false)
      line_number = lines.index!(&.includes?("item.upcase"))
      character = lines[line_number].rindex!("upcase") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil
      hover.not_nil!.contents.as(LSP::MarkupContent).value.should contain("String#upcase")
    end
  end

  it "gives non-dependency files lightweight project context" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      workspace.recalculate_dependencies(server, project)

      # A second file inside the project root that the entry point does not
      # require: it must still resolve project types in lightweight queries.
      scratch_path = File.join(File.dirname(uri.decoded_path), "scratch.cr")
      scratch_uri = URI.parse("file://#{scratch_path}")
      scratch_document = Crystalline::TextDocument.new(scratch_uri, nil, "greeter = Greeter.new\ngreeter.shout\n")
      workspace.opened_documents[scratch_uri.to_s] = scratch_document

      query = workspace.send_lightweight_query_for_test(scratch_document).should_not be_nil
      query.not_nil!.find_type("Greeter").should_not be_nil
    end
  end

  it "returns an empty list for resolved-but-empty lightweight completions" do
    source = <<-CRYSTAL
      class Greeter
        def demo
          @zzz
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      document = workspace.opened_documents[uri.to_s].not_nil!
      mark_workspace_document_dirty(document, source)

      lines = source.lines(chomp: false)
      line_number = lines.index!(&.includes?("@zzz"))
      character = lines[line_number].size - 1
      position = LSP::Position.new(line: line_number, character: character)

      # The engine resolves the request but finds no matching ivars: the
      # client must get a real (empty) list, not a fallthrough to nil.
      result = workspace.completion(server, uri, position, "@")
      result.should_not be_nil
      result = result.as(LSP::CompletionList)
      result.items.should be_empty
      result.is_incomplete.should be_false
    end
  end

  it "exposes lightweight miss reasons for dirty-buffer interactive requests" do
    # The prelude (stdlib surface) loads asynchronously once in the
    # process: load it deterministically so this spec behaves the same
    # whether it runs first or after the lightweight suite.
    Crystalline::Lightweight::PreludeIndex.ensure_loaded
    until Crystalline::Lightweight::PreludeIndex.get
      sleep 50.milliseconds
    end

    source = <<-CRYSTAL
      def demo(items : Array(String))
        items.unknown_method
      end
    CRYSTAL

    with_workspace_document(source) do |_server, workspace, uri|
      workspace.opened_documents[uri.to_s].not_nil!.update_contents([{source, nil}], version: 1)
      fixed_source = workspace.opened_documents[uri.to_s].not_nil!.contents
      lines = fixed_source.lines(chomp: false)
      line_number = lines.index!(&.includes?("items.unknown_method"))
      character = lines[line_number].rindex!("unknown_method") + 2
      completion_context = Crystalline::CompletionContext.detect(lines[line_number], character, ".").not_nil!
      query = workspace.send_lightweight_query_for_test(workspace.opened_documents[uri.to_s].not_nil!).not_nil!

      Crystalline::Lightweight::Hover.diagnose(fixed_source, line_number, character, query).should contain("no lightweight method hover")
      Crystalline::Lightweight::Definitions.diagnose(fixed_source, uri, line_number, character, query).should contain("no lightweight method definitions")
      # With the prelude layered under the project source, `items` (an
      # `Array(String)`) resolves to the full stdlib method list: the
      # completion itself is not a miss, only the unknown method is.
      Crystalline::Lightweight::Completion.diagnose(fixed_source, line_number, completion_context, query).should contain("resolved")
    end
  end

  it "rebuilds lightweight queries when the document changes" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      workspace.recalculate_dependencies(server, workspace.projects.first?.not_nil!)

      document = workspace.opened_documents[uri.to_s].not_nil!
      first_query = workspace.send_lightweight_query_for_test(document).not_nil!

      # A second request with the same contents is served from the cache.
      workspace.send_lightweight_query_for_test(document).should be(first_query)

      document.update_contents([{source.sub("def shout", "def shouter"), nil}], version: 1)

      # After the change the query is rebuilt from the new buffer.
      workspace.send_lightweight_query_for_test(document).should_not be(first_query)
    end
  end

  it "filters error-tolerant artifacts from the stdlib llvm wrapper" do
    llvm_error = Crystal::TypeException.new(
      "bogus conversion",
      Crystal::Location.new("/home/linuxbrew/.linuxbrew/Cellar/crystal/1.21.0/share/crystal/src/llvm/di_builder.cr", 99, 13),
    )
    user_error = Crystal::TypeException.new(
      "real error",
      Crystal::Location.new("/home/user/project/src/main.cr", 1, 1),
    )

    Crystalline::Analysis.stdlib_llvm_error_for_test?(llvm_error).should be_true
    Crystalline::Analysis.stdlib_llvm_error_for_test?(user_error).should be_false
  end

  it "invalidates the result cache on save even when dependency lookup no longer matches" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      entry_point = project.entry_point?.not_nil!
      result = Crystalline::Analysis.compile(
        server,
        entry_point,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil

      workspace.seed_result_cache(entry_point.to_s, result)
      workspace.seed_semantic_result(entry_point.to_s, result.not_nil!)
      workspace.result_cache_invalidated?(entry_point.to_s).should be_false
      workspace.semantic_cache_has_key?(entry_point.to_s).should be_true

      project.dependencies = Set{entry_point.decoded_path}

      workspace.save_document(
        server,
        LSP::DidSaveTextDocumentParams.new(
          text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
        ),
      )

      workspace.result_cache_invalidated?(entry_point.to_s).should be_true
      # The semantic cache is deliberately kept across edits (it is guarded
      # by the compiled-source freshness check instead).
      workspace.semantic_cache_has_key?(entry_point.to_s).should be_true
    end
  end

  it "keeps serving the last successful compile for clean buffers after an edit" do
    source = <<-CRYSTAL
      def demo(message : LSP::NotificationMessage)
        message.params
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      workspace.seed_semantic_result(project.entry_point?.not_nil!.to_s, result.not_nil!)

      # Edit the buffer, then save it: the buffer is clean again and the
      # last successful compile must still serve the fallback.
      workspace.update_document(
        server,
        LSP::DidChangeTextDocumentParams.new(
          text_document: LSP::VersionedTextDocumentIdentifier.new(uri: uri.to_s, version: 2),
          content_changes: [
            LSP::DidChangeTextDocumentParams::TextDocumentContentChangeEvent.new(
              range: LSP::Range.new(
                start: LSP::Position.new(line: 1, character: 4),
                end: LSP::Position.new(line: 1, character: 4),
              ),
              text: " ",
            ),
          ],
        ),
      )
      workspace.save_document(
        server,
        LSP::DidSaveTextDocumentParams.new(
          text_document: LSP::TextDocumentIdentifier.new(uri: uri.to_s),
        ),
      )

      lines = source.lines(chomp: false)
      line_number = lines.index!(&.includes?("message.params"))
      character = lines[line_number].rindex!("params") + 2
      hover = workspace.hover(server, uri, LSP::Position.new(line: line_number, character: character))
      hover.should_not be_nil
    end
  end

  it "does not serve the semantic cache for files changed on disk after the compile" do
    source = <<-CRYSTAL
      def demo(message : LSP::NotificationMessage)
        message.params
      end
    CRYSTAL

    with_workspace_document(source) do |server, workspace, uri|
      project = workspace.projects.first?.not_nil!
      result = Crystalline::Analysis.compile(
        server,
        uri,
        lib_path: project.default_lib_path,
        ignore_diagnostics: true,
        wants_doc: true,
        compiler_flags: project.flags,
      )
      result.should_not be_nil
      workspace.seed_semantic_result(project.entry_point?.not_nil!.to_s, result.not_nil!)
      workspace.seed_compiled_source_mtime(uri.decoded_path, File.info(uri.decoded_path).modification_time)

      lines = source.lines(chomp: false)
      line_number = lines.index!(&.includes?("message.params"))
      character = lines[line_number].rindex!("params") + 2
      position = LSP::Position.new(line: line_number, character: character)

      hover = workspace.hover(server, uri, position)
      hover.should_not be_nil

      # The file changes on disk without a compile: the stale cache must
      # refuse to serve it.
      File.touch(uri.decoded_path)
      workspace.hover(server, uri, position).should be_nil
    end
  end
end
