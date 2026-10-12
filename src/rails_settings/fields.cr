# Поля-сериализаторы: 1:1 к RailsSettings::Fields::* из гема.
#
# ВНИМАНИЕ: классы Fields::String/Integer/... затеняют глобальные типы —
# все ссылки на String/Array/Hash внутри этого модуля обязаны быть с «::».

module RailsSettings
  abstract class Field
    abstract def scope : Symbol?
    abstract def key : ::String
    abstract def readonly? : Bool
    abstract def type : Symbol
    abstract def options : ::Hash(::String, FieldValue)
    abstract def default : RailsSettings::DefaultArg
    abstract def default_value : FieldValue
    abstract def read : FieldValue
    abstract def save!(value : FieldValue) : FieldValue

    def deserialize(value : FieldValue) : FieldValue
      raise NotImplementedError.new("deserialize")
    end

    def serialize(value : FieldValue) : FieldValue
      raise NotImplementedError.new("serialize")
    end
  end

  module Fields
    SEPARATOR_REGEXP = /[\n,;]+/

    class Base(T) < RailsSettings::Field
      getter key : ::String
      getter scope : Symbol?
      getter options : ::Hash(::String, FieldValue)

      @default : RailsSettings::DefaultArg
      @readonly : Bool
      @type : Symbol
      @separator : ::String | Regex

      def initialize(@parent : T.class, @scope : Symbol? = nil, @key : ::String = "",
                     @default : RailsSettings::DefaultArg = nil,
                     @readonly : Bool = false, @type : Symbol = :string,
                     separator : ::String | Regex | Nil = nil,
                     @options : ::Hash(::String, FieldValue) = {} of ::String => FieldValue)
        @separator = separator || SEPARATOR_REGEXP
      end

      def readonly? : Bool
        @readonly
      end

      def default : RailsSettings::DefaultArg
        @default
      end

      def type : Symbol
        @type
      end

      def default_value : FieldValue
        case d = @default
        when Proc(FieldValue) then d.call
        else                       d
        end
      end

      def read : FieldValue
        saved = saved_value
        return deserialize(default_value) if readonly? || saved.nil?
        deserialize(saved)
      end

      def saved_value : FieldValue?
        if @parent.table_exists?
          @parent._all_settings[@key]?
        else
          puts(
            "WARNING: table: \"#{@parent.table_name}\" does not exist or not database connection, `#{@parent.name}.#{@key}` fallback to returns the default value."
          )
          nil
        end
      end

      def save!(value : FieldValue) : FieldValue
        serialized = serialize(value)
        record = @parent.find_by(var: @key) || @parent.new(var: @key)
        record.value = RailsSettings::Y.dump(serialized)
        record.save!
        RailsSettings::Y.load(record.value)
      end

      def separator : ::String | Regex
        @separator
      end
    end

    class String(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        value
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end

    class Integer(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        return nil if value.nil?
        RailsSettings::F.to_i(value)
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end

    class Float(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        return nil if value.nil?
        RailsSettings::F.to_f(value)
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end

    class BigDecimal(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        return nil if value.nil?
        RailsSettings::F.to_d(value)
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end

    class Boolean(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        return nil if value.nil?
        # Ruby: ["true", "1", 1, true].include?(value)
        case value
        when Bool        then value
        when ::String    then value == "true" || value == "1"
        when Int32       then value == 1
        when Int64       then value == 1
        else                  false
        end
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end

    class Array(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        return nil if value.nil?
        case value
        when ::String
          value.split(@separator).reject(&.empty?).map(&.strip)
        else
          value
        end
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end

    class Hash(T) < Base(T)
      def deserialize(value : FieldValue) : FieldValue
        return nil if value.nil?
        case value
        when ::String
          decoded = begin
            RailsSettings::Y.load(value)
          rescue
            nil
          end
          if decoded.is_a?(::Hash(::String, FieldValue))
            decoded
          else
            {} of ::String => FieldValue
          end
        else
          value
        end
      end

      def serialize(value : FieldValue) : FieldValue
        deserialize(value)
      end
    end
  end
end
