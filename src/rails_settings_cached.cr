# rails-settings-cached 2.9.5 (huacnlee) → Crystal, 1:1 API.
#
# Оригинал: oracle/src (vendored), поведение снято в oracle/expected.yml.
# Хранение: ActiveRecord (active_record_cr), таблица `settings` (var, value),
# value — YAML байт-в-байт как у Ruby Psych.
# Кэш: ActiveSupport::Cache (active_support_cr), по умолчанию MemoryStore.

require "active_record_cr"
require "active_support_cr"

require "./rails_settings/values"
require "./rails_settings/configuration"
require "./rails_settings/request_cache"
require "./rails_settings/fields"
require "./rails_settings/base"

module RailsSettings
  class ProtectedKeyError < Exception
    def initialize(key : String)
      super("Can't use #{key} as setting key.")
    end
  end

  def self.version : String
    "2.9.5"
  end
end
