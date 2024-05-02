{% if flag?(:ec) %}
  require "../src/execution_context"
{% end %}

def shuffle(arr)
  xs = 0xdeadbeef_u32

  arr.size.times do |i|
    xs ^= xs << 13
    xs ^= xs >> 17
    xs ^= xs << 5
    j = xs % (i + 1)
    arr[i], arr[j] = arr[j], arr[i]
  end
end

def qsort(arr)
  return insertion_sort(arr) if arr.size <= 32

  chan = Channel(Nil).new(capacity: 2)
  mid = partition(arr)
  low = arr[0...mid]
  high = arr[mid + 1...arr.size]

  spawn name: "f1" do
    qsort(low)
    chan.send nil
  end

  spawn name: "f2" do
    qsort(high)
    chan.send nil
  end

  2.times { chan.receive }
end

def partition(arr)
  pivot = arr.size - 1
  i = 0
  pivot.times do |j|
    if arr[j] <= arr[pivot]
      arr[i], arr[j] = arr[j], arr[i]
      i += 1
    end
  end
  arr[i], arr[pivot] = arr[pivot], arr[i]
  i
end

def insertion_sort(arr)
  (1...arr.size).each do |i|
    i.downto(1) do |n|
      break if arr[n] >= arr[n - 1]

      arr[n], arr[n - 1] = arr[n - 1], arr[n]
    end
  end
end

puts "init"
arr = Slice(Int32).new(200_000) { |i| i }

puts "shuffle"
shuffle(arr)

puts "running"
elapsed = Time.measure { qsort(arr) }

puts "took: #{elapsed}s"

arr.each_cons(2, reuse: true) do |(x, y)|
  abort "arr not sorted" if x >= y
end
