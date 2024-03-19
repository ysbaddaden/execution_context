module ExecutionContext
  # TODO: consider a specific implementation with a mere @runnext : Fiber? property
  # TODO: shutdown the context when @fiber is dead
  class Isolated < SingleThreaded
    @spawn_context : ExecutionContext
    private getter! fiber : Fiber

    def initialize(name : String, @spawn_context = ExecutionContext.default, &block)
      super name, hijack: false
      @fiber = fiber = Fiber.new(name, self, &block)
      enqueue fiber
    end

    def spawn(*, name : String? = nil, &block : ->) : Fiber
      @spawn_context.spawn(name: name, &block)
    end

    @[Deprecated]
    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      @spawn_context.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      if fiber == @fiber || fiber == @main_fiber
        super
      else
        raise RuntimeError.new("Can't enqueue #{fiber} in #{self}")
      end
    end
  end
end
