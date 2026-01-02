# Agent Guide (AGENTS.md)

This repository contains **Octonotify**, a GitHub Actions-based tool that polls GitHub repository activity and sends email notifications (digests).

## Project overview

- **What it does**: Periodically polls GitHub (GraphQL) for configured repositories/events and emails a digest to recipients.
- **Where it runs**: Primarily in **GitHub Actions** (`.github/workflows/octonotify.yml`) on a schedule or via manual dispatch.
- **Not real-time**: This is a poller + digest mailer; the `schedule` trigger is best-effort and may be delayed or skipped.
- **Persistence**: Uses `.octonotify/state.json` to store per-repo/event baselines, watermarks, resume cursors, and recently-notified IDs to prevent duplicates. The workflow commits this file back to the repo.

## Repository layout (high-signal)

- `bin/octonotify`: CLI entrypoint (runs `Octonotify::Runner`).
- `.github/workflows/octonotify.yml`: Main workflow (poll + commit `.octonotify/state.json`). The cron schedule is commented out by default.
- `.github/workflows/ci.yml`: CI (RuboCop + RSpec).
- `lib/octonotify/`: Core code.
  - `config.rb`: Loads and validates `.octonotify/config.yml`.
    - Sender/recipients come from env (`OCTONOTIFY_FROM`, `OCTONOTIFY_TO`), not YAML.
  - `graphql_client.rb`: GitHub GraphQL API client.
  - `poller.rb`: Polling logic that returns new events and suggested state changes.
  - `mailer.rb`: SMTP delivery and digest formatting.
  - `runner.rb`: Orchestrates polling + mailing + state persistence.
  - `state.rb`: State model for `.octonotify/state.json` (baselines/watermarks/resume cursors/duplicate prevention).
- `.octonotify/config.yml.example`: Example configuration to copy.
- `.octonotify/state.json`: Mutable state file (updated by Actions).
- `plans/`: Design notes for significant behavior changes.
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
- **State file safety**:
  - State reads/writes refuse to follow symlinks for `.octonotify/state.json` (prevents unexpected writes outside the repo). Do not bypass this.

## GitHub Actions / operational notes

- Workflow: `.github/workflows/octonotify.yml`
  - Scheduled to run every 5 minutes (cron), but the `schedule` block is **commented out by default** to avoid running before users complete setup on forks.
  - Manual runs are available via `workflow_dispatch`.
  - Uses `concurrency` to prevent overlapping runs (avoids state conflicts).
  - Commits `.octonotify/state.json` back to the default branch using a bot account.
- Runtime configuration comes from environment variables (Actions secrets):
  - `OCTONOTIFY_SMTP_HOST` (required), `OCTONOTIFY_SMTP_PORT` (optional; defaults to 587)
  - `OCTONOTIFY_SMTP_USERNAME` (optional), `OCTONOTIFY_SMTP_PASSWORD` (required if username is set)
  - `OCTONOTIFY_FROM` (required), `OCTONOTIFY_TO` (required; comma-separated)
  - `GITHUB_TOKEN` (required; in Actions, the workflow falls back to the default token `github.token`)
- If branch protection is enabled, ensure GitHub Actions is allowed to push (or adjust the workflow/branch protection).

## State and delivery behavior (high-signal)

- **Backfill prevention on new repos/events**:
  - When a repo or event type is newly added in config, `State#sync_with_config!` initializes its `baseline_time` (and `watermark_time`) to the current run start time.
  - The poller clamps its lookback window so it never scans earlier than `baseline_time`.
- **Rate limiting**:
  - If the GitHub API rate limit gets low, polling may stop early and save a `resume_cursor` so the next run can continue.
- **Email delivery failures**:
  - If email delivery partially fails, poll-derived state changes (watermarks / notified IDs / resume cursors) are not applied so events will be retried on the next run.

## Contribution / PR guidelines (agent-friendly)

- Keep PRs focused (one logical change set).
- Avoid committing `.octonotify/state.json` changes in feature PRs unless the change explicitly concerns state format/behavior.
- Update or add RSpec coverage for behavior changes, especially around:
  - Config validation
  - Polling thresholds/cursors/watermarks
  - Mail delivery failure behavior (state persistence is intentionally conservative)

## Vulnerability reporting

See `SECURITY.md`. Do not open public issues for suspected vulnerabilities.


