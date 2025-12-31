# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Octonotify
  class State
    DEFAULT_STATE_PATH = ".octonotify/state.json"
    RECENT_IDS_LIMIT = 100

    attr_reader :initialized_at, :notify_after, :last_run, :repos

    def initialize(state_path: DEFAULT_STATE_PATH)
      @state_path = state_path
      @repos = {}
      @last_run = {}
      load_or_initialize
    end

    def self.load(state_path: DEFAULT_STATE_PATH)
      new(state_path: state_path)
    end

    def save
      ensure_state_dir_exists
      ensure_state_path_is_safe!

      data = {
        "initialized_at" => @initialized_at,
        "notify_after" => @notify_after,
        "last_run" => @last_run,
        "repos" => @repos
      }

      json = JSON.pretty_generate(data)
      atomic_write(@state_path, json)
    end

    def start_run
      @last_run = {
        'started_at' => Time.now.utc.iso8601,
        'finished_at' => nil,
        'status' => 'running',
        'rate_limit' => nil
      }
    end

    def finish_run(status:, rate_limit: nil)
      @last_run['finished_at'] = Time.now.utc.iso8601
      @last_run['status'] = status
      @last_run['rate_limit'] = rate_limit
    end

    def repo_state(repo_name)
      @repos[repo_name] ||= new_repo_state(repo_name)
    end

    def event_state(repo_name, event_type)
      repo = repo_state(repo_name)
      repo["events"][event_type] ||= new_event_state
    end

    def update_watermark(repo_name, event_type, time)
      state = event_state(repo_name, event_type)
      state["watermark_time"] = time
      state["last_success_at"] = Time.now.utc.iso8601
      state["resume_cursor"] = nil
      state["incomplete"] = false
      state["reason"] = nil
    end

    def set_resume_cursor(repo_name, event_type, cursor, reason: nil)
      state = event_state(repo_name, event_type)
      state["resume_cursor"] = cursor
      state["incomplete"] = true
      state["reason"] = reason
    end

    def add_notified_id(repo_name, event_type, id)
      state = event_state(repo_name, event_type)
      ids = state["recent_notified_ids"]
      ids << id
      ids.shift while ids.size > RECENT_IDS_LIMIT
    end

    def notified?(repo_name, event_type, id)
      state = event_state(repo_name, event_type)
      state["recent_notified_ids"].include?(id)
    end

    def should_notify?(event_time)
      return false if event_time.nil?

      event_t = event_time.is_a?(Time) ? event_time : Time.parse(event_time)
      notify_after_t = Time.parse(@notify_after)
      event_t > notify_after_t
    end

    private

    def load_or_initialize
      if File.exist?(@state_path)
        ensure_state_path_is_safe!
        load_state
      else
        initialize_state
      end
    end

    def load_state
      data = JSON.parse(File.read(@state_path))
      @initialized_at = data['initialized_at']
      @notify_after = data['notify_after']
      @last_run = data['last_run'] || {}
      @repos = data['repos'] || {}
    rescue JSON::ParserError => e
      raise StateError, "Invalid state file: #{e.message}"
    end

    def initialize_state
      now = Time.now.utc.iso8601
      @initialized_at = now
      @notify_after = now
      @last_run = {}
      @repos = {}
    end

    def new_repo_state(repo_name)
      {
        "url" => "https://github.com/#{repo_name}",
        "events" => {}
      }
    end

    def new_event_state
      {
        "watermark_time" => @notify_after,
        "resume_cursor" => nil,
        "recent_notified_ids" => [],
        "last_success_at" => nil,
        "incomplete" => false,
        "reason" => nil
      }
    end

    def ensure_state_dir_exists
      dir = File.dirname(@state_path)
      FileUtils.mkdir_p(dir) unless dir.nil? || dir == '.'
    end

    def ensure_state_path_is_safe!
      return unless File.exist?(@state_path)

      # Security: refuse to read/write through symlinks (prevents unexpected writes outside repo).
      return unless File.lstat(@state_path).symlink?

      raise StateError, "State path must not be a symlink: #{@state_path}"
    end

    def atomic_write(path, content)
      dir = File.dirname(path)
      base = File.basename(path)
      tmp_path = File.join(dir, ".#{base}.tmp.#{Process.pid}")

      begin
        File.write(tmp_path, content)
        File.rename(tmp_path, path)
      ensure
        File.delete(tmp_path) if File.exist?(tmp_path)
      end
    end
  end
end
