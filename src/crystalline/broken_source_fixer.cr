class Crystalline::BrokenSourceFixer
  # Keep track of opening and closing keywords, and their idents,
  # as they happen in the code.
  record LineInfo,
    line_index : Int32,
    indent : Int32,
    keyword : String

  # Try to fix a broken source code by adding missing "end" and "}"
  # according to indentation.
  def self.fix(source : String) : String
    # A trailing dot (mid-typing `foo.`) is a syntax error the parser cannot
    # recover from: append a placeholder identifier so the rest of the source
    # still parses (and completion on the receiver keeps working).
    lines = source.lines.map do |line|
      # A trailing dot inside a comment is sentence punctuation, not a
      # method-call receiver: never append the placeholder there.
      if !line.lstrip.starts_with?("#") && (dot_index = trailing_dot_index(line))
        # The truncation deleted the line's tail, which may have held the
        # closing delimiters of calls opened before the dot: re-close them
        # right after the placeholder so the rest of the file still parses.
        closers = missing_closers(line[0...dot_index])
        # A cut inside the true-branch of a ternary (`cond ? foo.`) deleted
        # the else branch: supply `: nil` or the parser stops at the next
        # `end` expecting the ternary's `:`.
        ternary = ternary_else_suffix(line[0...dot_index])
        "#{line[0...dot_index + 1]}placeholder#{closers}#{ternary}#{line[dot_index + 1..]}#{line.ends_with?('\n') ? '\n' : ""}"
      elsif !line.lstrip.starts_with?("#") && (sigil_match = line.match(/@+$/))
        # A lone sigil (`@` or `@@`) mid-edit is the same kind of error:
        # give it a placeholder name so the rest of the source parses.
        "#{line[0...sigil_match.begin(0)]}#{sigil_match[0]}placeholder#{line.ends_with?('\n') ? '\n' : ""}"
      elsif !line.lstrip.starts_with?("#") && (colon_match = line.match(/::$/))
        # A trailing `::` (e.g. `when Severity::` mid-edit) needs a CONST
        # name after it before the source parses.
        "#{line[0...colon_match.begin(0)]}::Placeholder#{line.ends_with?('\n') ? '\n' : ""}"
      else
        line
      end
    end

    fixed = lines.join("\n")
    return fixed if parses?(fixed)

    # A trailing-dot cut can land inside a call opened on an EARLIER line
    # (`Location.new(\n  file_uri.`): the delimiters opened before the cut
    # are re-closed right after the placeholder, and the call's orphaned
    # remainder (its remaining argument lines and closing delimiter) is
    # dropped so the rest of the file still parses.
    if fix_multiline_call_tails!(lines)
      fixed = lines.join("\n")
      return fixed if parses?(fixed)
    end

    # A trailing-dot cut can delete a `do`-block header (`tokens.each do
    # |x|` -> `tokens.`): the block body and its `end` dangle below with
    # no opener. When the lines below form a self-contained block body
    # (a bare `end` at the cut's indent within a bounded window, nothing
    # shallower in between), re-open the block with `do` so the body's
    # own `end` closes it. Parse-guarded on a copy: a candidate that
    # does not parse leaves the lines untouched for the balance pass.
    if fix_block_tails!(lines)
      fixed = lines.join("\n")
      return fixed if parses?(fixed)
    end

    # The indentation-balancing pass is a last resort: it can make a broken
    # file worse (e.g. appending closers to unrelated lines). Only apply it
    # when the line fixes were not enough, and fall back to the line-fixed
    # version if the balanced output still does not parse.
    balanced = lines.dup
    balance!(balanced)
    fixed = balanced.join("\n")
    return fixed if parses?(fixed)

    # Mid-edit truncations can leave unterminated calls (`foo.bar(` with
    # the closing paren deleted): append the missing closing delimiters
    # at the end of the file so the rest parses.
    delimiter_fixed = balance_delimiters(fixed)
    return delimiter_fixed if parses?(delimiter_fixed)

    lines.join("\n")
  end

  private def self.parses?(source : String) : Bool
    Crystal::Parser.parse(source)
    true
  rescue
    false
  end

  private def self.balance!(lines : Array(String))
    # Keep a stack of opening keywords.
    # We push to the stack when we find an opening keyword and
    # we pop from the stack when we find a closing keyword,
    # or when we find a wrong indentation.
    stack = [] of LineInfo
    line_index = 0
    while line_index < lines.size
      line = lines[line_index]
      if line.blank? || line.lstrip.starts_with?('#') || line.lstrip.starts_with?("{%")
        # Blank lines, comment-only lines (can contain any text, e.g.
        # "the end") and macro lines (`{% if ... %}` / `{% end %}` carry
        # their own structure) are never interpreted as keywords.
        line_index += 1
        next
      end

      keyword = line_keyword(line)
      indent = line_indent(line)
      # A blank line before the current line signals a visual dedent: the
      # user left the block (without typing `end`).
      was_blank_gap = line_index > 0 && lines[line_index - 1].blank?

      # A line can both close a block and open a new one
      # (`}.try do |x|`, `end.each do |x|`): line_keyword reports only the
      # trailing opener, so the leading closer would be lost and the block
      # it closes would leak until a wrong-indent `; end` append corrupts
      # the line below. Close the leading closer first.
      if (keyword == "do" || keyword == "{") && (stripped = line.lstrip)
        if stripped.starts_with?('}')
          if last_info = stack.last?
            if last_info.keyword == "{"
              stack.pop
            elsif brace_index = stack.rindex { |info| info.keyword == "{" }
              stack.pop(stack.size - brace_index)
            end
          end
        elsif stripped.starts_with?("end") && (stripped.size == 3 || !stripped[3].ascii_alphanumeric?)
          if last_info = stack.last?
            stack.pop if last_info.keyword != "{"
          end
        end
      end

      while true
        last_info = stack.last?
        break unless last_info

        closing_keyword = closing_keyword(last_info)

        # Nothing to fix unless there's a wrong indent
        break unless wrong_indent?(indent, keyword, closing_keyword, last_info, line, was_blank_gap)

        # We have a wrong indentation so we fix/close the opening keyword
        # by adding an "end" (or "}") to it.
        last_line = lines[line_index - 1]

        lines[line_index - 1] =
          if last_line.blank?
            # If the line is empty we can change it to an end
            # and even use the correct indent.
            "#{("  " * last_info.indent)}#{closing_keyword}"
          else
            "#{last_line}; #{closing_keyword}"
          end

        stack.pop
      end

      # If we found a closing keyword matching the last opening keyword,
      # pop it. A mid-edit can leave an `end` with no opener (e.g. after
      # deleting a `do |x|` block header): treat it as closing the nearest
      # matching opener anyway so the rest of the file still parses.
      if last_info = stack.last?
        if keyword == "}" && last_info.keyword != "{"
          # A `}` closes the nearest `{` opener even when inner openers
          # sit above it (they are implicitly closed by the block's end):
          # pop everything down to and including the `{`.
          if brace_index = stack.rindex { |info| info.keyword == "{" }
            stack.pop(stack.size - brace_index)
            line_index += 1
            next
          end
        end

        if keyword == closing_keyword(last_info)
          if indent > last_info.indent + 1
            # A much deeper `end` is a legit closer aligned with its
            # branches (`value = if cond\n  a\nelse\n  b\nend` ends deeper
            # than the `if`): close the opener normally.
            stack.pop
          elsif indent > last_info.indent && keyword == "end"
            # An `end` one level deeper than its opener is an orphan left
            # behind by a deleted block header: drop the line (without
            # closing the opener) so the file still parses. A `}` one level
            # deeper is the normal closing style and is never dropped. The
            # deletion shifts every later line: keep the stack's stored
            # indices in sync, and re-examine the line that shifted into
            # this slot (it may be the enclosing block's real `end`, which
            # an each_with_index loop would silently skip).
            lines.delete_at(line_index)
            stack.map! do |info|
              info.line_index > line_index ? LineInfo.new(info.line_index - 1, info.indent, info.keyword) : info
            end
            next
          else
            stack.pop
          end
          line_index += 1
          next
        end
      end

      # Push to the stack if we found an opening keyword.
      if keyword && !closing_keyword?(keyword)
        stack << LineInfo.new(
          line_index: line_index,
          indent: indent,
          keyword: keyword
        )
      end
      line_index += 1
    end

    while (line_info = stack.pop?)
      lines[-1] = "#{lines[-1]}; #{closing_keyword(line_info)}"
    end
  end

  # The closing delimiters missing from *source*: `(`/`[`/`{` opened
  # without their match (strings, chars and comments are skipped; the
  # callers guard with a parse check, so a miscount simply falls back).
  private def self.missing_closers(source : String) : String
    openers = [] of Char
    quote = nil.as(Char?)
    prev = nil.as(Char?)
    chars = source.chars
    index = 0
    while index < chars.size
      char = chars[index]
      if quote
        if char == '\\'
          index += 2
          next
        elsif char == quote
          quote = nil
        end
      elsif char.in?('"', '\'')
        quote = char
      elsif char == '/' && regex_position?(prev)
        # A regex literal: skip to its unescaped closing slash (a slash
        # inside a `[...]` character class does not close it), so parens
        # inside regexes (e.g. `\.try\s*(?:\(\s*)?`) are not counted.
        index += 1
        in_class = false
        while index < chars.size
          c = chars[index]
          if c == '\\'
            index += 2
            next
          elsif c == '['
            in_class = true
          elsif c == ']'
            in_class = false
          elsif c == '/' && !in_class
            break
          end
          index += 1
        end
      elsif char == '#'
        index += 1
        while index < chars.size && chars[index] != '\n'
          index += 1
        end
        next
      elsif char.in?('(', '[', '{')
        openers << char
      elsif char.in?(')', ']', '}')
        if openers.last? == delimiter_counterpart(char)
          openers.pop
        end
      end
      prev = char unless char.whitespace? || quote
      index += 1
    end
    openers.reverse.map { |opener| delimiter_counterpart(opener) }.join
  end

  # Whether the cut prefix ends inside the true-branch of an unclosed
  # ternary (`cond ? receiver`): ` ? ` (a `?` preceded by whitespace or
  # an opener and followed by whitespace — not a `foo?` method name, a
  # `String?` nilable type or a `?a` char literal) with no `:` else
  # branch after it on the line. Returns the ` : nil` suffix to supply,
  # or an empty string when the ternary is complete or absent.
  private def self.ternary_else_suffix(prefix : String) : String
    last_ternary = -1
    quote = nil.as(Char?)
    prev = nil.as(Char?)
    chars = prefix.chars
    index = 0
    while index < chars.size
      char = chars[index]
      if quote
        quote = nil if char == quote
      elsif char.in?('"', '\'')
        quote = char
      elsif char == '?'
        nxt = index + 1 < chars.size ? chars[index + 1] : nil
        # A ternary `?` is spaced on both sides; `foo?`, `String?`,
        # `?a` and the nilable forms `x[0]?` / `foo()?` are not.
        if prev && nxt && nxt.whitespace? && !prev.ascii_alphanumeric? && prev != '_' && prev != '?' && !prev.in?(')', ']', '}')
          last_ternary = index
        end
      end
      prev = char
      index += 1
    end
    return "" if last_ternary < 0

    has_colon = false
    quote = nil.as(Char?)
    index = last_ternary + 1
    while index < chars.size
      char = chars[index]
      if quote
        quote = nil if char == quote
      elsif char.in?('"', '\'')
        quote = char
      elsif char == ':'
        has_colon = true
        break
      end
      index += 1
    end
    has_colon ? "" : " : nil"
  end

  # Whether a `/` at this position starts a regex literal rather than a
  # division: after a value (identifier, literal, closer, string) it is
  # division; at the start or after an operator/paren/comma it is a regex.
  private def self.regex_position?(prev : Char?) : Bool
    prev.nil? || (!prev.ascii_alphanumeric? && prev != '_' && !prev.in?(')', ']', '}', '"', '\''))
  end

  private def self.delimiter_counterpart(char : Char) : Char
    case char
    when '(' then ')'
    when '[' then ']'
    when '{' then '}'
    when ')' then '('
    when ']' then '['
    else          '{'
    end
  end

  private def self.balance_delimiters(source : String) : String
    closers = missing_closers(source)
    closers.empty? ? source : source + closers
  end

  # Re-closes delimiters opened BEFORE a trailing-dot cut and drops the
  # orphaned tail of the call the cut landed in. The line pass already
  # closed delimiters opened on the cut line itself; only delimiters open
  # since an earlier line indicate a multi-line call whose remainder
  # (remaining argument lines plus the closing delimiter) dangles below.
  # Returns true if any line was removed.
  private def self.fix_multiline_call_tails!(lines : Array(String)) : Bool
    changed = false
    deletions = [] of {Int32, Int32}
    line_index = 0
    while line_index < lines.size
      line = lines[line_index]
      if (dot = line.rindex(".placeholder"))
        entering = openers_before(lines, line_index)
        if entering.empty?
          # The cut may have deleted the call's OWN opener (`Foo.new(` ->
          # `Foo.`): the call's argument lines dangle below with no
          # delimiter to anchor them. Drop the tail when it looks like a
          # pure call remainder.
          if drop_dangling_args!(lines, line_index, deletions)
            changed = true
          end
        else
          # The cut is directly inside the TOP delimiter opened before it
          # (e.g. `Location.new(` above `file_uri.`); the openers further
          # down the stack belong to enclosing blocks whose closers come
          # later and must be left alone.
          top = entering[0]
          if top == '}'
            # The cut sits inside a brace block whose own closer may be
            # far below, while the deleted call's closer dangles right
            # under the cut. Drop the dangling tail; close the brace
            # inline only when the tail ends in the brace's own `}` (a
            # tuple), not a `)`/`]` that belongs to the deleted call.
            closer = drop_dangling_args!(lines, line_index, deletions)
            if closer
              changed = true
              if closer == '}'
                lines[line_index] = line.sub(".placeholder", ".placeholder}")
              end
            else
              # No clean tail: fall back to closing the brace inline and
              # dropping its own orphaned remainder (parse-guarded).
              lines[line_index] = line.sub(".placeholder", ".placeholder}")
              stack = ['{']
              j = line_index + 1
              while j < lines.size && !stack.empty? && j - line_index <= 100
                stack = consume_delimiters(stack, lines[j])
                j += 1
              end
              if stack.empty? && j > line_index + 1
                deletions << {line_index + 1, j - 1}
                changed = true
              end
            end
          else
            # A call/array cut: close the nested calls inline (the outer
            # calls' closers would otherwise be eaten by the tail drop,
            # orphaning their openers) and drop the orphaned remainder —
            # the remaining argument lines up to and including the line
            # closing the last nested opener. The closers are appended
            # after the line pass's own closers so the innermost
            # (same-line) call closes first. A `}` in *entering* is an
            # ENCLOSING brace block whose own body and closers live
            # below the cut: it is left alone (its `end`/`}` lines stay).
            # A mismatched closer or a scan that never balances leaves
            # the file as-is (the parse guards fall back).
            prefix = entering[0...(entering.index('}') || entering.size)]
            lines[line_index] = "#{line}#{prefix}"
            # prefix is innermost-first; the scan pops the stack top, so
            # the counterparts must be pushed outermost-first.
            stack = prefix.chars.reverse.map { |closer| delimiter_counterpart(closer) }
            j = line_index + 1
            while j < lines.size && !stack.empty? && j - line_index <= 100
              stack = consume_delimiters(stack, lines[j])
              j += 1
            end
            if stack.empty? && j > line_index + 1
              # An inner call's orphaned closer (`),`) can pop the scan
              # early, leaving the outer call's real closer dangling:
              # when the emptied line is comma-suffixed (mid-call), the
              # outer call's remaining argument lines still dangle below.
              # Extend the deletion over them when they form a pure arg
              # tail (delimiter balance goes negative at its closer).
              if j < lines.size && lines[j - 1].strip.ends_with?(',')
                b = 0
                k = j
                while k < lines.size && k - j <= 30
                  b += net_delimiters(lines[k])
                  if b < 0
                    j = k + 1
                    break
                  end
                  k += 1
                end
              end
              deletions << {line_index + 1, j - 1}
              changed = true
            end
          end
        end
      end
      line_index += 1
    end
    deletions.reverse_each do |from, to|
      to.downto(from) { |i| lines.delete_at(i) }
    end
    changed
  end

  # Re-opens a `do`-block whose header a trailing-dot cut deleted: when
  # the lines below a `.placeholder` line form a self-contained block
  # body (the next non-blank line is deeper-indented and a bare `end`
  # sits at the cut's own indent within a bounded window, with nothing
  # shallower in between), appending ` do` to the cut line lets the
  # body's own `end` close it. Each candidate is parse-checked on a
  # copy before it is committed. Returns true if any line changed.
  private def self.fix_block_tails!(lines : Array(String)) : Bool
    changed = false
    lines.each_with_index do |line, i|
      next unless line.includes?(".placeholder")
      base = line_indent(line)
      next unless base

      j = i + 1
      while j < lines.size && (lines[j].blank? || lines[j].lstrip.starts_with?('#'))
        j += 1
      end
      next if j >= lines.size
      next unless (first_indent = line_indent(lines[j])) && first_indent > base

      found = nil
      k = j
      while k < lines.size && k - i <= 30
        l = lines[k]
        if l.blank? || l.lstrip.starts_with?('#')
          k += 1
          next
        end
        ind = line_indent(l)
        stripped = l.lstrip
        if ind == base && stripped.starts_with?("end") && (stripped.size == 3 || !stripped[3].ascii_alphanumeric?)
          found = k
          break
        end
        # Any line at or above the cut's indent before the `end` means
        # the lines below are not a block body.
        break unless ind && ind > base
        k += 1
      end
      next unless found

      candidate = lines.dup
      candidate[i] = "#{line} do"
      next unless parses?(candidate.join("\n"))
      lines[i] = candidate[i]
      changed = true
    end
    changed
  end

  # The closers needed to close the delimiters opened before *line_index*
  # (top of the stack first). Unlike missing_closers on a joined prefix,
  # the quote/comment state resets at every line boundary: a lone quote in
  # a comment or a char literal must not swallow the rest of the file.
  private def self.openers_before(lines : Array(String), line_index : Int32) : String
    stack = [] of Char
    line_index.times do |i|
      line = lines[i]
      next if line.lstrip.starts_with?('#')
      quote = nil.as(Char?)
      prev = nil.as(Char?)
      chars = line.chars
      index = 0
      while index < chars.size
        char = chars[index]
        if quote
          if char == '\\'
            index += 2
            next
          elsif char == quote
            quote = nil
          end
        elsif char.in?('"', '\'')
          quote = char
        elsif char == '/' && regex_position?(prev)
          index += 1
          in_class = false
          while index < chars.size
            c = chars[index]
            if c == '\\'
              index += 2
              next
            elsif c == '['
              in_class = true
            elsif c == ']'
              in_class = false
            elsif c == '/' && !in_class
              break
            end
            index += 1
          end
        elsif char == '#'
          index += 1
          while index < chars.size && chars[index] != '\n'
            index += 1
          end
          next
        elsif char.in?('(', '[', '{')
          stack << char
        elsif char.in?(')', ']', '}')
          if stack.last? == delimiter_counterpart(char)
            stack.pop
          end
        end
        prev = char unless char.whitespace? || quote
        index += 1
      end
    end
    stack.reverse.map { |opener| delimiter_counterpart(opener) }.join
  end

  # Drops the dangling argument lines of a call whose opener was ON the
  # cut line (`Foo.new(` deleted with the line's tail). The tail must look
  # like a pure call remainder: the first non-blank line is arg-like
  # (comma-suffixed, a named argument, or a bare closer), the closer line
  # that drops the delimiter balance below zero arrives within a bounded
  # window, and no keyword line is crossed. Returns the closer char of the
  # dropped tail, or nil when no clean tail was found.
  private def self.drop_dangling_args!(lines : Array(String), line_index : Int32, deletions : Array({Int32, Int32})) : Char?
    j = line_index + 1
    while j < lines.size && (lines[j].blank? || lines[j].lstrip.starts_with?('#'))
      j += 1
    end
    return nil if j >= lines.size
    first = lines[j].strip
    return nil unless arg_like_line?(first) || bare_closer_line?(first)

    cut_indent = line_indent(lines[line_index])
    balance = 0
    while j < lines.size
      line = lines[j]
      # A keyword line at or above the cut's indent means the "tail" is
      # really the next statement. Keyword-looking content DEEPER than
      # the cut (a `try { |doc|` block or an `.end.to_s` call inside the
      # dangling call's own arguments) is part of the tail itself.
      if balance >= 0 && (kw = line_keyword(line)) && cut_indent && (ind = line_indent(line)) && ind <= cut_indent
        return nil
      end
      balance += net_delimiters(line)
      if balance < 0
        deletions << {line_index + 1, j}
        return line.rindex(/[)\]}]/).try { |i| line[i] }
      end
      j += 1
      return nil if j - line_index > 30
    end
    nil
  end

  # Whether *stripped* looks like an argument line of a multi-line call:
  # comma-suffixed, a named argument, or a nested closer/continuation.
  private def self.arg_like_line?(stripped : String) : Bool
    stripped.ends_with?(',') || stripped.ends_with?(':') ||
      stripped.ends_with?(')') || stripped.ends_with?(']') ||
      stripped.matches?(/^\w[\w?!]*\s*:/)
  end

  # Whether *stripped* is a bare closer line (`)`, `},`, `]`...).
  private def self.bare_closer_line?(stripped : String) : Bool
    stripped.matches?(/^[)\]}][\s,;]*$/)
  end

  # The net delimiter balance of *line* (strings, chars and comments
  # skipped): +1 per opener, -1 per closer.
  private def self.net_delimiters(line : String) : Int32
    net = 0
    quote = nil.as(Char?)
    prev = nil.as(Char?)
    chars = line.chars
    index = 0
    while index < chars.size
      char = chars[index]
      if quote
        if char == '\\'
          index += 2
          next
        elsif char == quote
          quote = nil
        end
      elsif char.in?('"', '\'')
        quote = char
      elsif char == '/' && regex_position?(prev)
        index += 1
        in_class = false
        while index < chars.size
          c = chars[index]
          if c == '\\'
            index += 2
            next
          elsif c == '['
            in_class = true
          elsif c == ']'
            in_class = false
          elsif c == '/' && !in_class
            break
          end
          index += 1
        end
      elsif char == '#'
        index += 1
        while index < chars.size && chars[index] != '\n'
          index += 1
        end
        next
      elsif char.in?('(', '[', '{')
        net += 1
      elsif char.in?(')', ']', '}')
        net -= 1
      end
      prev = char unless char.whitespace? || quote
      index += 1
    end
    net
  end

  # Walks *line* (skipping strings, chars and comments), pushing open
  # delimiters onto *stack* and popping matching closers. A closer that
  # does not match the top is ignored; the caller treats a stack that
  # never empties as "no clean tail" and falls back.
  private def self.consume_delimiters(stack : Array(Char), line : String) : Array(Char)
    quote = nil.as(Char?)
    prev = nil.as(Char?)
    chars = line.chars
    index = 0
    while index < chars.size
      char = chars[index]
      if quote
        if char == '\\'
          index += 2
          next
        elsif char == quote
          quote = nil
        end
      elsif char.in?('"', '\'')
        quote = char
      elsif char == '/' && regex_position?(prev)
        index += 1
        in_class = false
        while index < chars.size
          c = chars[index]
          if c == '\\'
            index += 2
            next
          elsif c == '['
            in_class = true
          elsif c == ']'
            in_class = false
          elsif c == '/' && !in_class
            break
          end
          index += 1
        end
      elsif char == '#'
        index += 1
        while index < chars.size && chars[index] != '\n'
          index += 1
        end
        next
      elsif char.in?('(', '[', '{')
        stack << char
      elsif char.in?(')', ']', '}')
        if stack.last? == delimiter_counterpart(char)
          stack.pop
        end
      end
      prev = char unless char.whitespace? || quote
      index += 1
    end
    stack
  end

  private def self.trailing_dot_index(line : String) : Int32?
    stripped = line.rstrip
    return unless stripped.size >= 2

    # A `.` right before a closing delimiter (mid-edit inside an
    # interpolation like `"#{foo.}"`) or at the end of the line.
    dot_index = stripped.rindex(/\.(?=\s*[}\)\]]|$)/)
    return unless dot_index
    return if dot_index == 0

    previous = stripped[dot_index - 1]
    # Exclude ranges (`a..`), splats (`*..`) and floats (`1.`), which are
    # either valid or not something a placeholder can fix.
    return if previous == '.'
    return if previous.ascii_number?

    dot_index
  end

  private def self.line_indent(line : String) : Int32?
    non_whitespace_char_index = line.each_char_with_index do |char, i|
      next if char.whitespace?
      break i
    end

    if non_whitespace_char_index
      non_whitespace_char_index // 2
    else
      0
    end
  end

  private def self.line_keyword(line : String) : String?
    if line.starts_with?(/\s*
      (
        if |
        unless |
        while |
        until |
        ((private|protected)\s+)?def |
        (private\s+)?(abstract\s+)?class |
        (private\s+)?(abstract\s+)?struct |
        (private\s+)?module |
        (private\s+)?enum |
        (private\s+)?annotation |
        (private\s+)?macro(?!\s*:) |
        case |
        select
      )(\s|$)/x)
      $1
    elsif m = line.match(/^\s*(?:[\w.?!@\[\]]+\s*=\s*)(if|unless|while|until|case|select)\s/)
      # An assignment-form opener (`value = if cond`): the `if` does not
      # start the line, but it still opens a block closed by `end`.
      m[1]
    elsif line.matches?(/\s*begin\s*$/)
      "begin"
    elsif line.ends_with?(/\s*do(\s+\|[^|]+\|)?\s*$/)
      "do"
    elsif line.ends_with?(/\s*\)\s*{(\s*\|[^|]+\|)?\s*$/)
      "{"
    elsif line.ends_with?(/\s*[\w\d]\s*{(\s*\|[^|]+\|)?\s*$/)
      "{"
    elsif line.matches?(/\s*\{\s*(\|[^|]*\|)?\s*$/)
      # A bare `{` (or `{ |x|`) on its own line — a multi-line tuple or
      # block opened without a call before it. Without this, the `}` that
      # closes it would rindex-pop an EARLIER `{` (and everything above it,
      # including still-open do-blocks).
      "{"
    elsif m = line.match(/(?:^|\W)(end|})([\s.,)\]}]|$)/)
      m[1]
    elsif line.matches?(/\s*else\s*$/)
      "else"
    elsif line.starts_with?(/\s*elsif\s+/)
      "elsif"
    elsif line.starts_with?(/\s*rescue(\b|\s)/)
      "rescue"
    elsif line.matches?(/\s*ensure\s*$/)
      "ensure"
    else
      nil
    end
  end

  private def self.closing_keyword(line_info : LineInfo)
    closing_keyword(line_info.keyword)
  end

  private def self.closing_keyword(keyword : String)
    keyword == "{" ? "}" : "end"
  end

  private def self.closing_keyword?(keyword : String)
    keyword.in?("end", "else", "elsif", "rescue", "ensure", "}")
  end

  private def self.wrong_indent?(
    indent : Int32,
    keyword : String?,
    closing_keyword : String?,
    last_info : LineInfo,
    line : String,
    was_blank_gap : Bool,
  )
    # If the indent is less than the opening one it's definitely wrong.
    if indent < last_info.indent
      return true
    end

    # If the indent is greater, it's all good (it's probably content inside that definition)
    if indent > last_info.indent
      return false
    end

    # Equal indentation is only wrong for a visual dedent; an arbitrary
    # statement at the same indentation is content (e.g. `next unless ...`
    # inside a block), and closing the open keyword for it would corrupt
    # the structure. Recognized keywords (closing keyword, else/elsif/
    # rescue/ensure, continuation lines) are never treated as dedents.
    stripped_line = line.strip
    if stripped_line.ends_with?(')') || stripped_line.ends_with?(']')
      return false
    end

    # All good if it's the closing keyword to an opening definition
    if keyword == closing_keyword
      return false
    end

    # Some special cases: else and elsif have the same indentation as
    # the opening keyword but they don't close it (more content is expected
    # to come until the "end" keyword)
    if last_info.keyword == "if" && keyword == "else"
      return false
    end

    if last_info.keyword == "if" && keyword == "elsif"
      return false
    end

    if last_info.keyword == "unless" && keyword == "else"
      return false
    end

    if last_info.keyword.in?("begin", "def", "do") && keyword.in?("rescue", "ensure", "else")
      return false
    end

    # A def signature can also be defined in multiple lines, like this:
    #
    # def foo(
    #   x, y
    # )
    #
    # In that case we don't want to consider the closing parentheses
    # as having wrong indentation.
    if last_info.keyword == "def" && line.strip == ")"
      return false
    end

    if was_blank_gap
      return true
    end

    false
  end
end
