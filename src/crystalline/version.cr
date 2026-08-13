module Crystalline
  # The LSP's own version (shard version + build commit), kept in its own
  # file so it is defined before the lightweight files are required: the
  # prelude cache is keyed on it, so upgraded builds regenerate their
  # prelude instead of reusing a stale one forever.
  VERSION = {{ (`shards version #{__DIR__}`.strip + "+" +
                system("git rev-parse --short HEAD || echo unknown").stringify).stringify.strip }}
end
