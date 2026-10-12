# rails_settings_cached.cr — порт rails-settings-cached

> ⚠️ EXPERIMENTAL, DO NOT USE IN PRODUCTION YET.

Порт [huacnlee/rails-settings-cached](https://github.com/huacnlee/rails-settings-cached)
**2.9.5** на Crystal. Оригинал: `~/.rvm/gems/ruby-3.4.5/gems/rails-settings-cached-2.9.5`
(полный исходник вендорен в `oracle/src`).

## Статус

**Готово, зелёное**: 141 пример (`crystal spec`):
- `spec/oracle_spec.cr` — 111 кейсов, снятых с настоящего гема
  (`oracle/cases.rb` → `oracle/expected.yml`, Ruby + ActiveRecord 8.1 +
  SQLite), воспроизводятся 1:1 (значения, побайтовое содержимое
  `settings.value`, тексты ошибок и валидаций);
- `spec/base_spec.cr` — порт `test/base_test.rb`;
- `spec/validation_spec.cr` — порт `test/validation_test.rb`.

Требования: PostgreSQL (`crails_rsc_test`, `RSC_TEST_URL`), таблица
создаётся миграцией в спеках. Модели читают `db/schema.yml`
(кодегенерация active_record_cr).

## API 1:1

```crystal
class Setting < RailsSettings::Base
  cache_prefix { "v1" }

  scope :application do
    field :host, default: "http://example.com", validates: {presence: true}
    field :admin_emails, type: :array, default: %w[admin@rubyonrails.org]
    field :captcha_enable, type: :boolean, default: true
    field :user_limits, type: :integer, default: 1,
      validates: {presence: true, format: {with: /\d+/, message: "must be numbers"}}
  end

  field :key_with_more_options, type: :array, default: %w[foo bar], foo: 1, section: :theme
end

Setting.host                      # => "http://example.com"
Setting.host = "https://..."      # save! (RecordInvalid при ошибке валидации)
Setting.captcha_enable?           # boolean-предикат
Setting.keys / editable_keys / readonly_keys / defined_fields
Setting.get_field("host")         # Field (Ruby возвращает Hash; nil для отсутствующего)
Setting.cache_key                 # "rails-settings-cached/v1"
Setting.clear_cache
RailsSettings.config.cache_storage = свой стор
RailsSettings.configure { |c| ... }
RailsSettings.version             # "2.9.5"
```

Типы полей: `:string :integer :float :big_decimal :boolean :array :hash`
(+ свои: `RailsSettings::Fields::Custom(T) < Base(T)`). Неизвестный тип →
String (1:1). `separator:` для array-полей (String или Regex).

Хранение: таблица `settings (var, value)`, `value` — YAML **байт-в-байт
как Ruby Psych**: квотинг строк по правилам Psych (`'true'`, `'42'`,
`"y"`, `'1:2'`, …), блок-стили для многострочных строк, BigDecimal в
marshal-формате `!ruby/object:BigDecimal N:0.ddde+X` (эмпирическая
формула префикса N сходится на всех контрольных значениях). Обратная
совместимость: база, написанная Ruby-гемом, читается портом и наоборот.

Кэш: `ActiveSupport::Cache` (active_support_cr), дефолт MemoryStore,
`expires_in: 7.days` — как в геме. `_all_settings` сериализуется в JSON
(строковое значение кэш-стора). `after_commit` на create/update/destroy
сбрасывает кэш (перехватом `__run_after_commit`, см. ниже).

## Отличия от Ruby (статическая типизация)

- `field`/`scope`/`cache_prefix` — макросы; ключ поля должен быть
  литералом-идентификатором. Значения полей — `RailsSettings::FieldValue`
  (union: Nil/Bool/Int32/Int64/Float64/BigDecimal/String/Symbol/массивы/
  хеши). Геттеры возвращают FieldValue; Integer-поля — Int64.
- **NoMethodError-кейсы** (запись в readonly-поле, несуществующее поле) —
  ошибки компиляции; в тестах проверяются через `responds_to?`.
- **Символы**: Ruby-символы (ключи `:foo`, значения `:symbol`) дампятся в
  YAML совместимо (`:foo:`, `sym: :symbol`), но при чтении возвращаются
  строками (`"foo"`, `"symbol"`) — runtime String→Symbol в Crystal нет.
- Инстанс-геттер `value` — сырая строка из БД (кодегенерация колонок AR);
  YAML-декод — `record.decoded_value`.
- `get_field` возвращает объект `Field`/nil (Ruby — Hash).
- RequestCache — классовая переменная (нет fiber-local хранилища);
  `Middleware` обёрнут блоком; запрос обязан завершаться `disable!`.
- Повторный `cache_prefix { }` из рантайма — через
  `Setting.__rs_override_cache_prefix = "v2"` (макрос повторно из метода
  не вызвать).
- `RailsSettings.config.cache_storage` по умолчанию — MemoryStore
  (Rails.cache в Crystal-порте нет; приложение подменяет в configure).
- scope с extension-блоком (`scope :by_prefix, ->(k){...} do def foo; end
  end`) не поддерживается; `to_sql` у active_record_cr — свой формат
  (явный список колонок, плейсхолдеры $1).
- `validates:` поддержан для presence/format/inclusion (1:1 сообщения
  Rails: "can't be blank", "must be numbers" (custom message),
  "is not included in the list"); валидация читает YAML-декодированное
  значение и включается только для записи с `var == key` (аналог
  `validates[:if]` + `read_attribute_for_validation`).
- NoConnectionSetting (гем-кейс «нет соединения») не переносился:
  active_record_cr держит одно глобальное соединение.

## Обход багов/квирков Crystal 1.21

1. **Методы, сгенерированные макросом в теле класса, НЕ видны в
   `t.methods` на этапе `macro finished`** (проверено минимальным репро).
   Поэтому `field`/`cache_prefix` пишут в compile-time реестры
   (`FIELD_REGISTRY`, `PREFIX_CLASSES`), а API уровня модели
   (`__rs_fields`/`keys`/`cache_key`/`_all_settings`/…) генерируется в
   собственном `macro finished` по `RailsSettings::Base.all_subclasses`.
2. По той же причине коллбэк `after_commit :clear_cache` не попадает в
   AR-хук-раннер — вместо него перехватывается сам
   `__run_after_commit(event)` с `previous_def` (порядок finished-макросов:
   active_record → rails_settings — переопределение срабатывает).
3. Классы `Fields::String/Integer/Float/BigDecimal/Boolean/Array/Hash`
   затеняют глобальные имена внутри `module Fields` — все внутренние
   ссылки обязаны быть `::String`, `::Array`, `::Hash` (и `when ::String`
   в case!). То же касается кастомных полей в приложении.
4. `YAML::Any#raw` даёт `Hash(YAML::Any, YAML::Any)`, а не
   `Hash(String, YAML::Any)` — ключи stringify-ятся при конвертации.
5. Proc-литерал `->{ F.v(1 + 1) }` без `.as(FieldValue)` внутри `F.v`
   инферится как `Proc(Int32)` и не матчит `Proc(FieldValue)` — `F.v`
   содержит явный `.as`.
6. Прочее (как у jbuilder.cr): SymbolLiteral#stringify даёт `":host"`
   (нужен `.id.stringify`); сплайс ArrayLiteral перед `.map` требует
   скобок; `responds_to?` — только Symbol-литерал.

## Структура

- `src/rails_settings_cached.cr` — вход (require, version,
  ProtectedKeyError)
- `src/rails_settings/values.cr` — FieldValue, коэрсинг F, YAML-кодек Y
  (Psych-совместимый dump/load), JSON-кодек кэша, ленивые to_i/to_f/to_d
- `src/rails_settings/fields.cr` — Field/Base(T) + типы полей
- `src/rails_settings/configuration.cr` — config/configure
- `src/rails_settings/request_cache.cr` — RequestCache + Middleware
- `src/rails_settings/base.cr` — DSL (field/scope/cache_prefix) +
  finished-генерация API модели
- `oracle/src` — вендоренный оригинал 2.9.5; `oracle/cases.rb` +
  `oracle/expected.yml` — снятое поведение (111 кейсов)
- `db/schema.yml` — таблицы для спек (settings, not-exist-settings)
- `spec/` — oracle_spec (реплей), base_spec, validation_spec (порты
  оригинальных тестов), smoke_spec

## TODO

- [ ] Проверить на реальной базе Ruby-приложения (~/qp2/website)
- [ ] Railtie-аналог для action_pack.cr (подключение Middleware)
- [ ] `railties`-генератор миграции (install_generator) — по запросу
