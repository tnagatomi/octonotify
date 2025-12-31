# frozen_string_literal: true

require "yaml"
require "tzinfo"

module Octonotify
  class Config
    DEFAULT_CONFIG_PATH = ".octonotify/config.yml"
    DEFAULT_TIMEZONE = "UTC"
    VALID_EVENTS = %w[release pull_request_created pull_request_merged issue_created].freeze

    attr_reader :timezone, :from, :to, :repos

    def initialize(config_path: DEFAULT_CONFIG_PATH)
      @config_path = config_path
      load_config
      validate
    end

    def self.load(config_path: DEFAULT_CONFIG_PATH)
      new(config_path: config_path)
    end

    def timezone_info
      @timezone_info ||= TZInfo::Timezone.get(@timezone)
    end

    def repos_with_event(event)
      @repos.select { |_name, repo_config| repo_config[:events].include?(event) }.keys
    end

    private

    def load_config
      raise ConfigError, "Config file not found: #{@config_path}" unless File.exist?(@config_path)

      # Security: do not permit Symbols or aliases from YAML.
      # This config is intended to be plain scalars/arrays/hashes only.
      raw = YAML.safe_load(File.read(@config_path), permitted_classes: [], permitted_symbols: [], aliases: false)
      raise ConfigError, 'Config file is empty or invalid' if raw.nil?

      @timezone = (raw['timezone'] || DEFAULT_TIMEZONE).to_s.strip
      @from = (raw['from'] || '').to_s.strip
      @to = Array(raw['to']).compact.map(&:to_s).map(&:strip).reject(&:empty?)
      @repos = parse_repos(raw['repos'] || {})
    end

    def parse_repos(repos_hash)
      raise ConfigError, "'repos' must be a mapping (YAML hash)" unless repos_hash.is_a?(Hash)

      repos_hash.transform_keys(&:to_s).transform_values do |repo_config|
        raise ConfigError, 'Repo config must be a mapping (YAML hash)' unless repo_config.is_a?(Hash)

        events = Array(repo_config['events']).compact.map(&:to_s).map(&:strip).reject(&:empty?)
        { events: events }
      end
    end

    def validate
      validate_timezone
      validate_from
      validate_to
      validate_repos
    end

    def validate_timezone
      TZInfo::Timezone.get(@timezone)
    rescue TZInfo::InvalidTimezoneIdentifier
      raise ConfigError, "Invalid timezone: #{@timezone}"
    end

    def validate_from
      raise ConfigError, "'from' is required" if @from.nil? || @from.empty?

      validate_header_value!(@from, field: 'from')
    end

    def validate_to
      raise ConfigError, "'to' must have at least one recipient" if @to.empty?

      @to.each { |recipient| validate_header_value!(recipient, field: 'to') }
    end

    def validate_repos
      raise ConfigError, "'repos' must have at least one repository" if @repos.empty?

      @repos.each do |repo_name, repo_config|
        validate_repo_name(repo_name)
        validate_repo_events(repo_name, repo_config[:events])
      end
    end

    def validate_repo_name(repo_name)
      return if repo_name.match?(%r{\A[^/]+/[^/]+\z})

      raise ConfigError, "Invalid repo format '#{repo_name}': must be 'owner/repo'"
    end

    def validate_repo_events(repo_name, events)
      raise ConfigError, "Repo '#{repo_name}' must have at least one event" if events.empty?

      invalid_events = events - VALID_EVENTS
      return if invalid_events.empty?

      raise ConfigError, "Repo '#{repo_name}' has invalid events: #{invalid_events.join(', ')}. " \
                         "Valid events are: #{VALID_EVENTS.join(', ')}"
    end

    def validate_header_value!(value, field:)
      # Security: prevent email header injection via CR/LF.
      return unless value.include?("\r") || value.include?("\n")

      raise ConfigError, "'#{field}' must not contain newlines"
    end
  end
end
