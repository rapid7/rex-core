module Rex

  # This provides a correct way to time an operation provided within a block.
  #
  # @see https://blog.dnsimple.com/2018/03/elapsed-time-with-ruby-the-right-way/
  #
  # @yield [] The block whose operation should be timed.
  #
  # @return Returns the result of the block and the elapsed time in seconds.
  def self.stopwatch
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ret = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    [ret, elapsed]
  end

end
