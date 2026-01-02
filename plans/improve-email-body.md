# Plan: Improve digest email body formatting

## Goals
- Remove the horizontal rule separators made of repeated `=` characters.
- Make repository headers more visually prominent without using markdown `##`.
- Revisit the event label for `pull_request_created` (currently rendered as `PR Created`).

## Non-goals
- Changing polling logic, event selection, or state persistence.
- Changing the email subject line format.
- Changing the SMTP delivery mechanism.

## Key observation (current behavior)
- The digest body is plain text built in `Octonotify::Mailer#build_body`.
- It currently includes a header rule (`"=" * 50`), repo headings like `## owner/repo`, and event labels like `[PR Created]`.

## Proposal / Decisions
- Use a **multipart email** (text + HTML):
  - **HTML part** enables “larger bold text” for repository headers (font size cannot be increased reliably in plain text).
  - **Text part** remains readable as a fallback for clients that do not render HTML.
- Remove the `=` rule line entirely (and consider removing the footer rule for consistency).

## Scope / Files
- `lib/octonotify/mailer.rb`
- `spec/octonotify/mailer_spec.rb`

## Plan
1. Refactor body generation:
   - Split `build_body` into `build_text_body(events)` and `build_html_body(events)`.
   - Update `send_email` to send multipart content (`text_part` and `html_part`).
2. Remove separators:
   - Delete the header and footer rule made of repeated `=` characters.
   - Delete the footer rule (currently `"-" * 50`) to avoid mixed visual styles.
3. Repository header formatting:
   - Text part: render repo heading as a plain line (e.g., `owner/repo`) with whitespace separation (no `##`).
   - HTML part: render repo heading as larger bold text (e.g., inline style with larger font size + font weight).
4. Tests:
   - Update specs that currently assert `## owner/repo`.
   - Add assertions that the email is multipart and contains the HTML repo heading styling.

## Acceptance criteria
- No digest email body contains the `=`-based separator line.
- Repository headings are no longer rendered as `## ...`.
- Repository headings appear as **larger bold** text in the HTML part.
- `spec/octonotify/mailer_spec.rb` passes with updated expectations.

