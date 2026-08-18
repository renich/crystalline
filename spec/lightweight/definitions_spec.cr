require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/lightweight/definitions"

private def build_definition_query(source : String)
  index = Crystalline::Lightweight::Index.from_source(source)
  raise "expected syntax index" unless index
  Crystalline::Lightweight::Query.new(index)
end

private def build_program_definition_query(source : String)
  path = File.join(Dir.tempdir, "crystalline-lightweight-definitions-#{Random::Secure.hex(8)}.cr")
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
    Crystalline::Lightweight::Query.new(Crystalline::Lightweight::Index.from_program(result.program))
  ensure
    File.delete(path) if File.exists?(path)
  end
end

describe Crystalline::Lightweight::Definitions do
  it "finds type definitions in standalone syntax-only files" do
    source = <<-CRYSTAL
      class Clazz
      end

      puts Clazz
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("puts Clazz"))
    character = lines[line_number].rindex!("Clazz") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(0)
  end

  it "finds method definitions for resolved receivers" do
    source = <<-CRYSTAL
      class Clazz
        def method1(num : Int32)
          2
        end
      end

      puts Clazz.new.method1(num: 42)
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("Clazz.new.method1"))
    character = lines[line_number].rindex!("method1") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(1)
  end

  it "finds top-level method definitions" do
    source = <<-CRYSTAL
      def helper
        1
      end

      helper
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |line| line.strip == "helper" }
    character = lines[line_number].index!("helper") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(0)
  end

  it "finds method definitions through richer helper chains" do
    source = <<-CRYSTAL
      class Greeter
        def shout : String
          "!"
        end
      end

      def demo(candidate : Greeter | Nil)
        lookup = {"primary" => Greeter.new}
        lookup.dig.shout

        items = [Greeter.new]
        items.find!.shout
        items.compact_map
        candidate.try &.shout
      end
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_program_definition_query(source)
    lines = source.lines(chomp: false)

    dig_line_number = lines.index! { |line| line.strip == "lookup.dig.shout" }
    dig_character = lines[dig_line_number].rindex!("shout") + 2
    dig_locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, dig_line_number, dig_character, query)
    dig_locations.should_not be_nil
    dig_locations.not_nil!.first.range.start.line.should eq(1)

    find_bang_line_number = lines.index! { |line| line.strip == "items.find!.shout" }
    find_bang_character = lines[find_bang_line_number].rindex!("shout") + 2
    find_bang_locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, find_bang_line_number, find_bang_character, query)
    find_bang_locations.should_not be_nil
    find_bang_locations.not_nil!.first.range.start.line.should eq(1)

    inherited_line_number = lines.index! { |line| line.strip == "items.compact_map" }
    inherited_character = lines[inherited_line_number].rindex!("compact_map") + 2
    inherited_locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, inherited_line_number, inherited_character, query)
    inherited_locations.should_not be_nil

    try_line_number = lines.index! { |line| line.strip == "candidate.try &.shout" }
    try_character = lines[try_line_number].rindex!("shout") + 2
    try_locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, try_line_number, try_character, query)
    try_locations.should_not be_nil
    try_locations.not_nil!.first.range.start.line.should eq(1)
  end

  it "finds namespace-relative type definitions through the indexed location" do
    source = <<-CRYSTAL
      module Outer
        class Inner
        end

        def demo
          Inner.new
        end
      end
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |line| line.strip == "Inner.new" }
    character = lines[line_number].rindex!("Inner") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(1)
  end

  it "finds the declaration of an instance variable" do
    source = <<-CRYSTAL
      class Greeter
        @server : String

        def initialize(@server : String)
        end

        def demo
          @server
        end
      end
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)

    lines = source.lines(chomp: false)
    line_number = lines.index! { |line| line.strip == "@server" }
    character = lines[line_number].rindex!("@server") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(1)
  end

  it "jumps to the accessor macro for a bare getter self-call" do
    source = <<-CRYSTAL
      class Clazz
        getter! workspace : Clazz

        def demo
          workspace
        end
      end
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |line| line.strip == "workspace" }
    character = lines[line_number].index!("workspace") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(1)
  end

  it "jumps to the first assignment for an undeclared ivar" do
    source = <<-CRYSTAL
      class Clazz
        def initialize
          @service = Service.new
        end

        def demo
          @service
        end
      end
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)
    lines = source.lines(chomp: false)
    line_number = lines.index! { |line| line.strip == "@service" }
    character = lines[line_number].index!("@service") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(2)
  end

  it "finds the shorthand ivar argument of initialize" do
    source = <<-CRYSTAL
      class Greeter
        def initialize(@server : String)
        end
      end
    CRYSTAL

    file_uri = URI.parse("file:///tmp/standalone.cr")
    query = build_definition_query(source)

    lines = source.lines(chomp: false)
    line_number = lines.index!(&.includes?("initialize"))
    character = lines[line_number].index!("@server") + 2

    locations = Crystalline::Lightweight::Definitions.definitions(source, file_uri, line_number, character, query)
    locations.should_not be_nil
    locations.not_nil!.first.range.start.line.should eq(1)
  end
end
