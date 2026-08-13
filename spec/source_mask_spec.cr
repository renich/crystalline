require "spec"
require "../src/crystalline/source_mask"

describe Crystalline::SourceMask do
  it "masks comments" do
    mask = Crystalline::SourceMask.new("x = 1 # the end\n")
    mask.comment_or_string?(0, 6).should be_true
    mask.comment_or_string?(0, 4).should be_false
  end

  it "masks string and char literals but not surrounding code" do
    source = %(x = "foo" + 'c' + "bar"\n)
    mask = Crystalline::SourceMask.new(source)
    mask.comment_or_string?(0, 5).should be_true  # inside "foo"
    mask.comment_or_string?(0, 13).should be_true # inside 'c'
    mask.comment_or_string?(0, 20).should be_true # inside "bar"
    mask.comment_or_string?(0, 2).should be_false # code
  end

  it "masks heredoc bodies until the terminator" do
    source = <<-SRC
      def demo
        text = <<-CRYSTAL
      hello world
        CRYSTAL
        text
      end
    SRC
    mask = Crystalline::SourceMask.new(source)
    mask.comment_or_string?(2, 0).should be_true # heredoc body
    mask.comment_or_string?(2, 6).should be_true
    mask.comment_or_string?(3, 0).should be_false # terminator line
    mask.comment_or_string?(4, 4).should be_false # code after
  end

  it "does not mistake shift-left expressions for heredocs" do
    mask = Crystalline::SourceMask.new("x << y\nz = 1\n")
    mask.comment_or_string?(1, 0).should be_false
  end
end
