require "../runnables"

abstract class ExecutionContext
  class MultiThreaded < ExecutionContext
    # Fiber scheduler. Owns a thread inside a MT execution context.
    #
    # Inherits from `ExecutionContext` to be the target for calls to the current
    # execution context (e.g. local spawn, yield, ...) while the actual
    # `ExecutionContext::MultiThread` is meant for cross context spawns and
    # enqueues.
    #
    # TODO: cooperative shutdown (e.g. when shrinking number of schedulers)
    class Scheduler < ExecutionContext
      property execution_context : MultiThreaded

      @thread = uninitialized Thread
      property thread : Thread

      @main_fiber = uninitialized Fiber
      property main_fiber : Fiber

      property idle? : Bool = false

      def initialize(@execution_context)
        @runnables = Runnables(256).new(@execution_context.global_queue)
        @tick = 0
      end

      # Unlike `ExecutionContext::MultiThreaded#enqueue` this method is only
      # safe to call on `ExecutionContext.current`!
      def enqueue(fiber : Fiber) : Nil
        @runnables.push(fiber)
      end

      def spawn(name : String?, &block : ->) : Fiber
        fiber = Fiber.new(name: name, execution_context: @execution_context, &block)
        enqueue fiber
        fiber
      end

      # :nodoc:
      def spawn(name : String?, same_thread : Bool, &block : ->) : Fiber
        raise RuntimeError.new("ExecutionContext::MultiThreaded doesn't support same_thread:true attribute") if same_thread
        self.spawn(name, &block)
      end

      protected def reschedule : Nil
        if fiber = dequeue?
          resume fiber
        else
          resume @main_fiber
        end
      end

      # In a multithreaded environment the fiber may be dequeued before its
      # running context has been saved on the stack; we must wait until the
      # context switch assembly saved all registers on the stack and set the
      # fiber as resumable.
      #
      # FIXME: if the thread saving the fiber context has been preempted, this
      #        also blocks the current thread from progressing... shall we abort
      #        and reenqueue the fiber after some spins?
      private def validate_resumable(fiber)
        until fiber.resumable?
          if fiber.dead?
            message = String.build do |str|
              str << "\nFATAL: tried to resume a dead fiber: "
              fiber.to_s(str)
              str << '\n'
              caller.each { |line| str << "  from " << line << '\n' }
            end

            Crystal::System.print_error(message)
            exit 1
          end

          Intrinsics.pause
        end
      end

      @[AlwaysInline]
      protected def steal_from(scheduler : Scheduler) : Fiber?
        @runnables.steal_from(scheduler.@runnables)
      end

      protected def run_loop : Nil
        loop do
          # first try to dequeue from local/global queues and run the event-loop
          # (nonblocking)
          if fiber = dequeue?
            resume(fiber)
          end

          # nothing to do: consider parking the thread, which will check the
          # queues again, run the event loop (blocking) and may eventually park
          # the thread if there's really nothing left to do
          if fiber = try_park_thread?
            resume(fiber)
          end
        end
      end

      @[AlwaysInline]
      private def dequeue? : Fiber?
        # every once in a while: dequeue from global queue; avoids two fibers
        # constantly respawing each other to completely occupy the queue
        if (@tick &+= 1) % 61 == 0
          if fiber = global_dequeue?
            return fiber
          end
        end

        # dequeue from local queue
        if fiber = local_dequeue?
          return fiber
        end

        # dequeue from global queue
        if fiber = @execution_context.global_dequeue?
          return fiber
        end

        # poll the event-loop unless another thread is already running it
        if Crystal::EventLoop.try_lock? { Crystal::EventLoop.run(blocking: false) }
          # eloop may have queued fibers, or not, or in another context
          if fiber = local_dequeue?
            return fiber
          end
        end

        # steal from another scheduler
        if fiber = @execution_context.steal(self)
          return fiber
        end
      end

      def local_dequeue? : Fiber?
        @runnables.get?
      end

      @[AlwaysInline]
      private def try_park_thread? : Fiber?
        # @execution_context.synchronize do
        #   # check again the local queue after we locked the mutex (avoid races)
        #   if fiber = local_dequeue?
        #     return fiber
        #   end

        #   # same for the global queue
        #   if fiber = global_dequeue?
        #     return fiber
        #   end

        #   ## try to lock the event loop, blocking the current thread:
        #   ##
        #   ## OPTIMIZE: consider checking whether it was locked blocking or
        #   ## nonblocking; if nonblocking we might want to try again before
        #   ## parking the thread
        #   #unless @event_loop.try_lock?
        #   #  # really nothing to do: let's sleep
        #   #  @idle = true
        #   #  @execution_context.park
        #   #  @idle = false

        #   #  # on wakeup: resume normal operation
        #   #  return
        #   #end
        # end

        # if we reached this point, we locked the event loop, let's run it and
        # block waiting for events to be triggerable:
        # begin
        #   if @event_loop.run(blocking: true)
        #     # eloop may have queued fibers, locally or globally, or in another
        #     # scheduler, or not or in another scheduler: resume normal operation
        #     return
        #   end
        # ensure
        #   Crystal::EvenLoop.unlock
        # end

      #rescue exception
      #  FIXME: a worker thread crashed (this is the thread's main fiber, not any fiber)
      #         => call a configurable handler?
      #         => print the error and continue?
      #         => panic & abort the process?
      end
    end
  end
end
