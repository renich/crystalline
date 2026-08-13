require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/lightweight/query"
require "../../src/crystalline/lightweight/inference"

private def build_lightweight_index(source : String)
  path = File.join(Dir.tempdir, "crystalline-lightweight-inference-#{Random::Secure.hex(8)}.cr")
  File.write(path, source)

  begin
    Crystalline::EnvironmentConfig.run
    server = LSP::Server.new(IO::Memory.new, IO::Memory.new)
    result = Crystalline::Analysis.compile(
      server,
      URI.parse("file://#{path}"),
      lib_path: File.join(Dir.current, "lib"),
      top_level: true,
      ignore_diagnostics: true,
    )
    raise "expected top-level semantic result" unless result
    Crystalline::Lightweight::Index.from_program(result.program)
  ensure
    File.delete(path) if File.exists?(path)
  end
end

private def prelude_index : Crystalline::Lightweight::Index
  Crystalline::Lightweight::PreludeIndex.ensure_loaded
  until (index = Crystalline::Lightweight::PreludeIndex.get)
    sleep 50.milliseconds
  end
  index
end

describe Crystalline::Lightweight::Inference do
  it "infers argument restrictions and simple literal assignments before the cursor" do
    index = build_lightweight_index <<-CRYSTAL
      class Foo
      end

      def top_level(value : Bool) : Int32
        value ? 1 : 0
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo(x : Int32)
        message = "hello"
        enabled = true
        amount = 1
        thing = Foo.new
        total = top_level(enabled)
        amount
      end
    CRYSTAL

    inference = Crystalline::Lightweight::Inference.for(
      source,
      7,
      14,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("x").should eq(["Int32"])
    inference.types_for("message").should eq(["String"])
    inference.types_for("enabled").should eq(["Bool"])
    inference.types_for("amount").should eq(["Int32"])
    inference.types_for("thing").should eq(["Foo"])
    inference.types_for("total").should eq(["Int32"])
  end

  it "infers self and instance variables from the enclosing type" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      class Wrapper
        def hello : String
          "hi"
        end
      end
    CRYSTAL

    source = <<-CRYSTAL
      class Wrapper
        def initialize
          @greeter = Greeter.new
        end

        def demo
          current = self
          @greeter.shout
          current.hello
        end

        def hello : String
          "hi"
        end
      end
    CRYSTAL

    inference = Crystalline::Lightweight::Inference.for(
      source,
      8,
      12,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.self_types.should eq({["Wrapper"], false})
    inference.types_for("current").should eq(["Wrapper"])
    inference.types_for_instance_var("@greeter").should eq(["Greeter"])
  end

  it "merges conditional branch assignments into union-like local types" do
    index = build_lightweight_index <<-CRYSTAL
      class Foo
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo(flag : Bool)
        value = 1

        if flag
          item = Foo.new
          value = "hello"
        else
          item = 1
        end

        item
        value
      end
    CRYSTAL

    inference = Crystalline::Lightweight::Inference.for(
      source,
      11,
      8,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("item").sort.should eq(["Foo", "Int32"])
    inference.types_for("value").sort.should eq(["Int32", "String"])
  end

  it "expands union restrictions and explicit return types into individual names" do
    index = build_lightweight_index <<-CRYSTAL
      class Foo
      end

      class Bar
      end

      def maybe_item : Foo | Bar | Nil
        Foo.new
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo(value : Foo | Bar | Nil)
        result = maybe_item
        result
      end
    CRYSTAL

    inference = Crystalline::Lightweight::Inference.for(
      source,
      3,
      8,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("value").sort.should eq(["Bar", "Foo", "Nil"])
    inference.types_for("result").sort.should eq(["Bar", "Foo", "Nil"])
  end

  it "narrows types inside is_a? and truthy conditional branches" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end
    CRYSTAL

    isa_source = <<-CRYSTAL
      def demo(candidate : Greeter | Nil | Int32)
        if candidate.is_a?(Greeter)
          narrowed = candidate
          narrowed
        end
      end
    CRYSTAL

    narrowed_inference = Crystalline::Lightweight::Inference.for(
      isa_source,
      4,
      10,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    narrowed_inference.should_not be_nil
    narrowed_inference = narrowed_inference.not_nil!
    narrowed_inference.types_for("candidate").should eq(["Greeter"])
    narrowed_inference.types_for("narrowed").should eq(["Greeter"])

    truthy_source = <<-CRYSTAL
      def demo(candidate : Greeter | Nil)
        if candidate
          truthy_candidate = candidate
          truthy_candidate
        end
      end
    CRYSTAL

    truthy_inference = Crystalline::Lightweight::Inference.for(
      truthy_source,
      4,
      12,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    truthy_inference.should_not be_nil
    truthy_inference = truthy_inference.not_nil!
    truthy_inference.types_for("candidate").should eq(["Greeter"])
    truthy_inference.types_for("truthy_candidate").should eq(["Greeter"])
  end

  it "narrows case subjects in when branches" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      class Wrapper
        def hello : String
          "hi"
        end
      end
    CRYSTAL

    case_source = <<-CRYSTAL
      def demo(candidate : Greeter | Wrapper)
        case candidate
        when Greeter
          narrowed = candidate
          narrowed
        end
      end
    CRYSTAL

    case_inference = Crystalline::Lightweight::Inference.for(
      case_source,
      5,
      1,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    case_inference.should_not be_nil
    case_inference = case_inference.not_nil!
    case_inference.types_for("candidate").should eq(["Greeter"])
    case_inference.types_for("narrowed").should eq(["Greeter"])

    # A subtype when narrows an abstract subject to the when-type.
    union_source = <<-CRYSTAL
      def demo(candidate : Greeter)
        case candidate
        when Greeter
          narrowed = candidate
          narrowed
        end
      end
    CRYSTAL

    union_inference = Crystalline::Lightweight::Inference.for(
      union_source,
      4,
      11,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )
    union_inference.should_not be_nil
    union_inference = union_inference.not_nil!
    union_inference.types_for("candidate").should eq(["Greeter"])
  end

  it "resolves inherited methods from bare-named parents" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end
    CRYSTAL

    query = Crystalline::Lightweight::Query.new(index, secondary: prelude_index)
    names = query.methods_for("Crystal::Def").map(&.name)
    # `location`/`doc` live on Crystal::ASTNode, which the prelude
    # records as a bare-named parent of Crystal::Def.
    names.should contain("location")
    names.should contain("doc")
  end

  it "infers fallback types from logical or expressions" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo(candidate : Greeter | Nil)
        resolved = candidate || Greeter.new
        resolved
      end
    CRYSTAL

    inference = Crystalline::Lightweight::Inference.for(
      source,
      3,
      12,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("resolved").should eq(["Greeter"])
  end

  it "preserves tuple literal element shapes for generic specialization" do
    index = build_lightweight_index <<-CRYSTAL
      def noop
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo
        pair = {1, "x"}
        pair
      end
    CRYSTAL

    inference = Crystalline::Lightweight::Inference.for(
      source,
      3,
      6,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("pair").should eq(["Tuple(Int32, String)"])
  end

  it "infers block args and container return types for richer collection helpers" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end

        def word : String | Nil
          "hi"
        end
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo
        lookup = {"primary" => Greeter.new}
        lookup.each do |key, value|
          key
          value
        end

        numbers = [1, 2]
        numbers.reduce do |memo, item|
          memo
          item
        end

        collected = lookup.values.each_with_object([] of String) do |item, memo|
          item.word.not_nil!
          memo.first?
        end

        mapped = lookup.values.map { |item| item.word.not_nil! }
        flat_mapped = lookup.values.flat_map { |item| [item.word.not_nil!] }
        compacted = lookup.values.compact_map { |item| item.word }
        indexed = lookup.values.index_by { |item| item.word.not_nil! }
        grouped = lookup.values.group_by { |item| item.word.not_nil! }
        found_value = lookup.values.find_value { |item| item.word }
        resolved = lookup.values.first?.try { |item| item.word.not_nil! }

        found = lookup.dig
        current = numbers.find!
        found
        current
      end
    CRYSTAL

    lines = source.lines(chomp: false)

    key_line_number = lines.index! { |line| line.strip == "key" } + 1
    key_column_number = lines[key_line_number - 1].index("key").not_nil! + 2
    hash_inference = Crystalline::Lightweight::Inference.for(
      source,
      key_line_number,
      key_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    hash_inference.should_not be_nil
    hash_inference = hash_inference.not_nil!
    hash_inference.types_for("key").should eq(["String"])
    hash_inference.types_for("value").should eq(["Greeter"])

    memo_line_number = lines.index! { |line| line.strip == "memo" } + 1
    memo_column_number = lines[memo_line_number - 1].index("memo").not_nil! + 2
    reduce_inference = Crystalline::Lightweight::Inference.for(
      source,
      memo_line_number,
      memo_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    reduce_inference.should_not be_nil
    reduce_inference = reduce_inference.not_nil!
    reduce_inference.types_for("memo").should eq(["Int32"])
    reduce_inference.types_for("item").should eq(["Int32"])

    each_with_object_line_number = lines.index! { |line| line.includes?("memo.first?") } + 1
    each_with_object_column_number = lines[each_with_object_line_number - 1].index("memo").not_nil! + 2
    each_with_object_inference = Crystalline::Lightweight::Inference.for(
      source,
      each_with_object_line_number,
      each_with_object_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    each_with_object_inference.should_not be_nil
    each_with_object_inference = each_with_object_inference.not_nil!
    each_with_object_inference.types_for("item").should eq(["Greeter"])
    each_with_object_inference.types_for("memo").should eq(["Array(String)"])

    found_line_number = lines.index! { |line| line.strip == "found" } + 1
    found_column_number = lines[found_line_number - 1].index("found").not_nil! + 2
    return_inference = Crystalline::Lightweight::Inference.for(
      source,
      found_line_number,
      found_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    return_inference.should_not be_nil
    return_inference = return_inference.not_nil!
    return_inference.types_for("collected").should eq(["Array(String)"])
    return_inference.types_for("mapped").should eq(["Array(String)"])
    return_inference.types_for("flat_mapped").should eq(["Array(String)"])
    return_inference.types_for("compacted").should eq(["Array(String)"])
    return_inference.types_for("indexed").should eq(["Hash(String, Greeter)"])
    return_inference.types_for("grouped").should eq(["Hash(String, Array(Greeter))"])
    return_inference.types_for("found_value").sort.should eq(["Nil", "String"])
    return_inference.types_for("resolved").sort.should eq(["Nil", "String"])
    return_inference.types_for("found").should eq(["Greeter", "Nil"])
    return_inference.types_for("current").should eq(["Int32"])
  end

  it "infers the reduce accumulator from the memo argument" do
    index = build_lightweight_index <<-CRYSTAL
      class Foo
      end
    CRYSTAL

    source = <<-CRYSTAL
      def demo(items : Array(String))
        items.reduce([] of Int32) do |acc, item|
          acc
        end
      end
    CRYSTAL

    lines = source.lines(chomp: false)
    acc_line_number = lines.index! { |line| line.strip == "acc" } + 1
    acc_column_number = lines[acc_line_number - 1].index("acc").not_nil! + 2
    inference = Crystalline::Lightweight::Inference.for(
      source,
      acc_line_number,
      acc_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("acc").should eq(["Array(Int32)"])
    inference.types_for("item").should eq(["String"])
  end

  it "infers top-level locals before the cursor" do
    index = build_lightweight_index <<-CRYSTAL
      class Foo
      end
    CRYSTAL

    source = <<-CRYSTAL
      foo = Foo.new
      message = "hello"
      count = 42
      foo
    CRYSTAL

    lines = source.lines(chomp: false)
    cursor_line_number = lines.index! { |line| line.strip == "foo" } + 1
    cursor_column_number = lines[cursor_line_number - 1].index("foo").not_nil! + 2
    inference = Crystalline::Lightweight::Inference.for(
      source,
      cursor_line_number,
      cursor_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("foo").should eq(["Foo"])
    inference.types_for("message").should eq(["String"])
    inference.types_for("count").should eq(["Int32"])
  end

  it "infers inside private defs and resolves bare self-calls" do
    index = build_lightweight_index <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end

        private def message : String
          shout
        end
      end
    CRYSTAL

    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end

        private def message : String
          m = shout
          m
        end
      end
    CRYSTAL

    lines = source.lines(chomp: false)
    cursor_line_number = lines.index! { |line| line.strip == "m" } + 1
    cursor_column_number = lines[cursor_line_number - 1].index("m").not_nil! + 2
    inference = Crystalline::Lightweight::Inference.for(
      source,
      cursor_line_number,
      cursor_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.current_def.not_nil!.name.should eq("message")
    inference.self_types[0].should eq(["Greeter"])
    # The bare self-call `shout` resolves through the enclosing type.
    inference.types_for("m").should eq(["String"])
  end

  it "infers assignments inside while loops and their conditions" do
    source = <<-CRYSTAL
      def demo
        while (line = "x")
          message = line
          message
        end
        message
      end
    CRYSTAL

    lines = source.lines(chomp: false)
    cursor_line_number = lines.rindex { |line| line.strip == "message" }.not_nil! + 1
    cursor_column_number = lines[cursor_line_number - 1].index("message").not_nil! + 2
    inference = Crystalline::Lightweight::Inference.for(
      source,
      cursor_line_number,
      cursor_column_number,
      Crystalline::Lightweight::Query.new(Crystalline::Lightweight::Index.new),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("line").should eq(["String"])
    inference.types_for("message").should eq(["String"])
  end

  it "infers assignments inside case and select when bodies" do
    source = <<-CRYSTAL
      def demo
        case 1
        when 1
          message = "one"
        when 2
          message = "two"
        end

        select
        when x = foo()
          selected = "x"
        else
          selected = "y"
        end
        message
      end
    CRYSTAL

    lines = source.lines(chomp: false)
    cursor_line_number = lines.rindex { |line| line.strip == "message" }.not_nil! + 1
    cursor_column_number = lines[cursor_line_number - 1].index("message").not_nil! + 2
    inference = Crystalline::Lightweight::Inference.for(
      source,
      cursor_line_number,
      cursor_column_number,
      Crystalline::Lightweight::Query.new(Crystalline::Lightweight::Index.new),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("message").should eq(["String"])
    inference.types_for("selected").should eq(["String"])
  end

  it "infers untyped args from call sites and same-name locals" do
    source = <<-CRYSTAL
      def compile(server : LSP::Server, file_uri)
        project = Project.best_fit_for_file
      end

      def recalculate_dependencies(server, project)
        server.
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    lines = fixed.lines(chomp: false)
    cursor_line_number = lines.index! { |line| line.includes?("server.") } + 1
    cursor_column_number = lines[cursor_line_number - 1].index("server").not_nil! + 2
    index = build_lightweight_index(<<-CRYSTAL)
      class Project
        def self.best_fit_for_file : Project?
          nil
        end
      end
    CRYSTAL
    inference = Crystalline::Lightweight::Inference.for(
      fixed,
      cursor_line_number,
      cursor_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("server").should eq(["LSP::Server"])
    inference.types_for("project").should contain("Project")
  end

  it "infers locals assigned inside a return unless guard" do
    source = <<-CRYSTAL
      def compile(server)
        project = Project.new
        recalculate_dependencies(project)
      end

      def recalculate_dependencies(project)
        return unless (target = project.entry_point?)
        target.
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    lines = fixed.lines(chomp: false)
    cursor_line_number = lines.index! { |line| line.includes?("target.") } + 1
    cursor_column_number = lines[cursor_line_number - 1].index("target").not_nil! + 2
    index = build_lightweight_index(<<-CRYSTAL)
      class Project
        def entry_point? : String
          "x"
        end
      end
    CRYSTAL
    inference = Crystalline::Lightweight::Inference.for(
      fixed,
      cursor_line_number,
      cursor_column_number,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    inference = inference.not_nil!
    inference.types_for("target").should eq(["String"])
  end

  it "walks ||= begin ... end blocks so the ivar keeps the block's type" do
    source = <<-CRYSTAL
      class Cache
        def get(key : String) : String
          @values ||= begin
            {} of String => String
          end
          @values[key]
        end
      end
    CRYSTAL

    index = build_lightweight_index(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.includes?("@values[key]") }
    cursor = lines[line_number].index("@values").not_nil! + "@values".size

    inference = Crystalline::Lightweight::Inference.for(
      source,
      line_number + 1,
      cursor + 1,
      Crystalline::Lightweight::Query.new(index, secondary: prelude_index),
    )

    inference.should_not be_nil
    # The index records no ivars; the ||= block's hash literal types it.
    inference.not_nil!.types_for_instance_var("@values").should eq(["Hash(String, String)"])
  end
end
