## When using Bend

- in Windows always use WSL, as Bend is installed there
- run `bend guide` to learn it
- use `LAWS.bend` to keep important rules
- run `bend PROOF.bend` before committing
- parallelize the code whenever possible

## Documentation and Generated Artifacts Policy

### 1. No Unnecessary Documentation
- Do NOT create or commit Markdown (`.md`) files containing:
  - Implementation summaries, progress reports, or change logs.
  - Analysis, investigations, reasoning, or decision-making processes.
  - Descriptions of what was attempted, executed, tested, or fixed.
  - AI-generated explanations of the development process.
- Do NOT document your work unless explicitly requested.
- Keep implementation details and execution summaries in the final conversation response, NOT in repository files.

### 2. No Generated Experimental Artifacts
- Do NOT commit files generated during testing, debugging, analysis, or experimentation unless explicitly requested.
- This includes, but is not limited to:
  - JSON, CSV, XML, YAML, TXT, and other data files containing experimental results.
  - Benchmark results, logs, profiling outputs, and temporary reports.
  - Intermediate datasets, debugging dumps, and generated statistics.
- Use temporary directories for experimental outputs and clean them up afterward.
- Never stage or commit temporary or experimental artifacts by default.

### 3. Keep Project Documentation Minimal
- Existing documentation files (README.md, CONTRIBUTING.md, AGENTS.md, etc.) must remain concise, practical, and focused on their intended audience.
- Documentation should contain ONLY:
  - Essential setup, installation, configuration, and usage instructions.
  - Relevant API references and architectural information necessary for developers.
  - Clear instructions required by users, contributors, or AI agents.
- Do NOT include:
  - Internal reasoning or thought processes.
  - Historical accounts of implementation steps.
  - Details of commands executed or experiments performed.
  - Self-congratulatory descriptions, verbose explanations, or redundant information.
- Update documentation ONLY when changes make existing instructions incorrect, outdated, or incomplete.
- Prefer modifying existing documentation over creating new files.
- Write documentation as a description of the CURRENT state of the project, not as a history of how it was developed.

### 4. Commit Hygiene
- Before committing, review all staged files and remove unnecessary documentation and generated artifacts.
- Do NOT use `git add .` or `git add -A` indiscriminately. Stage only files relevant to the requested changes.
- If unsure whether a generated file belongs in the repository, exclude it by default.
- Explicit user instructions always take precedence over these restrictions.