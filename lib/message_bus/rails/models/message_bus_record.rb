# frozen_string_literal: true

gem 'activerecord', '>= 6' # Require activerecord gem v6+

module MessageBus
  module Rails
    class MessageBusRecord < ::ActiveRecord::Base
      module DisableMBLogs
        def log(...)
          yield if block_given?
        end
      end

      self.abstract_class = true

      connects_to database: { writing: :message_bus, reading: :message_bus }

      unless ENV['MESSAGE_BUS_ENABLE_LOGS'] == 'true'
        class << self
          alias old_connection connection

          def connection
            old_connection.tap do |conn|
              conn.singleton_class.include(DisableMBLogs) unless conn.singleton_class < DisableMBLogs
            end
          end
        end
      end
    end
  end
end
