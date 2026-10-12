# RailsSettings::Base — 1:1 к rails-settings/base.rb.
#
# Модель настроек:
#
#   class Setting < RailsSettings::Base
#     cache_prefix { "v1" }
#
#     scope :application do
#       field :host, default: "http://example.com"
#       field :admin_emails, type: :array, default: %w[admin@rubyonrails.org]
#     end
#   end
#
# Отличия от Ruby, продиктованные Crystal:
#   * Base — абстрактный класс (AR-кодегенерация по db/schema.yml
#     работает для конкретных моделей);
#   * `field`/`scope`/`cache_prefix` — макросы; ключи полей должны быть
#     валидными идентификаторами;
#   * инстанс-геттер `value` остаётся «сырой» строкой из БД
#     (кодегенерация колонок AR); YAML-декодирование — `decoded_value`;
#   * NoMethodError при записи в readonly-поле / обращении к несуществующему
#     полю — это ошибки КОМПИЛЯЦИИ (метод не генерируется).

module RailsSettings
  # Compile-time реестры полей/префиксов: методы, сгенерированные макросом
  # `field`/`cache_prefix` внутри тела класса, НЕ видны в t.methods на
  # этапе `macro finished` — поэтому регистрируем при разборе.
  FIELD_REGISTRY = [] of Nil # {class name, key}
  PREFIX_CLASSES = [] of Nil # {class name}

  abstract class Base < ActiveRecord::Base
    PROTECTED_KEYS = {"var", "value"}

    @@__rs_override_cache_prefix : String? = nil

    def clear_cache : Nil
      self.class.clear_cache
    end

    def self.cache_storage : ActiveSupport::Cache::Store
      RailsSettings.config.cache_storage
    end

    # --- DSL --------------------------------------------------------------

    # Повторный cache_prefix { } в Ruby работает на этапе выполнения
    # (тесты гема его переопределяют). В Crystal повторный вызов макроса
    # из рантайма невозможен — поэтому генерируемый метод сначала
    # смотрит runtime-override.
    def self.__rs_override_cache_prefix=(v : String?) : Nil
      @@__rs_override_cache_prefix = v
    end

    macro cache_prefix(&block)
      {% RailsSettings::PREFIX_CLASSES << @type.name.stringify %}
      def self.__rs_cache_prefix : String
        if (o = @@__rs_override_cache_prefix)
          o
        else
          {{ block.body }}
        end
      end
    end

    # `scope :name do field ... end` — группировка полей (1:1 к гемовому
    # scope-DSL). Форма с параметрами/запросом — обычный AR-scope:
    #   scope :by_prefix do |key| where("var like ?", "#{key}%") end
    macro scope(name, &block)
      {% calls = [] of Nil %}
      {% if block.body.is_a?(Expressions) %}
        {% for e in block.body.expressions %}
          {% calls << e %}
        {% end %}
      {% else %}
        {% calls << block.body %}
      {% end %}
      {% is_group = !calls.empty? && calls.all? { |e| e.is_a?(Call) && e.name.stringify == "field" } %}
      {% if is_group %}
        {% for e in calls %}
          {% if e.is_a?(Call) %}
            field({{ name }}, {{ e.args.splat }}{% unless e.named_args.empty? %}, {% for na in e.named_args %}{{ na.name.id }}: {{ na.value }}, {% end %}{% end %})
          {% end %}
        {% end %}
      {% else %}
        def self.{{ name.id }}({{ block.args.splat }})
          {{ block.body }}
        end
      {% end %}
    end

    # field :key, default: nil, type: :string, readonly: false, separator: nil,
    #       validates: {presence: true, format: {...}, inclusion: {...}}, **opts
    macro field(scope_or_key, key = nil, default = nil, type = :string,
                readonly = false, separator = nil, validates = nil, **opts)
      {% k = key || scope_or_key %}
      {% if k.is_a?(SymbolLiteral) %}
        {% key_s = k.id.stringify %}
      {% elsif k.is_a?(StringLiteral) %}
        {% key_s = k.value %}
      {% else %}
        {% raise "field key must be a Symbol or String literal, got: #{k}" %}
      {% end %}
      {% scope_lit = key ? scope_or_key : nil %}

      {% type_name = type.id.stringify %}
      {% cls = "" %}
      {% for p in type_name.split("_") %}
        {% cls = cls + p.capitalize %}
      {% end %}
      {% resolved = "RailsSettings::Fields::String" %}
      {% for c in RailsSettings::Fields.constants %}
        {% if c.stringify == cls %}
          {% resolved = "RailsSettings::Fields::" + cls %}
        {% end %}
      {% end %}

      {% RailsSettings::FIELD_REGISTRY << { @type.name.stringify, key_s } %}

      def self.__rs_field_{{ key_s.id }} : RailsSettings::Field
        if {{ key_s }} == "var" || {{ key_s }} == "value"
          raise RailsSettings::ProtectedKeyError.new({{ key_s }})
        end
        @@__rs_f_{{ key_s.id }} ||= {{ resolved.id }}({{ @type }}).new(
          parent: {{ @type }},
          scope: {{ scope_lit }},
          key: {{ key_s }},
          default: RailsSettings::F.default({{ default }}),
          readonly: {{ readonly }},
          type: {{ type }},
          separator: {{ separator }},
          options: begin
            __rs_opts = {} of ::String => RailsSettings::FieldValue
            {% for a in opts %}
              __rs_opts[{{ a.stringify }}] = RailsSettings::F.d({{ opts[a] }})
            {% end %}
            __rs_opts
          end
        )
      end

      def self.{{ key_s.id }} : RailsSettings::FieldValue
        __rs_field_{{ key_s.id }}.read
      end

      {% unless readonly %}
        def self.{{ key_s.id }}=(value : Nil | Bool | Int32 | Int64 | Float64 | BigDecimal | String | Symbol)
          __rs_field_{{ key_s.id }}.save!(RailsSettings::F.d(value))
        end

        def self.{{ key_s.id }}=(value : ::Array(A)) forall A
          __rs_field_{{ key_s.id }}.save!(RailsSettings::F.d(value))
        end

        def self.{{ key_s.id }}=(value : Hash(K, V)) forall K, V
          __rs_field_{{ key_s.id }}.save!(RailsSettings::F.d(value))
        end
      {% end %}

      {% if type.id.stringify == "boolean" %}
        def self.{{ key_s.id }}? : Bool
          !!__rs_field_{{ key_s.id }}.read
        end
      {% end %}

      # инстанс-делегация: setting = Setting.new; setting.host
      def {{ key_s.id }} : RailsSettings::FieldValue
        self.class.{{ key_s.id }}
      end

      {% if validates && !readonly %}
        # валидация значения (read_attribute_for_validation ⇒ YAML-декод;
        # срабатывает только для записи с var == key — аналог validates[:if])
        def validation__rs_{{ key_s.id }}(context : Symbol) : Nil
          return unless @var == {{ key_s }}
          value = decoded_value
          {% if v = validates[:presence] %}
            if value.nil? || (value.is_a?(::String) && value.strip.empty?)
              errors.add({{ key_s }}, "can't be blank", :blank)
            end
          {% end %}
          {% if fmt = validates[:format] %}
            unless value.to_s.match({{ fmt[:with] }})
              errors.add({{ key_s }}, {{ fmt[:message] || "is invalid" }}, :invalid)
            end
          {% end %}
          {% if inc = validates[:inclusion] %}
            unless ({{ inc[:in] }}).map(&.to_s).includes?(value.to_s)
              errors.add({{ key_s }}, "is not included in the list", :inclusion)
            end
          {% end %}
        end
      {% end %}
    end
  end

  # Генерация API уровня модели для каждого конкретного класса настроек
  # (зеркалит macro finished из ActiveRecord::Base).
  macro finished
    {% for t in RailsSettings::Base.all_subclasses %}
      {% unless t.abstract? %}
        class ::{{ t.stringify.id }}
          # сброс кэша после create/update/destroy (1:1: after_commit
          # :clear_cache). AR-хук-раннеры собирают методы по t.methods, куда
          # не попадают методы, сгенерированные макросами, — поэтому
          # перехватываем сам раннер (previous_def сохраняет прочие
          # after_commit-коллбэки, если AR их собрал).
          def __run_after_commit(event : Symbol) : Nil
            if {:create, :update, :destroy}.includes?(event)
              clear_cache
            end
            previous_def(event)
          end

          @@__rs_fields : Array(RailsSettings::Field)?

          def self.__rs_fields : Array(RailsSettings::Field)
            if (cached = @@__rs_fields)
              cached
            else
              fs = [] of RailsSettings::Field
              {% for reg in RailsSettings::FIELD_REGISTRY %}
                {% if reg[0] == t.name.stringify %}
                  fs << __rs_field_{{ reg[1].id }}
                {% end %}
              {% end %}
              @@__rs_fields = fs
              fs
            end
          end

          {% has_prefix = false %}
          {% for pc in RailsSettings::PREFIX_CLASSES %}
            {% if pc == t.name.stringify %}{% has_prefix = true %}{% end %}
          {% end %}
          {% unless has_prefix %}
            def self.__rs_cache_prefix : String?
              @@__rs_override_cache_prefix
            end
          {% end %}

          def self.cache_key : String
            prefix = __rs_cache_prefix
            prefix ? "rails-settings-cached/#{prefix}" : "rails-settings-cached"
          end

          def self.clear_cache : Nil
            RailsSettings::RequestCache.reset
            cache_storage.delete(cache_key)
          end

          def self.keys : Array(String)
            __rs_fields.map(&.key)
          end

          def self.editable_keys : Array(String)
            __rs_fields.reject(&.readonly?).map(&.key)
          end

          def self.readonly_keys : Array(String)
            __rs_fields.select(&.readonly?).map(&.key)
          end

          def self.defined_fields : Array(RailsSettings::Field)
            __rs_fields
          end

          def self.get_field(key : String | Symbol) : RailsSettings::Field?
            k = key.to_s
            __rs_fields.find { |f| f.key == k }
          end

          def self.table_exists? : Bool
            ActiveRecord::Base.connection.query_one?(
              "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = $1)",
              table_name,
              as: Bool
            ) || false
          rescue ex
            false
          end

          def self._all_settings : Hash(String, RailsSettings::FieldValue)
            if (cached = RailsSettings::RequestCache.all_settings)
              return cached
            end
            json = cache_storage.fetch(cache_key, expires_in: 7.days) do
              result = {} of String => RailsSettings::FieldValue
              unscoped.select("var", "value").each do |record|
                result[record.var.not_nil!] = RailsSettings::Y.load(record.value)
              end
              RailsSettings::Y.cache_dump(result)
            end
            parsed = RailsSettings::Y.cache_load(json)
            RailsSettings::RequestCache.all_settings = parsed
            parsed
          end

          def decoded_value : RailsSettings::FieldValue
            RailsSettings::Y.load(value)
          end
        end
      {% end %}
    {% end %}
  end
end
