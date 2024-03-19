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
    getter? idle : Bool = false
    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new
    protected getter global_queue : GlobalQueue

    # :nodoc:
    def self.default(size : Int32) : self
      new("DEFAULT", size, hijack: true)
    end

    def self.new(name : String, size : Int32) : self
      new(name, size, hijack: false)
    end

    protected def initialize(@name : String, @size = 1, hijack = false)
      raise "ERROR: needs at least one thread" if @size <= 0

      @global_queue = GlobalQueue.new
      @schedulers = Array(Scheduler).new(@size)
      @threads = Array(Thread).new(@size)
      @rng = Random::PCG32.new

      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @parked = 0

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

      scheduler.main_fiber = scheduler.spawn(name: "#{@name}-#{index}:loop") do
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

    @[Deprecated]
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
        @global_queue.push(fiber)
        unpark_idle_thread
      end
    end

    # TODO: there should be one event loop per execution context (not per scheduler)
    # def event_loop : Crystal::EventLoop
    #   raise "BUG: call #{self.class.name}#Scheduler#event_loop instead of #{self.class.name}#event_loop"
    # end

    protected def steal(&) : Nil
      return if @size == 1

      # try to steal a few times
      1.upto(4) do |iter|
        i = @rng.next_int

        @size.times do |j|
          scheduler = @schedulers[(i + j) % @size]
          yield scheduler unless scheduler.idle?
        end

        # back-off
        iter.times { Intrinsics.pause }
      end
    end

    @[AlwaysInline]
    protected def park_thread(scheduler : Scheduler) : Fiber?
      @mutex.synchronize do
        # by the time we acquired the lock, another thread may have enqueued
        # fiber(s) and already tried to wakup a thread (race). we don't check
        # the scheduler's local queue nor it's event loop (both are empty)

        if fiber = scheduler.global_dequeue?
          return fiber
        end

        # if fiber = scheduler.try_steal?
        #   return fiber
        # end

        @parked += 1
        @condition.wait(@mutex)
        @parked -= 1
      end

      nil
    end

    # OPTIMIZE: there must be better heuristics than always waking up one parked
    #           thread, for example skip when there are spinning threads, how
    #           many fibers are queued and for how long they have been waiting
    #           in queue
    @[AlwaysInline]
    protected def unpark_idle_thread : Nil
      return if @parked == 0

      # OPTIMIZE: use trylock and return if we couldn't lock the mutex so we don't
      #           block the current thread!
      @mutex.synchronize do
        return if @parked == 0

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
