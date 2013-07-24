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

module Hooks
  def self.included(base)
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
        if sym =~ /\Aaround_(.*)\z/
          before_hook = "before_#{$1}"
          after_hook = "after_#{$1}"

          define_hooks(before_hook, opts)
          define_hooks(after_hook, opts)

          opts = opts.merge(:before => chain(before_hook), :after => chain(after_hook))

          self._hooks[sym.to_s] = Sidekiq::Middleware::AroundChain(opts)
        else
          self._hooks[sym.to_s] = Sidekiq::Middleware::Chain(opts)
        end
      end
    end

    def chain(sym)
      self._hooks[sym.to_s]
    end

    alias_method :define_hook, :define_hooks
  end
end