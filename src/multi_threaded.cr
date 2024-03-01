require "./global_queue"
require "./multi_threaded/scheduler"

abstract class ExecutionContext
  # A MT scheduler. Owns multiple threads and starts a scheduler in each one.
  #
  # TODO: M schedulers running on N threads (M <= N)
  # TODO: thread pool (global?) with min..max schedulers
  # TODO:
  # TODO: move a scheduler to another thread (e.g. cpu bound fiber is holding
  #       the thread and is blocking runnable fibers)
  #       the thread)
  # TODO: resize (grow or shrink)
  class MultiThreaded < ExecutionContext
    getter name : String
    getter size : Int32
    getter? idle : Bool = false
    protected getter global_queue : GlobalQueue

    # :nodoc:
    def self.default(size : Int32) : self
      new "DEFAULT", size, hijack: true
    end

    def self.default(name : String, size : Int32) : self
      new name, size, hijack: false
    end

    protected def initialize(@name : String, @size = 1, hijack = false)
      raise "ERROR: needs at least one thread" if @size <= 0

      @global_queue = GlobalQueue.new
      @rng = Random::PCG32.new

      @schedulers = Array(Scheduler).new(@size)
      @threads = Array(Thread).new(@size)

      @mutex = Thread::Mutex.new
      @condition = Thread::ConditionVariable.new
      @idling = 0

      start_schedulers(@size, hijack)
    end

    private def start_schedulers(count, hijack)
      wg = Thread::WaitGroup.new(count)

      @size.times do |index|
        scheduler = Scheduler.new(self)
        @schedulers << scheduler

        if hijack && index == 0
          hijack_current_thread(scheduler, index)
          wg.done
        else
          start_thread(scheduler, index) { wg.done }
        end
      end

      wg.wait
    end

    # Initializes a scheduler on the current thread (usually the executable's
    # main thread).
    private def hijack_current_thread(scheduler, index) : Nil
      thread = Thread.current
      thread.execution_context = scheduler
      thread.current_fiber = thread.@main_fiber.not_nil!
      scheduler.thread = thread
      scheduler.main_fiber = scheduler.spawn(name: "#{@name}-#{index}-main") do
        scheduler.run_loop
      end
      @threads << thread
    end

    private def start_thread(scheduler, index, &) : Nil
      thread = Thread.new(name: "#{@name}-#{index}") do |thread|
        scheduler.thread = thread
        thread.execution_context = scheduler
        scheduler.main_fiber = thread.current_fiber = thread.@main_fiber.not_nil!
        # scheduler.main_fiber.name = "#{@name}-#{index}-main"
        yield
        scheduler.run_loop
      end
      @threads << thread
    end

    # :nodoc:
    def spawn(name : String?, same_thread : Bool, &block : ->) : Fiber
      raise RuntimeError.new("ExecutionContext::MultiThreaded doesn't support same_thread:true attribute") if same_thread
      self.spawn(name, &block)
    end

    def enqueue(fiber : Fiber) : Nil
      @global_queue.lock do
        @global_queue.push(fiber)
      end
    end

    @[AlwaysInline]
    private def global_dequeue? : Fiber?
      @global_queue.lock do
        @global_queue.get(@runnables, @execution_context.size)
      end
    end

    protected def reschedule : Nil
      raise "Bug: calling #{self.class.name}#reschedule is prohibited (must call Scheduler#reschedule)"
    end

    protected def resume(fiber : Fiber) : Nil
      raise "Bug: calling #{self.class.name}#resume is prohibited (must call Scheduler#resume)"
    end

    protected def steal(scheduler : Scheduler) : Fiber?
      return if @schedulers.size == 1

      4.times do # try to steal a few times
        i = @rng.next_int

        @schedulers.size.times do |j|
          s = @schedulers[(i + j) % @schedulers.size]
          next if s == scheduler
          # OPTIMIZE: next if scheduler.idle?

          if fiber = scheduler.steal_from(s)
            return fiber
          end
        end
      end
    end

    @[AlwaysInline]
    protected def synchronize(&block) : Nil
      @mutex.synchronize(&block)
    end

    # @[AlwaysInline]
    # protected def park : Nil
    #   @idling += 1
    #   @condition.wait(@mutex)
    #   @idling -= 1
    # end

    # protected def unpark_one : Nil
    #   return if @idling == 0

    #   @mutex.synchronize do
    #     @condition.signal
    #   end
    # end
  end
end
