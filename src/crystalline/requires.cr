require "llvm/lib_llvm"
require "compiler/crystal/annotatable"
require "compiler/crystal/program"
require "compiler/crystal/tools/dependencies"
require "compiler/crystal/compiler"
require "compiler/crystal/config"
require "compiler/crystal/crystal_path"
require "compiler/crystal/error"
require "compiler/crystal/exception"
require "compiler/crystal/formatter"
require "compiler/crystal/loader"
require "compiler/crystal/macros"
require "compiler/crystal/progress_tracker"
require "compiler/crystal/semantic"
require "compiler/crystal/syntax"
require "compiler/crystal/types"
require "compiler/crystal/syntax/**"
require "compiler/crystal/semantic/**"
require "compiler/crystal/macros/**"
require "compiler/crystal/codegen/**"
require "compiler/crystal/tools/implementations"
require "compiler/crystal/tools/context"

# Crystal >= 1.21.0 references `Crystal::Command::Exit` from `CompilerError`
# overloads in the compiler, but `compiler/crystal/command` — which defines it —
# drags in the CLI's optional tooling (e.g. the `markd` shard for `crystal docs`).
# Define the enum here so the compiler can be required without the full CLI —
# unless the compiler already provides it (a future version might).
{% unless Crystal::Command.has_constant?(:Exit) %}
  module Crystal
    class Command
      enum Exit
        OK             = 0
        FAILURE        = 1
        USAGE_ERROR    = 1
        CODE_ERROR     = 1
        SOFTWARE_ERROR = 1
      end
    end
  end
{% end %}
