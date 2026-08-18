require "log"
require "lsp/server"
require "./version"
# Load the compiler modules before the ext extensions: ext/compiler.cr
# reopens Crystal compiler classes (Program, Compiler, ...) whose base
# types live in those modules, and a consumer requiring main.cr without
# requires.cr first (e.g. a spec) would otherwise compile the extensions
# against an empty compiler namespace.
require "./requires"
require "./ext/*"
require "./lightweight/*"
require "./*"

module Crystalline
  # Supported server capabilities.
  SERVER_CAPABILITIES = LSP::ServerCapabilities.new(
    text_document_sync: LSP::TextDocumentSyncKind::Incremental,
    document_formatting_provider: true,
    document_range_formatting_provider: true,
    completion_provider: LSP::CompletionOptions.new(
      # Identifier characters included so clients fire completion while the
      # user is typing a plain word (not just after `.`, `::` or `@`). The
      # lightweight path answers in tens of milliseconds, so per-keystroke
      # requests are cheap.
      trigger_characters: [".", ":", "@"] + ('a'..'z').to_a.map(&.to_s) + ('A'..'Z').to_a.map(&.to_s) + ["_"],
    ),
    hover_provider: true,
    definition_provider: true,
    document_symbol_provider: true,
    # signature_help_provider: LSP::SignatureHelpOptions.new(
    #   trigger_characters: ["(", " "]
    # ),
  )

  module EnvironmentConfig
    # Add the `crystal env` environment variables to the current env.
    def self.run
      initialize_from_crystal_env.each do |k, v|
        ENV[k] = v
      end
    end

    private def self.initialize_from_crystal_env
      parse_crystal_env_output(crystal_env)
    end

    # Parses `crystal env` output (bare `KEY=value` lines, values shell-
    # quoted) into an env map. Split on the first `=` only: a value may
    # contain `=` itself (`CRYSTAL_OPTS='-Dfoo=1'`), and a full split would
    # truncate it and leak the opening quote into the imported env — which
    # the next `crystal env` run re-escapes, growing the variable
    # exponentially until subprocess spawning fails with E2BIG.
    def self.parse_crystal_env_output(output : String) : Hash(String, String)
      output
        .lines
        .map(&.split('=', 2))
        .to_h
        .transform_values { |value| unquote_env_value(value) }
    end

    # `crystal env` shell-quotes values (e.g. `CRYSTAL_OPTS=''`). Import them
    # verbatim would re-import the quotes, which the next `crystal env` run
    # escapes again — growing the value exponentially until subprocess
    # spawning fails with E2BIG. Decode the shell quoting instead: values are
    # wrapped in single quotes, and a single quote inside the value is escaped
    # as `'"'"'` (close quote, double-quoted quote, reopen quote).
    def self.unquote_env_value(value : String) : String
      return value unless value.starts_with?('\'') && value.ends_with?('\'') && value.size >= 2

      String.build do |result|
        index = 1
        while index < value.size - 1
          char = value[index]
          if char == '\'' && value[index + 1]? == '"' && value[index + 2]? == '\'' && value[index + 3]? == '"' && value[index + 4]? == '\''
            # A single quote inside single quotes is escaped as `'"'"'`.
            result << '\''
            index += 5
          else
            result << char
            index += 1
          end
        end
      end
    end

    private def self.crystal_env
      String.build do |io|
        Process.run("crystal", ["env"], output: io)
      end
    end
  end

  def self.init(*, input : IO = STDIN, output : IO = STDOUT, log_level : ::Log::Severity = :warn)
    # Setup a temporary backend to STDERR so we can log early initialization errors.
    # This MUST be done first to avoid STDOUT corruption.
    ::Log.setup(log_level, ::Log::IOBackend.new(STDERR))

    EnvironmentConfig.run
    server = LSP::Server.new(input, output, SERVER_CAPABILITIES)

    # Re-setup with the LSP backend once the server is initialized.
    if backend = LSP::Log.backend
      ::Log.setup(log_level, backend)
    end

    Controller.new(server)
  rescue ex
    LSP::Log.error(exception: ex) { %(#{ex.message || "Unknown error during init."}\n#{ex.backtrace.join('\n')}) }
  end
end
