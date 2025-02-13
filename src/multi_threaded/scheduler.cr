require "crystal/pointer_linked_list"
require "../runnables"

module ExecutionContext
  class MultiThreaded
    include ExecutionContext

    # Fiber scheduler. Owns a thread inside a MT execution context.
    #
    # TODO: cooperative shutdown (e.g. when shrinking number of schedulers)
    class Scheduler
      include ExecutionContext::Scheduler

      protected property execution_context : MultiThreaded
      protected property! thread : Thread
      protected property! main_fiber : Fiber
      getter name : String

      @runnables : Runnables(256)

      @tick : Int32 = 0
      getter? idle : Bool
      getter? spinning : Bool = false
      @waiting = false
      @parked = false

      protected def initialize(@execution_context, @name, @idle = true)
        @global_queue = @execution_context.global_queue
        @event_loop = @execution_context.event_loop
        @runnables = Runnables(256).new(@global_queue)
      end

      # :nodoc:
      def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
        raise RuntimeError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
        self.spawn(name: name, &block)
      end

      # Unlike `ExecutionContext::MultiThreaded#enqueue` this method is only
      # safe to call on `ExecutionContext.current` which should always be the
      # case, since cross context enqueues will call EC::MT#enqueue through
      # Fiber#enqueue).
      protected def enqueue(fiber : Fiber) : Nil
        Crystal.trace :sched, "enqueue", fiber: fiber
        @runnables.push(fiber)
        @execution_context.wake_scheduler unless @execution_context.capacity == 1
      end

      # Enqueue a list of fibers in a single operation and returns a fiber to
      # resume immediately.
      #
      # This is called after running the event loop for example.
      private def enqueue(queue : Queue*) : Fiber?
        if fiber = queue.value.pop?
          Crystal.trace :sched, "enqueue", size: queue.value.size, fiber: fiber
          unless queue.value.empty?
            @runnables.bulk_push(queue)
            @execution_context.wake_scheduler
          end
          fiber
        end
      end

      protected def reschedule : Nil
        Crystal.trace :sched, "reschedule"
        if fiber = quick_dequeue?
          resume fiber unless fiber == thread.current_fiber
        else
          # nothing to do: switch back to the main loop to spin/park
          resume main_fiber
        end
      end

      protected def resume(fiber : Fiber) : Nil
        Crystal.trace :sched, "resume", fiber: fiber

        # in a multithreaded environment the fiber may be dequeued before its
        # running context has been saved on the stack (thread A tries to resume
        # fiber that thread B didn't yet saved its context); we must wait until
        # the context switch assembly saved all registers on the stack and set
        # the fiber as resumable.
        until fiber.resumable?
          if fiber.dead?
            Crystal::System.print_error_buffered(
              "FATAL: tried to resume a dead fiber %s (%s)",
              fiber.to_s, inspect, backtrace: caller)
            exit 1
          end

          # FIXME: if the thread saving the fiber context has been preempted,
          #        this will block the current thread from progressing...
          #        shall we abort and reenqueue the fiber after MAX iterations?
          Intrinsics.pause
        end

        swapcontext(fiber)
      end

      @[AlwaysInline]
      private def quick_dequeue? : Fiber?
        # every once in a while: dequeue from global queue to avoid two fibers
        # constantly respawing each other to completely occupy the local queue
        if (@tick &+= 1) % 61 == 0
          if fiber = @global_queue.pop?
            return fiber
          end
        end

        # dequeue from local queue
        if fiber = @runnables.get?
          return fiber
        end
      end

      private def try_steal? : Fiber?
        @execution_context.steal do |other|
          if other == self
            # no need to steal from ourselves
            next
          end

          if fiber = @runnables.steal_from(other.@runnables)
            Crystal.trace :sched, "stolen", from: other, size: @runnables.size, fiber: fiber
            return fiber
          end
        end
      end

      protected def run_loop : Nil
        Crystal.trace :sched, "started"

        loop do
          @idle = true

          if fiber = find_next_runnable
            spin_stop if @spinning
            @idle = false
            resume fiber
          else
            # the event loop enqueued a fiber (or was interrupted) or the
            # scheduler was unparked: go for the next iteration
          end
        rescue exception
          Crystal::System.print_error_buffered(
            "BUG: %s#run_loop [%s] crashed with %s (%s)",
            self.class.name,
            @name,
            exception.message,
            exception.class.name,
            backtrace: exception.backtrace)
        end
      end

      private def find_next_runnable : Fiber?
        find_next_runnable do |fiber|
          return fiber if fiber
        end
      end

      private def find_next_runnable(&) : Nil
        queue = Queue.new

        # nothing to do: start spinning
        spinning do
          yield @global_queue.grab?(@runnables, divisor: @execution_context.size)

          if @execution_context.lock_evloop? { @event_loop.run(pointerof(queue), blocking: false) }
            spin_stop
            yield enqueue(pointerof(queue))
          end

          yield try_steal?
        end

        # wait on the event loop for events and timers to activate
        result = @execution_context.lock_evloop? do
          @waiting = true

          # there is a time window between stop spinning and start waiting
          # during which another context may have enqueued a fiber, check again
          # before blocking on the event loop to avoid missing a runnable fiber,
          # which may block for a long time:
          yield @global_queue.grab?(@runnables, divisor: @execution_context.size)

          # block on the event loop until an event is ready or the loop is
          # interrupted
          @event_loop.run(pointerof(queue), blocking: true)
        ensure
          @waiting = false
        end

        if result
          yield enqueue(pointerof(queue))

          # the event loop was interrupted: restart
          return
        else
          # evloop doesn't wait when empty (e.g. libevent)
        end

        # no runnable fiber, no event in the event loop or another thread is
        # already running it: go into deep sleep until another scheduler or
        # another context enqueues a fiber
        @execution_context.park_thread do
          # by the time we acquired the lock, another thread may have enqueued
          # fiber(s) and already tried to wakeup a thread (race). we don't check
          # the scheduler's local queue nor its event loop (both are empty)
          yield @global_queue.unsafe_grab?(@runnables, divisor: @execution_context.size)

          # OPTIMIZE: may hold the lock for a while (increasing with threads)
          yield try_steal?

          @parked = true
          nil
        end
        @parked = false

        # immediately mark the scheduler as spinning (we just unparked);
        # we don't increment the number of spinning threads since
        # MultiThread#wake_scheduler already did before unparking the thread.
        @spinning = true
      end

      # OPTIMIZE: skip spinning if spinning >= running/2
      private def spinning(&)
        spin_start

        4.times do |iter|
          spin_backoff(iter) unless iter == 0
          yield
        end

        spin_stop
      end

      @[AlwaysInline]
      private def spin_start : Nil
        return if @spinning

        @spinning = true
        @execution_context.@spinning.add(1, :acquire_release)
      end

      @[AlwaysInline]
      private def spin_stop : Nil
        return unless @spinning

        @execution_context.@spinning.sub(1, :acquire_release)
        @spinning = false
      end

      @[AlwaysInline]
      private def spin_backoff(iter)
        # OPTIMIZE: consider exponential backoff, but beware of edge cases, like
        # creating latency before we notice a cross context enqueue, for example)
        Thread.yield
      end

      @[AlwaysInline]
      def inspect(io : IO) : Nil
        to_s(io)
      end

      def to_s(io : IO) : Nil
        io << "#<" << self.class.name << ":0x"
        object_id.to_s(io, 16)
        io << ' ' << @name << '>'
      end

      def status : String
        if @spinning
          "spinning"
        elsif @waiting
          "event-loop"
        elsif @parked
          "parked"
        elsif @idle
          "idle"
        else
          "running"
        end
      end
    end
  end
end
