data = Hash(Int32, Array(Float64)).new
# threads = [1, 2, 4, 8, 12, 16, 32, 64, 128]
threads = [1, 2, 4, 8, 12, 16]

class Array
  def avg
    size > 0 ? sum / size : 0
  end
end

threads.each do |i|
  print "MT:"
  print i

  ARGV.each do |command|
    results = [] of String

    10.times do
      results << `CRYSTAL_WORKERS=#{i} ./#{command}`
    end

    times = results.compact_map do |result|
      if result =~ /00:00:(\d\d\.\d+)/
        $1.to_f
      end
    end

    print '\t'
    print (times.avg * 1000).to_i
  end

  print '\n'
end

puts

data.each do |_, results|
  puts (results.avg * 1000).to_i
end
