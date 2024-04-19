require "./blocked_scheduler"
require "./global_queue"
require "./runnables"

module ExecutionContext
  # A ST scheduler. Owns a single thread. Concurrency is limited to that thread.
  class SingleThreaded
    include ExecutionContext
    include Scheduler

    getter name : String
    protected getter thread : Thread
    protected getter main_fiber : Fiber

    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new
    getter event_loop : Crystal::EventLoop = Crystal::EventLoop.create

    protected getter global_queue : GlobalQueue
    @runnables : Runnables(256)

    @tick : Int32 = 0
    getter? idle : Bool = false

    # :nodoc:
    def self.default : self
      new("DEFAULT", hijack: true)
    end

    def self.new(name : String) : self
      new(name, hijack: false)
    end

    protected def initialize(@name : String, hijack : Bool)
      @global_queue = GlobalQueue.new
      @runnables = Runnables(256).new(@global_queue)

      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @parked = false
      @spinning = Atomic(UInt8).new(0_u8)

      @thread = uninitialized Thread
      @main_fiber = uninitialized Fiber
      @blocked = uninitialized BlockedScheduler

      @thread = hijack ? hijack_current_thread : start_thread
      @blocked = BlockedScheduler.new(self)

      # self.spawn(name: "#{@name}:stackpool-collect") do
      #   stack_pool.collect_loop
      # end
    end

    # :nodoc:
    def execution_context : self
      self
    end

    # Initializes a scheduler on the current thread (usually the executable's
    # main thread).
    private def hijack_current_thread : Thread
      thread = Thread.current
      Thread.name = @name
      thread.execution_context = self
      thread.current_scheduler = self
      @main_fiber = Fiber.new("#{@name}:loop", self) { run_loop }
      thread
    end

    private def start_thread : Thread
      Thread.new(name: @name) do |thread|
        thread.execution_context = self
        thread.current_scheduler = self
        @main_fiber = thread.main_fiber
        @main_fiber.name = "#{@name}:loop"
        run_loop
      end
    end

    # :nodoc:
    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      # whatever the value of same_thread: the fibers will always run on the
      # same thread
      self.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      if ExecutionContext.current == self
        # local enqueue
        Crystal.trace "sched:enqueue fiber=%p [%s]", fiber.as(Void*), fiber.name
        @runnables.push(fiber)
      else
        # cross context enqueue
        Crystal.trace "sched:enqueue fiber=%p [%s] context=[%s]", fiber.as(Void*), fiber.name, @name
        @global_queue.push(fiber)
        wake_scheduler
      end
    end

    protected def reschedule : Nil
      Crystal.trace "sched:reschedule"
      if fiber = quick_dequeue?
        resume fiber unless fiber == thread.current_fiber
      else
        # nothing to do: switch back to the main loop to spin/park
        resume main_fiber
      end
    end

    private def resume(fiber : Fiber) : Nil
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

    @[AlwaysInline]
    private def quick_dequeue? : Fiber?
      # every once in a while: dequeue from global queue to avoid two fibers
      # constantly respawing each other to completely occupy the local queue
      if (@tick &+= 1) % 61 == 0
        if fiber = global_queue.pop?
          return fiber
        end
      end

      # dequeue from local queue
      if fiber = @runnables.get?
        return fiber
      end

      # NOTE: if we ever start sending fibers, we might want to avoid the
      # following calls as they take a bit of time to complete, blocking the
      # current fiber (that may have been sent)

      # grab from global queue (tries to refill local queue)
      if fiber = global_dequeue?
        return fiber
      end

      # run the event loop to see if any event is activable
      if @event_loop.run(blocking: false)
        if fiber = @runnables.get?
          return fiber
        end
      end
    end

    @[AlwaysInline]
    private def global_dequeue? : Fiber?
      if fiber = global_queue.grab?(@runnables, divisor: 1)
        fiber
      end
    end

    private def run_loop : Nil
      loop do
        @idle = true

        runnable { @runnables.get? }
        runnable { global_dequeue? }

        if @event_loop.run(blocking: false)
          runnable { @runnables.get? }
        end

        # nothing to do: start spinning
        spinning do
          if @event_loop.run(blocking: false)
            runnable { @runnables.get? }
          end

          runnable { global_dequeue? }
        end

        # block on the event loop, waiting for pending event(s) to activate
        if blocking { @event_loop.run(blocking: true) }
          # the event loop enqueued a fiber or was interrupted: restart
          next
        end

        # no runnable fiber, no event in the local event loop: go into deep
        # sleep until another context enqueues a fiber
        runnable do
          park_thread do
            # by the time we acquired the lock, another context may have
            # enqueued fiber(s) and already tried to wakeup the scheduler
            # (race). we don't check the scheduler's local queue nor its
            # event loop (both are empty)
            if fiber = global_dequeue?
              break fiber
            end
          end
        end

        # immediately mark the scheduler as spinning (we just unparked)
        spin_start
      rescue exception
        Crystal::System.print_error_buffered(
          "BUG: %s#run_loop [%s] crashed with %s (%s)",
          self.class.name, @name, exception.message, exception.class.name,
          backtrace: exception.backtrace)
      end
    end

    private macro runnable(&)
      if %fiber = {{yield}}
        spin_stop if spinning?
        @idle = false
        resume %fiber
        next
      end
    end

    private def spinning(&)
      spin_start

      4.times do |iter|
        yield
        spin_backoff(iter)
      end

      spin_stop
    end

    @[AlwaysInline]
    private def spinning? : Bool
      @spinning.get(:acquire) == 1_u8
    end

    @[AlwaysInline]
    private def spin_start
      @spinning.set(1_u8, :release)
    end

    @[AlwaysInline]
    private def spin_stop
      @spinning.set(0_u8, :release)
    end

    @[AlwaysInline]
    private def spin_backoff(iter)
      # OPTIMIZE: consider exponential backoff, but beware of edge cases, like
      # creating latency before we notice a cross context enqueue, for example)
      Thread.yield
    end

    @[AlwaysInline]
    private def blocking(&)
      @blocked.set
      begin
        yield
      ensure
        @blocked.trigger?
      end
    end

    @[AlwaysInline]
    protected def unblock : Nil
      # Crystal.trace "sched:unblock scheduler=%p [%s]", self.as(Void*), name
      @event_loop.interrupt_loop
    end

    private def park_thread : Fiber?
      @mutex.synchronize do
        # avoid races by checking queues again
        if fiber = yield
          return fiber
        end

        Crystal.trace "sched:parking"
        @parked = true
        @condition.wait(@mutex)
        @parked = false
        Crystal.trace "sched:wakeup"
      end

      nil
    end

    # This method runs in parallel to the rest of the ST scheduler!
    private def wake_scheduler : Nil
      return if spinning?

      if @blocked.trigger?
        @blocked.unblock
        return
      end

      return unless @parked

      @mutex.synchronize do
        return unless @parked
        return if spinning?

        @condition.signal
      end
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
  end
end
