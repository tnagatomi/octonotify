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

          expect(state.repos).to eq({})
          expect(state.last_run).to eq({})
        end
      end
    end

    context "when state file exists" do
      it "loads existing state" do
        existing_state = <<~JSON
          {
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
                    "baseline_time": "2024-01-01T00:00:00Z",
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

          expect(state.last_run["status"]).to eq("success")
          expect(state.repos["owner/repo"]["url"]).to eq("https://github.com/owner/repo")
          expect(state.repos["owner/repo"]["events"]["release"]["baseline_time"]).to eq("2024-01-01T00:00:00Z")
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
        config = instance_double(Octonotify::Config, repos: { "owner/repo" => { events: ["release"] } })
        state.sync_with_config!(config, baseline_time: "2024-01-01T00:00:00Z")
        state.save

        data = JSON.parse(File.read(path))
        expect(data["repos"]["owner/repo"]["url"]).to eq("https://github.com/owner/repo")
        expect(data["repos"]["owner/repo"]["events"]["release"]["baseline_time"]).to eq("2024-01-01T00:00:00Z")
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

  describe "#sync_with_config!" do
    it "creates missing repos/events with baseline_time" do
      with_state_file do |path|
        state = described_class.load(state_path: path)
        config = instance_double(Octonotify::Config, repos: {
                                   "owner/repo1" => { events: %w[release issue_created] },
                                   "owner/repo2" => { events: ["pull_request_merged"] }
                                 })

        state.sync_with_config!(config, baseline_time: "2024-01-15T12:00:00Z")

        # Verify repo1
        expect(state.repos["owner/repo1"]["events"]["release"]["baseline_time"]).to eq("2024-01-15T12:00:00Z")
        expect(state.repos["owner/repo1"]["events"]["release"]["watermark_time"]).to eq("2024-01-15T12:00:00Z")
        expect(state.repos["owner/repo1"]["events"]["issue_created"]["baseline_time"]).to eq("2024-01-15T12:00:00Z")

        # Verify repo2
        expect(state.repos["owner/repo2"]["events"]["pull_request_merged"]["baseline_time"])
          .to eq("2024-01-15T12:00:00Z")
      end
    end

    it "preserves existing event state" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-10T12:00:00Z",
                  "recent_notified_ids": ["R_123"],
                  "resume_cursor": null,
                  "last_success_at": "2024-01-10T12:00:00Z",
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)
        config = instance_double(Octonotify::Config, repos: {
                                   "owner/repo" => { events: ["release"] }
                                 })

        state.sync_with_config!(config, baseline_time: "2024-01-15T12:00:00Z")

        # Existing state should be preserved
        expect(state.repos["owner/repo"]["events"]["release"]["baseline_time"]).to eq("2024-01-01T00:00:00Z")
        expect(state.repos["owner/repo"]["events"]["release"]["watermark_time"]).to eq("2024-01-10T12:00:00Z")
        expect(state.repos["owner/repo"]["events"]["release"]["recent_notified_ids"]).to eq(["R_123"])
      end
    end

    it "adds new event type to existing repo" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-10T12:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)
        config = instance_double(Octonotify::Config, repos: {
                                   "owner/repo" => { events: %w[release issue_created] }
                                 })

        state.sync_with_config!(config, baseline_time: "2024-01-15T12:00:00Z")

        # New event type should have the new baseline_time
        expect(state.repos["owner/repo"]["events"]["issue_created"]["baseline_time"]).to eq("2024-01-15T12:00:00Z")
        # Existing event type should preserve its baseline_time
        expect(state.repos["owner/repo"]["events"]["release"]["baseline_time"]).to eq("2024-01-01T00:00:00Z")
      end
    end

    it "prunes repos not in config" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo1": {
              "url": "https://github.com/owner/repo1",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            },
            "owner/repo2": {
              "url": "https://github.com/owner/repo2",
              "events": {}
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)
        config = instance_double(Octonotify::Config, repos: {
                                   "owner/repo1" => { events: ["release"] }
                                 })

        state.sync_with_config!(config, baseline_time: "2024-01-15T12:00:00Z")

        expect(state.repos.keys).to eq(["owner/repo1"])
        expect(state.repos["owner/repo2"]).to be_nil
      end
    end

    it "prunes event types not in config" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                },
                "issue_created": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)
        config = instance_double(Octonotify::Config, repos: {
                                   "owner/repo" => { events: ["release"] }
                                 })

        state.sync_with_config!(config, baseline_time: "2024-01-15T12:00:00Z")

        expect(state.repos["owner/repo"]["events"].keys).to eq(["release"])
        expect(state.repos["owner/repo"]["events"]["issue_created"]).to be_nil
      end
    end
  end

  describe "#event_state" do
    it "returns event state when it exists" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T12:00:00Z",
                  "recent_notified_ids": ["R_123"],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)
        event = state.event_state("owner/repo", "release")

        expect(event["baseline_time"]).to eq("2024-01-01T00:00:00Z")
        expect(event["watermark_time"]).to eq("2024-01-01T12:00:00Z")
        expect(event["recent_notified_ids"]).to eq(["R_123"])
      end
    end

    it "raises StateError when repo does not exist" do
      with_state_file do |path|
        state = described_class.load(state_path: path)

        expect do
          state.event_state("owner/repo", "release")
        end.to raise_error(Octonotify::StateError, /Unknown repo/)
      end
    end

    it "raises StateError when event type does not exist" do
      existing_state = <<~JSON
        {
          "last_run": {},
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

        expect do
          state.event_state("owner/repo", "release")
        end.to raise_error(Octonotify::StateError, /Unknown event type/)
      end
    end
  end

  describe "#update_watermark" do
    it "updates watermark and clears incomplete state" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": "cursor123",
                  "last_success_at": null,
                  "incomplete": true,
                  "reason": "rate limit"
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)

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
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
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
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)

        expect(state.notified?("owner/repo", "release", "R_123")).to be(false)

        state.add_notified_id("owner/repo", "release", "R_123")
        expect(state.notified?("owner/repo", "release", "R_123")).to be(true)
      end
    end

    it "limits recent IDs to RECENT_IDS_LIMIT" do
      existing_state = <<~JSON
        {
          "last_run": {},
          "repos": {
            "owner/repo": {
              "url": "https://github.com/owner/repo",
              "events": {
                "release": {
                  "baseline_time": "2024-01-01T00:00:00Z",
                  "watermark_time": "2024-01-01T00:00:00Z",
                  "recent_notified_ids": [],
                  "resume_cursor": null,
                  "last_success_at": null,
                  "incomplete": false,
                  "reason": null
                }
              }
            }
          }
        }
      JSON

      with_state_file(existing_state) do |path|
        state = described_class.load(state_path: path)

        150.times { |i| state.add_notified_id("owner/repo", "release", "R_#{i}") }

        event = state.event_state("owner/repo", "release")
        expect(event["recent_notified_ids"].size).to eq(described_class::RECENT_IDS_LIMIT)
        expect(state.notified?("owner/repo", "release", "R_0")).to be(false)
        expect(state.notified?("owner/repo", "release", "R_149")).to be(true)
      end
    end
  end
end
