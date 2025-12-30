# frozen_string_literal: true

require 'English'

module Octonotify
  class Runner
    def initialize(
      config: nil,
      state: nil,
      client: nil,
      poller: nil,
      mailer: nil,
      github_token: nil,
      config_path: Config::DEFAULT_CONFIG_PATH,
      state_path: State::DEFAULT_STATE_PATH,
      logger: nil,
      persist_state: true
    )
      @config = config
      @state = state
      @client = client
      @poller = poller
      @mailer = mailer
      @github_token = github_token
      @config_path = config_path
      @state_path = state_path
      @logger = logger || default_logger
      @persist_state = persist_state
    end

    def run
      @logger.info('Starting Octonotify run')

      config = @config ||= Config.load(config_path: @config_path)
      state = @state ||= State.load(state_path: @state_path)

      state.start_run
      result = nil

      begin
        client = @client ||= build_client
        poller = @poller ||= Poller.new(config: config, state: state, client: client)
        mailer = @mailer ||= Mailer.new(config: config)

        result = execute_poll(poller, mailer)
        state.finish_run(status: result[:status], rate_limit: result[:rate_limit])
      rescue StandardError => e
        state.finish_run(status: 'error', rate_limit: nil)
        @logger.error("Run failed: #{e.message}")
        raise
      ensure
        save_state_safely(state, $ERROR_INFO)
      end

      log_result(result)
      result
    end

    private

    def save_state_safely(state, original_error)
      return unless @persist_state

      state.save
    rescue StandardError => e
      @logger.error("Failed to save state: #{e.message}")
      raise unless original_error
    end

    def build_client
      token = @github_token || ENV.fetch('GITHUB_TOKEN', nil)
      GraphQLClient.new(token: token)
    end

    def execute_poll(poller, mailer)
      poll_result = poller.poll

      if poll_result[:events].any?
        @logger.info("Found #{poll_result[:events].size} new event(s)")
        mailer.send_digest(poll_result[:events])
        @logger.info('Sent notification email(s)')
      else
        @logger.info('No new events found')
      end

      {
        status: poll_result[:incomplete] ? 'incomplete' : 'success',
        rate_limit: poll_result[:rate_limit],
        events_count: poll_result[:events].size,
        incomplete: poll_result[:incomplete]
      }
    rescue Mailer::DeliveryError => e
      @logger.warn("Email delivery partially failed: #{e.message}")
      {
        status: 'partial_failure',
        rate_limit: poll_result[:rate_limit],
        events_count: poll_result[:events].size,
        incomplete: poll_result[:incomplete],
        delivery_error: e
      }
    end

    def log_result(result)
      case result[:status]
      when 'success'
        @logger.info("Run completed successfully. Events: #{result[:events_count]}")
      when 'incomplete'
        @logger.warn('Run completed but incomplete due to rate limiting')
      when 'partial_failure'
        @logger.warn('Run completed with partial email delivery failure')
      end

      return unless result[:rate_limit]

      @logger.info("Rate limit remaining: #{result[:rate_limit]['remaining']}")
    end

    def default_logger
      require 'logger'
      logger = Logger.new($stdout)
      logger.level = Logger::INFO
      logger.formatter = proc do |severity, _datetime, _progname, msg|
        "[#{severity}] #{msg}\n"
      end
      logger
    end
  end
end
