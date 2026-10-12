# RequestCache — кэш настроек на время «запроса».
#
# Ruby-версия хранит состояние в Thread.current (CurrentAttributes /
# request_store). В Crystal нет thread/fiber-local хранилища — состояние
# классовое: обёртка запроса обязана звать disable! (или Middleware#call)
# в конце. Семантика enable!/disable!/reset/all_settings — 1:1.

module RailsSettings
  class RequestCache
    @@enabled = false
    @@settings : Hash(::String, FieldValue)?

    def self.enable! : Nil
      @@enabled = true
    end

    def self.disable! : Nil
      @@enabled = false
      @@settings = nil
    end

    def self.enabled? : Bool
      @@enabled
    end

    def self.reset : Nil
      @@settings = nil
    end

    def self.all_settings : Hash(::String, FieldValue)?
      @@settings if @@enabled
    end

    def self.all_settings=(val : Hash(::String, FieldValue)?) : Hash(::String, FieldValue)?
      @@settings = val
    end
  end

  # Аналог RailsSettings::Middleware: включает RequestCache на время
  # обработки запроса (Rack-цепочки в Crystal-порту нет — обёртка блоком).
  class Middleware
    def initialize(&@app)
    end

    def call
      RequestCache.enable!
      result = @app.call
      RequestCache.disable!
      result
    end
  end
end
