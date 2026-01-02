# frozen_string_literal: true

require "spec_helper"

RSpec.describe Octonotify::Mailer do
  let(:timezone) { "Asia/Tokyo" }
  let(:timezone_info) { TZInfo::Timezone.get(timezone) }
  let(:from) { "Octonotify <noreply@example.com>" }
  let(:to) { ["user1@example.com", "user2@example.com"] }
  let(:config) do
    instance_double(
      Octonotify::Config,
      from: from,
      to: to,
      timezone_info: timezone_info
    )
  end

  let(:mailer) { described_class.new(config: config, delivery_method: :test) }

  before do
    Mail::TestMailer.deliveries.clear
  end

  describe "#initialize" do
    around do |example|
      original_host = ENV.fetch("OCTONOTIFY_SMTP_HOST", nil)
      original_port = ENV.fetch("OCTONOTIFY_SMTP_PORT", nil)
      example.run
      ENV["OCTONOTIFY_SMTP_HOST"] = original_host
      if original_port.nil?
        ENV.delete("OCTONOTIFY_SMTP_PORT")
      else
        ENV["OCTONOTIFY_SMTP_PORT"] = original_port
      end
    end

    context "when OCTONOTIFY_SMTP_HOST is not set" do
      it "raises ConfigError" do
        ENV.delete("OCTONOTIFY_SMTP_HOST")
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /OCTONOTIFY_SMTP_HOST environment variable is required/)
      end
    end

    context "when OCTONOTIFY_SMTP_HOST is empty" do
      it "raises ConfigError" do
        ENV["OCTONOTIFY_SMTP_HOST"] = ""
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /OCTONOTIFY_SMTP_HOST environment variable is required/)
      end
    end

    context "when OCTONOTIFY_SMTP_HOST is set" do
      it "creates mailer successfully" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        expect { described_class.new(config: config) }.not_to raise_error
      end
    end

    context "when OCTONOTIFY_SMTP_PORT is not set" do
      it "defaults to 587" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        ENV.delete("OCTONOTIFY_SMTP_PORT")

        mailer = described_class.new(config: config)
        delivery = mailer.instance_variable_get(:@delivery_method)
        expect(delivery).to be_a(Array)
        expect(delivery[0]).to eq(:smtp)
        expect(delivery[1][:port]).to eq(587)
      end
    end

    context "when OCTONOTIFY_SMTP_PORT is empty" do
      it "defaults to 587 (GitHub Actions secret not set results in empty string)" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        ENV["OCTONOTIFY_SMTP_PORT"] = ""

        mailer = described_class.new(config: config)
        delivery = mailer.instance_variable_get(:@delivery_method)
        expect(delivery[1][:port]).to eq(587)
      end
    end

    context "when OCTONOTIFY_SMTP_PORT is invalid" do
      it "raises ConfigError for non-numeric port" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        ENV["OCTONOTIFY_SMTP_PORT"] = "not-a-number"

        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /OCTONOTIFY_SMTP_PORT must be a valid TCP port/)
      end

      it "raises ConfigError for out-of-range port" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        ENV["OCTONOTIFY_SMTP_PORT"] = "70000"

        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /OCTONOTIFY_SMTP_PORT must be a valid TCP port/)
      end
    end

    context "when OCTONOTIFY_SMTP_USERNAME is set but OCTONOTIFY_SMTP_PASSWORD is missing" do
      around do |example|
        original_username = ENV.fetch("OCTONOTIFY_SMTP_USERNAME", nil)
        original_password = ENV.fetch("OCTONOTIFY_SMTP_PASSWORD", nil)
        example.run
        ENV["OCTONOTIFY_SMTP_USERNAME"] = original_username
        ENV["OCTONOTIFY_SMTP_PASSWORD"] = original_password
      end

      it "raises ConfigError" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        ENV["OCTONOTIFY_SMTP_USERNAME"] = "user"
        ENV.delete("OCTONOTIFY_SMTP_PASSWORD")
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /OCTONOTIFY_SMTP_PASSWORD is required/)
      end

      it "raises ConfigError when password is empty" do
        ENV["OCTONOTIFY_SMTP_HOST"] = "smtp.example.com"
        ENV["OCTONOTIFY_SMTP_USERNAME"] = "user"
        ENV["OCTONOTIFY_SMTP_PASSWORD"] = ""
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /OCTONOTIFY_SMTP_PASSWORD is required/)
      end
    end
  end

  def build_event(attrs = {})
    defaults = {
      type: "release",
      repo: "owner/repo",
      id: "RE_123",
      title: "v1.0.0",
      url: "https://github.com/owner/repo/releases/tag/v1.0.0",
      time: Time.utc(2024, 1, 15, 12, 0, 0),
      author: nil,
      extra: { tag_name: "v1.0.0" }
    }
    Octonotify::Poller::Event.new(**defaults, **attrs)
  end

  describe "#send_digest" do
    context "when events is empty" do
      it "does not send any email" do
        mailer.send_digest([])

        expect(Mail::TestMailer.deliveries).to be_empty
      end
    end

    context "with single event" do
      it "sends email to each recipient" do
        mailer.send_digest([build_event])

        expect(Mail::TestMailer.deliveries.size).to eq(2)
        expect(Mail::TestMailer.deliveries.map(&:to).flatten).to contain_exactly(
          "user1@example.com", "user2@example.com"
        )
      end

      it "sets correct from address" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        expect(mail.from).to eq(["noreply@example.com"])
      end

      it "sets subject with single repo" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        expect(mail.subject).to eq("[Octonotify] 1 new event in owner/repo")
      end

      it "sends multipart email with text and html parts" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        expect(mail.parts.size).to eq(2)
        expect(mail.text_part).not_to be_nil
        expect(mail.html_part).not_to be_nil
      end

      it "includes event details in text part" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        body = mail.text_part.body.to_s

        expect(body).to include("owner/repo")
        expect(body).to include("https://github.com/owner/repo")
        expect(body).to include("Release")
        expect(body).to include("v1.0.0")
        expect(body).to include("https://github.com/owner/repo/releases/tag/v1.0.0")
        expect(body).to include("Tag: v1.0.0")
      end

      it "includes styled repo heading in html part" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        body = mail.html_part.body.to_s

        expect(body).to include("font-weight: bold")
        expect(body).to include("owner/repo")
        expect(body).to include("<h3")
        expect(body).to include("Release")
        expect(body).to include("v1.0.0")
      end

      it "does not include separator lines in text part" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        body = mail.text_part.body.to_s

        expect(body).not_to include("=" * 50)
        expect(body).not_to include("-" * 50)
      end

      it "converts time to configured timezone" do
        mailer.send_digest([build_event(time: Time.utc(2024, 1, 15, 12, 0, 0))])

        mail = Mail::TestMailer.deliveries.first
        body = mail.text_part.body.to_s

        # UTC 12:00 -> JST 21:00
        expect(body).to include("2024-01-15 21:00")
      end
    end

    context "with multiple events in single repo" do
      it "sets subject with event count" do
        events = [
          build_event(id: "RE_1", title: "v1.0.0"),
          build_event(id: "RE_2", title: "v2.0.0")
        ]
        mailer.send_digest(events)

        mail = Mail::TestMailer.deliveries.first
        expect(mail.subject).to eq("[Octonotify] 2 new events in owner/repo")
      end
    end

    context "with events from multiple repos" do
      it "sets subject with repo count" do
        events = [
          build_event(repo: "owner/repo1", id: "RE_1"),
          build_event(repo: "owner/repo2", id: "RE_2")
        ]
        mailer.send_digest(events)

        mail = Mail::TestMailer.deliveries.first
        expect(mail.subject).to eq("[Octonotify] 2 new events in 2 repositories")
      end

      it "groups events by repo in body" do
        events = [
          build_event(repo: "owner/repo1", id: "RE_1", title: "Release 1"),
          build_event(repo: "owner/repo2", id: "RE_2", title: "Release 2")
        ]
        mailer.send_digest(events)

        mail = Mail::TestMailer.deliveries.first
        body = mail.text_part.body.to_s

        expect(body).to include("owner/repo1")
        expect(body).to include("owner/repo2")
        expect(body).to include("Release 1")
        expect(body).to include("Release 2")
      end
    end

    context "with different event types" do
      it "formats release event with type heading" do
        event = build_event(
          type: "release",
          title: "v1.0.0",
          extra: { tag_name: "v1.0.0" }
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        expect(body).to include("  Release")
        expect(body).to include("Tag: v1.0.0")
      end

      it "formats pull_request_merged event with type heading" do
        event = build_event(
          type: "pull_request_merged",
          title: "Fix bug",
          author: "alice",
          extra: { merged_by: "bob" }
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        expect(body).to include("  PR Merged")
        expect(body).to include("Author: alice")
        expect(body).to include("Merged by: bob")
      end

      it "formats pull_request_created event with type heading" do
        event = build_event(
          type: "pull_request_created",
          title: "Add feature",
          author: "charlie",
          extra: {}
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        expect(body).to include("  PR Created")
        expect(body).to include("Author: charlie")
      end

      it "formats issue_created event with type heading" do
        event = build_event(
          type: "issue_created",
          title: "Bug report",
          author: "dave",
          extra: {}
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        expect(body).to include("  Issue Created")
        expect(body).to include("Author: dave")
      end
    end

    context "with single recipient" do
      let(:to) { ["single@example.com"] }

      it "sends only one email" do
        mailer.send_digest([build_event])

        expect(Mail::TestMailer.deliveries.size).to eq(1)
        expect(Mail::TestMailer.deliveries.first.to).to eq(["single@example.com"])
      end
    end

    context "with duplicate recipients" do
      let(:to) { ["user@example.com", "user@example.com", "other@example.com"] }

      it "sends email only once per unique recipient" do
        mailer.send_digest([build_event])

        expect(Mail::TestMailer.deliveries.size).to eq(2)
        recipients = Mail::TestMailer.deliveries.map(&:to).flatten
        expect(recipients).to contain_exactly("user@example.com", "other@example.com")
      end
    end

    context "when delivery fails for some recipients" do
      it "continues sending to remaining recipients and raises DeliveryError" do
        failing_mailer = described_class.new(config: config, delivery_method: :test)

        call_count = 0
        allow_any_instance_of(Mail::Message).to receive(:deliver) do
          call_count += 1
          raise StandardError, "SMTP error" if call_count == 1
        end

        expect { failing_mailer.send_digest([build_event]) }
          .to raise_error(Octonotify::Mailer::DeliveryError) do |error|
            expect(error.failed_recipients.size).to eq(1)
            expect(error.failed_recipients.keys.first).to eq("user1@example.com")
            # Verify error message does not contain email addresses (PII protection)
            expect(error.message).to eq("Failed to deliver to 1 recipient(s)")
            expect(error.message).not_to include("@")
          end
      end
    end

    context "with events from multiple repos in unsorted order" do
      it "sorts repos alphabetically in body" do
        events = [
          build_event(repo: "zeta/repo", id: "RE_1", title: "Zeta Release"),
          build_event(repo: "alpha/repo", id: "RE_2", title: "Alpha Release")
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        alpha_pos = body.index("alpha/repo")
        zeta_pos = body.index("zeta/repo")
        expect(alpha_pos).to be < zeta_pos
      end

      it "sorts events within repo by time descending (newest first)" do
        events = [
          build_event(id: "RE_1", title: "Older", time: Time.utc(2024, 1, 15, 10, 0, 0)),
          build_event(id: "RE_2", title: "Newer", time: Time.utc(2024, 1, 15, 12, 0, 0))
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        newer_pos = body.index("Newer")
        older_pos = body.index("Older")
        expect(newer_pos).to be < older_pos
      end
    end

    context "with charset encoding" do
      it "sets UTF-8 charset on text part" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        expect(mail.text_part.content_type).to include("charset=UTF-8")
      end

      it "sets UTF-8 charset on html part" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        expect(mail.html_part.content_type).to include("charset=UTF-8")
      end
    end

    context "with event type grouping" do
      it "groups events by type within repo with type as heading" do
        events = [
          build_event(type: "release", id: "RE_1", title: "v1.0.0"),
          build_event(type: "pull_request_merged", id: "PR_1", title: "Fix bug", extra: {}),
          build_event(type: "release", id: "RE_2", title: "v2.0.0")
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        # Release heading appears once, before release events
        release_heading_pos = body.index("  Release\n")
        v1_pos = body.index("v1.0.0")
        v2_pos = body.index("v2.0.0")
        pr_heading_pos = body.index("  PR Merged\n")

        expect(release_heading_pos).to be < v1_pos
        expect(release_heading_pos).to be < v2_pos
        expect(pr_heading_pos).to be > v2_pos
      end

      it "shows type heading only once per type in html" do
        events = [
          build_event(type: "release", id: "RE_1", title: "v1.0.0"),
          build_event(type: "release", id: "RE_2", title: "v2.0.0")
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        # Only one Release heading in HTML
        expect(body.scan("<h3").count).to eq(1)
        expect(body).to include("Release")
      end

      it "adds a blank line between events within the same type in text" do
        events = [
          build_event(
            type: "release",
            id: "RE_1",
            title: "v1.0.0",
            url: "https://github.com/owner/repo/releases/tag/v1.0.0",
            time: Time.utc(2024, 1, 15, 11, 0, 0),
            extra: { tag_name: "v1.0.0" }
          ),
          build_event(
            type: "release",
            id: "RE_2",
            title: "v2.0.0",
            url: "https://github.com/owner/repo/releases/tag/v2.0.0",
            time: Time.utc(2024, 1, 15, 12, 0, 0),
            extra: { tag_name: "v2.0.0" }
          )
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.text_part.body.to_s
        # Events are listed newest-first; ensure there's a blank line between event blocks.
        expect(body).to include("Tag: v2.0.0\n\n    v1.0.0")
      end

      it "adds spacing between events within the same type in html" do
        events = [
          build_event(
            type: "release",
            id: "RE_1",
            title: "v1.0.0",
            url: "https://github.com/owner/repo/releases/tag/v1.0.0",
            time: Time.utc(2024, 1, 15, 11, 0, 0),
            extra: { tag_name: "v1.0.0" }
          ),
          build_event(
            type: "release",
            id: "RE_2",
            title: "v2.0.0",
            url: "https://github.com/owner/repo/releases/tag/v2.0.0",
            time: Time.utc(2024, 1, 15, 12, 0, 0),
            extra: { tag_name: "v2.0.0" }
          )
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).to include("<div style=\"height: 8px;\"></div>")
      end
    end

    context "with HTML escaping" do
      it "escapes special characters in event title" do
        event = build_event(title: "<script>alert('xss')</script>")
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).not_to include("<script>")
        expect(body).to include("&lt;script&gt;")
      end

      it "escapes special characters in author name" do
        event = build_event(
          type: "pull_request_created",
          author: "<b>attacker</b>",
          extra: {}
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).not_to include("<b>attacker</b>")
        expect(body).to include("&lt;b&gt;attacker&lt;/b&gt;")
      end
    end

    context "with dangerous URLs" do
      it "does not create link for javascript: URL" do
        event = build_event(url: "javascript:alert('xss')")
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).not_to include("href=\"javascript:")
        expect(body).to include("javascript:alert")
      end

      it "does not create link for data: URL" do
        event = build_event(url: "data:text/html,<script>alert('xss')</script>")
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).not_to include("href=\"data:")
      end

      it "creates link for https URL" do
        event = build_event(url: "https://github.com/owner/repo")
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).to include("href=\"https://github.com/owner/repo\"")
      end

      it "creates link for http URL" do
        event = build_event(url: "http://example.com/path")
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.html_part.body.to_s
        expect(body).to include("href=\"http://example.com/path\"")
      end
    end
  end
end
