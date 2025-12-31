# Agent Guide (AGENTS.md)

This repository contains **Octonotify**, a GitHub Actions-based tool that polls GitHub repository activity and sends email notifications (digests).

## Project overview

- **What it does**: Periodically polls GitHub (GraphQL) for configured repositories/events and emails a digest to recipients.
- **Where it runs**: Primarily in **GitHub Actions** on a schedule (`.github/workflows/octonotify.yml`).
- **Persistence**: Uses `.octonotify/state.json` to store watermarks/cursors and prevent duplicates. The workflow commits this file back to the repo.

## Repository layout (high-signal)

- `bin/octonotify`: CLI entrypoint (runs `Octonotify::Runner`).
- `lib/octonotify/`: Core code.
  - `config.rb`: Loads and validates `.octonotify/config.yml`.
  - `graphql_client.rb`: GitHub GraphQL API client.
  - `poller.rb`: Polling logic that returns new events and suggested state changes.
  - `mailer.rb`: SMTP delivery and digest formatting.
  - `runner.rb`: Orchestrates polling + mailing + state persistence.
- `.octonotify/config.yml.example`: Example configuration to copy.
- `.octonotify/state.json`: Mutable state file (updated by Actions).
- `spec/`: RSpec tests.

## Build, lint, and test commands

This project is a plain Ruby + Bundler repo.

- **Ruby version**: `4.0.0` (see `.ruby-version`)

```bash
bundle install

# Lint
bundle exec rubocop

# Tests
bundle exec rspec
```

## Code style guidelines

- **RuboCop**: Enabled in CI. Run `bundle exec rubocop` before submitting changes.
- **Strings**: Prefer **double quotes** (see `.rubocop.yml`).
- **File headers**: Keep `# frozen_string_literal: true` at the top of Ruby files.
- **Errors / user-facing messages**: Keep them in **English** (consistency with existing code and CI logs).

## Testing instructions

- Tests are in `spec/` and run via RSpec:

```bash
bundle exec rspec
```

- RSpec runs with randomized order (`config.order = :random`). If you need to reproduce, rerun with the printed `--seed`.

## Security considerations

- **Secrets**:
  - Never commit SMTP credentials or tokens.
  - In GitHub Actions, secrets are provided via workflow `env:` and must not be printed to logs.
- **YAML loading**:
  - Config is loaded via `YAML.safe_load_file` without aliases/symbols. Keep config as plain scalars/arrays/hashes.
- **Email header injection**:
  - Config validation rejects CR/LF in `from`/`to`. Do not bypass this.

## GitHub Actions / operational notes

- Workflow: `.github/workflows/octonotify.yml`
  - Scheduled to run every 5 minutes (cron).
  - Uses `concurrency` to prevent overlapping runs (avoids state conflicts).
  - Commits `.octonotify/state.json` back to the default branch using a bot account.
- If branch protection is enabled, ensure GitHub Actions is allowed to push (or adjust the workflow/branch protection).

## Contribution / PR guidelines (agent-friendly)

- Keep PRs focused (one logical change set).
- Avoid committing `.octonotify/state.json` changes in feature PRs unless the change explicitly concerns state format/behavior.
- Update or add RSpec coverage for behavior changes, especially around:
  - Config validation
  - Polling thresholds/cursors/watermarks
  - Mail delivery failure behavior (state persistence is intentionally conservative)

## Vulnerability reporting

See `SECURITY.md`. Do not open public issues for suspected vulnerabilities.


