# Add hooks onto any class
# Credit to https://github.com/apotonick/hooks
#
# Example:
#
#   class Person
#     define_hook :before_eating
#
#     before_eating :wash_hands
#     before_eating :locate_food
#     before_eating :sit_down
#
#     def wash_hands; :washed_hands; end
#     def locate_food; :located_food; false; end
#     def sit_down; :sat_down; end
#   end
#
#   result = person.run_hook(:before_eating)#

require 'sidekiq/middleware/chain'

module Sidekiq
  module Middleware    
    module Hooks
      module InheritableAttribute
        # Creates an inheritable attribute with accessors in the singleton class. Derived classes inherit the
        # attributes. This is especially helpful with arrays or hashes that are extended in the inheritance
        # chain. Note that you have to initialize the inheritable attribute.
        #
        # Example:
        #
        #   class Cat
        #     inheritable_attr :drinks
        #     self.drinks = ["Becks"]
        #
        #   class Garfield < Cat
        #     self.drinks << "Fireman's 4"
        #
        # and then, later
        #
        #   Cat.drinks      #=> ["Becks"]
        #   Garfield.drinks #=> ["Becks", "Fireman's 4"]
        def inheritable_attr(name)
          instance_eval %Q{
            def #{name}=(v)
              @#{name} = v
            end
            
            def #{name}
              return @#{name} unless superclass.respond_to?(:#{name}) and value = superclass.#{name}
              @#{name} ||= value.clone # only do this once.
            end
          }
        end
      end

      def self.included(base)
        if base.is_a? Module
          puts "MODULE"
        else
          puts "NOT MODULE"
        end

        if base.is_a? Module
          base.instance_eval do
            extend InheritableAttribute
            extend ClassMethods
            inheritable_attr :_hooks
            self._hooks= HookSet.new
          end
        end


        base.class_eval do
          extend InheritableAttribute
          extend ClassMethods
          inheritable_attr :_hooks
          self._hooks= HookSet.new
        end
      end

      module ClassMethods
        def define_hooks(*syms)
          opts = (syms.last.is_a? Hash) ? syms.pop : {}

          syms.each do |sym|
            sym = sym.to_s

            if sym =~ /\Aaround_(.*)\z/
              before_hook = "before_#{$1}"
              after_hook = "after_#{$1}"

              define_hooks(before_hook, opts)
              define_hooks(after_hook, opts)

              opts = opts.merge(:before => chain(before_hook), :after => chain(after_hook))

              self._hooks[sym] = Sidekiq::Middleware::AroundChain.new(opts)
            else
              self._hooks[sym] = Sidekiq::Middleware::Chain.new(opts)
            end

            # Callback
            # around_push do |*args|
            #   ...
            # end
            define_method(sym) do |&block|
              if block
                self._hooks[sym].add(block)
              end
            end

            # Access chain
            # around_push_chain do |chain|
            #   chain.add(...)
            # end
            define_method("#{sym}_chain") do |&block|
              chain = self._hooks[sym]

              if block
                block.call(chain)
              end

              chain
            end
          end
        end

        def chain(sym)
          self._hooks[sym.to_s]
        end

        alias_method :define_hook, :define_hooks
      end

      class HookSet < Hash
        def [](name)
          super(name.to_sym)
        end

        def []=(name, values)
          super(name.to_sym, values)
        end

        def clone
          super.tap do |cloned|
            each { |name, callbacks| cloned[name] = callbacks.clone }
          end
        end
      end
    end
  end
end