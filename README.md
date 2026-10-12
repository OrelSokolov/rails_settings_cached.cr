# rails_settings_cached.cr

A Crystal port of [huacnlee/rails-settings-cached](https://github.com/huacnlee/rails-settings-cached)
**2.9.5** — cached, database-backed application settings as typed fields
on a `settings (var, value)` table. Values are stored as YAML
**byte-compatible with Ruby Psych** (string quoting rules, block styles,
BigDecimal marshal format), so a database written by the Ruby gem is
readable by the port and vice versa.

> ⚠️ EXPERIMENTAL — DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  rails_settings_cached_cr:
    github: OrelSokolov/rails_settings_cached.cr
```

```sh
shards install
```

Requires PostgreSQL (test DB `crails_rsc_test`, override with
`RSC_TEST_URL`); depends on `active_record.cr` and `active_support.cr`.

## Usage

```crystal
class Setting < RailsSettings::Base
  cache_prefix { "v1" }

  scope :application do
    field :host, default: "http://example.com", validates: {presence: true}
    field :admin_emails, type: :array, default: %w[admin@rubyonrails.org]
    field :captcha_enable, type: :boolean, default: true
    field :user_limits, type: :integer, default: 1,
      validates: {format: {with: /\d+/, message: "must be numbers"}}
  end
end

Setting.host                    # => "http://example.com"
Setting.host = "https://..."    # saves! (RecordInvalid on validation failure)
Setting.captcha_enable?         # boolean predicate
Setting.clear_cache
```

## Feature comparison vs rails-settings-cached 2.9.5

| Feature | Original (rails-settings-cached) | Port (rails_settings_cached.cr) | Status |
|---|---|---|---|
| `field` with `type:`, `default:`, `readonly:`, `separator:`, extra options | ✅ | Macro — key must be an identifier literal; values are `RailsSettings::FieldValue` (typed union) | 🔶 |
| Field types `:string :integer :float :big_decimal :boolean :array :hash`, custom `Fields::Custom(T) < Base(T)`, unknown type → String | ✅ | Same | ✅ |
| `scope` blocks | ✅ | Same (scope with an extension block not supported) | 🔶 |
| `cache_prefix { "v1" }` → `Setting.cache_key` (`rails-settings-cached/v1`) | ✅ | Same; runtime override via `Setting.__rs_override_cache_prefix = "v2"` | 🔶 |
| Getter/setter class API, boolean predicates, `Setting.keys / editable_keys / readonly_keys / defined_fields` | ✅ | Same | ✅ |
| `get_field("host")` | ✅ (returns Hash) | Returns a `Field` object or nil | 🔶 |
| YAML storage byte-compatible with Ruby Psych (quoting `'true'`/`'42'`/`"y"`/`'1:2'`, block styles, BigDecimal `!ruby/object:BigDecimal`) | ✅ | Same, round-trip verified | ✅ |
| Cache via `ActiveSupport::Cache`, `expires_in: 7.days`, `_all_settings` JSON-serialized, `clear_cache` | ✅ | Same; default store is `MemoryStore` (no global `Rails.cache` — the app overrides in `configure`) | 🔶 |
| Cache invalidation on commit (`after_commit` on create/update/destroy) | ✅ | Via an `__run_after_commit` interception | ✅ |
| `validates:` (presence/format/inclusion, Rails messages: "can't be blank", custom, "is not included in the list") | ✅ | Same; validation reads the YAML-decoded value, runs only for records with `var == key` | ✅ |
| `RailsSettings.config.cache_storage`, `RailsSettings.configure`, `RailsSettings.version` | ✅ | Same | ✅ |
| RequestCache + Middleware | ✅ | RequestCache is a class variable (no fiber-local storage); requests must end with `disable!` | 🔶 |
| Symbols round-trip (keys `:foo`, values `:symbol`) | ✅ | Dumped YAML-compatibly, but read back as Strings (no runtime `String#to_sym`) | 🔶 |
| Writing readonly/nonexistent field → `NoMethodError` | ✅ | Compile-time error; tests check with `responds_to?` | ❌ (equivalent: compile-time check) |
| `NoConnectionSetting` (no-DB mode) | ✅ | Not ported (single global connection) | ⬜ |

## Deviations & Crystal-specific notes

- `field`/`scope`/`cache_prefix` are macros; model-level API is
  generated in a `macro finished` pass from compile-time registries.
- Integer fields return `Int64`; the instance getter `value` is the raw
  DB string — use `record.decoded_value` for YAML decoding.
- `to_sql` from active_record.cr uses its own format (explicit column
  list, `$1` placeholders).
- `use_parent_strategy`-style stub semantics do not apply here; see
  factory_bot.cr for its own notes.

## Testing

```sh
crystal spec   # 141 examples
```

- `spec/oracle_spec.cr` — 111 cases recorded with the real gem
  (`oracle/cases.rb` → `oracle/expected.yml`, Ruby + AR 8.1 + SQLite),
  replayed 1:1 (values, byte-identical `settings.value`, error and
  validation texts).
- `spec/base_spec.cr`, `spec/validation_spec.cr` — ports of the gem's
  `base_test.rb` / `validation_test.rb`.
