require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/completion_context"
require "../../src/crystalline/lightweight/completion"

private def build_lightweight_query(source : String)
  path = File.join(Dir.tempdir, "crystalline-lightweight-completion-#{Random::Secure.hex(8)}.cr")
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
    Crystalline::Lightweight::Query.new(
      Crystalline::Lightweight::Index.from_program(result.program),
      secondary: prelude_index,
    )
  ensure
    File.delete(path) if File.exists?(path)
  end
end

private def prelude_index : Crystalline::Lightweight::Index
  Crystalline::Lightweight::PreludeIndex.ensure_loaded
  until index = Crystalline::Lightweight::PreludeIndex.get
    sleep 50.milliseconds
  end
  index
end

private def build_syntax_query(source : String)
  index = Crystalline::Lightweight::Index.from_source(source)
  raise "expected syntax index" unless index
  Crystalline::Lightweight::Query.new(index)
end

describe Crystalline::Lightweight::Completion do
  it "completes instance methods from inferred local receiver types" do
    source = <<-CRYSTAL
      class Greeter
        def greet(name : String) : String
          name
        end

        def shout : String
          "!"
        end
      end

      def demo
        greeter = Greeter.new
        greeter.gr
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("greeter.gr"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    items.map(&.insert_text).compact.should contain("greet")
    items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes through a record getter whose return type is a bare name" do
    # Mirrors `result.node.ac` where `result : Crystal::Compiler::Result`
    # and `#node : ASTNode` is recorded as the bare name: the chain must
    # resolve `ASTNode` against the method owner's namespace.
    source = <<-CRYSTAL
      module Compiler
        class ASTNode
          def accept(visitor)
          end

          def at : Location?
            nil
          end
        end

        record Result, program : Program, node : ASTNode

        def demo(result : Result)
          result.node.ac
        end
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("result.node.ac"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    items.map(&.insert_text).compact.should contain("accept")
    items.map(&.insert_text).compact.should contain("at")
  end

  it "completes bare identifiers with the current type's methods" do
    # A bare `proc` inside a def is a self-call: the enclosing type's own
    # methods and the methods of its included modules must be offered.
    source = <<-CRYSTAL
      module Mixin
        def process_result(result)
        end
      end

      class Visitor
        include Mixin

        def process_type(type)
        end

        def demo
          proc
        end
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.strip == "proc" }
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    names = items.map(&.insert_text).compact
    names.should contain("process_type")
    names.should contain("process_result")
  end

  it "completes ivar receivers whose types carry unions" do
    # `getter root_uri : URI?` seeds `@root_uri` with the raw union:
    # receiver lookups must expand it before checking type knowledge.
    source = <<-CRYSTAL
      class URI
        def path : String
          ""
        end

        def to_s : String
          ""
        end
      end

      class Holder
        getter root_uri : URI?
        getter projects = [] of Project

        def demo
          @root_uri.pa
        end
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("@root_uri."))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    names = items.map(&.insert_text).compact
    names.should contain("path")
    names.should contain("to_s")
  end

  it "completes class receivers through the synthesized new method" do
    source = <<-CRYSTAL
      class Greeter
        def initialize(name : String)
        end

        def self.build : Greeter
          new("x")
        end
      end

      def demo
        Greeter.bui
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("Greeter.bui"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    names = items.map(&.insert_text).compact
    names.should contain("new")
    names.should contain("build")
  end

  it "completes module receivers with the module's methods" do
    # A module's instance methods are callable on the module itself
    # (`extend self`): `Helpers.` must offer them.
    source = <<-CRYSTAL
      module Helpers
        extend self

        def greet(name : String) : String
          name
        end

        def shout : String
          "!"
        end
      end

      def demo
        Helpers.gr
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("Helpers.gr"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    names = items.map(&.insert_text).compact
    names.should contain("greet")
    names.should contain("shout")
  end

  it "completes class methods from constant receivers" do
    source = <<-CRYSTAL
      class Greeter
        def self.build(name : String) : Greeter
          new
        end
      end

      def demo
        Greeter.bu
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("Greeter.bu"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    items.map(&.insert_text).compact.should contain("build")
  end

  it "completes chained receivers using explicit return types" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      class Factory
        def build : Greeter
          Greeter.new
        end
      end

      def demo
        factory = Factory.new
        factory.build.sh
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("factory.build.sh"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes self and instance variable receivers" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      class Wrapper
        def initialize
          @greeter = Greeter.new
        end

        def hello : String
          "hi"
        end

        def demo
          self.he
          @greeter.sh
        end
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    self_line_number = lines.index!(&.includes?("self.he"))
    self_context = Crystalline::CompletionContext.detect(lines[self_line_number], lines[self_line_number].size - 1, nil)
    self_context.should_not be_nil

    self_items = Crystalline::Lightweight::Completion.complete(
      source,
      self_line_number,
      self_context.not_nil!,
      query,
    )

    self_items.should_not be_nil
    self_items.not_nil!.map(&.insert_text).compact.should contain("hello")

    ivar_line_number = lines.index!(&.includes?("@greeter.sh"))
    ivar_context = Crystalline::CompletionContext.detect(lines[ivar_line_number], lines[ivar_line_number].size - 1, nil)
    ivar_context.should_not be_nil

    ivar_items = Crystalline::Lightweight::Completion.complete(
      source,
      ivar_line_number,
      ivar_context.not_nil!,
      query,
    )

    ivar_items.should_not be_nil
    ivar_items.not_nil!.map(&.insert_text).compact.should contain("shout")
  end

  it "completes locals, top-level methods, self, instance variables, and types without dot triggers" do
    source = <<-CRYSTAL
      class Greeter
      end

      def top_level_name : String
        "name"
      end

      class Wrapper
        def initialize
          @greeter = Greeter.new
        end

        def demo(local_name : String)
          local_copy = local_name
          loc
          top_lev
          sel
          @gre
          Gre
        end
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    local_line_number = lines.index! { |item| item.strip == "loc" }
    local_context = Crystalline::CompletionContext.detect(lines[local_line_number], lines[local_line_number].index!("loc") + 3, nil)
    local_items = Crystalline::Lightweight::Completion.complete(source, local_line_number, local_context.not_nil!, query).not_nil!
    local_items.map(&.insert_text).compact.should contain("local_copy")

    method_line_number = lines.index! { |item| item.strip == "top_lev" }
    method_context = Crystalline::CompletionContext.detect(lines[method_line_number], lines[method_line_number].index!("top_lev") + 7, nil)
    method_items = Crystalline::Lightweight::Completion.complete(source, method_line_number, method_context.not_nil!, query).not_nil!
    method_items.map(&.insert_text).compact.should contain("top_level_name")

    self_line_number = lines.index! { |item| item.strip == "sel" }
    self_context = Crystalline::CompletionContext.detect(lines[self_line_number], lines[self_line_number].index!("sel") + 3, nil)
    self_items = Crystalline::Lightweight::Completion.complete(source, self_line_number, self_context.not_nil!, query).not_nil!
    self_items.map(&.insert_text).compact.should contain("self")

    ivar_line_number = lines.index! { |item| item.strip == "@gre" }
    ivar_context = Crystalline::CompletionContext.detect(lines[ivar_line_number], lines[ivar_line_number].index!("@gre") + 4, nil)
    ivar_items = Crystalline::Lightweight::Completion.complete(source, ivar_line_number, ivar_context.not_nil!, query).not_nil!
    ivar_items.map(&.insert_text).compact.should contain("@greeter")

    type_line_number = lines.index! { |item| item.strip == "Gre" }
    type_context = Crystalline::CompletionContext.detect(lines[type_line_number], lines[type_line_number].index!("Gre") + 3, nil)
    type_items = Crystalline::Lightweight::Completion.complete(source, type_line_number, type_context.not_nil!, query).not_nil!
    type_items.map(&.insert_text).compact.should contain("Greeter")
  end

  it "completes narrowed receivers inside conditional branches" do
    isa_source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(candidate : Greeter | Nil | Int32)
        if candidate.is_a?(Greeter)
          candidate.sh
        end
      end
    CRYSTAL

    query = build_lightweight_query(isa_source)
    isa_lines = isa_source.lines(chomp: false)
    isa_line_number = isa_lines.index!(&.includes?("candidate.sh"))
    isa_context = Crystalline::CompletionContext.detect(isa_lines[isa_line_number], isa_lines[isa_line_number].size - 1, nil)
    isa_items = Crystalline::Lightweight::Completion.complete(isa_source, isa_line_number, isa_context.not_nil!, query).not_nil!
    isa_items.map(&.insert_text).compact.should contain("shout")

    truthy_source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(candidate : Greeter | Nil)
        if candidate
          candidate.sh
        end
      end
    CRYSTAL

    truthy_query = build_lightweight_query(truthy_source)
    truthy_lines = truthy_source.lines(chomp: false)
    truthy_line_number = truthy_lines.index!(&.includes?("candidate.sh"))
    truthy_context = Crystalline::CompletionContext.detect(truthy_lines[truthy_line_number], truthy_lines[truthy_line_number].size - 1, nil)
    truthy_items = Crystalline::Lightweight::Completion.complete(truthy_source, truthy_line_number, truthy_context.not_nil!, truthy_query).not_nil!
    truthy_items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes receivers inferred from logical or fallbacks" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(candidate : Greeter | Nil)
        resolved = candidate || Greeter.new
        resolved.sh
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("resolved.sh"))
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size - 1, nil)
    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query).not_nil!
    items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes common helper and container receivers" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(candidate : Greeter | Nil)
        items = [Greeter.new]
        items.first.sh
        candidate.not_nil!.sh
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    first_line_number = lines.index!(&.includes?("items.first.sh"))
    first_context = Crystalline::CompletionContext.detect(lines[first_line_number], lines[first_line_number].size - 1, nil)
    first_items = Crystalline::Lightweight::Completion.complete(source, first_line_number, first_context.not_nil!, query).not_nil!
    first_items.map(&.insert_text).compact.should contain("shout")

    not_nil_line_number = lines.index!(&.includes?("candidate.not_nil!.sh"))
    not_nil_context = Crystalline::CompletionContext.detect(lines[not_nil_line_number], lines[not_nil_line_number].size - 1, nil)
    not_nil_items = Crystalline::Lightweight::Completion.complete(source, not_nil_line_number, not_nil_context.not_nil!, query).not_nil!
    not_nil_items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes methods in standalone syntax-only files" do
    source = <<-CRYSTAL
      class Clazz
        def method1(num : Int32)
          2
        end
      end

      puts Clazz.new.method
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("Clazz.new.method"))
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size - 1, nil)
    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query).not_nil!
    items.map(&.insert_text).compact.should contain("method1")
  end

  it "completes block arguments for iterator helpers" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo
        items = [Greeter.new]
        items.each_with_index do |item, index|
          item.sh
          index.to_
        end

        Greeter.new.tap do |value|
          value.sh
        end
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    item_line_number = lines.index!(&.includes?("item.sh"))
    item_context = Crystalline::CompletionContext.detect(lines[item_line_number], lines[item_line_number].size - 1, nil)
    item_items = Crystalline::Lightweight::Completion.complete(source, item_line_number, item_context.not_nil!, query).not_nil!
    item_items.map(&.insert_text).compact.should contain("shout")

    index_line_number = lines.index!(&.includes?("index.to_"))
    index_context = Crystalline::CompletionContext.detect(lines[index_line_number], lines[index_line_number].size - 1, nil)
    index_items = Crystalline::Lightweight::Completion.complete(source, index_line_number, index_context.not_nil!, query).not_nil!
    index_items.map(&.insert_text).compact.should contain("to_i")

    value_line_number = lines.index!(&.includes?("value.sh"))
    value_context = Crystalline::CompletionContext.detect(lines[value_line_number], lines[value_line_number].size - 1, nil)
    value_items = Crystalline::Lightweight::Completion.complete(source, value_line_number, value_context.not_nil!, query).not_nil!
    value_items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes tuple and named tuple derived receivers" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo
        pair = {Greeter.new, 1}
        pair.first.sh

        named = {greeter: Greeter.new}
        named.greeter.sh
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    tuple_line_number = lines.index!(&.includes?("pair.first.sh"))
    tuple_context = Crystalline::CompletionContext.detect(lines[tuple_line_number], lines[tuple_line_number].size - 1, nil)
    tuple_items = Crystalline::Lightweight::Completion.complete(source, tuple_line_number, tuple_context.not_nil!, query).not_nil!
    tuple_items.map(&.insert_text).compact.should contain("shout")

    named_line_number = lines.index!(&.includes?("named.greeter.sh"))
    named_context = Crystalline::CompletionContext.detect(lines[named_line_number], lines[named_line_number].size - 1, nil)
    named_items = Crystalline::Lightweight::Completion.complete(source, named_line_number, named_context.not_nil!, query).not_nil!
    named_items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes helper methods that preserve or refine collection receiver shapes" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(items : Array(Greeter), candidate : Greeter | Nil)
        items.select.first?.not_nil!.sh
        items.find.not_nil!.sh
        candidate.try &.sh
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    select_line_number = lines.index! { |item| item.includes?("items.select.first?.not_nil!.sh") }
    select_context = Crystalline::CompletionContext.detect(lines[select_line_number], lines[select_line_number].size - 1, nil)
    select_items = Crystalline::Lightweight::Completion.complete(source, select_line_number, select_context.not_nil!, query).not_nil!
    select_items.map(&.insert_text).compact.should contain("shout")

    find_line_number = lines.index!(&.includes?("items.find.not_nil!.sh"))
    find_context = Crystalline::CompletionContext.detect(lines[find_line_number], lines[find_line_number].size - 1, nil)
    find_items = Crystalline::Lightweight::Completion.complete(source, find_line_number, find_context.not_nil!, query).not_nil!
    find_items.map(&.insert_text).compact.should contain("shout")

    try_line_number = lines.index!(&.includes?("candidate.try &.sh"))
    try_context = Crystalline::CompletionContext.detect(lines[try_line_number], lines[try_line_number].size - 1, nil)
    try_items = Crystalline::Lightweight::Completion.complete(source, try_line_number, try_context.not_nil!, query).not_nil!
    try_items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes richer hash and reducer helper flows" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end

        def word : String | Nil
          "hi"
        end
      end

      def demo
        lookup = {"primary" => Greeter.new}
        lookup.each do |key, value|
          key.up
          value.sh
        end

        numbers = [1, 2]
        numbers.reduce do |memo, item|
          memo.to_
          item.to_
        end

        collected = lookup.values.each_with_object([] of String) do |collected_item, collected_memo|
          collected_item.sh
          collected_memo.fi
        end
        collected.first.up

        mapped = lookup.values.map { |item| item.word.not_nil! }
        mapped.first.up

        flat_mapped = lookup.values.flat_map { |item| [item.word.not_nil!] }
        flat_mapped.first.up

        compacted = lookup.values.compact_map { |item| item.word }
        compacted.first.up

        indexed = lookup.values.index_by { |item| item.word.not_nil! }
        indexed["primary"].sh

        grouped = lookup.values.group_by { |item| item.word.not_nil! }
        grouped["primary"].first.sh

        found_value = lookup.values.find_value { |item| item.word }
        found_value.not_nil!.up

        resolved = lookup.values.first?.try { |item| item.word.not_nil! }
        resolved.not_nil!.up

        lookup.dig.sh

        items = [Greeter.new]
        items.find!.sh
        items.comp
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)

    key_line_number = lines.index!(&.includes?("key.up"))
    key_context = Crystalline::CompletionContext.detect(lines[key_line_number], lines[key_line_number].size - 1, nil)
    key_items = Crystalline::Lightweight::Completion.complete(source, key_line_number, key_context.not_nil!, query).not_nil!
    key_items.map(&.insert_text).compact.should contain("upcase")

    value_line_number = lines.index!(&.includes?("value.sh"))
    value_context = Crystalline::CompletionContext.detect(lines[value_line_number], lines[value_line_number].size - 1, nil)
    value_items = Crystalline::Lightweight::Completion.complete(source, value_line_number, value_context.not_nil!, query).not_nil!
    value_items.map(&.insert_text).compact.should contain("shout")

    memo_line_number = lines.index!(&.includes?("memo.to_"))
    memo_context = Crystalline::CompletionContext.detect(lines[memo_line_number], lines[memo_line_number].size - 1, nil)
    memo_items = Crystalline::Lightweight::Completion.complete(source, memo_line_number, memo_context.not_nil!, query).not_nil!
    memo_items.map(&.insert_text).compact.should contain("to_i")

    item_line_number = lines.index!(&.includes?("item.to_"))
    item_context = Crystalline::CompletionContext.detect(lines[item_line_number], lines[item_line_number].size - 1, nil)
    item_items = Crystalline::Lightweight::Completion.complete(source, item_line_number, item_context.not_nil!, query).not_nil!
    item_items.map(&.insert_text).compact.should contain("to_i")

    each_with_object_item_line_number = lines.index!(&.includes?("collected_item.sh"))
    each_with_object_item_context = Crystalline::CompletionContext.detect(lines[each_with_object_item_line_number], lines[each_with_object_item_line_number].size - 1, nil)
    each_with_object_item_items = Crystalline::Lightweight::Completion.complete(source, each_with_object_item_line_number, each_with_object_item_context.not_nil!, query).not_nil!
    each_with_object_item_items.map(&.insert_text).compact.should contain("shout")

    each_with_object_memo_line_number = lines.index!(&.includes?("collected_memo.fi"))
    each_with_object_memo_context = Crystalline::CompletionContext.detect(lines[each_with_object_memo_line_number], lines[each_with_object_memo_line_number].size - 1, nil)
    each_with_object_memo_items = Crystalline::Lightweight::Completion.complete(source, each_with_object_memo_line_number, each_with_object_memo_context.not_nil!, query).not_nil!
    each_with_object_memo_items.map(&.insert_text).compact.should contain("first?")

    collected_line_number = lines.index!(&.includes?("collected.first.up"))
    collected_context = Crystalline::CompletionContext.detect(lines[collected_line_number], lines[collected_line_number].size - 1, nil)
    collected_items = Crystalline::Lightweight::Completion.complete(source, collected_line_number, collected_context.not_nil!, query).not_nil!
    collected_items.map(&.insert_text).compact.should contain("upcase")

    mapped_line_number = lines.index!(&.includes?("mapped.first.up"))
    mapped_context = Crystalline::CompletionContext.detect(lines[mapped_line_number], lines[mapped_line_number].size - 1, nil)
    mapped_items = Crystalline::Lightweight::Completion.complete(source, mapped_line_number, mapped_context.not_nil!, query).not_nil!
    mapped_items.map(&.insert_text).compact.should contain("upcase")

    flat_mapped_line_number = lines.index!(&.includes?("flat_mapped.first.up"))
    flat_mapped_context = Crystalline::CompletionContext.detect(lines[flat_mapped_line_number], lines[flat_mapped_line_number].size - 1, nil)
    flat_mapped_items = Crystalline::Lightweight::Completion.complete(source, flat_mapped_line_number, flat_mapped_context.not_nil!, query).not_nil!
    flat_mapped_items.map(&.insert_text).compact.should contain("upcase")

    compacted_line_number = lines.index!(&.includes?("compacted.first.up"))
    compacted_context = Crystalline::CompletionContext.detect(lines[compacted_line_number], lines[compacted_line_number].size - 1, nil)
    compacted_items = Crystalline::Lightweight::Completion.complete(source, compacted_line_number, compacted_context.not_nil!, query).not_nil!
    compacted_items.map(&.insert_text).compact.should contain("upcase")

    indexed_line_number = lines.index!(&.includes?("indexed[\"primary\"].sh"))
    indexed_context = Crystalline::CompletionContext.detect(lines[indexed_line_number], lines[indexed_line_number].size - 1, nil)
    indexed_items = Crystalline::Lightweight::Completion.complete(source, indexed_line_number, indexed_context.not_nil!, query).not_nil!
    indexed_items.map(&.insert_text).compact.should contain("shout")

    grouped_line_number = lines.index! { |item| item.includes?("grouped[\"primary\"].first.sh") }
    grouped_context = Crystalline::CompletionContext.detect(lines[grouped_line_number], lines[grouped_line_number].size - 1, nil)
    grouped_items = Crystalline::Lightweight::Completion.complete(source, grouped_line_number, grouped_context.not_nil!, query).not_nil!
    grouped_items.map(&.insert_text).compact.should contain("shout")

    found_value_line_number = lines.index!(&.includes?("found_value.not_nil!.up"))
    found_value_context = Crystalline::CompletionContext.detect(lines[found_value_line_number], lines[found_value_line_number].size - 1, nil)
    found_value_items = Crystalline::Lightweight::Completion.complete(source, found_value_line_number, found_value_context.not_nil!, query).not_nil!
    found_value_items.map(&.insert_text).compact.should contain("upcase")

    resolved_line_number = lines.index!(&.includes?("resolved.not_nil!.up"))
    resolved_context = Crystalline::CompletionContext.detect(lines[resolved_line_number], lines[resolved_line_number].size - 1, nil)
    resolved_items = Crystalline::Lightweight::Completion.complete(source, resolved_line_number, resolved_context.not_nil!, query).not_nil!
    resolved_items.map(&.insert_text).compact.should contain("upcase")

    dig_line_number = lines.index!(&.includes?("lookup.dig.sh"))
    dig_context = Crystalline::CompletionContext.detect(lines[dig_line_number], lines[dig_line_number].size - 1, nil)
    dig_items = Crystalline::Lightweight::Completion.complete(source, dig_line_number, dig_context.not_nil!, query).not_nil!
    dig_items.map(&.insert_text).compact.should contain("shout")

    find_bang_line_number = lines.index!(&.includes?("items.find!.sh"))
    find_bang_context = Crystalline::CompletionContext.detect(lines[find_bang_line_number], lines[find_bang_line_number].size - 1, nil)
    find_bang_items = Crystalline::Lightweight::Completion.complete(source, find_bang_line_number, find_bang_context.not_nil!, query).not_nil!
    find_bang_items.map(&.insert_text).compact.should contain("shout")

    inherited_line_number = lines.index!(&.includes?("items.comp"))
    inherited_context = Crystalline::CompletionContext.detect(lines[inherited_line_number], lines[inherited_line_number].size - 1, nil)
    inherited_items = Crystalline::Lightweight::Completion.complete(source, inherited_line_number, inherited_context.not_nil!, query).not_nil!
    inherited_items.map(&.insert_text).compact.should contain("compact_map")
  end

  it "scopes namespace completion to the receiver's nested types" do
    source = <<-CRYSTAL
      class Foo
        class Inner; end
      end
      class Unrelated; end

      def demo
        Foo::In
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("Foo::In"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    ).not_nil!

    labels = items.map(&.label)
    labels.should contain("Foo::Inner")
    labels.should_not contain("Unrelated")

    inner = items.find! { |item| item.label == "Foo::Inner" }
    inner.insert_text.should eq("Inner")
  end

  it "completes receivers from method calls with arguments" do
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
        Greeter.new("hi").sh
        factory.build("hi").sh
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)

    new_line_number = lines.index! { |item| item.strip == "Greeter.new(\"hi\").sh" }
    new_context = Crystalline::CompletionContext.detect(lines[new_line_number], lines[new_line_number].size - 1, nil)
    new_items = Crystalline::Lightweight::Completion.complete(source, new_line_number, new_context.not_nil!, query).not_nil!
    new_items.map(&.insert_text).compact.should contain("shout")

    build_line_number = lines.index! { |item| item.strip == "factory.build(\"hi\").sh" }
    build_context = Crystalline::CompletionContext.detect(lines[build_line_number], lines[build_line_number].size - 1, nil)
    build_items = Crystalline::Lightweight::Completion.complete(source, build_line_number, build_context.not_nil!, query).not_nil!
    build_items.map(&.insert_text).compact.should contain("shout")
  end

  it "completes accessor macros and top-level locals from source" do
    source = <<-CRYSTAL
      class User
        getter name : String
      end

      user = User.new
      user.na
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)

    accessor_line_number = lines.index! { |item| item.strip == "user.na" }
    accessor_context = Crystalline::CompletionContext.detect(lines[accessor_line_number], lines[accessor_line_number].size - 1, nil)
    accessor_items = Crystalline::Lightweight::Completion.complete(source, accessor_line_number, accessor_context.not_nil!, query).not_nil!
    accessor_items.map(&.insert_text).compact.should contain("name")
  end

  it "completes ivar receivers from parsed source at the class body" do
    source = <<-CRYSTAL
      class Service
        def ping : String
          "pong"
        end
      end

      class Controller
        @service = Service.new

        @service.
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    query = build_syntax_query(fixed)
    # Locate the marker in the raw source: the fixer rewrites the line to
    # `@service.placeholder` but keeps line positions intact.
    line_number = source.lines.index! { |item| item.strip == "@service." }
    fixed_lines = fixed.lines(chomp: false)
    context = Crystalline::CompletionContext.detect(fixed_lines[line_number], fixed_lines[line_number].size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(fixed, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("ping")
  end

  it "completes generic receivers against the secondary index" do
    source = <<-CRYSTAL
      class Controller
        @pending : Set(String)

        @pending.
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    primary = Crystalline::Lightweight::Index.from_source(fixed).not_nil!
    secondary = Crystalline::Lightweight::Index.from_source("class Set(T)\n  def add(x : T) : Nil\n  end\nend\n").not_nil!
    query = Crystalline::Lightweight::Query.new(primary, secondary: secondary)

    line_number = source.lines.index! { |item| item.strip == "@pending." }
    fixed_lines = fixed.lines(chomp: false)
    context = Crystalline::CompletionContext.detect(fixed_lines[line_number], fixed_lines[line_number].size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(fixed, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("add")
  end

  it "completes methods on a value typed as an alias" do
    source = <<-CRYSTAL
      class Greeter
        def hello : String
          "hi"
        end
      end

      alias Greet = Greeter

      def demo
        greeter = Greet.new
        greeter.he
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("greeter.he"))
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("hello")
  end

  it "completes ivars from source when the buffer does not parse" do
    source = <<-CRYSTAL
      class Greeter
        @pending : Int32

        def demo
          @p
        end
      end
      x = "unclosed
    CRYSTAL

    # The query is built from the parsed state of the file; the buffer is
    # the mid-edit version with an unclosed string that fails to parse.
    query = build_syntax_query(source.sub(/\n[ \t]*x = "unclosed/, "\n"))
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.strip == "@p" }
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size, "@").not_nil!
    items = Crystalline::Lightweight::Completion.complete(source, line_number, context, query).not_nil!
    items.map(&.insert_text).compact.should contain("@pending")
  end

  it "keeps the sigil in ivar completion items" do
    source = <<-CRYSTAL
      class Controller
        @documents_lock = Mutex.new

        def on_request
          @documents_lock.synchronize do
            @documents_
          end
        end
      end
    CRYSTAL

    query = build_syntax_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |item| item.strip == "@documents_" }
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(source, line_number, context.not_nil!, query)
    items.should_not be_nil
    item = items.not_nil!.find { |i| i.filter_text == "@documents_lock" }
    item.should_not be_nil
    item = item.not_nil!
    item.insert_text.should eq("@documents_lock")
    text_edit = item.text_edit.not_nil!
    text_edit.new_text.should eq("@documents_lock")
    replaced = lines[line_number][text_edit.range.start.character...text_edit.range.end.character]
    replaced.should eq("@documents_")
  end

  it "completes ivars after a lone @" do
    source = <<-CRYSTAL
      class Store
        @documents_mutex = Mutex.new

        def open(raw_uri : String)
          @documents_mutex.synchronize { @opened_documents[raw_uri] = raw_uri }
          @
        end
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    query = build_syntax_query(fixed)
    lines = fixed.lines(chomp: false)
    line_number = source.lines.index! { |item| item.strip == "@" }
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].index!("@") + 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(fixed, line_number, context.not_nil!, query)
    items.should_not be_nil
    names = items.not_nil!.map(&.insert_text).compact
    names.should contain("@documents_mutex")
    names.should contain("@opened_documents")
  end

  it "completes locals assigned inside && conditions" do
    source = <<-CRYSTAL
      class Project
        def entry_point? : Path?
          nil
        end
      end

      def demo(project : Project)
        if project && (entry_point = project.entry_point?)
          target = entry_point
          target.
        end
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    query = build_lightweight_query(fixed)
    lines = fixed.lines(chomp: false)
    line_number = source.lines.index! { |item| item.strip == "target." }
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(fixed, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("dirname")
  end

  it "resolves constant receivers and class methods when inferring calls" do
    source = <<-CRYSTAL
      module Crystalline
        class Project
          def self.best_fit_for_file(projects, file_uri) : Project?
            nil
          end

          def entry_point? : Path?
            nil
          end
        end

        class Workspace
          def compile(server, file_uri)
            project = Project.best_fit_for_file(@projects, file_uri)
            if project && (entry_point = project.entry_point?)
              target = entry_point
              target.
            end
          end
        end
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    query = build_lightweight_query(fixed)
    lines = fixed.lines(chomp: false)
    line_number = source.lines.index! { |item| item.strip == "target." }
    context = Crystalline::CompletionContext.detect(lines[line_number], lines[line_number].size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(fixed, line_number, context.not_nil!, query)
    items.should_not be_nil
    items.not_nil!.map(&.insert_text).compact.should contain("dirname")
  end

  it "keeps overloads with untyped args distinct from no-arg overloads" do
    # `foo` and `foo(x)` (an untyped arg) must both complete: a dedup key
    # built from restrictions alone joins both to the same empty signature
    # and silently drops one overload.
    source = <<-CRYSTAL
      class Overloads
        def foo : Int32
          1
        end

        def foo(x) : String
          "x"
        end
      end

      def demo(overloads : Overloads)
        overloads.fo
      end
    CRYSTAL

    query = build_lightweight_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("overloads.fo"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    items = items.not_nil!
    foos = items.select { |item| item.insert_text == "foo" }
    foos.size.should eq(2)
    foos.map(&.detail).compact.sort!.should contain("Overloads#foo() : Int32")
    foos.map(&.detail).compact.sort!.should contain("Overloads#foo(x) : String")
  end

  it "completes ivar names after a bare sigil" do
    source = <<-CRYSTAL
      class Foo
        @server : String
        @cache = {} of String => Int32

        def bar
          @
        end
      end
    CRYSTAL

    # A lone sigil does not parse: the fixer appends the placeholder, and
    # completion must still offer the ivars through the sigil trigger.
    fixed = Crystalline::BrokenSourceFixer.fix(source)
    query = build_syntax_query(fixed)
    lines = fixed.lines(chomp: false)
    line_number = lines.index! { |item| item.strip == "@placeholder" }
    line = lines[line_number]
    cursor = line.index!('@') + 1
    context = Crystalline::CompletionContext.detect(line, cursor, "@")
    context.should_not be_nil
    # The analysis prefix ends at the sigil so the fragment stays empty.
    context.not_nil!.analysis_column.should eq(cursor - 1)

    items = Crystalline::Lightweight::Completion.complete(
      fixed,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    names = items.not_nil!.map(&.insert_text).compact
    names.should contain("@server")
    names.should contain("@cache")
  end

  it "completes through a getter-with-initializer hash receiver" do
    source = <<-CRYSTAL
      class Store
        getter cache = {} of String => Int32

        def demo
          cache.has_
        end
      end
    CRYSTAL

    index = Crystalline::Lightweight::Index.from_source(source)
    raise "expected syntax index" unless index
    query = Crystalline::Lightweight::Query.new(index, secondary: prelude_index)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("cache.has_"))
    line = lines[line_number]
    context = Crystalline::CompletionContext.detect(line, line.size - 1, nil)
    context.should_not be_nil

    items = Crystalline::Lightweight::Completion.complete(
      source,
      line_number,
      context.not_nil!,
      query,
    )

    items.should_not be_nil
    # The getter's `of` clause names the shape: the receiver resolves to
    # Hash(String, Int32), whose methods complete.
    items.not_nil!.map(&.insert_text).compact.should contain("has_key?")
  end
end
