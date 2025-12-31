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
      original_host = ENV.fetch("SMTP_HOST", nil)
      example.run
      ENV["SMTP_HOST"] = original_host
    end

    context "when SMTP_HOST is not set" do
      it "raises ConfigError" do
        ENV.delete("SMTP_HOST")
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /SMTP_HOST environment variable is required/)
      end
    end

    context "when SMTP_HOST is empty" do
      it "raises ConfigError" do
        ENV["SMTP_HOST"] = ""
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /SMTP_HOST environment variable is required/)
      end
    end

    context "when SMTP_HOST is set" do
      it "creates mailer successfully" do
        ENV["SMTP_HOST"] = "smtp.example.com"
        expect { described_class.new(config: config) }.not_to raise_error
      end
    end

    context "when SMTP_USERNAME is set but SMTP_PASSWORD is missing" do
      around do |example|
        original_username = ENV.fetch("SMTP_USERNAME", nil)
        original_password = ENV.fetch("SMTP_PASSWORD", nil)
        example.run
        ENV["SMTP_USERNAME"] = original_username
        ENV["SMTP_PASSWORD"] = original_password
      end

      it "raises ConfigError" do
        ENV["SMTP_HOST"] = "smtp.example.com"
        ENV["SMTP_USERNAME"] = "user"
        ENV.delete("SMTP_PASSWORD")
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /SMTP_PASSWORD is required when SMTP_USERNAME is set/)
      end

      it "raises ConfigError when password is empty" do
        ENV["SMTP_HOST"] = "smtp.example.com"
        ENV["SMTP_USERNAME"] = "user"
        ENV["SMTP_PASSWORD"] = ""
        expect do
          described_class.new(config: config)
        end.to raise_error(Octonotify::ConfigError, /SMTP_PASSWORD is required when SMTP_USERNAME is set/)
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

      it "includes event details in body" do
        mailer.send_digest([build_event])

        mail = Mail::TestMailer.deliveries.first
        body = mail.body.to_s

        expect(body).to include("## owner/repo")
        expect(body).to include("https://github.com/owner/repo")
        expect(body).to include("[Release] v1.0.0")
        expect(body).to include("https://github.com/owner/repo/releases/tag/v1.0.0")
        expect(body).to include("Tag: v1.0.0")
      end

      it "converts time to configured timezone" do
        mailer.send_digest([build_event(time: Time.utc(2024, 1, 15, 12, 0, 0))])

        mail = Mail::TestMailer.deliveries.first
        body = mail.body.to_s

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
        body = mail.body.to_s

        expect(body).to include("## owner/repo1")
        expect(body).to include("## owner/repo2")
        expect(body).to include("Release 1")
        expect(body).to include("Release 2")
      end
    end

    context "with different event types" do
      it "formats release event correctly" do
        event = build_event(
          type: "release",
          title: "v1.0.0",
          extra: { tag_name: "v1.0.0" }
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.body.to_s
        expect(body).to include("[Release]")
        expect(body).to include("Tag: v1.0.0")
      end

      it "formats pull_request_merged event correctly" do
        event = build_event(
          type: "pull_request_merged",
          title: "Fix bug",
          author: "alice",
          extra: { merged_by: "bob" }
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.body.to_s
        expect(body).to include("[PR Merged]")
        expect(body).to include("Author: alice")
        expect(body).to include("Merged by: bob")
      end

      it "formats pull_request_created event correctly" do
        event = build_event(
          type: "pull_request_created",
          title: "Add feature",
          author: "charlie",
          extra: {}
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.body.to_s
        expect(body).to include("[PR Created]")
        expect(body).to include("Author: charlie")
      end

      it "formats issue_created event correctly" do
        event = build_event(
          type: "issue_created",
          title: "Bug report",
          author: "dave",
          extra: {}
        )
        mailer.send_digest([event])

        body = Mail::TestMailer.deliveries.first.body.to_s
        expect(body).to include("[Issue Created]")
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

        body = Mail::TestMailer.deliveries.first.body.to_s
        alpha_pos = body.index("## alpha/repo")
        zeta_pos = body.index("## zeta/repo")
        expect(alpha_pos).to be < zeta_pos
      end

      it "sorts events within repo by time descending (newest first)" do
        events = [
          build_event(id: "RE_1", title: "Older", time: Time.utc(2024, 1, 15, 10, 0, 0)),
          build_event(id: "RE_2", title: "Newer", time: Time.utc(2024, 1, 15, 12, 0, 0))
        ]
        mailer.send_digest(events)

        body = Mail::TestMailer.deliveries.first.body.to_s
        newer_pos = body.index("Newer")
        older_pos = body.index("Older")
        expect(newer_pos).to be < older_pos
      end
    end
  end
end
