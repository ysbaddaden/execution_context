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
      @waiting = Atomic(Bool).new(false)
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
      Crystal.trace :sched, "enqueue", fiber: fiber, context: self

      unless fiber == @main_fiber
        raise RuntimeError.new("ERROR: concurrency is disabled in isolated contexts")
      end

      @mutex.synchronize do
        # "enqueue" the fiber
        @enqueued.set(true, :release)

        # wake up the blocked thread
        if @waiting.get(:acquire)
          @event_loop.interrupt
        elsif @parked
          @condition.signal
        else
          # race: enqueued _before_ the thread entered #reschedule
        end
      end
    end

    protected def reschedule : Nil
      Crystal.trace :sched, "reschedule"

      # wait on the evloop
      @waiting.set(true, :release)

      queue = Queue.new

      loop do
        # check for parallel enqueue
        if @enqueued.get(:acquire)
          @waiting.set(false, :release)
          @enqueued.set(false, :release)
          Crystal.trace :sched, "resume"
          return
        end

        if @event_loop.run(pointerof(queue), blocking: true)
          if fiber = queue.pop?
            unless fiber == @main_fiber && queue.empty?
              raise RuntimeError.new("ERROR: concurrency is disabled in isolated contexts")
            end
            @waiting.set(false, :release)
            @enqueued.set(false, :release)
            Crystal.trace :sched, "resume"
            return
          else
            # the evloop got interrupted: restart
            next
          end
        else
          # evloop doesn't wait when empty (e.g. libevent)
          break
        end
      end
      @waiting.set(false, :release)

      # empty evloop: park the thread
      @mutex.synchronize do
        unless @enqueued.get(:acquire)
          @parked = true
          Crystal.trace :sched, "parking"
          @condition.wait(@mutex)
          @parked = false
        end

        @enqueued.set(false, :relaxed)
        return
      end

      Crystal.trace :sched, "resume"
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

    # Wait for the isolated fiber to terminate. Returns normally if the fiber
    # terminated normally; re-raises any uncatched exception raised by the
    # isolated fiber otherwise.
    @[AlwaysInline]
    def join : Nil
      @thread.join
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
      elsif @waiting
        "event-loop"
      elsif @parked
        "parked"
      else
        "running"
      end
    end
  end
end
