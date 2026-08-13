require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/broken_source_fixer"
require "../../src/crystalline/lightweight/query"
require "../../src/crystalline/lightweight/definitions"
require "../../src/crystalline/lightweight/completion"
require "../../src/crystalline/completion_context"
require "uri"

private def fix_parses(source : String)
  fixed = Crystalline::BrokenSourceFixer.fix(source)
  Crystal::Parser.parse(fixed)
  fixed
end

private def prelude_index : Crystalline::Lightweight::Index
  Crystalline::Lightweight::PreludeIndex.ensure_loaded
  until (index = Crystalline::Lightweight::PreludeIndex.get)
    sleep 50.milliseconds
  end
  index
end

private def syntax_query(source : String)
  index = Crystalline::Lightweight::Index.from_source(source)
  raise "expected syntax index" unless index
  Crystalline::Lightweight::Query.new(index, secondary: prelude_index)
end

describe "lightweight edge cases" do
  it "fixes a trailing dot inside a string interpolation" do
    source = <<-CRYSTAL
      def demo
        "\#{foo.}"
      end
    CRYSTAL
    fixed = fix_parses(source)
    Crystal::Parser.parse(fixed)
  end

  it "fixes a trailing dot after a method call with nested closers" do
    source = <<-CRYSTAL
      class Demo
        def run
          factory.build("hi").
        end
      end
    CRYSTAL
    fixed = fix_parses(source)
    fixed.should contain("placeholder")
  end

  it "keeps regex literals with parens intact when counting closers" do
    source = <<-CRYSTAL
      def demo
        text = "a(b"
        if text =~ /\\(/
          puts "matched"
        end
        text.
      end
    CRYSTAL
    fixed = fix_parses(source)
    fixed.should contain("placeholder")
  end

  it "definitions resolve a method through a multi-line receiver" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo
        greeter = Greeter.new
        greeter
          .shout
      end
    CRYSTAL
    query = syntax_query(source)
    uri = URI.parse("file:///tmp/demo.cr")
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.strip == ".shout" }
    character = lines[line_number].index("shout").not_nil! + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, uri, line_number, character, query)
    locations.should_not be_nil
  end

  it "completes a method through a multi-line receiver" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo
        greeter = Greeter.new
        greeter
          .shou
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?(".shou") }
    line = lines[line_number]
    cursor = line.index("shou").not_nil! + 4
    context = Crystalline::CompletionContext.detect(line, cursor, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("shout")
  end

  it "definitions resolve a require to a real file" do
    Crystalline::EnvironmentConfig.run
    source = %(require "uri"\n)
    query = syntax_query("class A\nend\n")
    uri = URI.parse("file:///tmp/def_require.cr")
    # Cursor on the string content.
    locations = Crystalline::Lightweight::Definitions.definitions(source, uri, 0, 10, query)
    locations.should_not be_nil
    locations.not_nil!.first.uri.should contain("uri.cr")
  end

  it "resolves methods on stdlib receivers from the prelude" do
    query = syntax_query("class A\nend\n")
    names = query.methods_for("String").map(&.name)
    names.should contain("upcase")
    names.should contain("split")
    names.should contain("size")
  end

  it "completes chained stdlib methods through locals" do
    source = <<-CRYSTAL
      def demo
        names = %w(a b c)
        names.map(&.upcase).fi
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?(".fi") }
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    names = items.not_nil!.map(&.insert_text).compact
    names.should contain("first?")
    names.should contain("find")
  end

  it "resolves hash receivers through [] lookups" do
    source = <<-CRYSTAL
      def demo
        lookup = {} of String => Int32
        lookup["x"].to_
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?(".to_") }
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    names = items.not_nil!.map(&.insert_text).compact
    names.should contain("to_s")
    names.should contain("to_i32")
  end

  it "resolves proc-typed locals through uninitialized declarations" do
    source = <<-CRYSTAL
      def demo
        walker = uninitialized Proc(Int32, String)
        walker.ca
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?("walker.ca") }
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("call")
  end

  it "narrows case subjects by when-types" do
    source = <<-CRYSTAL
      class Node
        def accept(v)
        end
      end

      class DefNode < Node
        def name : String
          ""
        end
      end

      def demo(node : Node)
        case node
        when DefNode
          node.na
        end
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.strip == "node.na" }
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("name")
  end

  it "resolves range-slice receivers as the array, not the element" do
    source = <<-CRYSTAL
      def demo
        arr = [1, 2, 3]
        arr[1..].fi
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?(".fi") }
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    # A slice returns the array: `first?`/`find` belong to the array, not
    # to its Int32 element.
    names = items.not_nil!.map(&.insert_text).compact
    names.should contain("first?")
    names.should contain("find")
  end

  it "resolves try-chains through nilable receivers" do
    source = <<-CRYSTAL
      class Config
        def value : String?
          "x"
        end
      end

      def demo(config : Config)
        config.value.try(&.upca)
      end
    CRYSTAL
    query = syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?(".upca") }
    line = lines[line_number]
    cursor = line.index(".upca").not_nil! + 4
    context = Crystalline::CompletionContext.detect(line, cursor, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("upcase")
  end
end
