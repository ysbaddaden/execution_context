module ExecutionContext
  struct AtomicBool
    TRUE  = 1_u8
    FALSE = 0_u8

    def initialize(value : Bool)
      @value = value ? TRUE : FALSE
    end

    def swap(value : Bool, ordering : Atomic::Ordering = :sequentially_consistent) : Bool
      int = value ? TRUE : FALSE

      case ordering
      in .relaxed?
        Atomic::Ops.atomicrmw(:xchg, pointerof(@value), int, :monotonic, false) == TRUE
      in .acquire?
        Atomic::Ops.atomicrmw(:xchg, pointerof(@value), int, :acquire, false) == TRUE
      in .release?
        Atomic::Ops.atomicrmw(:xchg, pointerof(@value), int, :release, false) == TRUE
      in .acquire_release?
        Atomic::Ops.atomicrmw(:xchg, pointerof(@value), int, :acquire_release, false) == TRUE
      in .sequentially_consistent?
        Atomic::Ops.atomicrmw(:xchg, pointerof(@value), int, :sequentially_consistent, false) == TRUE
      end
    end

    def get(ordering : Atomic::Ordering = :sequentially_consistent) : Bool
      case ordering
      in .relaxed?
        Atomic::Ops.load(pointerof(@value), :monotonic, true) == TRUE
      in .acquire?
        Atomic::Ops.load(pointerof(@value), :acquire, true) == TRUE
      in .sequentially_consistent?
        Atomic::Ops.load(pointerof(@value), :sequentially_consistent, true) == TRUE
      in .release?, .acquire_release?
        raise ArgumentError.new("Atomic load cannot have release semantic")
      end
    end

    def set(value : Bool, ordering : Atomic::Ordering = :sequentially_consistent) : Bool
      int = value ? TRUE : FALSE

      case ordering
      in .relaxed?
        Atomic::Ops.store(pointerof(@value), int, :monotonic, true) == TRUE
      in .release?
        Atomic::Ops.store(pointerof(@value), int, :release, true) == TRUE
      in .sequentially_consistent?
        Atomic::Ops.store(pointerof(@value), int, :sequentially_consistent, true) == TRUE
      in .acquire?, .acquire_release?
        raise ArgumentError.new("Atomic store cannot have acquire semantic")
      end
    end
  end
end
