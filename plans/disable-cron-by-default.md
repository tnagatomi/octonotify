# Plan: Disable schedule by default until users opt in

## Goals
- Prevent cron runs immediately after forking when secrets/config are not set
- Keep manual runs available via `workflow_dispatch`
- Document explicit steps to enable the schedule

## Scope / Files
- `.github/workflows/octonotify.yml`
- `README.md`

## Plan
1. Comment out the `schedule` block in the workflow and add a note that it is disabled by default for forks.
2. Update the README setup flow to instruct users to uncomment the cron block only after secrets/config are ready.
3. Add an Operations note that cron is disabled by default and manual runs are available until enabled.

## Acceptance criteria
- Forking the repo does not trigger scheduled runs automatically.
- Users can enable cron by uncommenting the schedule block as documented.
- README guidance matches the workflow behavior.
