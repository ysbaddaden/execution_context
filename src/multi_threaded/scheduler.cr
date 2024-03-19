require "../runnables"

module ExecutionContext
  class MultiThreaded
    include ExecutionContext

    # Fiber scheduler. Owns a thread inside a MT execution context.
    #
    # Inherits from `ExecutionContext` to be the target for calls to the current
    # execution context (e.g. local spawn, yield, ...) while the actual
    # `ExecutionContext::MultiThread` is meant for cross context spawns and
    # enqueues.
    #
    # TODO: cooperative shutdown (e.g. when shrinking number of schedulers)
    class Scheduler
      include ExecutionContext::Scheduler

      protected property execution_context : MultiThreaded
      protected property! thread : Thread
      protected property! main_fiber : Fiber
      protected getter name : String

      @runnables : Runnables(256)

      # TODO: should eventually have one EL per EC
      getter event_loop : Crystal::EventLoop

      property? idle : Bool = false

      @tick : Int32 = 0
      @name : String

      protected def initialize(@execution_context, @name)
        @runnables = Runnables(256).new(@execution_context.global_queue)
        @event_loop = Crystal::EventLoop.create
      end

      # :nodoc:
      def stack_pool : Fiber::StackPool
        @execution_context.stack_pool
      end

      @[Deprecated]
      def spawn(*, name : String? = nil, same_thread : Bool, &block : ->) : Fiber
        raise RuntimeError.new("#{self.class.name}#spawn doesn't support same_thread:true") if same_thread
        self.spawn(name: name, &block)
      end

      # Unlike `ExecutionContext::MultiThreaded#enqueue` this method is only
      # safe to call on `ExecutionContext.current` which should always be the
      # case, since cross context enqueues will call EC::MT#enqueue through
      # Fiber#enqueue).
      protected def enqueue(fiber : Fiber) : Nil
        @runnables.push(fiber)
        @execution_context.unpark_idle_thread unless @runnables.empty?
      end

      protected def reschedule : Nil
        if fiber = dequeue?
          resume fiber unless fiber == thread.current_fiber
        else
          # nothing to do: switch back to the main loop
          resume main_fiber
        end
      end

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

        # dequeue from local queue
        if fiber = @runnables.get?
          return fiber
        end

        # grab from global queue (tries to refill local queue)
        if fiber = global_dequeue?
          return fiber
        end

        # poll the event loop
        if @event_loop.run(blocking: false)
          if fiber = @runnables.get?
            return fiber
          end
        end

        # steal from another scheduler (if possible)
        if fiber = try_steal?
          return fiber
        end
      end

      @[AlwaysInline]
      protected def global_dequeue? : Fiber?
        if fiber = @execution_context.global_queue.grab?(@runnables, divisor: @execution_context.size)
          fiber
        end
      end

      @[AlwaysInline]
      protected def try_steal? : Fiber?
        @execution_context.steal do |other|
          if other == self
            next
          end

          if fiber = @runnables.steal_from(other.@runnables)
            return fiber
          end
        end
      end

      protected def run_loop : Nil
        loop do
          # the queue should usually be empty at this point (but just in case)
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
          #
          # OPTIMIZE: spin and sleep with an increasing back-off instead of
          #           parking the thread immediately to try and avoid
          #           consecutive park <-> wakeup loops
          if fiber = @execution_context.park_thread(self)
            @idle = false
            resume fiber
            next
          end

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
