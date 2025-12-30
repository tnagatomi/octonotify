# frozen_string_literal: true

module Octonotify
  class Error < StandardError; end
  class ConfigError < Error; end
  class StateError < Error; end
  class APIError < Error; end
end

require_relative "octonotify/version"
require_relative "octonotify/config"
require_relative "octonotify/state"
require_relative "octonotify/graphql_client"
require_relative "octonotify/poller"
require_relative "octonotify/mailer"
