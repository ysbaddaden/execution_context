require "./queue"
require "./runnables"

abstract class ExecutionContext
  # Global queue of runnable fibers. Unbounded. Shared by all schedulers in an
  # execution context.
  #
  # Individual methods aren't thread safe. Calling `#lock` is required for
  # concurrent accesses.
  class GlobalQueue
    def initialize
      @queue = Queue.new(nil, nil)
      @size = 0
      @lock = Crystal::SpinLock.new
    end

    # Put a runnable fiber on the global runnable queue.
    #
    # Lock must be held!
    def push(fiber : Fiber) : Nil
      @queue.push(fiber)
      @size += 1
    end

    # Put a batch of runnable fibers on the global runnable queue.
    # `n` is the number of fibers in `queue`.
    #
    # Lock must be held!
    def push(queue : Queue*, n : Int32) : Nil
      @queue.push_back_all(queue)
      @size += n
    end

    # Try to grab a batch of fibers from the global runnable queue. Returns the
    # next runnable fiber or `nil` if the queue was empty.
    #
    # `divisor` is meant for fair distribution of fibers across threads in the
    # execution context; it should be the number of threads.
    #
    # Lock must be held!
    def get(runnables : Runnables, divisor : Int32) : Fiber?
      return if @size == 0

      # always grab at least 1 fiber
      n = {@size // divisor + 1, @size, runnables.capacity // 2}.min
      @size -= n
      fiber = @queue.pop?

      # OPTIMIZE: q = @queue.split(n - 1) then `runnables.push(pointerof(q))` (?)
      (n - 1).times do
        break unless f = @queue.pop?
        runnables.push(f)
      end

      fiber
    end

    @[AlwaysInline]
    def empty? : Bool
      @size == 0
    end

    @[AlwaysInline]
    def lock(&)
      @lock.lock
      begin
        yield
      ensure
        @lock.unlock
      end
    end
  end
end
