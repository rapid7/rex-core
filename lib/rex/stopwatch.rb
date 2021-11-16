module Rex::Stopwatch

  # This provides a correct way to time an operation provided within a block.
  #
  # @see https://blog.dnsimple.com/2018/03/elapsed-time-with-ruby-the-right-way/
  # @see https://ruby-doc.org/core-2.7.1/Process.html#method-c-clock_gettime
  #
  # @param [Symbol] unit The unit of time in which to measure the duration. The
  #   argument is passed to Process.clock_gettime which defines the acceptable
  #   values.
  #
  # @yield [] The block whose operation should be timed.
  #
  # @return Returns the result of the block and the elapsed time in the specified unit.
  def self.elapsed_time(unit: :float_second)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC, unit)
    ret = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, unit) - start

    [ret, elapsed]
  end

end
