# frozen_string_literal: true

# Oracle-кейсы rails-settings-cached 2.9.5 (vendored в ./src).
# Запуск: `ruby oracle/cases.rb` → oracle/expected.yml
# Crystal-порт (spec/oracle_spec.cr) обязан воспроизвести каждый кейс:
#   * result  — нормализованное значение (norm);
#   * value_column — точное байтовое содержимое колонки settings.value
#     (YAML, совместимость с Ruby Psych);
#   * error   — "Класс: сообщение".

require "active_record"
require "active_support"
require "active_support/cache/memory_store"
require "active_support/current_attributes"
require "yaml"
require "json"

# Минимальный фейк Rails — гему нужны только Rails.cache и Rails::Railtie.
module Rails
  class Railtie
    def self.initializer(*); end
  end

  def self.cache
    @cache ||= ActiveSupport::Cache::MemoryStore.new
  end

  def self.application; end
end

$LOAD_PATH.unshift File.expand_path("../src/lib", __dir__)
require "rails-settings-cached"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.define(version: 1) do
  create_table :settings do |t|
    t.string :var, null: false
    t.text :value
    t.timestamps
  end
  add_index :settings, :var, unique: true
end

module RailsSettings
  module Fields
    class Custom < ::RailsSettings::Fields::Base
      def serialize(value)
        case value
        when 'a', 1 then 'a'
        when 'b', 2 then 'b'
        when 'c', 3 then 'c'
        else raise StandardError, 'invalid value'
        end
      end

      def deserialize(value)
        case value
        when 'a', 1 then 1
        when 'b', 2 then 2
        when 'c', 3 then 3
        end
      end
    end
  end
end

class Setting < RailsSettings::Base
  cache_prefix { "v1" }

  scope :application do
    field :host, default: "http://example.com", validates: {presence: true}
    field :admin_emails, type: :array, default: %w[admin@rubyonrails.org]
    field :captcha_enable, type: :boolean, default: true
    field :user_limits, type: :integer, default: 1, validates: {presence: true, format: {with: /\d+/, message: "must be numbers"}}
  end

  scope :contents do
    field :tips, type: :array, separator: /\n+/
    field :default_tags, type: :array, separator: /[\s,]+/, default: []
    field :default_value_with_block, type: :integer, default: -> { 1 + 1 }
  end

  scope :mailer do
    field :mailer_provider, default: "smtp", validates: {presence: true, inclusion: {in: %w[smtp sendmail sendgrid]}}
    field :smtp_settings, type: :hash, default: {
      host: "foo.com",
      username: "foo@bar.com",
      password: "123456"
    }
  end

  scope :readonly do
    field :readonly_item, type: :integer, default: 100, readonly: true
    field :readonly_item_with_proc, type: :integer, default: -> { readonly_item + 3 }, readonly: true
  end

  scope :omniauth do
    field :omniauth_google_options, default: {
      client_id: "the-client-id",
      client_secret: "the-client-secret"
    }, type: :hash, readonly: true
  end

  scope :test_types do
    field :string_item, type: :string
    field :integer_item, type: :integer
    field :float_item, type: :float, default: 7
    field :big_decimal_item, type: :big_decimal, default: 9
    field :boolean_item, type: :boolean
    field :array_item, type: :array
    field :hash_item, type: :hash
    field :custom_item, type: :custom, default: 1
  end

  field :key_with_more_options, type: :array, validates: {presence: true}, default: %w[foo bar], foo: 1, section: :theme
  field :fallback_field, type: :foo_bar, default: "hello"
end

class NoTableSetting < RailsSettings::Base
  self.table_name = "not-exist-settings"

  field :foo, type: :string, default: "Hello world"
end

CASES = []

def norm(v)
  case v
  when nil then "nil"
  when true, false then "bool:#{v}"
  when Integer then "int:#{v}"
  when Float then "flt:#{v}"
  when BigDecimal then "dec:#{v.to_s('F')}"
  when String then "str:#{v.inspect}"
  # Символы нормализуются как строки: Crystal-порт читает YAML-символы
  # строками (runtime String→Symbol в Crystal нет).
  when Symbol then "str:#{v.to_s.inspect}"
  when Array then "arr[#{v.map { |x| norm(x) }.join(',')}]"
  when Hash then "hash{#{v.sort.map { |k, x| "#{norm(k)}=>#{norm(x)}" }.join(',')}}"
  else "obj:#{v.class.name}"
  end
end

def raw_value(var)
  rec = Setting.unscoped.where(var: var.to_s).take
  return ":absent" if rec.nil?
  rec[:value]
end

def reset_state!
  Setting.destroy_all
  RailsSettings::RequestCache.reset
  Rails.cache.clear
end

def case!(name, value_column: nil)
  reset_state!
  result = yield
  entry = {"name" => name, "result" => norm(result)}
  entry["value_column"] = raw_value(value_column) if value_column
  CASES << entry
rescue Exception => e # rubocop:disable Lint/RescueException
  CASES << {"name" => name, "error" => "#{e.class}: #{e.message}"}
end

def direct_update_record(var, value)
  record = Setting.unscoped.where(var: var.to_s).take || Setting.new(var: var.to_s)
  record[:value] = YAML.dump(value)
  record.save!(validate: false)
end

# --- метаданные ----------------------------------------------------------

case!("version") { RailsSettings.version }

case!("cache_key default") { Setting.cache_key }

case!("cache_prefix change") do
  Setting.cache_prefix { "v2" }
  key = Setting.cache_key
  Setting.cache_prefix { "v1" }
  key
end

case!("keys") { Setting.keys }
case!("editable_keys") { Setting.editable_keys }
case!("readonly_keys") { Setting.readonly_keys }
case!("get_field: host") { Setting.get_field("host") }
case!("get_field: omniauth") { Setting.get_field("omniauth_google_options") }
case!("get_field: missing") { Setting.get_field("foooo") }
case!("get_field: options") { Setting.get_field("key_with_more_options") }

# --- чтение дефолтов -----------------------------------------------------

case!("default: string") { Setting.host }
case!("default: array") { Setting.admin_emails }
case!("default: boolean true") { Setting.captcha_enable }
case!("default: integer") { Setting.user_limits }
case!("default: integer nil") { Setting.integer_item }
case!("default: float 7") { Setting.float_item }
case!("default: float nil") { Setting.boolean_item }
case!("default: array nil") { Setting.array_item }
case!("default: hash nil") { Setting.hash_item }
case!("default: big_decimal 9") { Setting.big_decimal_item }
case!("default: proc int") { Setting.default_value_with_block }
case!("default: proc readonly") { Setting.readonly_item_with_proc }
case!("default: readonly int") { Setting.readonly_item }
case!("default: hash") { Setting.smtp_settings }
case!("default: hash readonly") { Setting.omniauth_google_options }
case!("default: fallback unknown type") { Setting.fallback_field }
case!("default: array with options") { Setting.key_with_more_options }
case!("default: no record in db") { Setting.where(var: "host").take }

case!("instance delegation") do
  setting = Setting.new
  [setting.host, setting.readonly_item, setting.default_tags]
end

case!("_all_settings empty") { Setting.send(:_all_settings) }

# --- записи: integer -----------------------------------------------------

case!("integer = 12", value_column: :integer_item) do
  Setting.integer_item = 12
  Setting.integer_item
end

case!("integer = \"27\"", value_column: :integer_item) do
  Setting.integer_item = "27"
  Setting.integer_item
end

case!("integer = 2.7", value_column: :integer_item) do
  Setting.integer_item = 2.7
  Setting.integer_item
end

case!("integer = nil", value_column: :integer_item) do
  Setting.integer_item = nil
  Setting.integer_item
end

case!("integer default after nil") do
  Setting.user_limits = nil
  Setting.user_limits
end

case!("integer = 100", value_column: :user_limits) do
  Setting.user_limits = 100
  Setting.user_limits
end

# --- записи: string ------------------------------------------------------

case!("string set", value_column: :string_item) do
  Setting.string_item = "https://www.example.com"
  Setting.string_item
end

case!("string yaml-ambiguous: true", value_column: :string_item) do
  Setting.string_item = "true"
  Setting.string_item
end

case!("string yaml-ambiguous: 42", value_column: :string_item) do
  Setting.string_item = "42"
  Setting.string_item
end

case!("string yaml-ambiguous: 3.14", value_column: :string_item) do
  Setting.string_item = "3.14"
  Setting.string_item
end

case!("string yaml-ambiguous: null", value_column: :string_item) do
  Setting.string_item = "null"
  Setting.string_item
end

case!("string yaml-ambiguous: ~", value_column: :string_item) do
  Setting.string_item = "~"
  Setting.string_item
end

case!("string yaml-ambiguous: yes", value_column: :string_item) do
  Setting.string_item = "yes"
  Setting.string_item
end

case!("string empty", value_column: :string_item) do
  Setting.string_item = ""
  Setting.string_item
end

case!("string leading space", value_column: :string_item) do
  Setting.string_item = " hello"
  Setting.string_item
end

case!("string with colon+space", value_column: :string_item) do
  Setting.string_item = "a: b"
  Setting.string_item
end

case!("string with hash sign", value_column: :string_item) do
  Setting.string_item = "a #b"
  Setting.string_item
end

# --- записи: float -------------------------------------------------------

case!("float = 9", value_column: :float_item) do
  Setting.float_item = 9
  Setting.float_item
end

case!("float = 2.9", value_column: :float_item) do
  Setting.float_item = 2.9
  Setting.float_item
end

case!("float = \"2.9\"", value_column: :float_item) do
  Setting.float_item = "2.9"
  Setting.float_item
end

case!("float = nil then default", value_column: :float_item) do
  Setting.float_item = nil
  Setting.float_item
end

# --- записи: big decimal -------------------------------------------------

case!("big_decimal = 7", value_column: :big_decimal_item) do
  Setting.big_decimal_item = 7
  Setting.big_decimal_item
end

case!("big_decimal = 2.9", value_column: :big_decimal_item) do
  Setting.big_decimal_item = 2.9
  Setting.big_decimal_item
end

case!("big_decimal = \"2.9\"", value_column: :big_decimal_item) do
  Setting.big_decimal_item = "2.9"
  Setting.big_decimal_item
end

case!("big_decimal = nil then default", value_column: :big_decimal_item) do
  Setting.big_decimal_item = nil
  Setting.big_decimal_item
end

# --- записи: boolean -----------------------------------------------------

case!("boolean = \"0\"", value_column: :boolean_item) do
  Setting.boolean_item = "0"
  [Setting.boolean_item, Setting.boolean_item?]
end

case!("boolean = \"1\"", value_column: :boolean_item) do
  Setting.boolean_item = "1"
  [Setting.boolean_item, Setting.boolean_item?]
end

case!("boolean = \"false\"", value_column: :boolean_item) do
  Setting.boolean_item = "false"
  Setting.boolean_item
end

case!("boolean = \"true\"", value_column: :boolean_item) do
  Setting.boolean_item = "true"
  Setting.boolean_item
end

case!("boolean = 0", value_column: :boolean_item) do
  Setting.boolean_item = 0
  Setting.boolean_item
end

case!("boolean = 1", value_column: :boolean_item) do
  Setting.boolean_item = 1
  Setting.boolean_item
end

case!("boolean = \"yes\"", value_column: :boolean_item) do
  Setting.boolean_item = "yes"
  Setting.boolean_item
end

# --- записи: array -------------------------------------------------------

emails = %w[admin@rubyonrails.org huacnlee@gmail.com]

case!("array = list", value_column: :array_item) do
  Setting.array_item = emails
  Setting.array_item
end

case!("array = join newline", value_column: :array_item) do
  Setting.array_item = emails.join("\n")
  Setting.array_item
end

case!("array = join comma", value_column: :array_item) do
  Setting.array_item = emails.join(",")
  Setting.array_item
end

case!("array = join semicolon", value_column: :array_item) do
  Setting.array_item = emails.join(";")
  Setting.array_item
end

case!("array = join ' , '", value_column: :array_item) do
  Setting.array_item = emails.join(" , ")
  Setting.array_item
end

case!("array = empty string", value_column: :array_item) do
  Setting.array_item = ""
  Setting.array_item
end

case!("array = nil", value_column: :array_item) do
  Setting.array_item = nil
  Setting.array_item
end

# --- записи: hash --------------------------------------------------------

case!("hash = string keys", value_column: :hash_item) do
  Setting.hash_item = {"foo" => "bar"}
  Setting.hash_item
end

case!("hash = symbol keys", value_column: :hash_item) do
  Setting.hash_item = {foo: "bar"}
  Setting.hash_item
end

case!("hash = nested", value_column: :hash_item) do
  Setting.hash_item = {"a" => {"b" => "c"}}
  Setting.hash_item
end

case!("hash = array value", value_column: :hash_item) do
  Setting.hash_item = {"a" => ["x", "y"]}
  Setting.hash_item
end

case!("hash = empty", value_column: :hash_item) do
  Setting.hash_item = {}
  Setting.hash_item
end

case!("hash = mixed types", value_column: :smtp_settings) do
  Setting.smtp_settings = {"title" => "456", "age" => 32, "name" => "Jason Lee"}
  Setting.smtp_settings
end

case!("hash = symbol value", value_column: :smtp_settings) do
  Setting.smtp_settings = {"sym" => :symbol, "str" => "string", "num" => 27.72}
  Setting.smtp_settings
end

case!("hash = nil", value_column: :hash_item) do
  Setting.hash_item = nil
  Setting.hash_item
end

case!("hash from json string in db") do
  Setting.find_by(var: :smtp_settings) || Setting.new(var: :smtp_settings).tap(&:save)
  Setting.find_by(var: :smtp_settings).update(value: {"sym" => "symbol", "num" => 27.72}.to_json)
  Setting.smtp_settings
end

# --- записи: custom field ------------------------------------------------

case!("custom = 2", value_column: :custom_item) do
  Setting.custom_item = 2
  Setting.custom_item
end

case!("custom = 3", value_column: :custom_item) do
  Setting.custom_item = 3
  Setting.custom_item
end

case!("custom = 4 raises") do
  Setting.custom_item = 4
  Setting.custom_item
end

# --- строки-в-БД совместимость ------------------------------------------

case!("db string → array") do
  direct_update_record(:admin_emails, "foo@gmail.com,bar@dar.com\naaa@bbb.com")
  Setting.admin_emails
end

case!("db string → integer") do
  direct_update_record(:user_limits, "100")
  Setting.user_limits
end

case!("db string → boolean false") do
  direct_update_record(:captcha_enable, "0")
  Setting.captcha_enable
end

case!("db string → boolean true") do
  direct_update_record(:captcha_enable, "true")
  Setting.captcha_enable
end

case!("db yaml string → integer") do
  direct_update_record(:user_limits, "--- 42\n")
  Setting.user_limits
end

case!("db string separators: tips") do
  direct_update_record(:tips, "Hello this is first line, and have comma.\nThis is second line.\n")
  Setting.tips
end

case!("db string separators: default_tags") do
  direct_update_record(:default_tags, "Ruby Rails,GitHub")
  Setting.default_tags
end

# --- _all_settings после записи ------------------------------------------

case!("_all_settings after save") do
  Setting.host = "https://example.com"
  Setting.send(:_all_settings)
end

# --- кэш ------------------------------------------------------------------

case!("cache storage default is Rails.cache") do
  RailsSettings.config.cache_storage.equal?(Rails.cache)
end

class DummyStore < ActiveSupport::Cache::Store
  attr_reader :data

  def initialize
    super
    @data = {}
  end

  def fetch(name, options = nil, &block)
    @data.fetch(name) { @data[name] = yield }
    @data[name]
  end

  def delete(name, options = nil)
    @data.delete(name)
  end
end

case!("custom cache storage used") do
  store = DummyStore.new
  RailsSettings.config.cache_storage = store
  Setting.user_limits = 42
  Setting.user_limits # чтение → fetch → попадает в кастомный стор
  keys = store.data.keys.select { |k| k.start_with?("rails-settings-cached") }
  RailsSettings.config.cache_storage = Rails.cache
  keys
end

case!("clear_cache deletes cache entry") do
  store = DummyStore.new
  RailsSettings.config.cache_storage = store
  Setting.user_limits = 42
  Setting.user_limits # populate
  Setting.clear_cache
  keys = store.data.keys
  RailsSettings.config.cache_storage = Rails.cache
  keys
end

case!("after_commit clears cache") do
  store = DummyStore.new
  RailsSettings.config.cache_storage = store
  Setting.user_limits = 42
  Setting.user_limits # populate
  Setting.user_limits = 43 # save! → after_commit → clear_cache
  keys = store.data.keys
  RailsSettings.config.cache_storage = Rails.cache
  keys
end

case!("request cache disabled by default") { RailsSettings::RequestCache.all_settings }

case!("request cache enable/disable") do
  RailsSettings::RequestCache.enable!
  enabled = RailsSettings::RequestCache.enabled?
  Setting.host = "cached.example.com"
  cached = RailsSettings::RequestCache.all_settings
  RailsSettings::RequestCache.disable!
  disabled = RailsSettings::RequestCache.enabled?
  after = RailsSettings::RequestCache.all_settings
  [enabled, !!cached, disabled, after]
end

# --- readonly / protected ------------------------------------------------

case!("readonly setter raises") { Setting.readonly_item = 1 }
case!("readonly hash setter raises") { Setting.omniauth_google_options = {foo: 1} }
case!("not exist field raises") { Setting.not_exist_method }

case!("protected key var") do
  class NewSetting < RailsSettings::Base
    field :var
  end
end

case!("protected key value") do
  class NewSetting2 < RailsSettings::Base
    field :value
  end
end

# --- таблицы нет / соединения нет ----------------------------------------

case!("no table fallback to default") { NoTableSetting.foo }
case!("no table defined_keys") { NoTableSetting.keys }

# --- валидации ------------------------------------------------------------

case!("validation host blank") do
  setting = Setting.new(var: "host")
  [setting.valid?, setting.errors.full_messages]
end

case!("validation host ok") do
  setting = Setting.new(var: "host")
  setting.value = "https://ruby-china.org"
  [setting.valid?, setting.errors.full_messages]
end

case!("validation user_limits blank") do
  setting = Setting.new(var: "user_limits")
  [setting.valid?, setting.errors.full_messages]
end

case!("validation user_limits format") do
  setting = Setting.new(var: "user_limits")
  setting.value = "hello"
  [setting.valid?, setting.errors.full_messages]
end

case!("validation user_limits ok") do
  setting = Setting.new(var: "user_limits")
  setting.value = "100"
  [setting.valid?, setting.errors.full_messages]
end

case!("validation mailer_provider blank") do
  setting = Setting.new(var: "mailer_provider")
  [setting.valid?, setting.errors.full_messages]
end

case!("validation assignment host raises") do
  Setting.host = ""
end

case!("validation assignment host ok") do
  Setting.host = "foo"
end

case!("validation assignment mailer raises") do
  Setting.mailer_provider = "foo"
end

File.write(File.expand_path("expected.yml", __dir__), YAML.dump(CASES))
puts "OK: #{CASES.size} cases → expected.yml"
