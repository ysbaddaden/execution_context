require "./blocked_scheduler"
require "./global_queue"
require "./multi_threaded/scheduler"

module ExecutionContext
  # A MT scheduler. Owns multiple threads and starts a scheduler in each one.
  # The number of threads is dynamic. Setting the minimum and maximum to the
  # same value will start a fixed number of threads.
  #
  # TODO: M schedulers running on N threads (M <= N)
  # TODO: move a scheduler to another thread (e.g. cpu bound fiber is holding
  #       the thread and is blocking runnable fibers)
  # TODO: resize (grow or shrink)
  class MultiThreaded
    include ExecutionContext

    getter name : String
    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new
    protected getter global_queue : GlobalQueue

    @parked = Atomic(Int32).new(0)
    @spinning = Atomic(Int32).new(0)

    # :nodoc:
    def self.default(size : Int32) : self
      new("DEFAULT", 1..size, hijack: true)
    end

    # Starts a context with a maximum number of threads. Threads aren't started
    # right away, but will be started as needed to increase parallelism up to
    # the configured maximum.
    def self.new(name : String, size : Int32) : self
      new(name, 0..size, hijack: false)
    end

    # Starts a context with a maximum number of threads. Threads aren't started
    # right away, but will be started as needed to increase parallelism up to
    # the configured maximum.
    def self.new(name : String, size : Range(Nil, Int32)) : self
      new(name, 0..size.end, hijack: false)
    end

    # Starts a context with a minimum and a maximum number of threads. The
    # minimum number of threads will be started right away, then threads may be
    # started as needed to increase parallelism up to the configured maximum.
    def self.new(name : String, size : Range(Int32, Int32)) : self
      new(name, size, hijack: false)
    end

    protected def initialize(@name : String, @size : Range(Int32, Int32), hijack : Bool)
      raise RuntimeError.new("ERROR: needs at least one thread") if @size.end <= 0
      raise RuntimeError.new("ERROR: needs at least one thread when hijacking a thread") if hijack && @size.begin <= 1

      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new

      @global_queue = GlobalQueue.new(@mutex)
      @schedulers = Array(Scheduler).new(@size.end)
      @threads = Array(Thread).new(@size.end)

      @rng = Random::PCG32.new

      # OPTIMIZE: the linked list won't be needed anymore with a single
      #           eventloop instance per execution context (an atomic will be
      #           enough, as in the ST scheduler)
      @blocked_lock = Crystal::SpinLock.new
      @blocked_list = Crystal::PointerLinkedList(BlockedScheduler).new

      start_schedulers
      start_initial_threads(hijack)

      ExecutionContext.execution_contexts.push(self)
    end

    def size : Int32
      @threads.size
    end

    def capacity : Int32
      @size.end
    end

    def stack_pool? : Fiber::StackPool?
      @stack_pool
    end

    private def start_schedulers
      @size.end.times do |index|
        @schedulers << Scheduler.new(self, name: "#{@name}-#{index}")
      end
    end

    private def start_initial_threads(hijack)
      @size.begin.times do |index|
        scheduler = @schedulers[index]

        if hijack && index == 0
          @threads << hijack_current_thread(scheduler, index)
        else
          @threads << start_thread(scheduler, index)
        end
      end
    end

    # Attaches *scheduler* to the current `Thread`, usually the executable's
    # main thread. Starts a `Fiber` to run the run loop.
    private def hijack_current_thread(scheduler, index) : Thread
      Thread.current.tap do |thread|
        Thread.name = scheduler.name
        thread.execution_context = self
        thread.current_scheduler = scheduler
        scheduler.thread = thread

        scheduler.main_fiber = Fiber.new("#{@name}-#{index}:loop", self) do
          scheduler.run_loop
        end
      end
    end

    # Start a new `Thread` and attaches *scheduler*. Runs the run loop directly
    # in the thread's main `Fiber`.
    private def start_thread(scheduler, index) : Thread
      Thread.new(name: scheduler.name) do |thread|
        thread.execution_context = self
        thread.current_scheduler = scheduler
        scheduler.thread = thread
        scheduler.main_fiber = thread.main_fiber
        scheduler.main_fiber.name = "#{@name}-#{index}:loop"
        scheduler.run_loop
      end
    end

    @[Deprecated("The same_thread argument to spawn is deprecated. Create execution contexts instead")]
    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      self.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      if ExecutionContext.current == self
        # within current context: push to local queue of current scheduler
        ExecutionContext::Scheduler.current.enqueue(fiber)
      else
        # cross context: push to global queue
        Crystal.trace :sched, "enqueue", fiber: fiber, to_context: self
        @global_queue.push(fiber)
        wake_scheduler
      end
    end

    # TODO: there should be one event loop per execution context (not per scheduler)
    # def event_loop : Crystal::EventLoop
    #   raise "BUG: call #{self.class.name}#Scheduler#event_loop instead of #{self.class.name}#event_loop"
    # end

    protected def steal(&) : Nil
      return if @size == 1

      i = @rng.next_int
      size = @schedulers.size

      size.times do |j|
        if scheduler = @schedulers[(i &+ j) % size]?
          yield scheduler unless scheduler.idle?
        end
      end
    end

    protected def park_thread : Fiber?
      @mutex.synchronize do
        # avoid races by checking queues again
        if fiber = yield
          return fiber
        end

        Crystal.trace :sched, "parking"
        @parked.add(1, :acquire_release)

        @condition.wait(@mutex)

        @parked.sub(1, :acquire_release)
        Crystal.trace :sched, "wakeup"
      end

      nil
    end

    # This method always runs in parallel!
    #
    # This can be called from any thread in the context but can also be called
    # from external execution contexts, in which case the context may have its
    # last thread about to park itself, and we must prevent the last thread from
    # parking when there is a parallel cross context enqueue!
    protected def wake_scheduler : Nil
      # another thread is spinning: nothing to do (it shall notice the enqueue)
      return if @spinning.get(:acquire) > 0

      # OPTIMIZE: with one eventloop per execution context, we might prefer to
      #           wakeup a parked thread *before* interrupting the event loop.
      unless @blocked_list.empty?
        # try to interrupt a thread blocked on the event loop
        if blocked = @blocked_lock.sync { @blocked_list.shift? }
          blocked.value.unblock if blocked.value.trigger?
        end
        return
      end

      # we can check @parked without locking the mutex because we can't push to
      # the global queue _and_ park the thread at the same time, so either the
      # thread is already parked (and we must awake it) or it noticed (or will
      # notice) the fiber in the global queue;
      #
      # we still rely on an atomic to make sure the actual value is visible by
      # the current thread
      if @parked.get(:acquire) > 0
        @mutex.synchronize do
          # OPTIMIZE: relaxed atomics should be enough (we're inside a mutex
          #           that shall already deal with memory order
          return if @parked.get(:acquire) == 0
          return if @spinning.get(:acquire) > 0

          # increase the number of spinning threads _now_ to avoid multiple
          # threads from trying to wakeup multiple threads at the same time
          @spinning.add(1, :acquire_release)

          # wakeup a thread
          @condition.signal
        end
        return
      end

      # shall we start another thread?
      # no need for atomics, the values shall be rather stable ovber time and
      # we check them again inside the mutex.
      return if @threads.size == @size.end

      @mutex.synchronize do
        index = @threads.size
        return if index == @size.end # check again (protect against races)

        @threads << start_thread(@schedulers[index], index)
      end
    end

    @[AlwaysInline]
    protected def blocking_start(blocked : Pointer(BlockedScheduler)) : Nil
      blocked.value.set
      @blocked_lock.sync { @blocked_list.push(blocked) }
    end

    @[AlwaysInline]
    protected def blocking_stop(blocked : Pointer(BlockedScheduler)) : Nil
      return unless blocked.value.trigger?
      @blocked_lock.sync { @blocked_list.delete(blocked) }
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
