module ExecutionContext
  # :nodoc:
  struct BlockedScheduler
    include Crystal::PointerLinkedList::Node

    def initialize(@scheduler : Scheduler)
    end

    @flag = Atomic(Int32).new(0)

    @[AlwaysInline]
    def set : Nil
      @flag.set(1, :relaxed)
    end

    @[AlwaysInline]
    def trigger? : Bool
      @flag.swap(0, :relaxed) == 1
    end

    @[AlwaysInline]
    def unblock : Nil
      # always trigger the atomic (to avoid a useless #delete in #blocking)
      return unless trigger?

      # don't interrupt the event loop for local enqueues: that's the EL
      # that enqueues runnable fibers!
      return if @scheduler == ExecutionContext::Scheduler.current

      # another scheduler enqueued something, interrupt the blocking EL to
      # resume spinning
      @scheduler.unblock
    end
  end
end
