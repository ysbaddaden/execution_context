module Crystal::System
  def self.print_error_buffered(message, *args, backtrace = nil) : Nil
    buf = Crystal::StackIO(4096).new
    printf(message, *args) { |bytes| buf.write(bytes) }
    buf.write("\n")
    backtrace.each { |frame| printf("  from %s\n", frame) { |bytes| buf.write(bytes) } } if backtrace
    Crystal::System.print_error(buf.to_slice)
  end
end
