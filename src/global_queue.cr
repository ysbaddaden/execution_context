require "./queue"
require "./runnables"

module ExecutionContext
  # Global queue of runnable fibers. Unbounded. Shared by all schedulers in an
  # execution context.
  #
  # Individual methods aren't thread safe. Calling `#lock` is required for
  # concurrent accesses.
  #
  # Ported from Go's `globrunq*` functions.
  class GlobalQueue
    def initialize(@mutex : Thread::Mutex)
      @queue = Queue.new
    end

    # Grabs the lock and enqueues a runnable fiber on the global runnable queue.
    def push(fiber : Fiber) : Nil
      @mutex.synchronize { unsafe_push(fiber) }
    end

    # Enqueues a runnable fiber on the global runnable queue. Assumes the lock
    # is currently held.
    def unsafe_push(fiber : Fiber) : Nil
      @queue.push(fiber)
    end

    # Grabs the lock and puts a runnable fiber on the global runnable queue.
    def bulk_push(queue : Queue*) : Nil
      @mutex.synchronize { unsafe_bulk_push(queue) }
    end

    # Puts a runnable fiber on the global runnable queue. Assumes the lock is
    # currently held.
    def unsafe_bulk_push(queue : Queue*) : Nil
      # ported from Go: globrunqputbatch
      @queue.bulk_unshift(queue)
    end

    # Grabs the lock and dequeues one runnable fiber from the global runnable
    # queue.
    def pop? : Fiber?
      @mutex.synchronize { unsafe_pop? }
    end

    # Dequeues one runnable fiber from the global runnable queue. Assumes the
    # lock is currently held.
    def unsafe_pop? : Fiber?
      @queue.pop?
    end

    # Grabs the lock then tries to grab a batch of fibers from the global
    # runnable queue. Returns the next runnable fiber or `nil` if the queue was
    # empty.
    #
    # `divisor` is meant for fair distribution of fibers across threads in the
    # execution context; it should be the number of threads.
    def grab?(runnables, divisor : Int32) : Fiber?
      @mutex.synchronize { unsafe_grab?(runnables, divisor) }
    end

    # Try to grab a batch of fibers from the global runnable queue. Returns the
    # next runnable fiber or `nil` if the queue was empty. Assumes the lock is
    # currently held.
    #
    # `divisor` is meant for fair distribution of fibers across threads in the
    # execution context; it should be the number of threads.
    def unsafe_grab?(runnables, divisor : Int32) : Fiber?
      # ported from Go: globrunqget
      return if @queue.empty?

      divisor = 1 if divisor < 1
      size = @queue.size

      n = {
        size,                    # can't grab more than available
        size // divisor + 1,     # divide + try to take at least 1 fiber
        runnables.capacity // 2, # refill half the destination queue
      }.min

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
      @queue.empty?
    end

    @[AlwaysInline]
    def size : Int32
      @queue.size
    end
  end
end
