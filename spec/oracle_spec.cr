# Реплей oracle/expected.yml (снято с настоящего rails-settings-cached 2.9.5,
# см. oracle/cases.rb). Каждый кейс: result — нормализованное значение,
# value_column — побайтовое содержимое settings.value, error — «Класс: msg».

require "./spec_helper"

def norm(v : RailsSettings::FieldValue) : String
  case v
  when Nil      then "nil"
  when Bool     then "bool:#{v}"
  when Int32    then "int:#{v}"
  when Int64    then "int:#{v}"
  when Float64  then "flt:#{v}"
  when BigDecimal
    s = v.to_s
    "dec:#{s.includes?('.') ? s : s + ".0"}"
  when String   then "str:#{v.inspect}"
  when Symbol   then "str:#{v.to_s.inspect}"
  when Array
    "arr[#{v.map { |x| norm(x.as(RailsSettings::FieldValue)) }.join(",")}]"
  when Hash
    pairs = v.map { |k, x| "str:#{k.to_s.inspect}=>#{norm(x)}" }
    "hash{#{pairs.sort.join(",")}}"
  else
    "obj:#{v.class.name}"
  end
end

# get_field → та же норм-строка, что даёт Ruby для field.to_h
# (ключи-символы нормализуются как строки, см. cases.rb norm)
def norm_field(f : RailsSettings::Field) : String
  default = f.default
  scope = f.scope
  scope_part = scope ? "str:#{scope.to_s.inspect}" : "nil"
  default_part =
    if default.is_a?(Proc(RailsSettings::FieldValue))
      "obj:Proc"
    else
      norm(default.as(RailsSettings::FieldValue))
    end
  "hash{str:\"default\"=>#{default_part},str:\"key\"=>str:#{f.key.inspect}," \
    "str:\"options\"=>#{norm_options(f.options)},str:\"readonly\"=>bool:#{f.readonly?}," \
    "str:\"scope\"=>#{scope_part},str:\"type\"=>str:#{f.type.to_s.inspect}}"
end

def norm_options(opts : Hash(String, RailsSettings::FieldValue)) : String
  "hash{#{opts.map { |k, x| "str:#{k.inspect}=>#{norm(x)}" }.sort.join(",")}}"
end

def norm_err(ex : Exception) : String
  # StandardError в Crystal — alias Exception: имя класса печатается как
  # «Exception», семантически это тот же StandardError, что в Ruby.
  cls = ex.class.name
  cls = "StandardError" if cls == "Exception"
  "#{cls}: #{ex.message}"
end

def expect_record(var : String, expected_yaml : String) : Nil
  rec = Setting.unscoped.where(var: var).take
  rec.should_not be_nil
  rec.not_nil!.value.should eq(expected_yaml)
end

EXPECTED = YAML.parse(File.read(File.join(__DIR__, "..", "oracle", "expected.yml"))).as_a

describe "oracle replay (rails-settings-cached 2.9.5)" do
  before_all { reset_db! }
  Spec.before_each { reset_state! }

  {% skip = ["cache storage default is Rails.cache", "readonly setter raises",
              "readonly hash setter raises", "not exist field raises"] %}

  {% for entry_i in 0...0 %}{% end %}

  EXPECTED.each do |entry|
    name = entry["name"].as_s
    expected_result = entry["result"]?.try(&.as_s)
    expected_value = entry["value_column"]?.try(&.as_s)
    expected_error = entry["error"]?.try(&.as_s)

    it name do
      # Кейсы, требующие адаптации (см. PLAN.md): NoMethodError в Crystal —
      # ошибки компиляции (проверяются отдельными статическими примерами),
      # дефолтный cache_storage — MemoryStore вместо Rails.cache.
      if expected_error && expected_error.starts_with?("NoMethodError")
        # NoMethodError-кейсы гема (readonly-сеттер, несуществующее поле) в
        # Crystal — ошибки компиляции: методы просто не генерируются.
        # Статически проверяется в base_spec.
        true
      elsif name == "cache storage default is Rails.cache"
        # адаптация: дефолт — MemoryStore (Rails.cache в Crystal-порте нет);
        # проверяется отдельным примером ниже.
        true
      else
        result, value_var = replay_case(name)
        if expected_error
          fail("ожидалась ошибка #{expected_error.inspect}, получено #{result.inspect}")
        end
        result.should eq(expected_result)
        if expected_value
          actual = raw_value(value_var.not_nil!)
          if expected_value == ":absent"
            actual.should be_nil
          else
            actual.should eq(expected_value)
          end
        end
      end
    rescue ex : Exception
      if expected_error
        norm_err(ex).should eq(expected_error)
      else
        raise ex
      end
    end
  end

  # Отдельно: кейс "cache storage default is Rails.cache" в адаптации.
  it "default cache storage is a MemoryStore (адаптация Rails.cache)" do
    store = RailsSettings.config.cache_storage
    store.should be_a(ActiveSupport::Cache::MemoryStore)
    # синглтон конфига: тот же инстанс между обращениями
    RailsSettings.config.cache_storage.should be(store)
  end
end

def replay_case(name : String) : Tuple(String, String?)
  v = nil
  r = case name
      when "version"
        norm(RailsSettings::F.v(RailsSettings.version))
      when "cache_key default"
        norm(Setting.cache_key)
      when "cache_prefix change"
        # повторное объявление cache_prefix перетирает префикс (1:1 Ruby;
        # в Crystal — runtime-override, повторный вызов макроса из метода
        # невозможен)
        Setting.__rs_override_cache_prefix = "v2"
        key = Setting.cache_key
        Setting.__rs_override_cache_prefix = nil
        norm(key)
      when "keys"
        norm(Setting.keys.map { |k| RailsSettings::F.v(k) })
      when "editable_keys"
        norm(Setting.editable_keys.map { |k| RailsSettings::F.v(k) })
      when "readonly_keys"
        norm(Setting.readonly_keys.map { |k| RailsSettings::F.v(k) })
      when "get_field: host"
        norm_field(Setting.get_field("host").not_nil!)
      when "get_field: omniauth"
        norm_field(Setting.get_field("omniauth_google_options").not_nil!)
      when "get_field: missing"
        # Ruby get_field для отсутствующего ключа возвращает {}
        Setting.get_field("foooo").nil? ? "hash{}" : "present"
      when "get_field: options"
        norm_field(Setting.get_field("key_with_more_options").not_nil!)
      when "default: string"
        norm(Setting.host)
      when "default: array"
        norm(Setting.admin_emails)
      when "default: boolean true"
        norm(Setting.captcha_enable)
      when "default: integer"
        norm(Setting.user_limits)
      when "default: integer nil"
        norm(Setting.integer_item)
      when "default: float 7"
        norm(Setting.float_item)
      when "default: float nil"
        norm(Setting.boolean_item)
      when "default: array nil"
        norm(Setting.array_item)
      when "default: hash nil"
        norm(Setting.hash_item)
      when "default: big_decimal 9"
        norm(Setting.big_decimal_item)
      when "default: proc int"
        norm(Setting.default_value_with_block)
      when "default: proc readonly"
        norm(Setting.readonly_item_with_proc)
      when "default: readonly int"
        norm(Setting.readonly_item)
      when "default: hash"
        norm(Setting.smtp_settings)
      when "default: hash readonly"
        norm(Setting.omniauth_google_options)
      when "default: fallback unknown type"
        norm(Setting.fallback_field)
      when "default: array with options"
        norm(Setting.key_with_more_options)
      when "default: no record in db"
        s = Setting.where(var: "host").take
        norm(s.nil? ? nil : "present")
      when "instance delegation"
        setting = Setting.new
        norm([setting.host, setting.readonly_item, setting.default_tags])
      when "_all_settings empty"
        norm_hash_flat(Setting._all_settings)
      when "integer = 12"
        v = "integer_item"
        Setting.integer_item = 12
        norm(Setting.integer_item)
      when %(integer = "27")
        v = "integer_item"
        Setting.integer_item = "27"
        norm(Setting.integer_item)
      when "integer = 2.7"
        v = "integer_item"
        Setting.integer_item = 2.7
        norm(Setting.integer_item)
      when "integer = nil"
        v = "integer_item"
        Setting.integer_item = nil
        norm(Setting.integer_item)
      when "integer default after nil"
        Setting.user_limits = nil
        norm(Setting.user_limits)
      when "integer = 100"
        v = "user_limits"
        Setting.user_limits = 100
        norm(Setting.user_limits)
      when "string set"
        v = "string_item"
        Setting.string_item = "https://www.example.com"
        norm(Setting.string_item)
      when %(string yaml-ambiguous: true)
        v = "string_item"
        Setting.string_item = "true"
        norm(Setting.string_item)
      when %(string yaml-ambiguous: 42)
        v = "string_item"
        Setting.string_item = "42"
        norm(Setting.string_item)
      when %(string yaml-ambiguous: 3.14)
        v = "string_item"
        Setting.string_item = "3.14"
        norm(Setting.string_item)
      when %(string yaml-ambiguous: null)
        v = "string_item"
        Setting.string_item = "null"
        norm(Setting.string_item)
      when %(string yaml-ambiguous: ~)
        v = "string_item"
        Setting.string_item = "~"
        norm(Setting.string_item)
      when %(string yaml-ambiguous: yes)
        v = "string_item"
        Setting.string_item = "yes"
        norm(Setting.string_item)
      when "string empty"
        v = "string_item"
        Setting.string_item = ""
        norm(Setting.string_item)
      when "string leading space"
        v = "string_item"
        Setting.string_item = " hello"
        norm(Setting.string_item)
      when "string with colon+space"
        v = "string_item"
        Setting.string_item = "a: b"
        norm(Setting.string_item)
      when "string with hash sign"
        v = "string_item"
        Setting.string_item = "a #b"
        norm(Setting.string_item)
      when "float = 9"
        v = "float_item"
        Setting.float_item = 9
        norm(Setting.float_item)
      when "float = 2.9"
        v = "float_item"
        Setting.float_item = 2.9
        norm(Setting.float_item)
      when %(float = "2.9")
        v = "float_item"
        Setting.float_item = "2.9"
        norm(Setting.float_item)
      when "float = nil then default"
        v = "float_item"
        Setting.float_item = nil
        norm(Setting.float_item)
      when "big_decimal = 7"
        v = "big_decimal_item"
        Setting.big_decimal_item = 7
        norm(Setting.big_decimal_item)
      when "big_decimal = 2.9"
        v = "big_decimal_item"
        Setting.big_decimal_item = 2.9
        norm(Setting.big_decimal_item)
      when %(big_decimal = "2.9")
        v = "big_decimal_item"
        Setting.big_decimal_item = "2.9"
        norm(Setting.big_decimal_item)
      when "big_decimal = nil then default"
        v = "big_decimal_item"
        Setting.big_decimal_item = nil
        norm(Setting.big_decimal_item)
      when %(boolean = "0")
        v = "boolean_item"
        Setting.boolean_item = "0"
        norm([Setting.boolean_item, Setting.boolean_item?])
      when %(boolean = "1")
        v = "boolean_item"
        Setting.boolean_item = "1"
        norm([Setting.boolean_item, Setting.boolean_item?])
      when %(boolean = "false")
        v = "boolean_item"
        Setting.boolean_item = "false"
        norm(Setting.boolean_item)
      when %(boolean = "true")
        v = "boolean_item"
        Setting.boolean_item = "true"
        norm(Setting.boolean_item)
      when "boolean = 0"
        v = "boolean_item"
        Setting.boolean_item = 0
        norm(Setting.boolean_item)
      when "boolean = 1"
        v = "boolean_item"
        Setting.boolean_item = 1
        norm(Setting.boolean_item)
      when %(boolean = "yes")
        v = "boolean_item"
        Setting.boolean_item = "yes"
        norm(Setting.boolean_item)
      when "array = list"
        v = "array_item"
        emails = ["admin@rubyonrails.org", "huacnlee@gmail.com"]
        Setting.array_item = emails
        norm(Setting.array_item)
      when "array = join newline"
        v = "array_item"
        emails = ["admin@rubyonrails.org", "huacnlee@gmail.com"]
        Setting.array_item = emails.join("\n")
        norm(Setting.array_item)
      when "array = join comma"
        v = "array_item"
        emails = ["admin@rubyonrails.org", "huacnlee@gmail.com"]
        Setting.array_item = emails.join(",")
        norm(Setting.array_item)
      when "array = join semicolon"
        v = "array_item"
        emails = ["admin@rubyonrails.org", "huacnlee@gmail.com"]
        Setting.array_item = emails.join(";")
        norm(Setting.array_item)
      when %(array = join ' , ')
        v = "array_item"
        emails = ["admin@rubyonrails.org", "huacnlee@gmail.com"]
        Setting.array_item = emails.join(" , ")
        norm(Setting.array_item)
      when "array = empty string"
        v = "array_item"
        Setting.array_item = ""
        norm(Setting.array_item)
      when "array = nil"
        v = "array_item"
        Setting.array_item = nil
        norm(Setting.array_item)
      when "hash = string keys"
        v = "hash_item"
        Setting.hash_item = {"foo" => "bar"}
        norm(Setting.hash_item)
      when "hash = symbol keys"
        v = "hash_item"
        Setting.hash_item = {:foo => "bar"}
        norm(Setting.hash_item)
      when "hash = nested"
        v = "hash_item"
        Setting.hash_item = {"a" => {"b" => "c"}}
        norm(Setting.hash_item)
      when "hash = array value"
        v = "hash_item"
        Setting.hash_item = {"a" => ["x", "y"]}
        norm(Setting.hash_item)
      when "hash = empty"
        v = "hash_item"
        Setting.hash_item = {} of String => String
        norm(Setting.hash_item)
      when "hash = mixed types"
        v = "smtp_settings"
        Setting.smtp_settings = {"title" => "456", "age" => 32, "name" => "Jason Lee"}
        norm(Setting.smtp_settings)
      when "hash = symbol value"
        v = "smtp_settings"
        Setting.smtp_settings = {"sym" => :symbol, "str" => "string", "num" => 27.72}
        norm(Setting.smtp_settings)
      when "hash = nil"
        v = "hash_item"
        Setting.hash_item = nil
        norm(Setting.hash_item)
      when "hash from json string in db"
        record = Setting.find_by(var: "smtp_settings")
        unless record
          record = Setting.new(var: "smtp_settings")
          record.save!
        end
        record.update({"value" => %({"sym": "symbol", "num": 27.72})})
        norm(Setting.smtp_settings)
      when "custom = 2"
        v = "custom_item"
        Setting.custom_item = 2
        norm(Setting.custom_item)
      when "custom = 3"
        v = "custom_item"
        Setting.custom_item = 3
        norm(Setting.custom_item)
      when "custom = 4 raises"
        Setting.custom_item = 4
        norm(Setting.custom_item)
      when "db string → array"
        direct_update_record("admin_emails", "foo@gmail.com,bar@dar.com\naaa@bbb.com")
        norm(Setting.admin_emails)
      when "db string → integer"
        direct_update_record("user_limits", "100")
        norm(Setting.user_limits)
      when "db string → boolean false"
        direct_update_record("captcha_enable", "0")
        norm(Setting.captcha_enable)
      when "db string → boolean true"
        direct_update_record("captcha_enable", "true")
        norm(Setting.captcha_enable)
      when "db yaml string → integer"
        direct_update_record("user_limits", "--- 42\n")
        norm(Setting.user_limits)
      when "db string separators: tips"
        direct_update_record("tips", "Hello this is first line, and have comma.\nThis is second line.\n")
        norm(Setting.tips)
      when "db string separators: default_tags"
        direct_update_record("default_tags", "Ruby Rails,GitHub")
        norm(Setting.default_tags)
      when "_all_settings after save"
        Setting.host = "https://example.com"
        norm_hash_flat(Setting._all_settings)
      when "custom cache storage used"
        original = RailsSettings.config.cache_storage
        store = DummyStore.new
        RailsSettings.config.cache_storage = store
        Setting.user_limits = 42
        Setting.user_limits
        keys = store.data.keys.select(&.starts_with?("rails-settings-cached"))
        RailsSettings.config.cache_storage = original
        norm(keys.map { |k| RailsSettings::F.v(k) })
      when "clear_cache deletes cache entry"
        original = RailsSettings.config.cache_storage
        store = DummyStore.new
        RailsSettings.config.cache_storage = store
        Setting.user_limits = 42
        Setting.user_limits
        Setting.clear_cache
        keys = store.data.keys
        RailsSettings.config.cache_storage = original
        norm(keys.map { |k| RailsSettings::F.v(k) })
      when "after_commit clears cache"
        original = RailsSettings.config.cache_storage
        store = DummyStore.new
        RailsSettings.config.cache_storage = store
        Setting.user_limits = 42
        Setting.user_limits
        Setting.user_limits = 43
        keys = store.data.keys
        RailsSettings.config.cache_storage = original
        norm(keys.map { |k| RailsSettings::F.v(k) })
      when "request cache disabled by default"
        c = RailsSettings::RequestCache.all_settings
        c.nil? ? "nil" : "present"
      when "request cache enable/disable"
        RailsSettings::RequestCache.enable!
        enabled = RailsSettings::RequestCache.enabled?
        Setting.host = "cached.example.com"
        cached = RailsSettings::RequestCache.all_settings
        RailsSettings::RequestCache.disable!
        # Ruby хранит флаг как nil/true (Thread.current) — «disabled»
        # нормализуется как nil
        disabled = RailsSettings::RequestCache.enabled? ? true : nil
        after = RailsSettings::RequestCache.all_settings
        norm([enabled, !cached.nil?, disabled, after])
      when "protected key var"
        NewSetting.__rs_fields
        "no error"
      when "protected key value"
        NewSetting2.__rs_fields
        "no error"
      when "no table fallback to default"
        norm(NoTableSetting.foo)
      when "no table defined_keys"
        norm(NoTableSetting.keys.map { |k| RailsSettings::F.v(k) })
      when "validation host blank"
        setting = Setting.new(var: "host")
        norm([setting.valid?, setting.errors.full_messages.map { |m| RailsSettings::F.v(m) }])
      when "validation host ok"
        setting = Setting.new(var: "host")
        setting.value = "https://ruby-china.org"
        norm([setting.valid?, setting.errors.full_messages.map { |m| RailsSettings::F.v(m) }])
      when "validation user_limits blank"
        setting = Setting.new(var: "user_limits")
        norm([setting.valid?, setting.errors.full_messages.map { |m| RailsSettings::F.v(m) }])
      when "validation user_limits format"
        setting = Setting.new(var: "user_limits")
        setting.value = "hello"
        norm([setting.valid?, setting.errors.full_messages.map { |m| RailsSettings::F.v(m) }])
      when "validation user_limits ok"
        setting = Setting.new(var: "user_limits")
        setting.value = "100"
        norm([setting.valid?, setting.errors.full_messages.map { |m| RailsSettings::F.v(m) }])
      when "validation mailer_provider blank"
        setting = Setting.new(var: "mailer_provider")
        norm([setting.valid?, setting.errors.full_messages.map { |m| RailsSettings::F.v(m) }])
      when "validation assignment host raises"
        Setting.host = ""
        "no error"
      when "validation assignment host ok"
        norm(Setting.host = "foo")
      when "validation assignment mailer raises"
        Setting.mailer_provider = "foo"
        "no error"
      else
        raise "нет раннера для кейса #{name.inspect}"
      end
  {r, v}
end

# _all_settings — Hash(String, FieldValue): нормализуем как Ruby-хеш
def norm_hash_flat(h : Hash(String, RailsSettings::FieldValue)) : String
  "hash{#{h.map { |k, x| "str:#{k.inspect}=>#{norm(x)}" }.sort.join(",")}}"
end
