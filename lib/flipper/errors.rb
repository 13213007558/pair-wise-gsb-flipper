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

  # Raised when an adapter is asked to write a gate it cannot persist (for
  # example, a deny gate written to an adapter that does not support it).
  class UnsupportedGateDataType < Flipper::Error
    def initialize(data_type, adapter = nil)
      message = "#{data_type.inspect} is not supported by this adapter"
      message = "#{message} (#{adapter.class.name})" if adapter
      super(message)
    end
  end

  # Raised when an emergency deny (actor/group) is written through an adapter
  # that cannot persist it. Only adapters that store the full gate hash
  # (currently the Memory adapter and wrappers around it) support deny gates.
  class DenyNotSupported < Flipper::Error
    def initialize(adapter = nil)
      message = "deny actors/groups are not supported by this adapter"
      message = "#{message} (#{adapter.class.name})" if adapter
      super(message)
    end
  end
end
