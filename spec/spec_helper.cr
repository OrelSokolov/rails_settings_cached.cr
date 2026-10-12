require "spec"
require "../src/rails_settings_cached"

# --- модель (зеркало oracle/src/test/dummy/app/models/setting.rb) ---------

module RailsSettings
  module Fields
    # Кастомное поле (зеркало dummy-приложения: 'a'/'b'/'c' ↔ 1/2/3).
    # Внимание: `when ::String` — Fields::String затеняет глобальный тип!
    class Custom(T) < Base(T)
      def serialize(value : FieldValue) : FieldValue
        case value
        when ::String
          value
        when Int32, Int64
          case value
          when 1 then "a"
          when 2 then "b"
          when 3 then "c"
          else
            raise Exception.new("invalid value")
          end
        else
          raise Exception.new("invalid value")
        end
      end

      def deserialize(value : FieldValue) : FieldValue
        case value
        when ::String
          case value
          when "a" then 1_i64
          when "b" then 2_i64
          when "c" then 3_i64
          else          nil
          end
        when Int32 then value.to_i64
        when Int64 then value
        else            nil
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
    field :default_tags, type: :array, separator: /[\s,]+/, default: [] of String
    field :default_value_with_block, type: :integer, default: ->{ RailsSettings::F.v(1 + 1) }
  end

  scope :mailer do
    field :mailer_provider, default: "smtp", validates: {presence: true, inclusion: {in: %w[smtp sendmail sendgrid]}}
    field :smtp_settings, type: :hash, default: {
      "host"     => "foo.com",
      "username" => "foo@bar.com",
      "password" => "123456",
    }
  end

  scope :readonly do
    field :readonly_item, type: :integer, default: 100, readonly: true
    field :readonly_item_with_proc, type: :integer,
      default: ->{ RailsSettings::F.v((Setting.readonly_item.as?(Int64) || 100_i64) + 3) }, readonly: true
  end

  scope :omniauth do
    field :omniauth_google_options, default: {
      "client_id"     => "the-client-id",
      "client_secret" => "the-client-secret",
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

  scope :by_prefix do |key|
    where("var LIKE ?", "#{key}%")
  end

  scope :ordered do
    order(id: :desc)
  end

  field :key_with_more_options, type: :array, validates: {presence: true},
    default: %w[foo bar], foo: 1, section: :theme
  field :fallback_field, type: :foo_bar, default: "hello"
end

class NoTableSetting < RailsSettings::Base
  set_table_name "not-exist-settings"

  field :foo, type: :string, default: "Hello world"
end

# --- тестовая БД ------------------------------------------------------------

TEST_URL = ENV["RSC_TEST_URL"]? ||
           "postgres://root@/crails_rsc_test?host=/var/run/postgresql"

class CreateSettings < ActiveRecord::Migration
  def change
    create_table :settings, force: :cascade do |t|
      t.string :var, null: false
      t.text :value
      t.timestamps
      t.index :var, unique: true
    end
  end
end

def reset_db!
  ActiveRecord::Base.establish_connection(TEST_URL)
  CreateSettings.new.migrate(:down) rescue nil
  CreateSettings.new.migrate(:up)
end

def reset_state!
  Setting.destroy_all
  RailsSettings::RequestCache.reset
  RailsSettings.config.cache_storage.clear
end

def raw_value(var : String) : String?
  rec = Setting.unscoped.where(var: var).take
  rec ? rec.value : nil
end

def direct_update_record(var : String, value : String)
  record = Setting.unscoped.where(var: var).take || Setting.new(var: var)
  record.value = RailsSettings::Y.dump(value)
  record.save!
end

# --- ProtectedKey-модели (см. oracle-кейс "protected key var/value") ------
# таблица переиспользуется settings — до БД дело не доходит (ошибка раньше).

class NewSetting < RailsSettings::Base
  set_table_name "settings"

  field :var
end

class NewSetting2 < RailsSettings::Base
  set_table_name "settings"

  field :value
end

# --- DummyStore (зеркало test/dummy/lib/active_support/cache/dummy_store) --

class DummyStore < ActiveSupport::Cache::Store
  getter data : Hash(String, ActiveSupport::Cache::Entry)

  def initialize
    @data = {} of String => ActiveSupport::Cache::Entry
  end

  def lookup(name : String) : ActiveSupport::Cache::Entry?
    @data[name]?
  end

  def store(name : String, entry : ActiveSupport::Cache::Entry) : Nil
    @data[name] = entry
  end

  def remove(name : String) : Nil
    @data.delete(name)
  end

  def clear : Nil
    @data.clear
  end
end
