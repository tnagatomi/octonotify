# frozen_string_literal: true

require "faraday"
require "faraday/retry"
require "json"

module Octonotify
  class GraphQLClient
    GITHUB_GRAPHQL_ENDPOINT = "https://api.github.com/graphql"

    def initialize(token: ENV.fetch("GITHUB_TOKEN", nil), connection: nil)
      raise APIError, "GITHUB_TOKEN is required" if token.nil? || token.empty?

      @connection = connection || build_connection(token)
    end

    def fetch_releases(owner:, repo:, first: 10, after: nil)
      query = <<~GRAPHQL
        query($owner: String!, $repo: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            releases(first: $first, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                name
                tagName
                url
                publishedAt
              }
            }
          }
          rateLimit {
            cost
            remaining
            resetAt
          }
        }
      GRAPHQL

      variables = { owner: owner, repo: repo, first: first, after: after }
      execute(query, variables)
    end

    def fetch_merged_pull_requests(owner:, repo:, first: 10, after: nil)
      query = <<~GRAPHQL
        query($owner: String!, $repo: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequests(first: $first, after: $after, states: MERGED, orderBy: {field: UPDATED_AT, direction: DESC}) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                title
                url
                mergedAt
                author {
                  login
                }
                mergedBy {
                  login
                }
              }
            }
          }
          rateLimit {
            cost
            remaining
            resetAt
          }
        }
      GRAPHQL

      variables = { owner: owner, repo: repo, first: first, after: after }
      execute(query, variables)
    end

    def fetch_created_pull_requests(owner:, repo:, first: 10, after: nil)
      query = <<~GRAPHQL
        query($owner: String!, $repo: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            pullRequests(first: $first, after: $after, states: OPEN, orderBy: {field: CREATED_AT, direction: DESC}) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                title
                url
                createdAt
                author {
                  login
                }
              }
            }
          }
          rateLimit {
            cost
            remaining
            resetAt
          }
        }
      GRAPHQL

      variables = { owner: owner, repo: repo, first: first, after: after }
      execute(query, variables)
    end

    def fetch_issues(owner:, repo:, first: 10, after: nil)
      query = <<~GRAPHQL
        query($owner: String!, $repo: String!, $first: Int!, $after: String) {
          repository(owner: $owner, name: $repo) {
            issues(first: $first, after: $after, orderBy: {field: CREATED_AT, direction: DESC}) {
              pageInfo {
                hasNextPage
                endCursor
              }
              nodes {
                id
                title
                url
                createdAt
                author {
                  login
                }
              }
            }
          }
          rateLimit {
            cost
            remaining
            resetAt
          }
        }
      GRAPHQL

      variables = { owner: owner, repo: repo, first: first, after: after }
      execute(query, variables)
    end

    private

    def build_connection(token)
      Faraday.new(url: GITHUB_GRAPHQL_ENDPOINT) do |conn|
        conn.request :retry, max: 3, interval: 0.5, backoff_factor: 2,
                             exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
        conn.headers["Authorization"] = "Bearer #{token}"
        conn.headers["Content-Type"] = "application/json"
        conn.headers["User-Agent"] = "Octonotify/#{VERSION}"
        conn.adapter Faraday.default_adapter
      end
    end

    def execute(query, variables)
      body = { query: query, variables: variables }.to_json
      response = @connection.post("", body)

      unless response.success?
        raise APIError, "GraphQL request failed: #{response.status} #{response.body}"
      end

      data = JSON.parse(response.body)

      if data["errors"]
        raise APIError, "GraphQL errors: #{data['errors'].map { |e| e['message'] }.join(', ')}"
      end

      data["data"]
    end
  end
end
