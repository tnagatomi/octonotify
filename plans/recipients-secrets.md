# Plan: Move recipients to GitHub Actions Secrets

## Goal
- Remove recipient configuration entirely from `.octonotify/config.yml`
- Inject recipients via GitHub Actions **Secrets** (environment variable `OCTONOTIFY_TO`)
- Allow forks to be **public** without committing recipient email addresses (private repos have GitHub Actions usage quotas depending on plan)

## Decisions
- **Secret name**: `OCTONOTIFY_TO`
- **Format**: comma-separated list (multiple recipients allowed)
  - Example: `user1@example.com,user2@example.com`
- If `OCTONOTIFY_TO` is missing or empty, fail fast with a clear error message

## Implementation
### 1) Load recipients from ENV in `Octonotify::Config`
- Target: `lib/octonotify/config.rb`
- Changes:
  - Stop reading `to` from YAML
  - Parse `ENV["OCTONOTIFY_TO"]` with `split(",")`, `strip`, and drop empty entries to build `@to`
  - Apply existing `validate_header_value!` to each recipient (CR/LF header-injection protection)

### 2) Wire the Secret into the GitHub Actions workflow
- Target: `.github/workflows/octonotify.yml`
- Changes:
  - Add `OCTONOTIFY_TO: ${{ secrets.OCTONOTIFY_TO }}` under `env:` in the `Run Octonotify` step

### 3) Remove recipients from the config example
- Target: `.octonotify/config.yml.example`
- Changes:
  - Delete the `to:` section
  - Add an English comment explaining recipients must be configured via `OCTONOTIFY_TO`

### 4) Update README to be Secrets-first
- Target: `README.md`
- Changes:
  - Remove/replace any instruction that suggests putting recipients into `config.yml`
  - Add `OCTONOTIFY_TO` to the Secrets list
  - Add a local-run example: `export OCTONOTIFY_TO=...`
  - Remove `to` from the `config.yml` options table

### 5) Update tests
- Target: `spec/octonotify/config_spec.rb` (and any related specs if needed)
- Changes:
  - Update tests to assume recipients come from ENV
  - Add coverage for: missing/empty `OCTONOTIFY_TO` errors, and comma-separated parsing

## Acceptance criteria
- With `OCTONOTIFY_TO` set (via Secrets), Octonotify can send emails without recipients in `config.yml`
- Missing recipients fails with a clear error
- `.octonotify/config.yml.example` and `README.md` no longer mention recipients in config
- All RSpec tests pass


