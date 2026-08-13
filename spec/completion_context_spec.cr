require "spec"
require "lsp/server"
require "../src/crystalline/completion_context"

describe Crystalline::CompletionContext do
  it "returns nil inside comments" do
    context = Crystalline::CompletionContext.detect("foo # bar.", 10, ".")
    context.should be_nil
  end

  it "returns nil inside quoted strings" do
    context = Crystalline::CompletionContext.detect("\"foo.bar\"", 7, nil)
    context.should be_nil
  end

  it "returns nil inside regex literals" do
    context = Crystalline::CompletionContext.detect("/foo./", 5, nil)
    context.should be_nil
  end

  it "returns nil inside percent string literals" do
    context = Crystalline::CompletionContext.detect("%(foo.bar)", 8, nil)
    context.should be_nil
  end

  it "still completes after a closed string literal" do
    context = Crystalline::CompletionContext.detect("\"a\".up", 6, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(".")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(4)
    context.replace_end.should eq(6)
  end

  it "still completes after a closed regex literal" do
    context = Crystalline::CompletionContext.detect("/a/.up", 6, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(".")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(4)
    context.replace_end.should eq(6)
  end

  it "still completes after a closed percent string literal" do
    context = Crystalline::CompletionContext.detect("%(a).up", 7, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(".")
    context.analysis_column.should eq(4)
    context.replace_start.should eq(5)
    context.replace_end.should eq(7)
  end

  it "detects dot completion from an identifier fragment" do
    context = Crystalline::CompletionContext.detect("foo.ba", 6, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(".")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(4)
    context.replace_end.should eq(6)
  end

  it "detects namespace completion from a path fragment" do
    context = Crystalline::CompletionContext.detect("Foo::Ba", 7, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(":")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(5)
    context.replace_end.should eq(7)
  end

  it "detects ivar completion and includes the sigil in replacement" do
    context = Crystalline::CompletionContext.detect("@iv", 3, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq("@")
    context.analysis_column.should eq(0)
    context.replace_start.should eq(0)
    context.replace_end.should eq(3)
  end

  it "detects a lone @ as ivar completion" do
    context = Crystalline::CompletionContext.detect("    @", 5, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq("@")
    context.analysis_column.should eq(4)
    context.replace_start.should eq(4)
    context.replace_end.should eq(5)
  end

  it "does not let a placeholder after the sigil widen the replace range" do
    context = Crystalline::CompletionContext.detect("    @placeholder", 5, nil)
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq("@")
    context.replace_start.should eq(4)
    context.replace_end.should eq(5)
  end

  it "handles explicit dot triggers" do
    context = Crystalline::CompletionContext.detect("foo.", 4, ".")
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(".")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(4)
    context.replace_end.should eq(4)
  end

  it "infers the dot trigger when the reported trigger is an identifier character" do
    # Clients register the identifier characters as completion triggers:
    # typing `foo.a` arrives with trigger "a", but the receiver analysis
    # must still end at the dot or the method list is replaced by context
    # items.
    context = Crystalline::CompletionContext.detect("foo.a", 5, "a")
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(".")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(4)
    context.replace_end.should eq(5)
  end

  it "infers the :: trigger from an identifier-character trigger" do
    context = Crystalline::CompletionContext.detect("Foo::B", 6, "B")
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq(":")
    context.analysis_column.should eq(3)
    context.replace_start.should eq(5)
    context.replace_end.should eq(6)
  end

  it "infers the sigil trigger from an identifier-character trigger" do
    context = Crystalline::CompletionContext.detect("@docu", 5, "u")
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq("@")
    context.analysis_column.should eq(0)
    context.replace_start.should eq(0)
    context.replace_end.should eq(5)
  end

  it "keeps plain-word completions in context mode for identifier triggers" do
    context = Crystalline::CompletionContext.detect("  greeter", 9, "r")
    context.should_not be_nil
    context = context.not_nil!

    context.trigger_character.should eq("r")
    context.analysis_column.should eq(9)
  end
end
