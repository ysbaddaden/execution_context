module ExecutionContext
  # OPTIMIZE: put a low priority on the thread so the OS can schedule it on a
  #           low power CPU core, rather than an efficient one.
  class Monitor
    struct Timer
      def initialize(@every : Time::Span)
        @last = Time.monotonic
      end

      def elapsed?(now)
        ret = @last + @every <= now
        @last = now if ret
        ret
      end
    end

    DEFAULT_EVERY                = 10.milliseconds
    DEFAULT_COLLECT_STACKS_EVERY = 5.seconds

    def initialize(
      @every = DEFAULT_EVERY,
      collect_stacks_every = DEFAULT_COLLECT_STACKS_EVERY
    )
      @collect_stacks_timer = Timer.new(collect_stacks_every)
      @thread = uninitialized Thread
      @thread = Thread.new(name: "SYSMON") { run_loop }
      @running_fibers = {} of Scheduler => {Fiber, Int32}
    end

    private def run_loop : Nil
      every do |now|
        mark_long_running_fibers(now)
        # TODO: run each EC event-loop every once in a while
        collect_stacks if @collect_stacks_timer.elapsed?(now)
      end
    end

    # Executes the block at exact intervals (depending on the OS scheduler
    # precision and overall OS load), without counting the time to execute the
    # block.
    #
    # OPTIMIZE: consider exponential backoff when all schedulers are pending to
    #           reduce CPU usage
    private def every(&)
      remaining = @every

      loop do
        Thread.sleep(remaining)
        now = Time.monotonic
        yield(now)
        remaining = (now + @every - Time.monotonic).clamp(Time::Span.zero..)
      rescue exception
        Crystal::System.print_error_buffered(
          "BUG: %s#every crashed with %s (%s)",
          self.class.name,
          exception.message,
          exception.class.name,
          backtrace: exception.backtrace)
      end
    end

    # Iterates each ExecutionContext and collects unused Fiber stacks.
    #
    # TODO: should maybe happen during GC collections (?)
    private def collect_stacks
      Crystal.trace :sched, "collect_stacks" do
        ExecutionContext.each(&.stack_pool?.try(&.collect))
      end
    end

    # Iterates each ExecutionContext::Scheduler and checks for how long the
    # current fiber has been running, and tells those that were already running
    # during the previous iteration to yield.
    #
    # Skips `Isolated` contexts where concurrency is disabled. Their fiber is
    # expected to run for as long as needed.
    #
    # At best, a fiber may be noticed right when it started, then found again on
    # the next iteration, so it will be asked to yield after running for ~10ms.
    #
    # At worst, a fiber may start right after an iteration, thus be noticed on
    # the next iteration, then asked to yield on the next one, so it will be
    # asked to yield after running for ~20ms.
    #
    # NOTE: fibers are still cooperative, which means they will only yield when
    #       reaching a yielding point, if it ever reaches such a point.
    private def mark_long_running_fibers(now)
      Thread.each do |thread|
        case scheduler = thread.current_scheduler?
        when MultiThreaded
          tick = scheduler.@tick
        when SingleThreaded
          tick = scheduler.@tick
        else
          next
        end

        # never ask a scheduler's main fiber to yield (it musn't)
        running_fiber = thread.current_fiber
        next if running_fiber == scheduler.@main_fiber

        # using tick to avoid ABA problem: if it changed then the scheduler
        # yielded, and just happens to be running the same fiber (don't
        # interrupt it)
        #
        # FIXME: not atomic, tick & current fiber may be out of sync (consider
        #        DWCAS? TaggedPointer?)
        if @running_fibers[scheduler]? == {running_fiber, tick}
          # the same fiber has been running continuously since the previous
          # loop iteration: tell it to yield

          if running_fiber.should_yield!
            # TODO: complain that the fiber has already been told to yield (but
            #       still hasn't)
          end
        end

        @running_fibers[scheduler] = {running_fiber, tick}
      end
    end
  end
end
