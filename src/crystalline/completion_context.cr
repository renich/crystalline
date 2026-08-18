require "compiler/crystal/syntax"
require "./position_utils"

class Crystalline::CompletionContext
  record TokenSpan,
    type : Crystal::Token::Kind,
    start_char : Int32,
    end_char : Int32,
    delimiter_kind : Crystal::Token::DelimiterKind? = nil,
    delimiter_end : String? = nil

  getter trigger_character : String?
  getter analysis_column : Int32
  getter replace_start : Int32
  getter replace_end : Int32

  def self.detect(line : String, cursor : Int32, trigger_character : String?) : self?
    new(line, cursor, trigger_character).detect
  end

  def initialize(@line : String, @cursor : Int32, @trigger_character : String?)
    @analysis_column = cursor
    @replace_start = cursor
    @replace_end = cursor
  end

  def detect : self?
    # The LSP cursor column is UTF-16-based; everything computed from it
    # (fragments, token spans, analysis column) is character-based.
    @cursor = PositionUtils.utf16_to_char_index(@line, @cursor)

    fragment_start, fragment_end = identifier_fragment_bounds
    @replace_start = fragment_start
    @replace_end = fragment_end

    tokens = begin
      tokens_for_line
    rescue Crystal::SyntaxException
      # Mid-edit lines can contain lexer garbage (a lone `@`, an unterminated
      # string...): fall back to an empty token list so completion detection
      # can still run on the fragment.
      [] of TokenSpan
    end
    # The lexer lexes a `#{` inside a string as the start of a comment, and
    # the cursor is "inside a string" per the delimiter scan — but an
    # interpolation is code: completion should still work there
    # (`"#{position.`).
    in_interpolation = (interp = @line.rindex("\#{", @cursor)) && !@line[interp + 2, @cursor - interp - 2].includes?('}')
    return if !in_interpolation && (inside_comment?(tokens) || inside_delimited_literal?(tokens))

    trigger = @trigger_character
    if trigger.nil? || trigger.matches?(/\A[A-Za-z]\z/) || trigger == "_"
      # Clients register the identifier characters as completion triggers
      # (per-keystroke completions), so typing `foo.a` arrives with
      # trigger "a" — but the receiver is still `foo`, and the analysis
      # must end at the trigger dot (or `::`/sigil) or the method list is
      # replaced by plain context items. Infer the structural trigger from
      # the line when the reported one is an identifier character.
      if inferred = inferred_trigger(tokens, fragment_start)
        @trigger_character = inferred
      end
    end

    case @trigger_character
    when "."
      if operator = preceding_period(tokens, fragment_start)
        @analysis_column = operator.start_char
        @replace_start = operator.end_char
      elsif fragment_start > 0 && @line[fragment_start - 1] == '.'
        # The tokenizer could not identify the period (mid-edit lexer
        # failures on regex/string-heavy lines): the character before
        # the fragment is still the trigger, so the analysis prefix
        # must end there — otherwise the fragment is dragged into the
        # receiver chain (`foo.scan(/x/).placeholde`) and resolution
        # fails on it.
        @analysis_column = fragment_start - 1
        @replace_start = fragment_start
      end
    when ":"
      if operator = preceding_colon_colon(tokens, fragment_start)
        @analysis_column = operator.start_char
        @replace_start = operator.end_char
      end
    when "@"
      # The replace range covers the sigil (`@documents_`), so the edit
      # text carries the full name and VSCode's filter word matches the
      # filterText as a clean prefix. The range ends at the cursor: the
      # fixer may have appended a placeholder name to the sigil, which the
      # user has not typed.
      if sigil = current_sigiled_token(tokens)
        @analysis_column = sigil.start_char
        @replace_start = sigil.start_char
        @replace_end = @cursor
      elsif @cursor > 1 && @line[@cursor - 2, 2]? == "@@"
        @analysis_column = @cursor - 2
        @replace_start = @cursor - 2
        @replace_end = @cursor
      elsif @cursor > 0 && @line[@cursor - 1] == '@'
        @analysis_column = @cursor - 1
        @replace_start = @cursor - 1
        @replace_end = @cursor
      end
    else
      @analysis_column = @cursor
    end

    self
  rescue Crystal::SyntaxException
    nil
  end

  def analysis_prefix : String
    @line[0...@analysis_column]
  end

  def completion_range(line_number : Int32) : LSP::Range
    LSP::Range.new(
      start: LSP::Position.new(line: line_number, character: PositionUtils.char_to_utf16_index(@line, @replace_start)),
      end: LSP::Position.new(line: line_number, character: PositionUtils.char_to_utf16_index(@line, @replace_end)),
    )
  end

  private def identifier_fragment_bounds
    start_char = @cursor
    while start_char > 0 && ident_char?(@line[start_char - 1])
      start_char -= 1
    end

    end_char = @cursor
    while (char = @line[end_char]?) && ident_char?(char)
      end_char += 1
    end

    {start_char, end_char}
  end

  private def tokens_for_line
    lexer = Crystal::Lexer.new(@line)
    lexer.comments_enabled = true

    spans = [] of TokenSpan

    loop do
      token = lexer.next_token
      break if token.type.eof? || token.type.newline?
      length = token_length(token)
      spans << TokenSpan.new(
        type: token.type,
        start_char: token.column_number - 1,
        end_char: token.column_number - 1 + length,
        delimiter_kind: token.type.delimiter_start? ? token.delimiter_state.kind : nil,
        delimiter_end: token.type.delimiter_start? ? token.delimiter_state.end.to_s : nil,
      ) if length > 0
    end

    spans
  end

  private def token_length(token)
    case token.type
    when .ident?, .const?, .instance_var?, .class_var?, .comment?, .global?, .symbol?, .number?
      token.value.to_s.size
    when .delimiter_start?
      token.delimiter_state.kind.in?(Crystal::Token::DelimiterKind::STRING, Crystal::Token::DelimiterKind::REGEX) ? 1 : 2
    when .op_colon_colon?
      2
    when .op_period?
      1
    else
      token.type.to_s.size
    end
  end

  private def inside_comment?(tokens : Array(TokenSpan))
    tokens.any? { |token| token.type.comment? && @cursor >= token.start_char }
  end

  private def inside_delimited_literal?(tokens : Array(TokenSpan))
    open_delimiter = nil.as(TokenSpan?)

    tokens.each do |token|
      if current = open_delimiter
        if delimiter_end?(token, current)
          return true if @cursor > current.start_char && @cursor <= token.start_char
          open_delimiter = nil
        else
          return true if @cursor >= token.start_char && @cursor < token.end_char
        end
      elsif token.type.delimiter_start?
        open_delimiter = token
      end
    end

    open_delimiter ? @cursor > open_delimiter.not_nil!.start_char : false
  end

  private def delimiter_end?(token : TokenSpan, current : TokenSpan)
    delimiter_end = current.delimiter_end
    return false unless delimiter_end

    if token.type.delimiter_start?
      token.delimiter_end == delimiter_end
    else
      token_text(token) == delimiter_end
    end
  end

  private def inferred_trigger(tokens : Array(TokenSpan), fragment_start : Int32)
    if token = current_sigiled_token(tokens)
      return "@" if token.type.instance_var? || token.type.class_var?
    elsif @cursor > 0 && @line[@cursor - 1] == '@'
      return "@"
    end

    return "." if preceding_period(tokens, fragment_start)
    return ":" if preceding_colon_colon(tokens, fragment_start)

    # Fallback for mid-edit lines the lexer cannot tokenize as code (a `#{`
    # inside a string lexes as a comment): the character before the fragment
    # still tells us the trigger.
    if fragment_start > 0
      return "." if @line[fragment_start - 1] == '.'
      return ":" if fragment_start >= 2 && @line[fragment_start - 2, 2] == "::"
    end
  end

  private def current_sigiled_token(tokens : Array(TokenSpan))
    tokens.find do |token|
      (token.type.instance_var? || token.type.class_var?) &&
        @cursor >= token.start_char &&
        @cursor <= token.end_char
    end
  end

  private def preceding_period(tokens : Array(TokenSpan), fragment_start : Int32)
    tokens.reverse_each.find do |token|
      token.type.op_period? && token.end_char == fragment_start
    end
  end

  private def preceding_colon_colon(tokens : Array(TokenSpan), fragment_start : Int32)
    tokens.reverse_each.find do |token|
      token.type.op_colon_colon? && token.end_char == fragment_start
    end
  end

  private def token_text(token : TokenSpan)
    case token.type
    when .op_colon_colon?
      "::"
    when .op_period?
      "."
    else
      @line[token.start_char, token.end_char - token.start_char]? || ""
    end
  end

  private def ident_char?(char : Char)
    char.ascii_alphanumeric? || char == '_' || char == '?' || char == '!'
  end
end
