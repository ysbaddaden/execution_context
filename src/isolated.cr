abstract class ExecutionContext
  # TODO: shutdown the context when @fiber is dead
  class Isolated < SingleThreaded
    @spawn_context : ExecutionContext
    @fiber = uninitialized Fiber

    def initialize(name : String, @spawn_context = ExecutionContext.default, &block)
      super name, hijack: false
      @fiber = Fiber.new(name: name, execution_context: self, &block)
      enqueue @fiber
    end

    def spawn(name : String? = nil, same_thread : Bool = false, &block) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      @spawn_context.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      if fiber == @fiber || fiber == @main_fiber
        super
      else
        raise RuntimeError.new("Can't resume #{fiber} in #{self}")
      end
    end
  end
end
