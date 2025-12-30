# frozen_string_literal: true

require_relative "octonotify/version"
require_relative "octonotify/config"

module Octonotify
  class Error < StandardError; end
  class ConfigError < Error; end
  class StateError < Error; end
  class APIError < Error; end
end
