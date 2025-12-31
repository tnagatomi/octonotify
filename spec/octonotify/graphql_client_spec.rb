# frozen_string_literal: true

require "spec_helper"

RSpec.describe Octonotify::GraphQLClient do
  let(:token) { "test_token" }

  def build_test_connection(stubs)
    Faraday.new do |conn|
      conn.adapter :test, stubs
    end
  end

  describe "#initialize" do
    it "raises APIError when token is nil" do
      expect do
        described_class.new(token: nil)
      end.to raise_error(Octonotify::APIError, /GITHUB_TOKEN is required/)
    end

    it "raises APIError when token is empty" do
      expect do
        described_class.new(token: "")
      end.to raise_error(Octonotify::APIError, /GITHUB_TOKEN is required/)
    end
  end

  describe "#fetch_releases" do
    it "fetches releases with all expected fields" do
      response_body = {
        data: {
          repository: {
            releases: {
              pageInfo: { hasNextPage: true, endCursor: "cursor_abc" },
              nodes: [
                {
                  id: "RE_123",
                  name: "Release v1.0.0",
                  tagName: "v1.0.0",
                  url: "https://github.com/owner/repo/releases/tag/v1.0.0",
                  publishedAt: "2024-01-15T12:00:00Z"
                }
              ]
            }
          },
          rateLimit: { cost: 1, remaining: 4999, resetAt: "2024-01-15T13:00:00Z" }
        }
      }.to_json

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") { [200, { "Content-Type" => "application/json" }, response_body] }
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))
      result = client.fetch_releases(owner: "owner", repo: "repo")

      expect(result).to match(
        "repository" => {
          "releases" => {
            "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor_abc" },
            "nodes" => [
              {
                "id" => "RE_123",
                "name" => "Release v1.0.0",
                "tagName" => "v1.0.0",
                "url" => "https://github.com/owner/repo/releases/tag/v1.0.0",
                "publishedAt" => "2024-01-15T12:00:00Z"
              }
            ]
          }
        },
        "rateLimit" => { "cost" => 1, "remaining" => 4999, "resetAt" => "2024-01-15T13:00:00Z" }
      )

      stubs.verify_stubbed_calls
    end
  end

  describe "#fetch_merged_pull_requests" do
    it "fetches merged PRs with all expected fields" do
      response_body = {
        data: {
          repository: {
            pullRequests: {
              pageInfo: { hasNextPage: false, endCursor: nil },
              nodes: [
                {
                  id: "PR_123",
                  title: "Fix critical bug",
                  url: "https://github.com/owner/repo/pull/42",
                  mergedAt: "2024-01-15T14:30:00Z",
                  author: { login: "alice" },
                  mergedBy: { login: "bob" }
                }
              ]
            }
          },
          rateLimit: { cost: 1, remaining: 4998, resetAt: "2024-01-15T15:00:00Z" }
        }
      }.to_json

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") { [200, { "Content-Type" => "application/json" }, response_body] }
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))
      result = client.fetch_merged_pull_requests(owner: "owner", repo: "repo")

      expect(result).to match(
        "repository" => {
          "pullRequests" => {
            "pageInfo" => { "hasNextPage" => false, "endCursor" => nil },
            "nodes" => [
              {
                "id" => "PR_123",
                "title" => "Fix critical bug",
                "url" => "https://github.com/owner/repo/pull/42",
                "mergedAt" => "2024-01-15T14:30:00Z",
                "author" => { "login" => "alice" },
                "mergedBy" => { "login" => "bob" }
              }
            ]
          }
        },
        "rateLimit" => { "cost" => 1, "remaining" => 4998, "resetAt" => "2024-01-15T15:00:00Z" }
      )

      stubs.verify_stubbed_calls
    end
  end

  describe "#fetch_created_pull_requests" do
    it "fetches open PRs with all expected fields" do
      response_body = {
        data: {
          repository: {
            pullRequests: {
              pageInfo: { hasNextPage: true, endCursor: "cursor_xyz" },
              nodes: [
                {
                  id: "PR_456",
                  title: "Add new feature",
                  url: "https://github.com/owner/repo/pull/99",
                  createdAt: "2024-01-15T10:00:00Z",
                  author: { login: "charlie" }
                }
              ]
            }
          },
          rateLimit: { cost: 1, remaining: 4997, resetAt: "2024-01-15T11:00:00Z" }
        }
      }.to_json

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") { [200, { "Content-Type" => "application/json" }, response_body] }
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))
      result = client.fetch_created_pull_requests(owner: "owner", repo: "repo")

      expect(result).to match(
        "repository" => {
          "pullRequests" => {
            "pageInfo" => { "hasNextPage" => true, "endCursor" => "cursor_xyz" },
            "nodes" => [
              {
                "id" => "PR_456",
                "title" => "Add new feature",
                "url" => "https://github.com/owner/repo/pull/99",
                "createdAt" => "2024-01-15T10:00:00Z",
                "author" => { "login" => "charlie" }
              }
            ]
          }
        },
        "rateLimit" => { "cost" => 1, "remaining" => 4997, "resetAt" => "2024-01-15T11:00:00Z" }
      )

      stubs.verify_stubbed_calls
    end
  end

  describe "#fetch_issues" do
    it "fetches issues with all expected fields" do
      response_body = {
        data: {
          repository: {
            issues: {
              pageInfo: { hasNextPage: false, endCursor: "cursor_issue" },
              nodes: [
                {
                  id: "I_789",
                  title: "Bug: Application crashes on startup",
                  url: "https://github.com/owner/repo/issues/100",
                  createdAt: "2024-01-15T08:00:00Z",
                  author: { login: "dave" }
                }
              ]
            }
          },
          rateLimit: { cost: 1, remaining: 4996, resetAt: "2024-01-15T09:00:00Z" }
        }
      }.to_json

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") { [200, { "Content-Type" => "application/json" }, response_body] }
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))
      result = client.fetch_issues(owner: "owner", repo: "repo")

      expect(result).to match(
        "repository" => {
          "issues" => {
            "pageInfo" => { "hasNextPage" => false, "endCursor" => "cursor_issue" },
            "nodes" => [
              {
                "id" => "I_789",
                "title" => "Bug: Application crashes on startup",
                "url" => "https://github.com/owner/repo/issues/100",
                "createdAt" => "2024-01-15T08:00:00Z",
                "author" => { "login" => "dave" }
              }
            ]
          }
        },
        "rateLimit" => { "cost" => 1, "remaining" => 4996, "resetAt" => "2024-01-15T09:00:00Z" }
      )

      stubs.verify_stubbed_calls
    end
  end

  describe "error handling" do
    it "raises APIError on HTTP error" do
      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") { [500, {}, "Internal Server Error"] }
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))

      expect do
        client.fetch_releases(owner: "owner", repo: "repo")
      end.to raise_error(Octonotify::APIError, /GraphQL request failed: 500/)
    end

    it "raises APIError on GraphQL errors" do
      response_body = {
        errors: [{ message: "Repository not found" }]
      }.to_json

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") { [200, { "Content-Type" => "application/json" }, response_body] }
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))

      expect do
        client.fetch_releases(owner: "owner", repo: "repo")
      end.to raise_error(Octonotify::APIError, /GraphQL errors: Repository not found/)
    end
  end

  describe "pagination" do
    it "supports after cursor parameter" do
      response_body = {
        data: {
          repository: {
            releases: {
              pageInfo: { hasNextPage: false, endCursor: nil },
              nodes: []
            }
          },
          rateLimit: { cost: 1, remaining: 4995, resetAt: "2024-01-15T01:00:00Z" }
        }
      }.to_json

      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post("") do |env|
          body = JSON.parse(env.body)
          expect(body["variables"]["after"]).to eq("cursor123")
          [200, { "Content-Type" => "application/json" }, response_body]
        end
      end

      client = described_class.new(token: token, connection: build_test_connection(stubs))
      result = client.fetch_releases(owner: "owner", repo: "repo", after: "cursor123")

      expect(result["repository"]["releases"]["pageInfo"]["hasNextPage"]).to eq(false)
      stubs.verify_stubbed_calls
    end
  end
end
