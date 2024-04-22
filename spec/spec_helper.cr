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

class TestTimeout
  def initialize(@timeout : Time::Span = 2.seconds)
    @start = Time.monotonic
    @cancelled = Atomic(Int32).new(0)
  end

  def cancel : Nil
    @cancelled.set(1)
    # LibC.dprintf 2, "TIMEOUT:CANCEL\n"
  end

  def elapsed?
    (Time.monotonic - @start) >= @timeout
  end

  def done?
    return true if @cancelled.get == 1
    raise "timeout reached" if elapsed?
    false
  end

  def sleep(interval = 100.milliseconds) : Nil
    # LibC.dprintf 2, "TIMEOUT:SLEEP\n"
    until done?
      ::sleep interval
    end
    # LibC.dprintf 2, "TIMEOUT:DONE\n"
  end

  def reset : Nil
    # LibC.dprintf 2, "TIMEOUT:RESET\n"
    @start = Time.monotonic
    @cancelled.set(0)
  end
end
