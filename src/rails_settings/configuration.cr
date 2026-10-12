# RailsSettings.config / configure — 1:1 к rails-settings/configuration.rb.
# Отличие: нет глобального Rails.cache — по умолчанию MemoryStore
# (Rails-приложение подменит на свой кэш через configure).

module RailsSettings
  class Configuration
    property cache_storage : ActiveSupport::Cache::Store

    def initialize
      @cache_storage = ActiveSupport::Cache::MemoryStore.new
    end
  end

  @@config : Configuration?

  def self.config : Configuration
    @@config ||= Configuration.new
  end

  def self.configure(&) : Nil
    yield config
  end
end
