# frozen_string_literal: true

require "time"

module Octonotify
  class Poller
    LOOKBACK_WINDOW = 30 * 60 # 30 minutes in seconds
    DEFAULT_PAGE_SIZE = 25
    RATE_LIMIT_THRESHOLD = 100

    Event = Data.define(:type, :repo, :id, :title, :url, :time, :author, :extra)

    def initialize(config:, state:, client:)
      @config = config
      @state = state
      @client = client
    end

    def poll
      events = []
      rate_limit = nil

      @config.repos.each do |repo_name, repo_config|
        owner, repo = repo_name.split("/")

        repo_config[:events].each do |event_type|
          result = poll_event(owner: owner, repo: repo, event_type: event_type)
          events.concat(result[:events])
          rate_limit = result[:rate_limit]

          if rate_limit && rate_limit["remaining"] < RATE_LIMIT_THRESHOLD
            return { events: events, rate_limit: rate_limit, incomplete: true }
          end
        end
      end

      { events: events, rate_limit: rate_limit, incomplete: false }
    end

    private

    def poll_event(owner:, repo:, event_type:)
      repo_name = "#{owner}/#{repo}"
      event_state = @state.event_state(repo_name, event_type)
      cursor = event_state["resume_cursor"]

      threshold = calculate_threshold(event_state["watermark_time"])
      events = []
      new_watermark = nil
      rate_limit = nil

      loop do
        result = fetch_events(owner: owner, repo: repo, event_type: event_type, cursor: cursor)
        rate_limit = result[:rate_limit]
        page_info = result[:page_info]
        nodes = result[:nodes]

        break if nodes.empty?

        nodes.each do |node|
          event_time = parse_event_time(node, event_type)
          next if event_time.nil?

          new_watermark = event_time if new_watermark.nil? || event_time > new_watermark

          break if event_time < threshold

          event = build_event(node, event_type, repo_name)
          next if @state.notified?(repo_name, event_type, event.id)
          next unless @state.should_notify?(event_time)

          events << event
          @state.add_notified_id(repo_name, event_type, event.id)
        end

        oldest_time = parse_event_time(nodes.last, event_type)
        break if oldest_time && oldest_time < threshold
        break unless page_info["hasNextPage"]

        if rate_limit && rate_limit["remaining"] < RATE_LIMIT_THRESHOLD
          @state.set_resume_cursor(repo_name, event_type, page_info["endCursor"], reason: "rate limit")
          return { events: events, rate_limit: rate_limit }
        end

        cursor = page_info["endCursor"]
      end

      @state.update_watermark(repo_name, event_type, new_watermark.iso8601) if new_watermark

      { events: events, rate_limit: rate_limit }
    end

    def fetch_events(owner:, repo:, event_type:, cursor:)
      result = case event_type
               when "release"
                 @client.fetch_releases(owner: owner, repo: repo, first: DEFAULT_PAGE_SIZE, after: cursor)
               when "pull_request_merged"
                 @client.fetch_merged_pull_requests(owner: owner, repo: repo, first: DEFAULT_PAGE_SIZE, after: cursor)
               when "pull_request_created"
                 @client.fetch_created_pull_requests(owner: owner, repo: repo, first: DEFAULT_PAGE_SIZE, after: cursor)
               when "issue_created"
                 @client.fetch_issues(owner: owner, repo: repo, first: DEFAULT_PAGE_SIZE, after: cursor)
               else
                 raise ArgumentError, "Unknown event type: #{event_type}"
               end

      collection_key = case event_type
                       when "release" then "releases"
                       when "pull_request_merged", "pull_request_created" then "pullRequests"
                       when "issue_created" then "issues"
                       end

      collection = result["repository"][collection_key]

      {
        nodes: collection["nodes"],
        page_info: collection["pageInfo"],
        rate_limit: result["rateLimit"]
      }
    end

    def calculate_threshold(watermark_time)
      Time.parse(watermark_time) - LOOKBACK_WINDOW
    end

    def parse_event_time(node, event_type)
      time_field = case event_type
                   when "release" then "publishedAt"
                   when "pull_request_merged" then "mergedAt"
                   when "pull_request_created", "issue_created" then "createdAt"
                   end

      time_str = node[time_field]
      return nil if time_str.nil?

      Time.parse(time_str)
    end

    def build_event(node, event_type, repo_name)
      extra = {}

      case event_type
      when "release"
        extra[:tag_name] = node["tagName"]
      when "pull_request_merged"
        extra[:merged_by] = node.dig("mergedBy", "login")
      end

      Event.new(
        type: event_type,
        repo: repo_name,
        id: node["id"],
        title: node["title"] || node["name"],
        url: node["url"],
        time: parse_event_time(node, event_type),
        author: node.dig("author", "login"),
        extra: extra
      )
    end
  end
end
