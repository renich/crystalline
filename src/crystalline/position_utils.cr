module Crystalline::PositionUtils
  extend self

  # LSP positions are UTF-16 code units while Crystal source positions
  # (lexer/parser columns, String#[]) are character-based. Both are identical
  # unless the line contains astral-plane characters (e.g. emoji), which
  # occupy one character but two UTF-16 code units.
  #
  # Convert a UTF-16 column to a character index within *line*.
  def utf16_to_char_index(line : String, utf16_index : Int32) : Int32
    return utf16_index if utf16_index <= 0

    char_index = 0
    line.each_char do |char|
      break if utf16_index <= 0
      utf16_index -= (char.ord > 0xFFFF ? 2 : 1)
      char_index += 1
    end
    char_index
  end

  # Convert a character index within *line* back to a UTF-16 column.
  def char_to_utf16_index(line : String, char_index : Int32) : Int32
    return char_index if char_index <= 0

    utf16_index = 0
    line.each_char_with_index do |char, index|
      break if index >= char_index
      utf16_index += (char.ord > 0xFFFF ? 2 : 1)
    end
    utf16_index
  end
end
