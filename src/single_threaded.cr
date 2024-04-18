module ExecutionContext
  class SingleThreaded
    include ExecutionContext
    include Scheduler # TODO: extract a scheduler type (?)

    private getter! thread : Thread
    private getter! main_fiber : Fiber

    getter name : String
    getter? idle : Bool = false
    getter event_loop : Crystal::EventLoop = Crystal::EventLoop.create
    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new

    # TODO: Replace the Lock+Deque with a simple bounded queue with overflow to
    #       a GlobalQueue where cross context spawns/enqueues would also happen.
    #
    #       We could reuse Runnables but there won't be any stealing, so we can
    #       spare the atomics over the local queue.
    @lock = Crystal::SpinLock.new
    @runnables = Deque(Fiber).new

    # :nodoc:
    def self.default : self
      new "DEFAULT", hijack: true
    end

    def self.new(name : String) : self
      new name, hijack: false
    end

    protected def initialize(@name : String, hijack : Bool)
      if hijack
        hijack_current_thread
      else
        wg = Thread::WaitGroup.new(1)
        start_thread { wg.done }
        wg.wait
      end

      # self.spawn(name: "#{@name}:stackpool-collect") do
      #   stack_pool.collect_loop
      # end
    end

    # Setups the scheduler inside the current thread.
    # Spawns a fiber to run the scheduler loop.
    private def hijack_current_thread : Nil
      @thread = thread = Thread.current
      Thread.name = @name
      thread.execution_context = self
      thread.current_scheduler = self
      @main_fiber = self.spawn(name: "#{@name}:loop") { run_loop }
    end

    # Starts a thread to run the scheduler.
    # The thread's main fiber will run the scheduler loop.
    private def start_thread(&block : ->) : Nil
      Thread.new(name: @name) do |thread|
        @thread = thread
        thread.execution_context = self
        thread.current_scheduler = self
        thread.main_fiber.name = "#{@name}:loop"
        @main_fiber = thread.main_fiber
        block.call
        run_loop
      end
    end

    @[AlwaysInline]
    def execution_context : SingleThreaded
      self
    end

    # :nodoc:
    @[AlwaysInline]
    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      # whatever the value for same thread, fibers will always run on the same
      # thread anyway
      self.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      Crystal.trace "sched:enqueue fiber=%p [%s]", fiber.as(Void*), fiber.name

      @lock.lock
      @runnables << fiber

      if @idle
        @idle = false
        @lock.unlock
        @event_loop.interrupt_loop
      else
        @lock.unlock
      end
    end

    protected def reschedule : Nil
      Crystal.trace "sched:reschedule"

      if fiber = dequeue?
        resume fiber unless fiber == thread.current_fiber
      else
        # nothing to do: switch back to the main loop
        resume main_fiber
      end
    end

    protected def resume(fiber : Fiber) : Nil
      Crystal.trace "sched:resume fiber=%p [%s]", fiber.as(Void*), fiber.name

      # NOTE: when we start sending fibers between contexts, then we must loop
      #       on Fiber#resumable? because thread B may try to resume the fiber
      #       before thread A saved its context!
      unless fiber.resumable?
        message =
          if fiber.dead?
            "FATAL: tried to resume a dead fiber %s (%s)"
          else
            "FATAL: can't resume a running fiber %s (%s)"
          end
        Crystal::System.print_error_buffered(
          message, fiber.to_s, inspect, backtrace: caller)
        exit 1
      end

      swapcontext(fiber)
    end

    # Dequeues one fiber from the runnable queue.
    # Fallbacks to run the event queue (nonblocking).
    private def dequeue? : Fiber?
      if fiber = @lock.sync { @runnables.shift? }
        return fiber
      end

      if @event_loop.run(blocking: false)
        return @lock.sync { @runnables.shift? }
      end
    end

    private def run_loop : Nil
      loop do
        @lock.lock

        # check the runnables queue after we locked the mutex (another context
        # may have enqueued a fiber):
        if fiber = @runnables.shift?
          @lock.unlock
          resume fiber
          next
        end

        # we can't check the event loop again (nonblocking) while we hold the
        # lock (it would deadlock when calling #enqueue); we could _if_ it
        # returned fibers instead of calling #enqueue

        # no runnable fiber, set idle state
        @idle = true
        @lock.unlock

        # always block, even when there's nothing to do: the fiber got rescheduled
        # so we likely wait on cross context communication, like a channel:
        @event_loop.run(blocking: true, block_when_empty: true)
      rescue ex
        message = "BUG: %s#run_loop crashed with %s"
        Crystal::System.print_error_buffered(message, self.class.name, ex.class.name, backtrace: ex.backtrace)
      end
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
