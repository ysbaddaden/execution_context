# Identical to `master` but explicitly calls `_exit(2)` instead of returning the
# status for main to return normally. this is required when the default execution
# context is MT, where the main thread's main fiber may be stolen and resumed by
# any thread: let's explicitly exit, instead of relying on main returning.

module Crystal
  def self.main(&block)
    GC.init

    status =
      begin
        yield
        0
      rescue ex
        1
      end

    LibC._exit(self.exit(status, ex))
  end

  def self.main(argc : Int32, argv : UInt8**)
    main do
      main_user_code(argc, argv)
    rescue ex
      Crystal::System.print_exception "Unhandled exception", ex
      LibC._exit(1)
    end
  end
end
