lib LibGC
  fun stop_world_external = GC_stop_world_external
  fun start_world_external = GC_start_world_external
end

module GC
  # :nodoc:
  @[AlwaysInline]
  def self.stop_world : Nil
    LibGC.stop_world_external
  end

  # :nodoc:
  @[AlwaysInline]
  def self.start_world : Nil
    LibGC.start_world_external
  end
end
