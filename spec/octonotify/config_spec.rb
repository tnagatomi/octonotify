# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe Octonotify::Config do
  let(:valid_config_yaml) do
    <<~YAML
      timezone: Asia/Tokyo
      from: "Octonotify <noreply@example.com>"
      to:
        - user@example.com
      repos:
        owner/repo:
          events:
            - release
            - pull_request_merged
    YAML
  end

  def with_config_file(yaml_content)
    Tempfile.create(["config", ".yml"]) do |f|
      f.write(yaml_content)
      f.rewind
      yield f.path
    end
  end

  describe ".load" do
    context "with valid config" do
      it "loads config successfully" do
        with_config_file(valid_config_yaml) do |path|
          config = described_class.load(config_path: path)

          expect(config.timezone).to eq("Asia/Tokyo")
          expect(config.from).to eq("Octonotify <noreply@example.com>")
          expect(config.to).to eq(["user@example.com"])
          expect(config.repos).to eq({
            "owner/repo" => { events: ["release", "pull_request_merged"] }
          })
        end
      end

      it "uses UTC as default timezone" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          config = described_class.load(config_path: path)
          expect(config.timezone).to eq("UTC")
        end
      end

      it "accepts single recipient as string" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to: user@example.com
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          config = described_class.load(config_path: path)
          expect(config.to).to eq(["user@example.com"])
        end
      end
    end

    context "with missing config file" do
      it "raises ConfigError" do
        expect {
          described_class.load(config_path: "/nonexistent/config.yml")
        }.to raise_error(Octonotify::ConfigError, /Config file not found/)
      end
    end

    context "with invalid timezone" do
      it "raises ConfigError" do
        yaml = <<~YAML
          timezone: Invalid/Zone
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /Invalid timezone/)
        end
      end
    end

    context "with missing from" do
      it "raises ConfigError" do
        yaml = <<~YAML
          to:
            - user@example.com
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /'from' is required/)
        end
      end
    end

    context "with empty to" do
      it "raises ConfigError" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to: []
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /'to' must have at least one recipient/)
        end
      end
    end

    context "with blank recipients" do
      it "treats blank recipients as missing and raises ConfigError" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - "   "
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /'to' must have at least one recipient/)
        end
      end
    end

    context "with newline in from" do
      it "raises ConfigError to prevent header injection" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>\\nBcc: attacker@example.com"
          to:
            - user@example.com
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /must not contain newlines/)
        end
      end
    end

    context "with newline in to recipient" do
      it "raises ConfigError to prevent header injection" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - "user@example.com\\r\\nBcc: attacker@example.com"
          repos:
            owner/repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /must not contain newlines/)
        end
      end
    end

    context "with invalid repo format" do
      it "raises ConfigError for repo without slash" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos:
            invalid-repo:
              events:
                - release
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /Invalid repo format.*must be 'owner\/repo'/)
        end
      end
    end

    context "with invalid events" do
      it "raises ConfigError" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos:
            owner/repo:
              events:
                - invalid_event
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /invalid events.*invalid_event/)
        end
      end
    end

    context "with repos not a mapping" do
      it "raises ConfigError" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos: []
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /'repos' must be a mapping/)
        end
      end
    end

    context "with repo config not a mapping" do
      it "raises ConfigError" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos:
            owner/repo: "oops"
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /Repo config must be a mapping/)
        end
      end
    end

    context "with empty events" do
      it "raises ConfigError" do
        yaml = <<~YAML
          from: "Octonotify <noreply@example.com>"
          to:
            - user@example.com
          repos:
            owner/repo:
              events: []
        YAML

        with_config_file(yaml) do |path|
          expect {
            described_class.load(config_path: path)
          }.to raise_error(Octonotify::ConfigError, /must have at least one event/)
        end
      end
    end
  end

  describe "#timezone_info" do
    it "returns TZInfo::Timezone object" do
      with_config_file(valid_config_yaml) do |path|
        config = described_class.load(config_path: path)
        expect(config.timezone_info).to be_a(TZInfo::Timezone)
        expect(config.timezone_info.identifier).to eq("Asia/Tokyo")
      end
    end
  end

  describe "#repos_with_event" do
    it "returns repos that have the specified event" do
      yaml = <<~YAML
        from: "Octonotify <noreply@example.com>"
        to:
          - user@example.com
        repos:
          owner/repo1:
            events:
              - release
              - pull_request_merged
          owner/repo2:
            events:
              - release
          owner/repo3:
            events:
              - issue_created
      YAML

      with_config_file(yaml) do |path|
        config = described_class.load(config_path: path)

        expect(config.repos_with_event("release")).to contain_exactly("owner/repo1", "owner/repo2")
        expect(config.repos_with_event("pull_request_merged")).to contain_exactly("owner/repo1")
        expect(config.repos_with_event("issue_created")).to contain_exactly("owner/repo3")
      end
    end
  end
end
