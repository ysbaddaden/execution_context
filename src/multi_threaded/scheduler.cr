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
      protected property execution_context : MultiThreaded
      protected property! thread : Thread
      protected property! main_fiber : Fiber

      @runnables : Runnables(256)

      # TODO: should eventually have one EL per EC
      getter event_loop : Crystal::EventLoop = Crystal::EventLoop.create

      property? idle : Bool = false
      @tick : Int32 = 0
      @name : String

      protected def initialize(@execution_context, @name)
        @runnables = Runnables(256).new(@execution_context.global_queue)
      end

      # :nodoc:
      def stack_pool : Fiber::StackPool
        # TODO: there should be one stack pool per execution context
        # @execution_context.stack_pool
        @stack_pool ||= Fiber::StackPool.new
      end

      # Unlike `ExecutionContext::MultiThreaded#enqueue` this method is only
      # safe to call on `ExecutionContext.current` which should always be the
      # case, since cross context enqueues will call EC::MT#enqueue).
      def enqueue(fiber : Fiber) : Nil
        # LibC.dprintf 2, "thread=0x#{LibC.pthread_self.to_s(16)} mt.scheduler#enqueue fiber=0x#{fiber.object_id.to_s(16)}\n"

        @runnables.push(fiber)
        @execution_context.unpark_idle_thread
      end

      def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
        raise RuntimeError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
        self.spawn(name: name, &block)
      end

      protected def reschedule : Nil
        # LibC.dprintf 2, "thread=0x#{LibC.pthread_self.to_s(16)} mt.scheduler#reschedule fiber=0x#{Fiber.current.object_id.to_s(16)}\n"

        if fiber = dequeue?
          resume fiber unless fiber == thread.current_fiber
        else
          # nothing to do: switch back to the main loop
          resume main_fiber
        end
      end

      # protected def resume(fiber : Fiber) : Nil
      #   LibC.dprintf 2, "thread=0x#{LibC.pthread_self.to_s(16)} mt.scheduler#resume fiber=0x#{fiber.object_id.to_s(16)}\n"
      #   super
      # end

      # In a multithreaded environment the fiber may be dequeued before its
      # running context has been saved on the stack; we must wait until the
      # context switch assembly saved all registers on the stack and set the
      # fiber as resumable.
      private def validate_resumable(fiber : Fiber) : Nil
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

          # FIXME: if the thread saving the fiber context has been preempted,
          #        this will block the current thread from progressing...
          #        shall we abort and reenqueue the fiber after MAX iterations?
          Intrinsics.pause
        end
      end

      @[AlwaysInline]
      private def dequeue? : Fiber?
        # every once in a while: dequeue from global queue to avoid two fibers
        # constantly respawing each other to completely occupy the local queue
        if (@tick &+= 1) % 61 == 0
          if fiber = @execution_context.global_queue.pop?
            return fiber
          end
        end

        # grab from local queue
        if fiber = @runnables.get?
          return fiber
        end

        # dequeue from global queue (tries to refill local queue)
        if fiber = global_dequeue?
          return fiber
        end

        # poll the event loop
        if @event_loop.run(blocking: false)
          if fiber = @runnables.get?
            return fiber
          end
        end

        # steal from another scheduler
        if fiber = @execution_context.steal(self)
          return fiber
        end
      end

      @[AlwaysInline]
      private def global_dequeue? : Fiber?
        @execution_context
          .global_queue
          .grab?(@runnables, @execution_context.size)
      end

      protected def run_loop : Nil
        loop do
          # dequeue from local/global queues, poll the event-loop, steal, ...
          if fiber = @runnables.get?
            resume fiber
            next
          end

          if fiber = global_dequeue?
            resume fiber
            next
          end

          @idle = true

          # block on the event loop, waiting for pending event(s) to activate
          if @event_loop.run(blocking: true)
            if fiber = @runnables.get?
              @idle = false
              resume fiber
              next
            end
          end

          # no runnable fiber, no pending event in the local event loop: go into
          # deep sleep until another scheduler or another context enqueues a
          # fiber
          @execution_context.park_thread

          @idle = false
        rescue exception
          message = String.build do |str|
            str << "BUG: " << self.class.name << "#run_loop crashed with " << exception.class.name << '\n'
            exception.backtrace.each { |line| str << "  from " << line << '\n' }
          end
          Crystal::System.print_error(message)
        end
      end

      @[AlwaysInline]
      protected def steal_from(scheduler : Scheduler) : Fiber?
        @runnables.steal_from(scheduler.@runnables)
      end

      @[AlwaysInline]
      def inspect(io : IO) : Nil
        to_s(io)
      end

      def to_s(io : IO) : Nil
        io << "#<" << self.class.name << ":0x"
        object_id.to_s(io, 16)
        io << ' ' << @name << " thread=0x"
        thread.@system_handle.to_s(io, 16)
        io << '>'
      end
    end
  end
end
