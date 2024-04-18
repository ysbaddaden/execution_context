module ExecutionContext
  # Runs a single fiber, isolated on its own dedicated thread.
  #
  # Concurrency is disabled. Calls to `#spawn` will create fibers in another
  # execution context (by default it's the default context). Any calls that
  # result in waiting (e.g. sleep, or socket read/write) will block the thread
  # since there are no other fibers to switch to.
  #
  # Isolated fibers can still communicate with other fibers running in other
  # execution contexts using standard means, such as `Channel(T)` and `Mutex`.
  #
  # Example:
  #
  # ```
  # ExecutionContext::Isolated.new("Gtk") { Gtk.main }
  # ```
  class Isolated
    include ExecutionContext
    include ExecutionContext::Scheduler

    getter event_loop : Crystal::EventLoop
    getter thread : Thread
    @main_fiber : Fiber?
    getter name : String
    getter? running : Bool = true

    def initialize(@name : String, @spawn_context = ExecutionContext.default, &@func : ->)
      @event_loop = Crystal::EventLoop.create
      @thread = uninitialized Thread

      wg = Thread::WaitGroup.new(1)

      Thread.new(@name) do |thread|
        @thread = thread
        thread.execution_context = self
        thread.current_scheduler = self
        thread.main_fiber.name = @name
        @main_fiber = thread.main_fiber
        wg.done

        run
      end

      wg.wait
    end

    @[AlwaysInline]
    def execution_context : Isolated
      self
    end

    def stack_pool : Fiber::StackPool
      raise NotImplementedError.new("No stack pool for isolated contexts")
    end

    @[AlwaysInline]
    def spawn(*, name : String? = nil, &block : ->) : Fiber
      @spawn_context.spawn(name: name, &block)
    end

    # :nodoc:
    @[AlwaysInline]
    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      @spawn_context.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      if fiber == @main_fiber
        if ExecutionContext.current == self
          # local enqueue: the event loop is the one pushing
        else
          # cross context communication (e.g. channel, mutex)
          @event_loop.interrupt_loop
        end
      else
        # concurrency is disabled
        raise RuntimeError.new("Can't enqueue #{fiber} in #{self}")
      end
    end

    protected def reschedule : Nil
      Crystal.trace "sched:reschedule"

      # always block, even when there's nothing to do; the fiber got rescheduled
      # so we likely wait on cross context communication, like a channel:
      @event_loop.run(blocking: true, block_when_empty: true)

      Crystal.trace "sched:resume"
    end

    protected def resume(fiber : Fiber) : Nil
      raise RuntimeError.new("Can't resume #{fiber} in #{self}")
    end

    private def run
      @func.call
    rescue ex
      message = "BUG: %s#run crashed with %s"
      Crystal::System.print_error_buffered(message, self.class.name, ex.class.name, backtrace: ex.backtrace)
    ensure
      @running = false
    end

    @[AlwaysInline]
    def inspect(io : IO) : Nil
      to_s(io)
    end

    def to_s(io : IO) : Nil
      io << "#<" << self.class.name << ":0x"
      object_id.to_s(io, 16)
      io << ' ' << name << " thread=0x"
      thread.@system_handle.to_s(io, 16)
      io << '>'
    end
  end
end
