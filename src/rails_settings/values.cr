# FieldValue / коэрсинг / YAML-кодек, байт-совместимый с Ruby Psych.
#
# Колонка settings.value хранит YAML ровно в том виде, в каком его пишет
# Ruby (rails-settings-cached ⇒ YAML.dump): строки с квотингом по правилам
# Psych, BigDecimal в marshal-формате "!ruby/object:BigDecimal N:0.ddde+X".

require "yaml"
require "json"
require "big"

module RailsSettings
  alias FieldValue = Nil | Bool | Int32 | Int64 | Float64 | BigDecimal | String | Symbol |
                     ::Array(String) | ::Array(FieldValue) | Hash(::String, FieldValue) |
                     Hash(Symbol, FieldValue)
  alias DefaultArg = FieldValue | Proc(FieldValue)

  module F
    # identity для proc-дефолтов: `-> { F.v(1 + 1) }` ⇒ Proc(FieldValue)
    # (.as нужен: иначе proc-литерал инферится как Proc(Int32) и не матчится
    # на Proc(FieldValue))
    def self.v(x : FieldValue) : FieldValue
      x.as(FieldValue)
    end

    # Коэрсинг литералов из макроса `field` (default:, options).
    # Оверлоады не пересекаются: скаляры / массивы / хеши.
    def self.d(v : Nil | Bool | Int32 | Int64 | Float64 | BigDecimal | String | Symbol) : FieldValue
      v
    end

    def self.d(v : ::Array(A)) : FieldValue forall A
      out = [] of FieldValue
      v.each { |e| out << d(e) }
      out
    end

    def self.d(v : Hash(K, V)) : FieldValue forall K, V
      out = {} of K => FieldValue
      v.each { |k, e| out[k] = d(e) }
      out
    end

    def self.default(v : Nil | Bool | Int32 | Int64 | Float64 | BigDecimal | String | Symbol | Proc(FieldValue)) : DefaultArg
      v
    end

    def self.default(v : ::Array(A)) : DefaultArg forall A
      d(v)
    end

    def self.default(v : Hash(K, V)) : DefaultArg forall K, V
      d(v)
    end

    # Ленивые преобразования в духе Ruby String#to_i / #to_f / .to_d:
    # разбирают числовой префикс, при неудаче дают 0.
    def self.to_i(v : FieldValue) : Int64
      case v
      when Int64         then v
      when Int32         then v.to_i64
      when Float64       then v.floor.to_i64
      when BigDecimal    then v.to_f64.floor.to_i64
      when String        then lenient_to_i(v)
      when Bool          then v ? 1_i64 : 0_i64
      else                    0_i64
      end
    end

    def self.to_f(v : FieldValue) : Float64
      case v
      when Float64       then v
      when Int32, Int64  then v.to_f
      when BigDecimal    then v.to_f64
      when String        then lenient_to_f(v)
      when Bool          then v ? 1.0 : 0.0
      else                    0.0
      end
    end

    def self.to_d(v : FieldValue) : BigDecimal
      case v
      when BigDecimal    then v
      when Int32, Int64  then BigDecimal.new(v.to_s)
      when Float64       then BigDecimal.new(v.to_s)
      when String
        begin
          BigDecimal.new(number_prefix(v))
        rescue
          BigDecimal.new(0)
        end
      else
        BigDecimal.new(0)
      end
    end

    def self.lenient_to_i(s : String) : Int64
      m = s.match(/\A\s*([+-]?\d+)/)
      return 0_i64 unless m
      value = m[1].to_i64?
      overflow = value.nil?
      value || (m[1].starts_with?('-') ? Int64::MIN : Int64::MAX)
    end

    def self.lenient_to_f(s : String) : Float64
      m = s.match(/\A\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/)
      return 0.0 unless m
      m[1].to_f? || 0.0
    end

    def self.number_prefix(s : String) : String
      m = s.match(/\A\s*([+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)/)
      m ? m[1] : "0"
    end
  end

  module Y
    # --- dump (Psych-совместимо) ------------------------------------------

    def self.dump(v : FieldValue) : String
      String.build { |io| dump_root(io, v) }
    end

    private def self.dump_root(io : IO, v : FieldValue) : Nil
      case v
      when Nil        then io << "---\n"
      when Bool       then io << "--- " << v << "\n"
      when Int32      then io << "--- " << v << "\n"
      when Int64      then io << "--- " << v << "\n"
      when Float64    then io << "--- " << v << "\n"
      when BigDecimal then io << "--- !ruby/object:BigDecimal " << bd_marshal(v) << "\n"
      when String     then io << root_string(v)
      when Symbol     then io << "--- :" << v << "\n"
      when ::Array
        if v.empty?
          io << "--- []\n"
        else
          io << "---\n"
          dump_seq(io, v, 0)
        end
      when Hash
        if v.empty?
          io << "--- {}\n"
        else
          io << "---\n"
          dump_hash(io, v, 0)
        end
      end
    end

    private def self.root_string(s : String) : String
      return "--- " + scalar(s) + "\n" unless s.includes?('\n')
      lines = s.split('\n')
      if s.ends_with?('\n')
        String.build do |io|
          io << "--- |\n"
          lines[0...-1].each { |l| io << "  " << l << "\n" }
        end
      else
        String.build do |io|
          io << "--- |-\n"
          lines.each { |l| io << "  " << l << "\n" }
        end
      end
    end

    private def self.dump_hash(io : IO, h : Hash, indent : Int32) : Nil
      pad = " " * indent
      h.each do |k, v|
        key = hash_key(k)
        case v
        when Hash
          if v.empty?
            io << pad << key << ": {}\n"
          else
            io << pad << key << ":\n"
            dump_hash(io, v, indent + 2)
          end
        when ::Array
          if v.empty?
            io << pad << key << ": []\n"
          else
            io << pad << key << ":\n"
            dump_seq(io, v, indent)
          end
        when String
          if v.includes?('\n')
            io << pad << key << ": |\n"
            v.split('\n')[0...-1].each { |l| io << (" " * (indent + 2)) << l << "\n" }
          else
            io << pad << key << ": " << scalar(v) << "\n"
          end
        when Symbol
          io << pad << key << ": :" << v << "\n"
        when BigDecimal
          io << pad << key << ": !ruby/object:BigDecimal " << bd_marshal(v) << "\n"
        else
          io << pad << key << ": " << v << "\n"
        end
      end
    end

    private def self.dump_seq(io : IO, a : ::Array, indent : Int32) : Nil
      pad = " " * indent
      a.each do |v|
        case v
        when String
          if v.includes?('\n')
            io << pad << "- |\n"
            v.split('\n')[0...-1].each { |l| io << (" " * (indent + 2)) << l << "\n" }
          else
            io << pad << "- " << scalar(v) << "\n"
          end
        when Symbol
          io << pad << "- :" << v << "\n"
        when Hash
          if v.empty?
            io << pad << "- {}\n"
          else
            inner = " " * (indent + 2)
            first = true
            v.each do |k, val|
              if first
                io << pad << "- " << hash_key(k) << ": " << inline_value(val) << "\n"
                first = false
              else
                io << inner << hash_key(k) << ": " << inline_value(val) << "\n"
              end
            end
          end
        else
          io << pad << "- " << v << "\n"
        end
      end
    end

    private def self.inline_value(v : FieldValue) : String
      case v
      when String  then scalar(v)
      when Symbol  then ":#{v}"
      else              v.to_s
      end
    end

    # Скаляр строки: plain / одинарные / двойные кавычки — по правилам Psych.
    def self.scalar(s : String) : String
      return "''" if s.empty?
      return dq(s) if needs_double?(s)
      if ambiguous?(s) || s.ends_with?(' ') || s.ends_with?(':') ||
         s.includes?(": ") || s.includes?(" #")
        sq(s)
      else
        s
      end
    end

    private def self.needs_double?(s : String) : Bool
      return true if s.size == 1 && "~-?yYnN".includes?(s[0])
      return true if s[0]? == ' '
      first = s[0]? || ' '
      return true if "-+.!&*[]{}#|>%@`=?".includes?(first)
      s.each_byte do |b|
        return true if b < 0x20
      end
      false
    end

    private def self.ambiguous?(s : String) : Bool
      bool_re = /\A(?:y|Y|yes|Yes|YES|n|N|no|No|NO|true|True|TRUE|false|False|FALSE|on|On|ON|off|Off|OFF)\z/
      null_re = /\A(?:null|Null|NULL|~)\z/
      int_re  = /\A[-+]?[\d_]+\z|\A[-+]?0[xX][0-9a-fA-F_]+\z|\A[-+]?0[bB][01_]+\z|\A[-+]?[\d_,]+\z/
      float_re = /\A[-+]?\d[\d_]*\.[\d_]*(?:[eE][-+]?\d+)?\z/
      sext_re = /\A[-+]?\d+:\d+(?::\d+(?:\.\d+)?)?\z/
      bool_re.match(s) != nil || null_re.match(s) != nil || int_re.match(s) != nil ||
        float_re.match(s) != nil || sext_re.match(s) != nil
    end

    # Ключ маппинга: символ-ключи Ruby пишет с двоеточием (":foo:").
    private def self.hash_key(k) : String
      k.is_a?(Symbol) ? ":#{k}" : scalar(k.as(::String))
    end

    private def self.dq(s : String) : String
      String.build do |io|
        io << '"'
        s.each_char do |c|
          case c
          when '"'  then io << "\\\""
          when '\\' then io << "\\\\"
          when '\t' then io << "\\t"
          when '\n' then io << "\\n"
          when '\r' then io << "\\r"
          else
            if c.ord < 0x20
              io << "\\x" + c.ord.to_s(16).rjust(2, '0').upcase
            else
              io << c
            end
          end
        end
        io << '"'
      end
    end

    private def self.sq(s : String) : String
      "'#{s.gsub('\'', "''")}'"
    end

    # Marshal-строка BigDecimal, как пишет Ruby _dump: "N:0.ddde±X",
    # N = 9 × число «лимбов» (эмпирическая формула, воспроизводит Psych
    # на всех контрольных значениях, см. oracle).
    def self.bd_marshal(v : BigDecimal) : String
      s = v.to_s
      sign = ""
      idx = 0
      if s[0]? == '-' || s[0]? == '+'
        sign = "-" if s[0] == '-'
        idx = 1
      end
      body = s[idx..]
      dot = body.index('.')
      int_part = dot ? body[0...dot] : body
      frac_part = dot ? body[(dot + 1)..] : ""
      digits = (int_part + frac_part).lstrip('0')
      digits = digits.rstrip('0')
      digits = "0" if digits.empty?
      # позиция первой значащей цифры: (int_digits - leading_zeros_of_int)
      lz = int_part.size - int_part.lstrip('0').size
      exp = int_part.size - lz
      sig_len = digits.size
      int_digits = exp > 0 ? exp : 0
      frac_digits = sig_len - int_digits
      limbs = int_digits > 0 && frac_digits > 0 ? ((sig_len + 8) // 9) + 1 : ((sig_len + 8) // 9)
      "#{sign}#{limbs * 9}:0.#{digits}e#{exp}"
    end

    # --- load --------------------------------------------------------------

    def self.load(raw : String?) : FieldValue
      return nil if raw.nil?
      s = raw.not_nil!
      if s.starts_with?("--- !ruby/object:BigDecimal ")
        payload = s.split(' ', 3)[2]?
        return bd_unmarshal(payload) if payload && !payload.empty?
      end
      convert_yaml(YAML.parse(s).raw)
    end

    private def self.convert_yaml(raw) : FieldValue
      case raw
      when Nil, Bool, Int64, Float64 then raw
      when String
        # YAML-«символ» Ruby (":name") в Crystal-порт строке без двоеточия
        if raw.starts_with?(':') && raw.size > 1 && !raw.includes?(' ')
          raw[1..]
        else
          raw
        end
      when Array(YAML::Any)
        out = [] of FieldValue
        raw.each { |e| out << convert_yaml(e.raw) }
        out
      when Hash(YAML::Any, YAML::Any)
        out = {} of ::String => FieldValue
        raw.each do |k, e|
          # YAML-«символ»-ключ (":foo") → "foo"
          key = k.to_s
          key = key[1..] if key.starts_with?(':') && key.size > 1
          out[key] = convert_yaml(e.raw)
        end
        out
      else
        raw.to_s
      end
    end

    def self.bd_unmarshal(payload : String) : BigDecimal
      # "N:0.29e1" → 2.9 (префикс-точность игнорируется, как в BigDecimal._load)
      body = payload.strip.split(':', 2)[1]? || payload.strip
      begin
        BigDecimal.new(body)
      rescue
        BigDecimal.new(0)
      end
    end

    # --- кэш-кодек (JSON, значения String в ActiveSupport::Cache) ----------

    def self.cache_dump(h : Hash(::String, FieldValue)) : String
      to_jsonable(h).to_json
    end

    def self.cache_load(json : String) : Hash(::String, FieldValue)
      out = {} of ::String => FieldValue
      JSON.parse(json).as_h.each do |k, v|
        out[k] = from_jsonable(v)
      end
      out
    end

    private def self.to_jsonable(v : FieldValue) : JSON::Any::Type
      case v
      when Nil, Bool, String  then v
      when Int32              then v.to_i64
      when Int64              then v
      when Float64            then v
      when BigDecimal         then v.to_f64
      when Symbol             then v.to_s
      when ::Array
        v.map { |e| JSON::Any.new(to_jsonable(e)) }
      when Hash
        h = {} of ::String => JSON::Any
        v.each { |k, e| h[k.to_s] = JSON::Any.new(to_jsonable(e)) }
        h
      end
    end

    private def self.from_jsonable(v : JSON::Any) : FieldValue
      case raw = v.raw
      when Nil, Bool, Int64, Float64, String then raw
      when Array(JSON::Any)
        out = [] of FieldValue
        raw.each { |e| out << from_jsonable(e) }
        out
      when Hash(::String, JSON::Any)
        out = {} of ::String => FieldValue
        raw.each { |k, e| out[k] = from_jsonable(e) }
        out
      else
        raw.to_s
      end
    end
  end
end
