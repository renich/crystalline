============
Contributing
============

We welcome contributions to ``crystalline``! Please follow these guidelines to make the process smooth for everyone.

Getting Started
===============

#. Fork the repository on GitHub: `<https://github.com/renich/crystalline/fork>`_.
#. Clone your fork locally.
#. Create a new branch for your changes:

   .. code-block:: bash

      git checkout -b feature/my-cool-feature

Environment Setup
=================

Crystalline requires LLVM to be installed and available on your system in order to run semantic analysis and build.

On some systems, the compiler may need help finding the ``llvm-config`` binary. You can set the ``LLVM_CONFIG`` environment variable:

.. code-block:: bash

   export LLVM_CONFIG="$(brew --prefix llvm)/bin/llvm-config" # MacOS (Homebrew)
   # Or on Fedora/RHEL:
   export LLVM_CONFIG="/usr/bin/llvm-config"

To install development dependencies:

.. code-block:: bash

   shards install

Codebase Architecture
=====================

A brief map of the repository's files to help you navigate:

* **src/crystalline.cr**: The CLI entry point where options (using ``OptionParser``) are parsed.
* **src/crystalline/main.cr**: Initializes and boots the LSP server.
* **src/crystalline/controller.cr**: Handles incoming LSP requests and routes them to workspace actions.
* **src/crystalline/workspace.cr**: Manages document collections, compiler sessions, and code diagnostics.
* **src/crystalline/ext/**: Contains overrides, monkeypatches, and Boehm GC tuning for compiler integration.
* **spec/**: Contains integration and unit specs for the Language Server.

Development Workflow
====================

To speed up development, you can use `Sentry <https://github.com/samueleaton/sentry>`_ to rebuild the server automatically on file changes:

.. code-block:: bash

   # Build Sentry once
   shards build --release sentry
   # Run Sentry to watch the filesystem and auto-compile crystalline in debug mode
   ./bin/sentry -i

To build the project manually:

.. code-block:: bash

   shards build crystalline          # Debug build
   shards build crystalline --release # Production/Release build

Formatting & Linting
====================

Always run the formatter and linter before committing your changes:

.. code-block:: bash

   crystal tool format
   ./bin/ameba

Debugging & Testing
===================

To run the test suite:

.. code-block:: bash

   crystal spec

Since LSP servers communicate over stdin/stdout, standard ``puts`` statements can break the JSON-RPC protocol. Instead, use the built-in LSP logger to print diagnostic information:

.. code-block:: crystal

   LSP::Log.info { "Debugging value: #{my_var}" }

You can enable verbose debug logging by launching crystalline with the log level flag:

.. code-block:: bash

   ./bin/crystalline -l debug

Commit Guidelines
=================

We use `Conventional Commits <https://www.conventionalcommits.org/>`_. Please format your commit messages as follows:

.. code-block:: text

   type(scope): description

   Body description (optional)

* **Types**: ``feat``, ``fix``, ``docs``, ``style``, ``refactor``, ``perf``, ``test``, ``chore``.
* **Mood**: Use the imperative mood ("add feature" instead of "added feature").

Submitting a Pull Request
=========================

#. Push your branch to GitHub:

   .. code-block:: bash

      git push origin feature/my-cool-feature

#. Open a Pull Request against the ``master`` branch of the main repository.
#. Describe your changes clearly and link to any related issues.
