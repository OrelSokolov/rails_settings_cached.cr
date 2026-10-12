# Порт test/base_test.rb из rails-settings-cached 2.9.5.
# Адаптации под статическую типизацию:
#   * Integer в Crystal — Int64 (12 → 12_i64);
#   * `record.value` — сырая YAML-строка (AR-кодеген), декод — decoded_value;
#   * NoMethodError-кейсы (readonly-сеттер, несуществующее поле) — ошибки
#     компиляции; проверяются через responds_to?;
#   * scope с extension-блоком (`scope :by_prefix, ->(k) {...} do def foo`)
#     не поддерживается — проверка `by_prefix(...).foo` опущена.

require "./spec_helper"

def find_value(var_name : String)
  Setting.where(var: var_name).take
end

def direct_update_record(var : String, value)
  record = find_value(var) || Setting.new(var: var)
  record.value = RailsSettings::Y.dump(RailsSettings::F.d(value))
  record.save!
end

def assert_no_record(var : String)
  find_value(var).should be_nil
end

def assert_record_value(var : String, val : RailsSettings::FieldValue, dumped : String)
  record = find_value(var).should_not be_nil
  record = find_value(var).not_nil!
  record.value.should eq(dumped)
  record.decoded_value.should eq(val)
end

describe "BaseTest (порт base_test.rb)" do
  before_all { reset_db! }
  Spec.before_each { reset_state! }

  describe "define setting with protected keys" do
    it "raises ProtectedKeyError for var" do
      expect_raises(RailsSettings::ProtectedKeyError, "Can't use var as setting key.") do
        NewSetting.__rs_fields
      end
    end

    it "raises ProtectedKeyError for value" do
      expect_raises(RailsSettings::ProtectedKeyError, "Can't use value as setting key.") do
        NewSetting2.__rs_fields
      end
    end
  end

  it "cache_prefix and cache_key" do
    Setting.cache_key.should eq("rails-settings-cached/v1")
    Setting.__rs_override_cache_prefix = "v2"
    Setting.cache_key.should eq("rails-settings-cached/v2")
    Setting.__rs_override_cache_prefix = nil
  end

  it "_all_settings" do
    Setting._all_settings.should eq({} of String => RailsSettings::FieldValue)
  end

  it "setting_keys" do
    Setting.keys.size.should eq(22)
    Setting.keys.should contain("host")
    Setting.keys.should contain("readonly_item")
    Setting.keys.should contain("default_tags")
    Setting.keys.should contain("omniauth_google_options")

    Setting.editable_keys.size.should eq(19)
    Setting.editable_keys.should contain("host")
    Setting.editable_keys.should contain("default_tags")

    Setting.readonly_keys.size.should eq(3)
    Setting.readonly_keys.should contain("readonly_item")
    Setting.readonly_keys.should contain("readonly_item_with_proc")
    Setting.readonly_keys.should contain("omniauth_google_options")
  end

  it "get_field" do
    # Ruby для отсутствующего ключа возвращает {} — порт возвращает nil
    Setting.get_field("foooo").should be_nil
    host = Setting.get_field("host").not_nil!
    host.key.should eq("host")
    host.default.should eq("http://example.com")
    host.type.should eq(:string)
    host.readonly?.should be_false
    host.options.should eq({} of String => RailsSettings::FieldValue)
    host.scope.should eq(:application)

    omniauth = Setting.get_field("omniauth_google_options").not_nil!
    omniauth.key.should eq("omniauth_google_options")
    omniauth.default.should eq({"client_id" => "the-client-id", "client_secret" => "the-client-secret"})
    omniauth.type.should eq(:hash)
    omniauth.readonly?.should be_true
    omniauth.scope.should eq(:omniauth)
  end

  it "defined_fields and scope" do
    scopes = Setting.defined_fields.reject(&.readonly?)
      .group_by { |f| f.scope || :none }
    scopes.keys.sort_by(&.to_s).should eq(%i[application contents mailer none test_types])
    scopes[:application].size.should eq(4)
    scopes[:contents].size.should eq(3)
    scopes[:mailer].size.should eq(2)
  end

  it "not exist field — ошибка компиляции (метод не сгенерирован)" do
    Setting.responds_to?(:not_exist_method).should be_false
  end

  it "readonly field" do
    Setting.readonly_item.should eq(100_i64)
    # readonly_item = 1 — не компилируется; сеттер не генерируется
    Setting.responds_to?(:"readonly_item=").should be_false
    Setting.readonly_item_with_proc.should eq(103_i64)
    omniauth = Setting.omniauth_google_options.as(Hash(String, RailsSettings::FieldValue))
    omniauth["client_id"].should eq("the-client-id")
    omniauth["client_secret"].should eq("the-client-secret")
    Setting.responds_to?(:"omniauth_google_options=").should be_false
  end

  it "instance method get field" do
    setting = Setting.new
    setting.host.should eq(Setting.host)
    setting.default_tags.should eq(Setting.default_tags)
    setting.readonly_item.should eq(Setting.readonly_item)
    setting.readonly_item_with_proc.should eq(103_i64)
  end

  it "value serialize" do
    Setting.user_limits.should eq(1_i64)
    Setting.user_limits = 12
    Setting.user_limits.should eq(12_i64)
    assert_record_value("user_limits", 12_i64, "--- 12\n")
  end

  it "string field" do
    Setting.host.should eq("http://example.com")
    Setting.host = "https://www.example.com"
    Setting.host.should eq("https://www.example.com")
    Setting.host = "https://www.rubyonrails.org"
    Setting.host.should eq("https://www.rubyonrails.org")
  end

  it "integer field" do
    Setting.integer_item.should be_nil

    Setting.integer_item = 12
    Setting.integer_item.should eq(12_i64)
    Setting.integer_item.should be_a(Int64)
    assert_record_value("integer_item", 12_i64, "--- 12\n")

    Setting.integer_item = "27"
    Setting.integer_item.should eq(27_i64)
    assert_record_value("integer_item", 27_i64, "--- 27\n")

    Setting.integer_item = 2.7
    Setting.integer_item.should eq(2_i64)
    assert_record_value("integer_item", 2_i64, "--- 2\n")

    Setting.integer_item = nil
    Setting.integer_item.should be_nil
    assert_record_value("integer_item", nil, "---\n")

    Setting.default_value_with_block.should eq(2_i64)
    Setting.default_value_with_block = 100
    Setting.default_value_with_block.should eq(100_i64)
  end

  it "float field" do
    Setting.float_item.should eq(7.0)
    Setting.float_item.should be_a(Float64)
    assert_no_record("float_item")

    Setting.float_item = 9
    Setting.float_item.should eq(9.0)
    assert_record_value("float_item", 9.0, "--- 9.0\n")

    Setting.float_item = 2.9
    Setting.float_item.should eq(2.9)
    assert_record_value("float_item", 2.9, "--- 2.9\n")

    Setting.float_item = "2.9"
    Setting.float_item.should eq(2.9)
    assert_record_value("float_item", 2.9, "--- 2.9\n")

    Setting.float_item = nil
    assert_record_value("float_item", nil, "---\n")
    Setting.float_item.should eq(7.0)
  end

  it "big decimal field" do
    Setting.big_decimal_item.should eq(BigDecimal.new("9"))
    Setting.big_decimal_item.should be_a(BigDecimal)
    assert_no_record("big_decimal_item")

    Setting.big_decimal_item = 7
    Setting.big_decimal_item.should eq(BigDecimal.new("7"))
    assert_record_value("big_decimal_item", BigDecimal.new("7"),
      "--- !ruby/object:BigDecimal 9:0.7e1\n")

    Setting.big_decimal_item = 2.9
    Setting.big_decimal_item.should eq(BigDecimal.new("2.9"))
    assert_record_value("big_decimal_item", BigDecimal.new("2.9"),
      "--- !ruby/object:BigDecimal 18:0.29e1\n")

    Setting.big_decimal_item = "2.9"
    Setting.big_decimal_item.should eq(BigDecimal.new("2.9"))
    assert_record_value("big_decimal_item", BigDecimal.new("2.9"),
      "--- !ruby/object:BigDecimal 18:0.29e1\n")

    Setting.big_decimal_item = nil
    assert_record_value("big_decimal_item", nil, "---\n")
    Setting.big_decimal_item.should eq(BigDecimal.new("9"))
  end

  it "array field" do
    Setting.array_item.should be_nil
    assert_no_record("array_item")

    new_emails = ["admin@rubyonrails.org", "huacnlee@gmail.com"]
    Setting.array_item = new_emails
    Setting.array_item.should eq(new_emails)
    assert_record_value("array_item", new_emails, "---\n- admin@rubyonrails.org\n- huacnlee@gmail.com\n")

    Setting.array_item = new_emails.join("\n")
    Setting.array_item.should eq(new_emails)
    Setting.array_item = new_emails.join(",")
    Setting.array_item.should eq(new_emails)
    Setting.array_item = new_emails.join(";")
    Setting.array_item.should eq(new_emails)
    Setting.array_item = new_emails.join(" , ")
    Setting.array_item.should eq(new_emails)

    Setting.array_item = nil
    Setting.array_item.should be_nil
    assert_record_value("array_item", nil, "---\n")
  end

  it "hash field" do
    Setting.hash_item.should be_nil

    Setting.hash_item = {"foo" => "bar"}
    Setting.hash_item.should eq({"foo" => "bar"})
    assert_record_value("hash_item", {"foo" => "bar"}, "---\nfoo: bar\n")

    Setting.hash_item = {:foo => "bar"}
    Setting.hash_item.should eq({"foo" => "bar"})

    Setting.hash_item = nil
    Setting.hash_item.should be_nil
    assert_record_value("hash_item", nil, "---\n")
  end

  it "hash field integration" do
    Setting.smtp_settings.should eq({"host" => "foo.com", "username" => "foo@bar.com", "password" => "123456"})
    assert_no_record("smtp_settings")

    Setting.smtp_settings = {"title" => "123", "name" => "456"}
    Setting.smtp_settings.should eq({"title" => "123", "name" => "456"})

    new_value = {"title" => "456", "age" => 32, "name" => "Jason Lee"}
    Setting.smtp_settings = new_value
    Setting.smtp_settings.should eq({"title" => "456", "age" => 32_i64, "name" => "Jason Lee"})
    smtp = Setting.smtp_settings.as(Hash(String, RailsSettings::FieldValue))
    smtp["title"].should eq("456")
    smtp["age"].should eq(32_i64)

    # JSON-строка в value-колонке (адаптация: символы → строки)
    Setting.find_by(var: "smtp_settings").not_nil!
      .update({"value" => %({"sym": "symbol", "str": "string", "num": 27.72})})
    Setting.smtp_settings.should eq({"sym" => "symbol", "str" => "string", "num" => 27.72})
    Setting.smtp_settings.as(Hash(String, RailsSettings::FieldValue))["sym"].should eq("symbol")
  end

  it "boolean field" do
    Setting.captcha_enable.should be_true
    assert_no_record("captcha_enable")
    Setting.captcha_enable = "0"
    Setting.captcha_enable.should be_false
    Setting.captcha_enable?.should be_false
    Setting.captcha_enable = "1"
    Setting.captcha_enable.should be_true
    Setting.captcha_enable?.should be_true
    Setting.captcha_enable = "false"
    Setting.captcha_enable.should be_false
    Setting.captcha_enable = "true"
    Setting.captcha_enable.should be_true
    Setting.captcha_enable = 0
    Setting.captcha_enable.should be_false
    Setting.captcha_enable = 1
    Setting.captcha_enable.should be_true
    Setting.captcha_enable = false
    Setting.captcha_enable.should be_false
    Setting.captcha_enable = true
    Setting.captcha_enable.should be_true
  end

  it "custom field" do
    Setting.custom_item.should eq(1_i64)
    Setting.custom_item.should be_a(Int64)
    assert_no_record("custom_item")

    Setting.custom_item = 2
    Setting.custom_item.should eq(2_i64)
    assert_record_value("custom_item", "b", "--- b\n")

    Setting.custom_item = 3
    Setting.custom_item.should eq(3_i64)
    assert_record_value("custom_item", "c", "--- c\n")

    expect_raises(Exception, "invalid value") { Setting.custom_item = 4 }
  end

  it "string value in db compatible" do
    # array
    direct_update_record("admin_emails", "foo@gmail.com,bar@dar.com\naaa@bbb.com")
    admin = Setting.admin_emails.as(Array(String))
    admin.should be_a(Array(String))
    admin.size.should eq(3)
    admin.should eq(["foo@gmail.com", "bar@dar.com", "aaa@bbb.com"])

    # integer
    direct_update_record("user_limits", "100")
    Setting.user_limits.should eq(100_i64)
    Setting.user_limits.should be_a(Int64)

    # boolean
    direct_update_record("captcha_enable", "0")
    Setting.captcha_enable.should be_false
    direct_update_record("captcha_enable", "false")
    Setting.captcha_enable.should be_false
    direct_update_record("captcha_enable", "true")
    Setting.captcha_enable.should be_true
    direct_update_record("captcha_enable", "1")
    Setting.captcha_enable.should be_true
  end

  it "array with separator" do
    value = "Hello this is first line, and have comma.\nThis is second line.\n"
    direct_update_record("tips", value)
    tips = Setting.tips.not_nil!.as(Array(String))
    tips.size.should eq(2)
    tips[0].should eq("Hello this is first line, and have comma.")
    tips[1].should eq("This is second line.")

    direct_update_record("default_tags", "Ruby Rails,GitHub")
    Setting.default_tags.should eq(["Ruby", "Rails", "GitHub"])
  end

  it "unsupported type to string" do
    Setting.fallback_field.should eq("hello")
    Setting.fallback_field = "bar"
    Setting.fallback_field.should eq("bar")
  end

  it "key with complex options" do
    Setting.key_with_more_options.should eq(["foo", "bar"])
    field = Setting.get_field("key_with_more_options").not_nil!
    field.scope.should be_nil
    field.key.should eq("key_with_more_options")
    field.default.should eq(["foo", "bar"])
    field.type.should eq(:array)
    field.readonly?.should be_false
    field.options.should eq({"foo" => 1, "section" => :theme})
  end

  it "rails_scope" do
    Setting.ordered.should be_a(ActiveRecord::Relation(Setting))
    # формат to_sql у active_record_cr — явный список колонок без алиаса
    # таблицы (в Rails: SELECT "settings".* ... ORDER BY "settings"."id" DESC)
    Setting.ordered.to_sql.should eq(
      %(SELECT "id", "var", "value", "created_at", "updated_at" FROM "settings" ORDER BY "id" DESC))
    # extension-блок (by_prefix(...).foo) не поддерживается — см. PLAN.md
    Setting.by_prefix("readonly_").to_sql.should eq(
      %(SELECT "id", "var", "value", "created_at", "updated_at" FROM "settings" WHERE (var LIKE $1) ORDER BY "id" ASC))
  end

  describe "CustomCacheStorageTest" do
    it "uses expected cached storage" do
      original = RailsSettings.config.cache_storage
      store = DummyStore.new
      RailsSettings.config.cache_storage = store

      Setting.user_limits = 42
      Setting.user_limits.should eq(42_i64)
      store.data.keys.any?(&.starts_with?("rails-settings-cached")).should be_true

      RailsSettings.config.cache_storage = original
    end
  end
end
