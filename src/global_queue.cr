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

    # Grabs the lock and enqueues a runnable fiber on the global runnable queue.
    def push(fiber : Fiber) : Nil
      lock { unsafe_push(fiber) }
    end

    # Enqueues a runnable fiber on the global runnable queue. Assumes the lock
    # is currently held.
    def unsafe_push(fiber : Fiber) : Nil
      @queue.push(fiber)
      @size += 1
    end

    # Grabs the lock and puts a runnable fibers on the global runnable queue.
    # `size` is the number of fibers in `queue`.
    def push(queue : Queue*, size : Int32) : Nil
      lock { unsafe_push(queue, size) }
    end

    # Puts a runnable fibers on the global runnable queue. Assumes the lock is
    # currently held. `size` is the number of fibers in `queue`.
    def unsafe_push(queue : Queue*, size : Int32) : Nil
      @queue.bulk_unshift(queue)
      @size += size
    end

    # Grabs the lock and dequeues one runnable fiber from the global runnable
    # queue.
    def get? : Fiber?
      lock { unsafe_get? }
    end

    # Dequeues one runnable fiber from the global runnable queue. Assumes the
    # lock is currently held.
    def unsafe_get? : Fiber?
      if fiber = @queue.pop?
        @size -= 1
        fiber
      end
    end

    # Grabs the lock then tries to grab a batch of fibers from the global
    # runnable queue. Returns the next runnable fiber or `nil` if the queue was
    # empty.
    #
    # `divisor` is meant for fair distribution of fibers across threads in the
    # execution context; it should be the number of threads.
    def grab?(runnables : Runnables, divisor : Int32) : Fiber?
      lock { unsafe_grab?(runnables, divisor) }
    end

    # Try to grab a batch of fibers from the global runnable queue. Returns the
    # next runnable fiber or `nil` if the queue was empty. Assumes the lock is
    # currently held.
    #
    # `divisor` is meant for fair distribution of fibers across threads in the
    # execution context; it should be the number of threads.
    def unsafe_grab?(runnables : Runnables, divisor : Int32) : Fiber?
      return if @size == 0

      # always grab at least 1 fiber
      n = {
        @size // divisor + 1,
        @size,
        runnables.capacity // 2
      }.min
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
