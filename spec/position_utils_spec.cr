require "spec"
require "../src/crystalline/position_utils"

# "aé😀bc": a = 1 code unit, é = 1, 😀 (astral) = 2, b = 1, c = 1.
LINE = "aé😀bc"

describe Crystalline::PositionUtils do
  describe ".utf16_to_char_index" do
    it "is the identity on ascii lines" do
      Crystalline::PositionUtils.utf16_to_char_index("abc", 2).should eq(2)
    end

    it "maps bmp characters one-to-one" do
      Crystalline::PositionUtils.utf16_to_char_index(LINE, 2).should eq(2)
    end

    it "accounts for astral characters" do
      Crystalline::PositionUtils.utf16_to_char_index(LINE, 4).should eq(3)
    end

    it "clamps past the end of the line" do
      Crystalline::PositionUtils.utf16_to_char_index(LINE, 99).should eq(5)
    end
  end

  describe ".char_to_utf16_index" do
    it "is the identity on ascii lines" do
      Crystalline::PositionUtils.char_to_utf16_index("abc", 2).should eq(2)
    end

    it "accounts for astral characters" do
      Crystalline::PositionUtils.char_to_utf16_index(LINE, 3).should eq(4)
      Crystalline::PositionUtils.char_to_utf16_index(LINE, 5).should eq(6)
    end
  end
end
