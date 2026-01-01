# Octonotify

A GitHub Actions-based tool that monitors GitHub repository events and sends email notifications.

Currently supported events:

- Release
- PR created
- PR merged
- Issue created.

## Setup

### 1. Fork this repository

Fork this repository to your own GitHub account.

### 2. Configure Secrets

Go to your forked repository's Settings → Secrets and variables → Actions and configure the following secrets:

| Secret | Description | Example |
|--------|-------------|---------|
| `OCTONOTIFY_SMTP_HOST` | SMTP server hostname | `smtp.gmail.com` |
| `OCTONOTIFY_SMTP_PORT` | SMTP server port (optional; default: `587`) | `587` |
| `OCTONOTIFY_SMTP_USERNAME` | SMTP authentication username (optional) | `your-email@example.com` |
| `OCTONOTIFY_SMTP_PASSWORD` | SMTP authentication password (required when `OCTONOTIFY_SMTP_USERNAME` is set) | App password for Gmail |
| `OCTONOTIFY_FROM` | Sender email address | `Octonotify <noreply@example.com>` |
| `OCTONOTIFY_TO` | Recipient email addresses (comma-separated) | `user1@example.com,user2@example.com` |
| `GITHUB_TOKEN` | GitHub token. In GitHub Actions, the workflow uses the default token (`github.token`) automatically. Set this secret only if you need a PAT (e.g., to monitor private repositories or increase rate limits). | `ghp_...` |

#### Using Gmail

1. Enable [2-Step Verification](https://myaccount.google.com/security) on your Google account
2. Generate an [App Password](https://myaccount.google.com/apppasswords)
3. Use the generated app password as `OCTONOTIFY_SMTP_PASSWORD`

### 3. Create configuration file

Copy `.octonotify/config.yml.example` to `.octonotify/config.yml` and configure the repositories and events you want to monitor.

### 4. Enable GitHub Actions

Go to the Actions tab in your forked repository and enable workflows if they are disabled.

### 5. Enable the schedule

The scheduled trigger is commented out by default to avoid failures right after forking.
After you finish setup (secrets and `.octonotify/config.yml`), uncomment the `schedule` block in `.github/workflows/octonotify.yml` to enable cron.

### 6. Commit and push changes

```bash
git add .octonotify/config.yml .github/workflows/octonotify.yml
git commit -m "Configure Octonotify"
git push
```

## Configuration Options

### config.yml

| Key | Required | Description | Default |
|-----|----------|-------------|---------|
| `timezone` | No | Timezone for email display (IANA format) | `UTC` |
| `repos` | Yes | Repository monitoring configuration | - |

### Event Types

| Event | Description |
|-------|-------------|
| `release` | When a release is published |
| `pull_request_created` | When a PR is created |
| `pull_request_merged` | When a PR is merged |
| `issue_created` | When an issue is created (excludes PRs) |

For concrete examples, see `.octonotify/config.yml.example`.

## Operations

### Execution Schedule

By default, the scheduled trigger (every 5 minutes) is commented out to prevent failures on new forks.
Once setup is complete, uncomment the `schedule` block in `.github/workflows/octonotify.yml` to enable the cron trigger.

### Manual Execution

Optional: You can manually trigger the workflow from the Actions tab using "Run workflow".

### State File

`.octonotify/state.json` stores the following information:

- Last execution timestamp
- Watermark for processed events per repository
- Notified event IDs (for duplicate prevention)

The state file is automatically updated by Actions. Do not edit it manually.

Note: The workflow commits and pushes `.octonotify/state.json` back to your fork to persist state between runs. If you have branch protection rules enabled, you may need to allow GitHub Actions to push to the branch or adjust the workflow/branch protection settings.

### Rate Limiting

If the GitHub API rate limit is reached, processing will be interrupted but will resume from where it left off on the next run. The interruption position is saved in the state file.

## License

MIT License
