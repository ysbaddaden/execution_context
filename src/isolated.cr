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

    getter event_loop : Crystal::EventLoop = Crystal::EventLoop.create
    getter thread : Thread
    @main_fiber : Fiber
    getter name : String
    getter? running : Bool = true

    def initialize(@name : String, @spawn_context = ExecutionContext.default, &@func : ->)
      @thread = uninitialized Thread
      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @enqueued = Atomic(Bool).new(false)
      @parked = false
      @main_fiber = uninitialized Fiber

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
      ExecutionContext.execution_contexts.push(self)
    end

    @[AlwaysInline]
    def execution_context : Isolated
      self
    end

    def stack_pool : Fiber::StackPool
      raise NotImplementedError.new("No stack pool for isolated contexts")
    end

    def stack_pool? : Fiber::StackPool?
      nil
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
          Crystal.trace :sched, "enqueue", fiber: fiber
        else
          # cross context communication (e.g. channel, mutex)
          Crystal.trace :sched, "enqueue", fiber: fiber, to_context: self

          @mutex.synchronize do
            @enqueued.set(true, :release)
            @condition.signal if @parked
          end
        end
      else
        # concurrency is disabled
        raise RuntimeError.new("Can't enqueue #{fiber} in #{self}")
      end
    end

    protected def reschedule : Nil
      Crystal.trace :sched, "reschedule"

      if blocking { @event_loop.run(blocking: true) }
        Crystal.trace :sched, "resume"
        return
      end

      # avoid the mutex if another thread already enqueued
      return if @enqueued.swap(false, :acquire)

      @mutex.synchronize do
        # avoid a race condition with #enqueue
        return if @enqueued.swap(false, :relaxed)

        Crystal.trace :sched, "parking"
        @parked = true

        @condition.wait(@mutex)

        @parked = false
        @enqueued.set(false, :relaxed)
      end

      if @main_fiber.dead?
        raise "BUG: can't resume dead fiber: #{@main_fiber}"
      end

      Crystal.trace :sched, "resume"
    end

    private def blocking(&)
      @blocked = true
      yield
    ensure
      @blocked = false
    end

    protected def resume(fiber : Fiber) : Nil
      raise RuntimeError.new("Can't resume #{fiber} in #{self}")
    end

    private def run
      Crystal.trace :sched, "started"
      @func.call
    rescue exception
      Crystal::System.print_error_buffered(
        "BUG: %s#run [%s] crashed with %s (%s)",
        self.class.name,
        @name,
        exception.message,
        exception.class.name,
        backtrace: exception.backtrace)
    ensure
      @running = false
      ExecutionContext.execution_contexts.delete(self)
    end

    @[AlwaysInline]
    def inspect(io : IO) : Nil
      to_s(io)
    end

    def to_s(io : IO) : Nil
      io << "#<" << self.class.name << ":0x"
      object_id.to_s(io, 16)
      io << ' ' << name << '>'
    end

    def status : String
      if !@running
        "terminated"
      elsif @blocked
        "event_loop"
      elsif @parked
        "parked"
      else
        "running"
      end
    end
  end
end
