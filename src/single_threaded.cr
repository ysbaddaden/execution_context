abstract class ExecutionContext
  class SingleThreaded < ExecutionContext
    private getter! thread : Thread
    private getter! main_fiber : Fiber
    @deep_sleep_fiber : Fiber?

    getter name : String?
    getter? idle : Bool = false
    getter event_loop : Crystal::EventLoop = Crystal::EventLoop.create
    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new

    # TODO: consider Runnables(N) + GlobalQueue instead of SpinLock + Deque
    @lock = Crystal::SpinLock.new
    @runnables = Deque(Fiber).new
    @fiber_channel = Crystal::FiberChannel.new

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

      # TODO: enqueue stack pool collector fiber
    end

    # Setups the scheduler inside the current thread.
    # Spawns a fiber to run the scheduler loop.
    private def hijack_current_thread : Nil
      @thread = thread = Thread.current
      thread.execution_context = self
      @main_fiber = self.spawn(name: "#{@name}-main") { run_loop }
    end

    # Starts a thread to run the scheduler.
    # The thread's main fiber will run the scheduler loop.
    private def start_thread(&block : ->) : Nil
      Thread.new do |thread|
        @thread = thread
        thread.execution_context = self
        @main_fiber = thread.main_fiber
        # @main_fiber.name = "#{@name}-main"
        block.call
        run_loop
      end
    end

    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      # whatever the value for same thread, fibers will always run on the same
      # thread anyway
      super(name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      @lock.lock

      if @idle
        # only wakeup once
        @idle = false
        @lock.unlock
        @fiber_channel.send(fiber)
      else
        # prefer to enqueue directly
        @runnables << fiber
        @lock.unlock
      end
    end

    protected def reschedule : Nil
      if fiber = dequeue?
        resume fiber unless fiber == thread.current_fiber
      else
        # nothing to do: switch back to the main loop
        resume main_fiber
      end
    end

    # Dequeues one fiber from the runnable queue.
    # Fallbacks to run the event queue (nonblocking).
    protected def dequeue? : Fiber?
      loop do
        if fiber = @lock.sync { @runnables.shift? }
          return fiber
        end

        if @event_loop.run(blocking: true)
          # event loop may have enqueued a new fiber (or not)
          if fiber = @lock.sync { @runnables.shift? }
            return fiber
          end
        end

        # nothing to do
        return
      end
    end

    private def validate_resumable(fiber : Fiber) : Nil
      return if fiber.resumable?

      message = String.build do |str|
        str << "\nFATAL: "
        if fiber.dead?
          str << "tried to resume a dead fiber"
        else
          str << "can't resume a running fiber"
        end
        str << ": "
        fiber.to_s(str)
        str << ' '
        inspect(str)
        str << '\n'
        caller.each { |line| str << "  from " << line << '\n' }
      end

      Crystal::System.print_error(message)
      exit 1
    end

    protected def run_loop : Nil
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
        # lock (it would deadlock when calling #enqueue)

        # no runnable fiber, set idle state
        @idle = true
        @lock.unlock

        # block on the event loop, waiting for pending event(s) to activate.
        if @event_loop.run(blocking: true)
          # while idling the next runnable is sent to the fiber channel
          resume @fiber_channel.receive
          next
        end

        # no runnable fiber, no pending event in the event loop: go into deep
        # sleep until another context enqueues a fiber.
        #
        # switch to a dedicated fiber that waits on the fiber channel; we need
        # the extra fiber to create a wait event in the event loop, leading the
        # thread to resume the main loop, eventually waiting on the even loop.
        resume deep_sleep_fiber
      rescue exception
        message = String.build do |str|
          str << "BUG: " << self.class.name << "#run_loop crashed with " << exception.class.name << '\n'
          exception.backtrace.each { |line| str << "  from " << line << '\n' }
        end
        Crystal::System.print_error(message)
      end
    end

    private def deep_sleep_fiber : Fiber
      @deep_sleep_fiber ||= Fiber.new(name: "#{@name}-sleep", execution_context: self) do
        loop do
          resume @fiber_channel.receive
        end
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
