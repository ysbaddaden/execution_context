require "spec"
require "../src/execution_context"

lib LibC
  fun nanosleep(Timespec*, Timespec*) : UInt
end

class Thread
  def self.sleep(span : Time::Span) : Nil
    ts = uninitialized LibC::Timespec
    ts.tv_sec = typeof(ts.tv_sec).new(span.seconds)
    ts.tv_nsec = typeof(ts.tv_nsec).new(span.nanoseconds)

    if LibC.nanosleep(pointerof(ts), out rem) == -1
      raise RuntimeError.from_errno("nanosleep") unless Errno.value == Errno::EINTR
    end
  end
end

class FiberCounter
  def initialize(@fiber : Fiber)
    @counter = Atomic(Int32).new(0)
  end

  # fetch and add
  def increment
    @counter.add(1, :relaxed) + 1
  end

  def counter
    @counter.get(:relaxed)
  end
end

