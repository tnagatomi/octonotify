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
      state_changes = empty_state_changes

      @config.repos.each do |repo_name, repo_config|
        owner, repo = repo_name.split("/")

        repo_config[:events].each do |event_type|
          result = poll_event(owner: owner, repo: repo, event_type: event_type)
          events.concat(result[:events])
          rate_limit = result[:rate_limit]
          merge_state_changes!(state_changes, result[:state_changes])

          if rate_limit && rate_limit["remaining"] < RATE_LIMIT_THRESHOLD
            return { events: events, rate_limit: rate_limit, incomplete: true, state_changes: state_changes }
          end
        end
      end

      { events: events, rate_limit: rate_limit, incomplete: false, state_changes: state_changes }
    end

    private

    def poll_event(owner:, repo:, event_type:)
      repo_name = "#{owner}/#{repo}"
      event_state = peek_event_state(repo_name, event_type)
      cursor = event_state["resume_cursor"]

      threshold = calculate_threshold(event_state["watermark_time"])
      events = []
      new_watermark = nil
      rate_limit = nil
      state_changes = empty_state_changes
      seen_ids = {}

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
          next if notified?(repo_name, event_type, event.id)
          next unless @state.should_notify?(event_time)
          next if seen_ids[event.id]

          events << event
          seen_ids[event.id] = true
          state_changes[:notified_ids] << { repo: repo_name, event_type: event_type, id: event.id }
        end

        oldest_time = parse_event_time(nodes.last, event_type)
        break if oldest_time && oldest_time < threshold
        break unless page_info["hasNextPage"]

        if rate_limit && rate_limit["remaining"] < RATE_LIMIT_THRESHOLD
          state_changes[:resume_cursors] << {
            repo: repo_name,
            event_type: event_type,
            cursor: page_info["endCursor"],
            reason: "rate limit"
          }
          return { events: events, rate_limit: rate_limit, state_changes: state_changes }
        end

        cursor = page_info["endCursor"]
      end

      if new_watermark
        state_changes[:watermarks] << {
          repo: repo_name,
          event_type: event_type,
          watermark_time: new_watermark.iso8601
        }
      end

      { events: events, rate_limit: rate_limit, state_changes: state_changes }
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

    def empty_state_changes
      { notified_ids: [], watermarks: [], resume_cursors: [] }
    end

    def merge_state_changes!(into, other)
      return if other.nil?

      into[:notified_ids].concat(other[:notified_ids] || [])
      into[:watermarks].concat(other[:watermarks] || [])
      into[:resume_cursors].concat(other[:resume_cursors] || [])
    end

    def peek_event_state(repo_name, event_type)
      existing = @state.repos.dig(repo_name, "events", event_type)
      return existing if existing

      {
        "watermark_time" => @state.notify_after,
        "resume_cursor" => nil,
        "recent_notified_ids" => [],
        "incomplete" => false,
        "reason" => nil
      }
    end

    def notified?(repo_name, event_type, id)
      ids = @state.repos.dig(repo_name, "events", event_type, "recent_notified_ids") || []
      ids.include?(id)
    end
  end
end
