module Sidekiq
  # Middleware is code configured to run before/after
  # a message is processed.  It is patterned after Rack
  # middleware. Middleware exists for the client side
  # (pushing jobs onto the queue) as well as the server
  # side (when jobs are actually processed).
  #
  # To add middleware for the client:
  #
  # Sidekiq.configure_client do |config|
  #   config.client_middleware do |chain|
  #     chain.add MyClientHook
  #   end
  # end
  #
  # To modify middleware for the server, just call
  # with another block:
  #
  # Sidekiq.configure_server do |config|
  #   config.server_middleware do |chain|
  #     chain.add MyServerHook
  #     chain.remove ActiveRecord
  #   end
  # end
  #
  # To insert immediately preceding another entry:
  #
  # Sidekiq.configure_client do |config|
  #   config.client_middleware do |chain|
  #     chain.insert_before ActiveRecord, MyClientHook
  #   end
  # end
  #
  # To insert immediately after another entry:
  #
  # Sidekiq.configure_client do |config|
  #   config.client_middleware do |chain|
  #     chain.insert_after ActiveRecord, MyClientHook
  #   end
  # end
  #
  # This is an example of a minimal server middleware:
  #
  # class MyServerHook
  #   def call(worker_instance, msg, queue)
  #     puts "Before work"
  #     yield
  #     puts "After work"
  #   end
  # end
  #
  # This is an example of a minimal client middleware:
  #
  # class MyClientHook
  #   def call(worker_class, msg, queue)
  #     puts "Before push"
  #     yield
  #     puts "After push"
  #   end
  # end
  #
  module Middleware
    class Chain
      attr_reader :entries
      attr_reader :options

      def initialize(options={})
        options[:halt_on_false] = true if not options.include?(:halt_on_false)

        @entries = []
        @options = options
        yield self if block_given?
      end

      def remove(hid)
        entries.delete_if { |entry| entry.hid and entry.hid == hid }
      end

      def add(callable=nil, hid=nil, &block)
        unless hid and exists?(hid)
          entries << Entry.new(callable, hid, &block)
        end
      end

      def insert_before(oldhid, callable=nil, newhid=nil, &block)
        # Remove the entry if it already exists
        new_entry = remove_old(newhid) || Entry.new(callable, newhid, &block)
        i = entries.find_index { |entry| entry.hid == oldhid } || 0
        entries.insert(i, new_entry)
      end

      def insert_after(oldhid, callable=nil, newhid=nil, &block)
        # Remove the entry if it already exists
        new_entry = remove_old(newhid) || Entry.new(callable, newhid, &block)
        i = entries.find_index { |entry| entry.hid == oldhid } || entries.count - 1
        entries.insert(i+1, new_entry)
      end

      def exists?(hid)
        if hid
          entries.any? { |entry| entry.hid and entry.hid == hid }
        end
      end

      def clear
        entries.clear
      end

      def invoke(*args)
        entries.each do |callable|
          if callable.call(*args) == false and @options[:halt_on_false]
            return false
          end
        end

        true
      end

      # Pass this an array of arrays of arguments!
      def invoke_bulk(*args_array)
        args_array.map do |args|
          invoke_chain(*args)
        end
      end

      private

      def remove_old(hid)
        if hid and i = entries.index { |entry| entry.hid and entry.hid == hid }
          entries.delete_at(i)
        end
      end
    end

    class AroundChain < Chain
      def invoke(*args, &final_action)
        # Run the before callback. If halt_on_false is true, return early
        if options[:before]
          if options[:before].invoke(*args) == false and options[:halt_on_false]
            return
          end
        end

        chain = entries.dup
        value = nil
        traverse_chain = lambda do
          if chain.empty?
            value = final_action.call
          else
            chain.shift.call(*args, &traverse_chain)
          end
        end

        traverse_chain.call

        # Run the after callback
        if options[:after]
          options[:after].invoke(*args)
        end

        value
      end

      def invoke_bulk(*args_array, &final_action)
        success = Array.new(args_array.size, false)

        value = nil
        next_chain = lambda do |i|
          if i < success.size
            chain = entries.dup

            # Run the before callback. If halt_on_false is true, skip to the next item
            if options[:before]
              if options[:before].invoke(*args_array[i]) == false and @options[:halt_on_false]
                return next_chain(i+1)
              end
            end

            traverse_chain = lambda do
              if chain.empty?
                success[i] = true
                val = next_chain.call(i+1)
              else
                chain.shift.call(*args_array[i], &traverse_chain)
              end
            end

            # Even if something in the chain failed to yield, just go to the next chain
            if not success[i]
              next_chain(i+1)
            end
          else
            successful_args = args_array.each_with_index.map {|args, i| args if success[i]}.compact

            # Run the final action on all items that succeeded
            value = final_action(*args_array.each_with_index.map {|args, i| args if success[i]}.compact)

            if options[:after]
              successful_args.each do |args|
                options[:after].invoke(*args)
              end
            end
          end
        end

        next_chain.call(0)
        value
      end
    end

    class Entry
      attr_reader :hid
      def initialize(callable=nil, hid=nil, &block)
        @hid = hid
        @callable  = (callable || block)
      end

      def call(*args, &block)
        @callable.call(*args, &block)
      end
    end

    class OldChain
      def initialize(new_chain=nil)
        @new_chain = new_chain || AroundChain.new
      end

      [:remove, :exists?, :clear, :retrieve].each do |m|
        define_method(m) do |*args, &block|
          @new_chain.send(m, *args, &block)
        end 
      end

      def add(klass, *kargs)
        @new_chain.add(wrap_klass(klass, *args), klass)
      end

      def insert_before(oldklass, newklass, *args)
        @new_chain.insert_before(oldklass, wrap_klass(newklass, *args), newklass)
      end

      def insert_after(oldklass, newklass, *args)
        @new_chain.insert_after(oldklass, wrap_klass(newklass, *args), newklass)
      end

      def retrieve
        @new_chain.entries
      end

      private

      def wrap_klass(*kargs)
        Proc.new do |*args, &block|
          klass.new(*kargs).call(*args, &block)
        end
      end
    end
  end
end
