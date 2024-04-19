require "./global_queue"
require "./multi_threaded/scheduler"

module ExecutionContext
  # A MT scheduler. Owns multiple threads and starts a scheduler in each one.
  #
  # TODO: M schedulers running on N threads (M <= N)
  # TODO: move a scheduler to another thread (e.g. cpu bound fiber is holding
  #       the thread and is blocking runnable fibers)
  # TODO: resize (grow or shrink)
  class MultiThreaded
    include ExecutionContext

    getter name : String
    getter size : Int32
    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new
    protected getter global_queue : GlobalQueue

    # :nodoc:
    def self.default(size : Int32) : self
      new("DEFAULT", size, hijack: true)
    end

    def self.new(name : String, size : Int32) : self
      new(name, size, hijack: false)
    end

    protected def initialize(@name : String, @size : Int32, hijack = false)
      raise "ERROR: needs at least one thread" if @size <= 0

      @global_queue = GlobalQueue.new
      @schedulers = Array(Scheduler).new(@size)
      @threads = Array(Thread).new(@size)
      @rng = Random::PCG32.new

      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @parked = 0
      @spinning = Atomic(Int32).new(0)

      @blocked_lock = Crystal::SpinLock.new
      @blocked_list = Crystal::PointerLinkedList(BlockedScheduler).new

      start_schedulers(@size, hijack)

      # self.spawn(name: "#{@name}:stackpool-collect") do
      #   stack_pool.collect_loop
      # end
    end

    # Starts `count` schedulers and threads.
    # If `hijack` if true: setups the first scheduler on the current thread, and
    # starts `count - 1` threads for the rest of the schedulers.
    # Blocks the current thread until all threads are started and all schedulers
    # are fully setup.
    private def start_schedulers(count, hijack)
      wg = Thread::WaitGroup.new(count)

      @size.times do |index|
        scheduler = Scheduler.new(self, name: "#{@name}-#{index}")
        @schedulers << scheduler

        if hijack && index == 0
          @threads << hijack_current_thread(scheduler, index)
          wg.done
        else
          @threads << start_thread(scheduler, index) { wg.done }
        end
      end

      wg.wait
    end

    # Initializes a scheduler on the current thread (usually the executable's
    # main thread).
    private def hijack_current_thread(scheduler, index) : Thread
      thread = Thread.current
      Thread.name = scheduler.name
      thread.execution_context = self
      thread.current_scheduler = scheduler
      scheduler.thread = thread

      scheduler.main_fiber = Fiber.new("#{@name}-#{index}:loop", self) do
        scheduler.run_loop
      end

      thread
    end

    private def start_thread(scheduler, index, &block) : Thread
      Thread.new(name: scheduler.name) do |thread|
        thread.execution_context = self
        thread.current_scheduler = scheduler
        scheduler.thread = thread
        scheduler.main_fiber = thread.main_fiber
        scheduler.main_fiber.name = "#{@name}-#{index}:main"
        block.call
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
        Crystal.trace "sched:enqueue fiber=%p [%s]", fiber.as(Void*), fiber.name
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

      @size.times do |j|
        if scheduler = @schedulers[(i &+ j) % @size]?
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

        Crystal.trace "sched:parking"
        @parked += 1
        @condition.wait(@mutex)
        @parked -= 1
        Crystal.trace "sched:wakeup"
      end

      nil
    end

    protected def wake_scheduler : Nil
      return if @spinning.get(:acquire) > 0

      unless @blocked_list.empty?
        if blocked = @blocked_lock.sync { @blocked_list.shift? }
          blocked.value.unblock
        end
        return
      end

      return if @parked == 0

      # OPTIMIZE: use trylock and return if we couldn't lock the mutex so we don't
      #           block the current thread trying to wakeup another one (?)
      @mutex.synchronize do
        return if @parked == 0
        return if @spinning.get(:acquire) > 0

        # OPTIMIZE: potential thundering herd issue: we can't target a specific
        #           scheduler to unpark, which means we may have multiple
        #           enqueues try to wakeup multiple threads before a scheduler
        #           is given the chance to mark itself as spinning.
        #
        #           maybe we could take control of the list, which would allow
        #           to mark the scheduler as spinning before we even resume it,
        #           along with a check that we only wake 1 scheduler thread at a
        #           time (not multiple).
        @condition.signal
      end
    end

    @[AlwaysInline]
    protected def blocking_start(blocked : Pointer(Scheduler::Blocked)) : Nil
      blocked.value.set
      @blocked_lock.sync { @blocked_list.push(blocked) }
    end

    @[AlwaysInline]
    protected def blocking_stop(blocked : Pointer(Scheduler::Blocked)) : Nil
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
