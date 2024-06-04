module ExecutionContext
  # :nodoc:
  struct BlockedScheduler
    include Crystal::PointerLinkedList::Node

    def initialize(@scheduler : Scheduler)
    end

    @flag = Atomic(Bool).new(false)

    @[AlwaysInline]
    def set : Nil
      @flag.set(true, :release)
    end

    @[AlwaysInline]
    def set? : Bool
      @flag.get(:relaxed)
    end

    @[AlwaysInline]
    def trigger? : Bool
      @flag.swap(false, :acquire)
    end

    @[AlwaysInline]
    def unblock : Nil
      # don't interrupt the event loop for local enqueues: that's the EL
      # that enqueues runnable fibers!
      return if @scheduler == ExecutionContext::Scheduler.current

      # another scheduler enqueued something, interrupt the blocking EL to
      # resume spinning
      @scheduler.unblock
    end
  end
end
