require "./global_queue"
require "./multi_threaded/scheduler"

abstract class ExecutionContext
  # A MT scheduler. Owns multiple threads and starts a scheduler in each one.
  #
  # TODO: M schedulers running on N threads (M <= N)
  # TODO: move a scheduler to another thread (e.g. cpu bound fiber is holding
  #       the thread and is blocking runnable fibers)
  #       the thread)
  # TODO: resize (grow or shrink)
  class MultiThreaded < ExecutionContext
    getter name : String
    getter size : Int32
    getter? idle : Bool = false

    protected getter global_queue : GlobalQueue = GlobalQueue.new
    getter stack_pool : Fiber::StackPool = Fiber::StackPool.new

    # :nodoc:
    def self.default(size : Int32) : self
      new "DEFAULT", size, hijack: true
    end

    def self.new(name : String, size : Int32) : self
      new name, size, hijack: false
    end

    protected def initialize(@name : String, @size = 1, hijack = false)
      raise "ERROR: needs at least one thread" if @size <= 0

      @schedulers = Array(Scheduler).new(@size)
      @threads = Array(Thread).new(@size)
      @rng = Random::PCG32.new

      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @parked = 0

      start_schedulers(@size, hijack)
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
      thread.execution_context = scheduler
      scheduler.thread = thread
      scheduler.main_fiber = scheduler.spawn(name: "#{@name}-#{index}-main") do
        scheduler.run_loop
      end
      thread
    end

    private def start_thread(scheduler, index, &block) : Thread
      Thread.new(name: "#{@name}-#{index}") do |thread|
        thread.execution_context = scheduler
        scheduler.thread = thread
        scheduler.main_fiber = thread.main_fiber
        # scheduler.main_fiber.name = "#{@name}-#{index}-main"
        block.call
        scheduler.run_loop
      end
    end

    def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
      raise ArgumentError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
      self.spawn(name: name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      @global_queue.push(fiber)
      unpark_idle_thread
    end

    # TODO: there should be one event loop per execution context (not per scheduler)
    def event_loop : Crystal::EventLoop
      raise "BUG: call #{self.class.name}#Scheduler#event_loop instead of #{self.class.name}#event_loop"
    end

    protected def reschedule : Nil
      raise "BUG: call #{self.class.name}::Scheduler#reschedule instead of #{self.class.name}#reschedule)"
    end

    protected def resume(fiber : Fiber) : Nil
      raise "BUG: call #{self.class.name}::Scheduler#resume instead of #{self.class.name}#resume)"
    end

    protected def validate_resumable(fiber : Fiber) : Nil
      raise "BUG: call #{self.class.name}::Scheduler#validate_resumable instead of #{self.class.name}#validate_resumable)"
    end

    protected def steal(scheduler : Scheduler) : Fiber?
      return if @size == 1

      # try to steal a few times
      1.upto(4) do |iter|
        i = @rng.next_int

        @size.times do |j|
          sched = @schedulers[(i + j) % @size]
          next if sched == scheduler
          # OPTIMIZE: next if scheduler.idle?

          if fiber = scheduler.steal_from(sched)
            return fiber
          end
        end

        # back-off
        iter.times { Intrinsics.pause }
      end
    end

    @[AlwaysInline]
    protected def park_thread : Nil
      @mutex.synchronize do
        # FIXME: by the time we acquired the lock, another thread may have
        #        enqueued fiber(s) and already tried to wakup a thread (race)
        #        => try global queue
        #        => try stealing
        @parked += 1
        @condition.wait(@mutex)
        @parked -= 1
      end
    end

    # OPTIMIZE: there must be better heuristics than always waking up one parked
    #           thread, for example how many fibers are queued and for how long
    #           they have been waiting in queue
    @[AlwaysInline]
    protected def unpark_idle_thread : Nil
      return if @parked == 0

      # FIXME: use trylock and return if we couldn't lock the mutex so we don't
      #        block the current thread (oops)
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
