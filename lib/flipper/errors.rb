module Flipper
  # Top level error that all other errors inherit from.
  class Error < StandardError; end

  # Raised when gate can not be found for an actor.
  class GateNotFound < Error
    def initialize(actor)
      super "Could not find gate for #{actor.inspect}"
    end
  end

  # Raised when attempting to declare a group name that has already been used.
  class DuplicateGroup < Error; end

  # Raised when an invalid value is set to a configuration property
  class InvalidConfigurationValue < Flipper::Error
    def initialize(message = nil)
      default = "Configuration value is not valid."
      super(message || default)
    end
  end

  # Raised by read-only diagnostics when a feature uses a gate that cannot
  # be diagnosed deterministically (registered Ruby groups, percentage of
  # time or a time/random expression) or when a requested attribute change
  # is invalid.
  class UnsupportedDiagnostic < Error; end
end
