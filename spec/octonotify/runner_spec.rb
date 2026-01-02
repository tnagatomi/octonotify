# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "tmpdir"

RSpec.describe Octonotify::Runner do
  let(:config) { instance_double(Octonotify::Config) }
  let(:state) { instance_double(Octonotify::State) }
  let(:client) { instance_double(Octonotify::GraphQLClient) }
  let(:poller) { instance_double(Octonotify::Poller) }
  let(:mailer) { instance_double(Octonotify::Mailer) }
  let(:logger) { Logger.new(StringIO.new) }

  let(:poll_result) do
    {
      events: [],
      rate_limit: { "remaining" => 4999 },
      incomplete: false
    }
  end

  before do
    allow(state).to receive(:start_run)
    allow(state).to receive(:sync_with_config!)
    allow(state).to receive(:finish_run)
    allow(state).to receive(:save)
    allow(poller).to receive(:poll).and_return(poll_result)
    allow(mailer).to receive(:send_digest)
  end

  describe "#run" do
    context "with no new events" do
      it "completes successfully without sending email" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        result = runner.run

        expect(result[:status]).to eq("success")
        expect(result[:events_count]).to eq(0)
        expect(mailer).not_to have_received(:send_digest)
      end

      it "calls finish_run with success status and rate_limit" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        runner.run

        expect(state).to have_received(:finish_run).with(
          status: "success",
          rate_limit: { "remaining" => 4999 }
        )
      end
    end

    context "with new events" do
      let(:events) do
        [
          Octonotify::Poller::Event.new(
            type: "release",
            repo: "owner/repo",
            id: "RE_123",
            title: "v1.0.0",
            url: "https://github.com/owner/repo/releases/tag/v1.0.0",
            time: Time.now,
            author: nil,
            extra: {}
          )
        ]
      end

      let(:poll_result) do
        {
          events: events,
          rate_limit: { "remaining" => 4999 },
          incomplete: false
        }
      end

      it "sends digest email" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        result = runner.run

        expect(result[:status]).to eq("success")
        expect(result[:events_count]).to eq(1)
        expect(mailer).to have_received(:send_digest).with(events)
      end

      it "calls finish_run with success status and rate_limit" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        runner.run

        expect(state).to have_received(:finish_run).with(
          status: "success",
          rate_limit: { "remaining" => 4999 }
        )
      end
    end

    context "when polling is incomplete due to rate limit" do
      let(:poll_result) do
        {
          events: [],
          rate_limit: { "remaining" => 50 },
          incomplete: true
        }
      end

      it "returns incomplete status" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        result = runner.run

        expect(result[:status]).to eq("incomplete")
        expect(result[:incomplete]).to be(true)
      end

      it "calls finish_run with incomplete status" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        runner.run

        expect(state).to have_received(:finish_run).with(
          status: "incomplete",
          rate_limit: { "remaining" => 50 }
        )
      end
    end

    context "when email delivery partially fails" do
      let(:events) do
        [
          Octonotify::Poller::Event.new(
            type: "release",
            repo: "owner/repo",
            id: "RE_123",
            title: "v1.0.0",
            url: "https://github.com/owner/repo/releases/tag/v1.0.0",
            time: Time.now,
            author: nil,
            extra: {}
          )
        ]
      end

      let(:poll_result) do
        {
          events: events,
          rate_limit: { "remaining" => 4999 },
          incomplete: false
        }
      end

      it "returns partial_failure status" do
        allow(mailer).to receive(:send_digest).and_raise(
          Octonotify::Mailer::DeliveryError.new({ "user@example.com" => StandardError.new })
        )

        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        result = runner.run

        expect(result[:status]).to eq("partial_failure")
        expect(result[:delivery_error]).to be_a(Octonotify::Mailer::DeliveryError)
      end

      it "calls finish_run with partial_failure status" do
        allow(mailer).to receive(:send_digest).and_raise(
          Octonotify::Mailer::DeliveryError.new({ "user@example.com" => StandardError.new })
        )

        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        runner.run

        expect(state).to have_received(:finish_run).with(
          status: "partial_failure",
          rate_limit: { "remaining" => 4999 }
        )
      end
    end

    context "when polling fails" do
      it "records error status and re-raises exception" do
        allow(poller).to receive(:poll).and_raise(Octonotify::APIError, "API failed")

        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        expect { runner.run }.to raise_error(Octonotify::APIError, "API failed")
        expect(state).to have_received(:finish_run).with(status: "error", rate_limit: nil)
      end
    end

    context "with persist_state: true" do
      it "saves state after run" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: true
        )

        runner.run

        expect(state).to have_received(:save)
      end
    end

    context "with persist_state: false" do
      it "does not save state" do
        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: false
        )

        runner.run

        expect(state).not_to have_received(:save)
      end
    end

    context "when state.save fails but original error exists" do
      it "logs save error and raises original error" do
        allow(poller).to receive(:poll).and_raise(Octonotify::APIError, "API failed")
        allow(state).to receive(:save).and_raise(IOError, "Write failed")

        log_output = StringIO.new
        test_logger = Logger.new(log_output)

        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: test_logger,
          persist_state: true
        )

        expect { runner.run }.to raise_error(Octonotify::APIError, "API failed")
        expect(log_output.string).to include("Failed to save state")
      end
    end

    context "when state.save fails with no original error" do
      it "raises save error" do
        allow(state).to receive(:save).and_raise(IOError, "Write failed")

        runner = described_class.new(
          config: config,
          state: state,
          client: client,
          poller: poller,
          mailer: mailer,
          logger: logger,
          persist_state: true
        )

        expect { runner.run }.to raise_error(IOError, "Write failed")
      end
    end

    it "calls state lifecycle methods in correct order with persist_state: true" do
      call_order = []
      allow(state).to receive(:start_run) { call_order << :start_run }
      allow(state).to receive(:sync_with_config!) { call_order << :sync_with_config! }
      allow(state).to receive(:finish_run) { call_order << :finish_run }
      allow(state).to receive(:save) { call_order << :save }

      runner = described_class.new(
        config: config,
        state: state,
        client: client,
        poller: poller,
        mailer: mailer,
        logger: logger,
        persist_state: true
      )

      runner.run

      expect(call_order).to eq(%i[start_run sync_with_config! finish_run save])
    end

    it "calls state lifecycle methods without save when persist_state: false" do
      call_order = []
      allow(state).to receive(:start_run) { call_order << :start_run }
      allow(state).to receive(:sync_with_config!) { call_order << :sync_with_config! }
      allow(state).to receive(:finish_run) { call_order << :finish_run }
      allow(state).to receive(:save) { call_order << :save }

      runner = described_class.new(
        config: config,
        state: state,
        client: client,
        poller: poller,
        mailer: mailer,
        logger: logger,
        persist_state: false
      )

      runner.run

      expect(call_order).to eq(%i[start_run sync_with_config! finish_run])
      expect(call_order).not_to include(:save)
    end

    context "when using github_token parameter" do
      it "passes token to GraphQLClient" do
        allow(Octonotify::GraphQLClient).to receive(:new).and_return(client)
        allow(Octonotify::Poller).to receive(:new).and_return(poller)
        allow(Octonotify::Mailer).to receive(:new).and_return(mailer)

        runner = described_class.new(
          config: config,
          state: state,
          github_token: "test_token_123",
          logger: logger,
          persist_state: false
        )

        runner.run

        expect(Octonotify::GraphQLClient).to have_received(:new).with(token: "test_token_123")
      end
    end

    context "with no-miss policy for state persistence" do
      let(:config) { instance_double(Octonotify::Config, repos: { "owner/repo" => { events: ["release"] } }) }
      let(:client) { instance_double(Octonotify::GraphQLClient) }
      let(:poller) { instance_double(Octonotify::Poller) }
      let(:logger) { Logger.new(StringIO.new) }

      def build_event
        Octonotify::Poller::Event.new(
          type: "release",
          repo: "owner/repo",
          id: "RE_123",
          title: "v1.0.0",
          url: "https://github.com/owner/repo/releases/tag/v1.0.0",
          time: Time.utc(2024, 1, 15, 12, 0, 0),
          author: nil,
          extra: {}
        )
      end

      it "does not apply state changes when email delivery fails" do
        Dir.mktmpdir do |dir|
          state_path = File.join(dir, "state.json")
          state = Octonotify::State.new(state_path: state_path)

          poll_result = {
            events: [build_event],
            rate_limit: { "remaining" => 4999 },
            incomplete: false,
            state_changes: {
              notified_ids: [{ repo: "owner/repo", event_type: "release", id: "RE_123" }],
              watermarks: [{ repo: "owner/repo", event_type: "release", watermark_time: "2024-01-15T12:00:00Z" }],
              resume_cursors: []
            }
          }
          allow(poller).to receive(:poll).and_return(poll_result)

          mailer = instance_double(Octonotify::Mailer)
          allow(mailer).to receive(:send_digest).and_raise(
            Octonotify::Mailer::DeliveryError.new({ "user@example.com" => StandardError.new })
          )

          runner = described_class.new(
            config: config,
            state: state,
            client: client,
            poller: poller,
            mailer: mailer,
            logger: logger,
            persist_state: false
          )

          result = runner.run
          expect(result[:status]).to eq("partial_failure")
          # State should have been synced (repo exists) but no state_changes applied
          expect(state.repos["owner/repo"]).not_to be_nil
          expect(state.repos["owner/repo"]["events"]["release"]["recent_notified_ids"]).to eq([])
        end
      end

      it "applies state changes when email delivery succeeds" do
        Dir.mktmpdir do |dir|
          state_path = File.join(dir, "state.json")
          state = Octonotify::State.new(state_path: state_path)

          poll_result = {
            events: [build_event],
            rate_limit: { "remaining" => 4999 },
            incomplete: false,
            state_changes: {
              notified_ids: [{ repo: "owner/repo", event_type: "release", id: "RE_123" }],
              watermarks: [{ repo: "owner/repo", event_type: "release", watermark_time: "2024-01-15T12:00:00Z" }],
              resume_cursors: []
            }
          }
          allow(poller).to receive(:poll).and_return(poll_result)

          mailer = instance_double(Octonotify::Mailer, send_digest: nil)

          runner = described_class.new(
            config: config,
            state: state,
            client: client,
            poller: poller,
            mailer: mailer,
            logger: logger,
            persist_state: false
          )

          result = runner.run
          expect(result[:status]).to eq("success")

          event_state = state.repos.dig("owner/repo", "events", "release")
          expect(event_state).not_to be_nil
          expect(event_state["recent_notified_ids"]).to include("RE_123")
          expect(event_state["watermark_time"]).to eq("2024-01-15T12:00:00Z")
        end
      end
    end
  end
end
