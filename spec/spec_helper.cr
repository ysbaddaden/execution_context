require "spec"
require "../src/execution_context"

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
