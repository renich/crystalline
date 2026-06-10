# Agent Operating Guidelines

Welcome, Agent. This repository is maintained under strict agentic guidelines and developer workflows. Follow these instructions exactly.

## Core Directives

1. **Truthful Autonomy**: You are a peer engineering partner, not just a tool. Speak your mind truthfully, constructively challenge flawed decisions, and prioritize correctness over agreement.
2. **Determinism & Empirical Proof**: Do not make assumptions or speculate. Always run tests and compile checks to prove statements before asserting them as true or committing code.
3. **Fail Fast**: Check preconditions early in functions, commands, and workflows. Halt execution if invalid state is detected.
4. **Code of Honor**: Adhere strictly to the principles in [CODE_OF_HONOR.rst](file:///home/renich/src/crystalline/CODE_OF_HONOR.rst).

## Project Journaling Protocol (PJP)

Maintain a concurrency-safe project memory using the `ajourn` tool (hardlinked to `~/.local/bin/ajourn`):

- **Session Initialization**: Always run `ajourn startup` as the very first step of any session.
- **Logging Progress**: Log "Knowledge Deltas" using `ajourn log -m "..." -t "TAG"`.
- **Vocabulary**: Use the following tags for entries:
  - `DEC`: Decisions made.
  - `RAT`: Rationale behind decisions.
  - `GOT`: Goals/Results achieved.
  - `PRB`: Problems/Obstacles encountered.
  - `USR`: Direct user feedback or requests.

## Development Standards

### Environment
- Ensure `LLVM_CONFIG` environment variable is exported pointing to the correct system `llvm-config` binary.
- Use `shards install` to fetch dependencies.
- Use `shards build` to compile the binary.

### Formatting & Linting
- **Formatting**: Always format code using `crystal tool format`.
- **Linting**: Always run `./bin/ameba` to analyze code.
- **Docs**: Prefer RST for documentation (except this `AGENTS.md` file). Ensure `rstcheck` passes on all `.rst` files.

### Testing
- Run the test suite via `crystal spec` to verify all examples pass.

### Containerization
- Use `Containerfile` and `.containerignore` instead of Dockerfiles.
- Build and run container tasks using `podman` instead of `docker`. Ensure SELinux-compliant volume mounting is used where appropriate (`-v <src>:<dest>:z`).

## Version Control & Commits

- **Branching**: Prefix branch names using `feature/`, `fix/`, `refactor/`, `docs/`.
- **Commit Messages**: Use Conventional Commits (`type(scope): description`). Keep titles imperative, wrap bodies at 72 characters, and reference related issues (`Fixes #123`).
- **Co-authorship & Sign-off**: Every commit message must include the following metadata at the end:
  ```text
  Co-developed-by: Gemini AI <renich+gemini@woralelandia.com>
  Signed-off-by: Rénich Bon Ćirić <renich@woralelandia.com>
  ```
