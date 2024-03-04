abstract class ExecutionContext
  class Isolated < SingleThreaded
    @spawn_context : ExecutionContext
    @fiber = uninitialized Fiber

    def initialize(name : String, @spawn_context = ExecutionContext.default, &block)
      super name
      @fiber = Fiber.new(name: name, execution_context: self, &block)
      enqueue @fiber
    end

    def spawn(name : String? = nil, &block) : Fiber
      @spawn_context.spawn(name, &block)
    end

    # :nodoc:
    def spawn(name : String?, same_thread : Bool, &block : ->) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      self.spawn(name, &block)
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
