require "spec"
require "compiler/crystal/syntax"
require "../src/crystalline/broken_source_fixer"

# The real-source site tests read project files; specs run from the repo
# root but resolve relative to this file to stay robust.
SPEC_SRC_ROOT = File.expand_path("..", __DIR__)

# The wave-15 sweep cuts a real source line at its last dot (the
# in-progress-typing state) and requires the fixer to restore a parseable
# program. Duplicated patterns use occurrence order (the sweep hit both
# `LSP::CompletionItem.new(` sites).
SITES = [
  {"src/crystalline/lightweight/completion.cr", "LSP::CompletionItem.new(", 1, "CompletionItem cut"},
  {"src/crystalline/lightweight/completion.cr", "text_edit: LSP::TextEdit.new(", 1, "nested TextEdit cut"},
  {"src/crystalline/lightweight/completion.cr", "range: @context.completion_range(@line_number),", 1, "multi-level entering closers"},
  {"src/crystalline/lightweight/completion.cr", "LSP::CompletionItem.new(", 2, "scoped type item cut"},
  {"src/crystalline/lightweight/completion.cr", "text_edit: LSP::TextEdit.new(", 2, "nested TextEdit cut 2"},
  {"src/crystalline/completion_context.cr", "spans << TokenSpan.new(", 1, "TokenSpan cut"},
  {"src/crystalline/completion_context.cr", "tokens.each do |token|", 1, "do-block header cut"},
  {"src/crystalline/workspace.cr", "start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),", 1, "three-level call cut"},
  {"src/crystalline/controller.cr", "range: message.params.range,", 1, "array-in-blocks cut"},
  {"src/crystalline/lightweight/index.cr", "record_info.methods << MethodInfo.new(", 1, "MethodInfo cut"},
]

def it_fixes(from, to, file = __FILE__, line = __LINE__)
  it(file: file, line: line) do
    Crystalline::BrokenSourceFixer.fix(from).should eq(to)
  end
end

describe Crystalline::BrokenSourceFixer do
  it_fixes <<-CRYSTAL, <<-CRYSTAL
    # a comment ending with a dot.
    puts 1
    CRYSTAL
    # a comment ending with a dot.
    puts 1
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    foo.
    CRYSTAL
    foo.placeholder
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    @documents_mutex.synchronize { @opened_documents[uri] = doc }
    @
    CRYSTAL
    @documents_mutex.synchronize { @opened_documents[uri] = doc }
    @placeholder
    CRYSTAL

  it "keeps one-line { } blocks intact when only a sigil needs fixing" do
    source = <<-CRYSTAL
      @documents_mutex.synchronize { @opened_documents[uri] = doc }
      @
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    fixed.should eq("  @documents_mutex.synchronize { @opened_documents[uri] = doc }\n  @placeholder")
    Crystal::Parser.parse(fixed)
  end

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    if foo
    CRYSTAL
    if foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      if bar
    end
    CRYSTAL
    def foo
      if bar; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      if bar

      puts 1
    end
    CRYSTAL
    def foo
      if bar
      end
      puts 1
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      if bar
        if baz

      puts 1
    end
    CRYSTAL
    def foo
      if bar
        if baz
        end; end
      puts 1
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    class Foo
      def bar
      end
    CRYSTAL
    class Foo
      def bar
      end; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    module Foo
      def bar
      end
    CRYSTAL
    module Foo
      def bar
      end; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    struct Foo
      def bar
      end
    CRYSTAL
    struct Foo
      def bar
      end; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    enum Foo
      def bar
      end
    CRYSTAL
    enum Foo
      def bar
      end; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    class Foo
      annotation Bar
    end
    CRYSTAL
    class Foo
      annotation Bar; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    class Foo
      def bar
    end
    CRYSTAL
    class Foo
      def bar; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call(1) do
    end
    CRYSTAL
    def foo
      call(1) do; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call(1) do |x|
    end
    CRYSTAL
    def foo
      call(1) do |x|; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call(1) do |x, y|
    end
    CRYSTAL
    def foo
      call(1) do |x, y|; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call do
    end
    CRYSTAL
    def foo
      call do; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call(1) {
    end
    CRYSTAL
    def foo
      call(1) {; }
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call(1) { |x|
    end
    CRYSTAL
    def foo
      call(1) { |x|; }
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call(1) { |x, y|
    end
    CRYSTAL
    def foo
      call(1) { |x, y|; }
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call {
    end
    CRYSTAL
    def foo
      call {; }
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      call x {
    end
    CRYSTAL
    def foo
      call x {; }
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    call x {
    CRYSTAL
    call x {; }
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    unless foo
    CRYSTAL
    unless foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    while foo
    CRYSTAL
    while foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    until foo
    CRYSTAL
    until foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      if bar
        1
      else
    end
    CRYSTAL
    def foo
      if bar
        1
      else; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      unless bar
        1
      else
    end
    CRYSTAL
    def foo
      unless bar
        1
      else; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      if bar
        1
      elsif bar
    end
    CRYSTAL
    def foo
      if bar
        1
      elsif bar; end
    end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private def foo
    CRYSTAL
    private def foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    protected def foo
    CRYSTAL
    protected def foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private class Foo
    CRYSTAL
    private class Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private struct Foo
    CRYSTAL
    private struct Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private module Foo
    CRYSTAL
    private module Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private enum Foo
    CRYSTAL
    private enum Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private annotation Foo
    CRYSTAL
    private annotation Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    abstract class Foo
    CRYSTAL
    abstract class Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private abstract class Foo
    CRYSTAL
    private abstract class Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    abstract struct Foo
    CRYSTAL
    abstract struct Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    private abstract struct Foo
    CRYSTAL
    private abstract struct Foo; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo(
    )
      1
    CRYSTAL
    def foo(
    )
      1; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    foo 1,
      bar do
    CRYSTAL
    foo 1,
      bar do; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    begin
      puts 1
    CRYSTAL
    begin
      puts 1; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    begin
      puts 1
    rescue
      puts 2
    CRYSTAL
    begin
      puts 1
    rescue
      puts 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    begin
      puts 1
    rescue ex
      puts 2
    CRYSTAL
    begin
      puts 1
    rescue ex
      puts 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    begin
      puts 1
    ensure
      puts 2
    CRYSTAL
    begin
      puts 1
    ensure
      puts 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    begin
      puts 1
    rescue
      puts 2
    else
      puts 3
    CRYSTAL
    begin
      puts 1
    rescue
      puts 2
    else
      puts 3; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      puts 1
    rescue
      puts 2
    CRYSTAL
    def foo
      puts 1
    rescue
      puts 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      puts 1
    rescue
      puts 2
    else
      puts 3
    CRYSTAL
    def foo
      puts 1
    rescue
      puts 2
    else
      puts 3; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      puts 1
    ensure
      puts 2
    CRYSTAL
    def foo
      puts 1
    ensure
      puts 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    foo do |x|
      puts 1
    rescue
      puts 2
    CRYSTAL
    foo do |x|
      puts 1
    rescue
      puts 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    foo do |x|
      puts 1
    rescue
      puts 2
    else
      puts 3
    CRYSTAL
    foo do |x|
      puts 1
    rescue
      puts 2
    else
      puts 3; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    foo do |x|
      puts 1
    ensure
      puts 2
    CRYSTAL
    foo do |x|
      puts 1
    ensure
      puts 2; end
    CRYSTAL

  # A blank line before a closing keyword is not a visual dedent: the real
  # `end` closes the block, and a sibling block still needs its own end.
  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      x = 1

    end

    def bar
      y = 2
    CRYSTAL
    def foo
      x = 1

    end

    def bar
      y = 2; end
    CRYSTAL

  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
      if bar
        1

      else
        2
      end
    CRYSTAL
    def foo
      if bar
        1

      else
        2
      end; end
    CRYSTAL

  # Comment-only lines must never be interpreted as keywords.
  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
    # the end is near
    x = 1
    CRYSTAL
    def foo
    # the end is near
    x = 1; end
    CRYSTAL

  # A word ending in "end" (e.g. `depend`) is not a closing keyword.
  it_fixes <<-CRYSTAL, <<-CRYSTAL
    def foo
    depend = 1
    CRYSTAL
    def foo
    depend = 1; end
    CRYSTAL

  # `case`/`when` and `macro` blocks must survive the balancing pass, and an
  # `end` orphaned by deleting a block header is dropped without closing its
  # opener.
  it "balances case and macro blocks and drops orphaned ends" do
    source = <<-CRYSTAL
      class Foo
        def severity_name(severity : Severity) : String
          case severity
          when Severity::Info
            "info"
          end
        end

        macro define_handler(name)
          def {{name.id}}
            {{block.body}}
          end
        end

        def collect_ids : Array(Int32)
          ids = [] of Int32
          @events.
          ids << key unless key == 0
          end
          ids
        end
      end
    CRYSTAL

    fixed = Crystalline::BrokenSourceFixer.fix(source)
    Crystal::Parser.parse(fixed)
    fixed.should_not contain("end\n          end")
    fixed.should_not contain("ids << key unless key == 0\n          end")
  end

  # The wave-15 sweep cuts a real source line at its last dot (the
  # in-progress-typing state) and requires the fixer to restore a parseable
  # program. Sites are located by content so line shifts fail loudly instead
  # of silently testing the wrong line; duplicated patterns use occurrence
  # order (the sweep hit both `LSP::CompletionItem.new(` sites).
  describe "real cut sites from the lightweight sweep" do
    SITES.each do |(rel, pattern, occurrence, label)|
      it "repairs the #{label} (#{rel})" do
        lines = File.read_lines(File.join(SPEC_SRC_ROOT, rel))
        count = 0
        li = nil
        lines.each_with_index do |l, i|
          if l.includes?(pattern)
            count += 1
            li = i if count == occurrence
          end
        end
        raise "site not found: #{pattern} ##{occurrence} in #{rel}" unless li
        line = lines[li.not_nil!]
        last_dot = line.rindex('.')
        raise "bad site: #{rel} line #{li.not_nil! + 1}" unless last_dot && last_dot > 0 && last_dot < line.size - 1

        lines[li.not_nil!] = line[0, last_dot + 1]
        fixed = Crystalline::BrokenSourceFixer.fix(lines.join("\n"))
        Crystal::Parser.parse(fixed)
      end
    end

    it "passes valid sources through unchanged" do
      %w[src/crystalline/workspace.cr src/crystalline/controller.cr src/crystalline/lightweight/inference.cr].each do |rel|
        source = File.read(File.join(SPEC_SRC_ROOT, rel))
        Crystalline::BrokenSourceFixer.fix(source).rstrip('\n').should eq(source.rstrip('\n'))
      end
    end

    it "leaves the fixer's own multi-line regex literal unparseable (known remaining)" do
      lines = File.read_lines(File.join(SPEC_SRC_ROOT, "src/crystalline/broken_source_fixer.cr"))
      li = lines.index { |l| l.lstrip.starts_with?("if line.starts_with?") }
      raise "self-regex site not found" unless li
      line = lines[li.not_nil!]
      last_dot = line.rindex('.')
      raise "bad site" unless last_dot

      lines[li.not_nil!] = line[0, last_dot + 1]
      fixed = Crystalline::BrokenSourceFixer.fix(lines.join("\n"))
      expect_raises(Crystal::SyntaxException) { Crystal::Parser.parse(fixed) }
    end
  end
end
