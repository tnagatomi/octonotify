# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "json"

RSpec.describe Octonotify::State do
  def with_state_file(content = nil)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, content) if content
      yield path
    end
  end

  describe ".load" do
    context "when state file does not exist" do
      it "initializes new state" do
        with_state_file do |path|
          state = described_class.load(state_path: path)

          expect(state.initialized_at).not_to be_nil
          expect(state.notify_after).to eq(state.initialized_at)
          expect(state.repos).to eq({})
          expect(state.last_run).to eq({})
        end
      end
    end

    context "when state file exists" do
      it "loads existing state" do
        existing_state = <<~JSON
          {
            "initialized_at": "2024-01-01T00:00:00Z",
            "notify_after": "2024-01-01T00:00:00Z",
            "last_run": {
              "started_at": "2024-01-02T00:00:00Z",
              "finished_at": "2024-01-02T00:01:00Z",
              "status": "success"
            },
            "repos": {
              "owner/repo": {
                "url": "https://github.com/owner/repo",
                "events": {
                  "release": {
                    "watermark_time": "2024-01-01T12:00:00Z",
                    "recent_notified_ids": ["R_123"]
                  }
                }
              }
            }
          }
        JSON

        with_state_file(existing_state) do |path|
          state = described_class.load(state_path: path)

          expect(state.initialized_at).to eq("2024-01-01T00:00:00Z")
          expect(state.notify_after).to eq("2024-01-01T00:00:00Z")
          expect(state.last_run["status"]).to eq("success")
          expect(state.repos["owner/repo"]["url"]).to eq("https://github.com/owner/repo")
        end
      end
    end

    context "when state file is invalid JSON" do
      it "raises StateError" do
        with_state_file("invalid json") do |path|
          expect do
            described_class.load(state_path: path)
          end.to raise_error(Octonotify::StateError, /Invalid state file/)
        end
      end
    end
  end

  describe "#save" do
    it "writes state to file" do
      with_state_file do |path|
        state = described_class.load(state_path: path)
        state.repo_state("owner/repo")
        state.save

        data = JSON.parse(File.read(path))
        expect(data["initialized_at"]).to eq(state.initialized_at)
        expect(data["repos"]["owner/repo"]["url"]).to eq("https://github.com/owner/repo")
      end
    end
  end

  describe "#start_run and #finish_run" do
    it "tracks run lifecycle" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        state.start_run
        expect(state.last_run["status"]).to eq("running")
        expect(state.last_run["started_at"]).not_to be_nil
        expect(state.last_run["finished_at"]).to be_nil

        state.finish_run(status: "success", rate_limit: { "remaining" => 4500 })
        expect(state.last_run["status"]).to eq("success")
        expect(state.last_run["finished_at"]).not_to be_nil
        expect(state.last_run["rate_limit"]["remaining"]).to eq(4500)
      end
    end
  end

  describe "#repo_state" do
    it "creates new repo state if not exists" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        repo = state.repo_state("owner/repo")
        expect(repo["url"]).to eq("https://github.com/owner/repo")
        expect(repo["events"]).to eq({})
      end
    end

    it "returns existing repo state" do
      existing_state = <<~JSON
        {
          "initialized_at": "2024-01-01T00:00:00Z",
          "notify_after": "2024-01-01T00:00:00Z",
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {}
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)
        repo = state.repo_state("owner/repo")
        expect(repo["url"]).to eq("https://github.com/owner/repo")
      end
    end
  end

  describe "#event_state" do
    it "creates new event state if not exists" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        event = state.event_state("owner/repo", "release")
        expect(event["watermark_time"]).to eq(state.notify_after)
        expect(event["recent_notified_ids"]).to eq([])
        expect(event["incomplete"]).to be(false)
      end
    end
  end

  describe "#update_watermark" do
    it "updates watermark and clears incomplete state" do
      with_state_file do |path|
        state = described_class.load(state_path: path)
        state.set_resume_cursor("owner/repo", "release", "cursor123", reason: "rate limit")

        state.update_watermark("owner/repo", "release", "2024-01-15T00:00:00Z")

        event = state.event_state("owner/repo", "release")
        expect(event["watermark_time"]).to eq("2024-01-15T00:00:00Z")
        expect(event["resume_cursor"]).to be_nil
        expect(event["incomplete"]).to be(false)
        expect(event["last_success_at"]).not_to be_nil
      end
    end
  end

  describe "#set_resume_cursor" do
    it "sets cursor and marks as incomplete" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        state.set_resume_cursor("owner/repo", "release", "cursor123", reason: "rate limit exceeded")

        event = state.event_state("owner/repo", "release")
        expect(event["resume_cursor"]).to eq("cursor123")
        expect(event["incomplete"]).to be(true)
        expect(event["reason"]).to eq("rate limit exceeded")
      end
    end
  end

  describe "#add_notified_id and #notified?" do
    it "tracks notified IDs" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        expect(state.notified?("owner/repo", "release", "R_123")).to be(false)

        state.add_notified_id("owner/repo", "release", "R_123")
        expect(state.notified?("owner/repo", "release", "R_123")).to be(true)
      end
    end

    it "limits recent IDs to RECENT_IDS_LIMIT" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        150.times { |i| state.add_notified_id("owner/repo", "release", "R_#{i}") }

        event = state.event_state("owner/repo", "release")
        expect(event["recent_notified_ids"].size).to eq(described_class::RECENT_IDS_LIMIT)
        expect(state.notified?("owner/repo", "release", "R_0")).to be(false)
        expect(state.notified?("owner/repo", "release", "R_149")).to be(true)
      end
    end
  end

  describe "#should_notify?" do
    it "returns true for events after notify_after" do
      existing_state = <<~JSON
        {
          "initialized_at": "2024-01-01T00:00:00Z",
          "notify_after": "2024-01-01T00:00:00Z",
          "repos": {}
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)

        expect(state.should_notify?("2024-01-01T00:00:01Z")).to be(true)
        expect(state.should_notify?("2024-01-02T00:00:00Z")).to be(true)
      end
    end

    it "returns false for events at or before notify_after" do
      existing_state = <<~JSON
        {
          "initialized_at": "2024-01-01T00:00:00Z",
          "notify_after": "2024-01-01T00:00:00Z",
          "repos": {}
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)

        expect(state.should_notify?("2024-01-01T00:00:00Z")).to be(false)
        expect(state.should_notify?("2023-12-31T00:00:00Z")).to be(false)
      end
    end

    it "returns false for nil event time" do
      with_state_file do |path|
        state = described_class.load(state_path: path)
        expect(state.should_notify?(nil)).to be(false)
      end
    end
  end
end
