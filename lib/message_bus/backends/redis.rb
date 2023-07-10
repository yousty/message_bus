# frozen_string_literal: true

require 'redis'
require 'digest'

module MessageBus
  module Backends
    # The Redis backend stores published messages in Redis sorted sets (using
    # ZADD, where the score is the message ID), one for each channel (where
    # the full message is stored), and also in a global backlog as a simple
    # pointer to the respective channel and channel-specific ID. In addition,
    # publication publishes full messages to a Redis PubSub channel; this is
    # used for actively subscribed message_bus servers to consume published
    # messages in real-time while connected and forward them to subscribers,
    # while catch-up is performed from the backlog sorted sets.
    #
    # Message lookup is performed using the Redis ZRANGEBYSCORE command, and
    # backlog trimming uses ZREMRANGEBYSCORE. The last used channel-specific
    # and global IDs are stored as integers in simple Redis keys and
    # incremented on publication.
    #
    # Publication is implemented using a Lua script to ensure that it is
    # atomic and messages are not corrupted by parallel publication.
    #
    # @note This backend diverges from the standard in Base in the following ways:
    #
    #   * `max_backlog_age` options in this backend differ from the behaviour of
    #     other backends, in that either no messages are removed (when
    #     publications happen more regularly than this time-frame) or all
    #     messages are removed (when no publication happens during this
    #     time-frame).
    #
    # @see Base general information about message_bus backends
    class Redis < Base
      class BackLogOutOfOrder < StandardError
        attr_accessor :highest_id

        def initialize(highest_id)
          @highest_id = highest_id
        end
      end

      # @param [Hash] redis_config in addition to the options listed, see https://github.com/redis/redis-rb for other available options
      # @option redis_config [Logger] :logger a logger to which logs will be output
      # @option redis_config [Boolean] :enable_redis_logger (false) whether or not to enable logging by the underlying Redis library
      # @option redis_config [Integer] :clear_every (1) the interval of publications between which the backlog will not be cleared
      # @param [Integer] max_backlog_size the largest permitted size (number of messages) for per-channel backlogs; beyond this capacity, old messages will be dropped.
      def initialize(redis_config = {}, max_backlog_size = 1000)
        @redis_config = redis_config.dup
        @clear_every = redis_config.delete(:clear_every) || 1
        @logger = @redis_config[:logger]
        unless @redis_config[:enable_redis_logger]
          @redis_config[:logger] = nil
        end
        @max_backlog_size = max_backlog_size
        @max_global_backlog_size = 2000
        @lock = Mutex.new
        @pub_redis = nil
        @subscribed = false
        # after 7 days inactive backlogs will be removed
        @max_backlog_age = 604800
      end

      # Reconnects to Redis; used after a process fork, typically triggered by a forking webserver
      # @see Base#after_fork
      def after_fork
        @pub_redis&.disconnect!
      end

      # (see Base#reset!)
      def reset!
        pub_redis.keys("__mb_*").each do |k|
          pub_redis.del k
        end
      end

      # (see Base#destroy)
      def destroy
        @pub_redis&.disconnect!
      end

      # Deletes all backlogs and their data. Does not delete ID pointers, so new publications will get IDs that continue from the last publication before the expiry. Use with extreme caution.
      # @see Base#expire_all_backlogs!
      def expire_all_backlogs!
        pub_redis.keys("__mb_*backlog_n").each do |k|
          pub_redis.del k
        end
      end

      # (see Base#publish)
      def publish(channel, data, opts = nil)
        max_backlog_age = (opts && opts[:max_backlog_age]) || self.max_backlog_age
        max_backlog_size = (opts && opts[:max_backlog_size]) || self.max_backlog_size

        redis = pub_redis
        backlog_id_key = backlog_id_key(channel)
        backlog_key = backlog_key(channel)

        backlog_id = nil
        redis.multi do
          global_id = redis.incr(global_id_key)
          backlog_id = redis.incr(backlog_id_key)
          msg = MessageBus::Message.new global_id, backlog_id, channel, data
          payload = msg.encode
          redis.zadd(backlog_key, backlog_id, payload)
          redis.expire(backlog_key, max_backlog_age)
          redis.zadd(global_backlog_key, global_id, payload)
          redis.expire(global_backlog_key, max_backlog_age)
          redis.publish(redis_channel_name, payload)
          redis.expire(backlog_id_key, max_backlog_age)
          if backlog_id > max_backlog_size && backlog_id % clear_every == 0
            redis.zremrangebyscore(backlog_key, '1', (backlog_id - max_backlog_size).to_s)
          end
          if global_id > max_global_backlog_size && global_id % clear_every == 0
            redis.zremrangebyscore(global_backlog_key, '1', (global_id - max_global_backlog_size).to_s)
          end
        end
        backlog_id
      end

      # (see Base#last_id)
      def last_id(channel)
        backlog_id_key = backlog_id_key(channel)
        pub_redis.get(backlog_id_key).to_i
      end

      # (see Base#last_ids)
      def last_ids(*channels)
        return [] if channels.size == 0
        backlog_id_keys = channels.map { |c| backlog_id_key(c) }
        pub_redis.mget(*backlog_id_keys).map(&:to_i)
      end

      # (see Base#backlog)
      def backlog(channel, last_id = 0)
        redis = pub_redis
        backlog_key = backlog_key(channel)
        items = redis.zrangebyscore backlog_key, last_id.to_i + 1, "+inf"

        items.map do |i|
          MessageBus::Message.decode(i)
        end
      end

      # (see Base#global_backlog)
      def global_backlog(last_id = 0)
        items = pub_redis.zrangebyscore global_backlog_key, last_id.to_i + 1, "+inf"

        items.map! do |i|
          message = MessageBus::Message.decode(i)
          get_message(message.channel, message.message_id)
        end

        items.compact!
        items
      end

      # (see Base#get_message)
      def get_message(channel, message_id)
        redis = pub_redis
        backlog_key = backlog_key(channel)

        items = redis.zrangebyscore backlog_key, message_id, message_id
        if items && items[0]
          MessageBus::Message.decode(items[0])
        else
          nil
        end
      end

      # (see Base#subscribe)
      def subscribe(channel, last_id = nil)
        # trivial implementation for now,
        #   can cut down on connections if we only have one global subscriber
        raise ArgumentError unless block_given?

        if last_id
          # we need to translate this to a global id, at least give it a shot
          #   we are subscribing on global and global is always going to be bigger than local
          #   so worst case is a replay of a few messages
          message = get_message(channel, last_id)
          if message
            last_id = message.global_id
          end
        end
        global_subscribe(last_id) do |m|
          yield m if m.channel == channel
        end
      end

      # (see Base#global_unsubscribe)
      def global_unsubscribe
        begin
          new_redis = new_redis_connection
          new_redis.publish(redis_channel_name, UNSUB_MESSAGE)
        ensure
          new_redis&.disconnect!
          @subscribed = false
        end
      end

      # (see Base#global_subscribe)
      def global_subscribe(last_id = nil, &blk)
        raise ArgumentError unless block_given?

        highest_id = last_id

        clear_backlog = lambda do
          retries = 4
          begin
            highest_id = process_global_backlog(highest_id, retries > 0, &blk)
          rescue BackLogOutOfOrder => e
            highest_id = e.highest_id
            retries -= 1
            sleep(rand(50) / 1000.0)
            retry
          end
        end

        begin
          global_redis = new_redis_connection

          if highest_id
            clear_backlog.call(&blk)
          end

          global_redis.subscribe(redis_channel_name) do |on|
            on.subscribe do
              if highest_id
                clear_backlog.call(&blk)
              end
              @subscribed = true
            end

            on.unsubscribe do
              @subscribed = false
            end

            on.message do |_c, m|
              if m == UNSUB_MESSAGE
                @subscribed = false
                global_redis.unsubscribe
                return
              end
              m = MessageBus::Message.decode m

              # we have 3 options
              #
              # 1. message came in the correct order GREAT, just deal with it
              # 2. message came in the incorrect order COMPLICATED, wait a tiny bit and clear backlog
              # 3. message came in the incorrect order and is lowest than current highest id, reset

              if highest_id.nil? || m.global_id == highest_id + 1
                highest_id = m.global_id
                yield m
              else
                clear_backlog.call(&blk)
              end
            end
          end
        rescue => error
          @logger.warn "#{error} subscribe failed, reconnecting in 1 second. Call stack #{error.backtrace.join("\n")}"
          sleep 1
          global_redis&.disconnect!
          retry
        ensure
          global_redis&.disconnect!
        end
      end

      private

      def new_redis_connection
        config = @redis_config.filter do |k, v|
          # This is not ideal, required for Redis gem version 5
          # redis-client no longer accepts arbitrary params
          # anything unknown will error out.
          # https://github.com/redis-rb/redis-client/blob/4c8e05acfb3477c1651138a4924616e79e6116f2/lib/redis_client/config.rb#L21-L39
          #
          #
          # We should be doing the opposite and allowlisting params
          # or splitting the object up. Starting with the smallest change that is backwards compatible
          ![
            :backend,
            :logger,
            :long_polling_enabled,
            :long_polling_interval,
            :backend_options,
            :base_route,
            :client_message_filters,
            :site_id_lookup,
            :group_id_lookup,
            :user_id_lookup,
            :transport_codec
          ].include?(k)
        end
        ::Redis.new(config)
      end

      # redis connection used for publishing messages
      def pub_redis
        @pub_redis ||= new_redis_connection
      end

      def redis_channel_name
        db = @redis_config[:db] || 0
        "_message_bus_#{db}"
      end

      def backlog_key(channel)
        "__mb_backlog_n_#{channel}"
      end

      def backlog_id_key(channel)
        "__mb_backlog_id_n_#{channel}"
      end

      def global_id_key
        "__mb_global_id_n"
      end

      def global_backlog_key
        "__mb_global_backlog_n"
      end

      def process_global_backlog(highest_id, raise_error)
        if highest_id > pub_redis.get(global_id_key).to_i
          highest_id = 0
        end

        global_backlog(highest_id).each do |old|
          if highest_id + 1 == old.global_id
            yield old
            highest_id = old.global_id
          else
            raise BackLogOutOfOrder.new(highest_id) if raise_error

            if old.global_id > highest_id
              yield old
              highest_id = old.global_id
            end
          end
        end

        highest_id
      end

      def is_readonly?
        key = "__mb_is_readonly"

        begin
          # disconnect to force a reconnect when attempting to set the key
          # in case we are not connected to the correct server
          # which can happen when sharing ips
          pub_redis.disconnect!
          pub_redis.set(key, '1')
          false
        rescue ::Redis::CommandError => e
          return true if e.message =~ /^READONLY/
        end
      end

      MessageBus::BACKENDS[:redis] = self
    end
  end
end
