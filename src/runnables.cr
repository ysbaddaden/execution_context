require "./global_queue"

abstract class ExecutionContext
  # Local queue or runnable fibers for schedulers.
  #
  # Private to an execution context scheduler, except for stealing methods that
  # can be called from any thread in the execution context.
  class Runnables(N)
    def initialize(@global_queue : GlobalQueue)
      @head = Atomic(Int32).new(0)
      @tail = Atomic(Int32).new(0)
      @buffer = uninitialized StaticArray(Fiber, N)
    end

    @[AlwaysInline]
    def capacity : Int32
      N
    end

    # @[AlwaysInline]
    # def empty? : Bool
    #   head = @head.get(:relaxed)
    #   tail = @tail.get(:relaxed)
    #   tail - head == 0
    # end

    # Tries to push fiber on the local runnable queue. If the run queue is full,
    # pushes fiber on the global queue.
    #
    # Executed only by the owner.
    def push(fiber : Fiber) : Nil
      loop do
        head = @head.get(:acquire) # sync with consumers
        tail = @tail.get(:relaxed)

        if (tail - head) < N
          # put fiber to local queue
          @buffer.to_unsafe[tail % N] = fiber

          # make the fiber available for consumption
          @tail.set(tail + 1, :release)
          return
        end

        return if push_slow(fiber, head, tail)

        # the queue isn't full, now the push above must succeed
      end
    end

    # Push fiber, along with a batch of fibers from local queue, on global queue.
    #
    # Executed only by the owner.
    private def push_slow(fiber : Fiber, head : Int32, tail : Int32) : Bool
      n = (tail - head) // 2
      raise "BUG: queue is not full" if n != N // 2

      # first, try to grab a batch of fibers from local queue
      batch = uninitialized StaticArray(Fiber, N)
      n.times do |i|
        batch.to_unsafe[i] = @buffer.to_unsafe[(head + i) % N]
      end
      _, success = @head.compare_and_set(head, head + n, :acquire_release, :acquire)
      return false unless success

      # append fiber to the batch
      batch.to_unsafe[n] = fiber

      # link the fibers
      n.times do |i|
        batch.to_unsafe[i].schedlink = batch.to_unsafe[i + 1]
      end
      queue = Queue.new(batch.to_unsafe[0], batch.to_unsafe[n])

      # now put the batch on global queue
      @global_queue.lock do
        @global_queue.push(pointerof(queue), n + 1)
      end

      true
    end

    # Tries to put all the fibers on queue on the local queue. If the queue is
    # full, they are put on the global queue; in that case this will temporarily
    # acquire the global queue lock.
    #
    # Executed only by the owner.
    def push(queue : Queue*, size : Int32) : Nil
      head = @head.get(:acquire) # sync with other consumers
      tail = @tail.get(:relaxed)

      while !queue.value.empty? && (tail - head) < N
        fiber = queue.value.pop
        @buffer.to_unsafe[tail % N] = fiber
        tail += 1
        size -= 1
      end

      # make the fibers available for consumption
      @tail.set(tail, :release)

      # put any overflow on global queue
      if size > 0
        @global_queue.lock do
          @global_queue.push(queue, size)
        end
      end
    end

    # Get fiber from local runnable queue.
    #
    # Executed only by the owner.
    def get? : Fiber?
      head = @head.get(:acquire) # sync with other consumers

      loop do
        tail = @tail.get(:relaxed)
        return if tail == head

        fiber = @buffer.to_unsafe[head % N]
        head, success = @head.compare_and_set(head, head + 1, :acquire_release, :acquire)
        return fiber if success
      end
    end

    # Steal half of elements from local queue of src and put onto local queue.
    # Returns one of the stolen elements (or `nil` if failed).
    #
    # Can be executed by any scheduler.
    def steal_from(src : Runnables) : Fiber?
      tail = @tail.get(:relaxed)
      n = src.grab(@buffer, tail)
      return if n == 0

      n -= 1
      fiber = @buffer.to_unsafe[(tail + n) % N]
      return fiber if n == 0

      head = @head.get(:acquire) # sync with consumers
      raise "BUG: local queue overflow" if tail - head + n >= N

      # make the fibers available for consumption
      @tail.set(tail + n, :release)

      fiber
    end

    # Grabs a batch of fibers from local queue into dest local queue. Returns
    # number of grabbed fibers.
    #
    # Can be executed by any scheduler.
    protected def grab(buffer : StaticArray(Fiber, N), buffer_head : Int32) : Int32
      head = @head.get(:acquire) # sync with other consumers

      loop do
        tail = @tail.get(:acquire) # sync with the producer
        n = (tail - head) // 2

        return 0 if n == 0 # queue is empty
        next if n > N // 2 # read inconsistent head and tail

        n.times do |i|
          fiber = @buffer.to_unsafe[(head + i) % N]
          buffer.to_unsafe[(buffer_head + i) % N] = fiber
        end
        head, success = @head.compare_and_set(head, head + n, :acquire_release, :acquire)
        return n if success
      end
    end
  end
end
