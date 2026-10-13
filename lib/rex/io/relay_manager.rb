require 'rex/io/fiber_scheduler'

module Rex
module IO

# An IO RelayManager which will read data from a socket and write it to a sink
# using a background thread.
class RelayManager
  attr_reader :thread

  def initialize
    @thread = nil
    @scheduler = FiberScheduler.new
    @mutex = Mutex.new
    @teardown_condition = ConditionVariable.new
    @tearing_down = false
    @running = false
  end

  # Add a IO relay to the manager. This will start relaying data from the source
  # socket to the destination sink immediately. An optional "on_exit" callback
  # can be provided which will be called when the socket is closed.
  #
  # @param sock [::Socket] The source socket that data will be read from.
  # @param sink [#write, #call] A data destination where read data will be sent. It is called
  #   with one parameter, the data to be transferred. If the object exposes a #write method, it will
  #   be called repeatedly all data is processed and the return value will be used to determine how
  #   much of the data was written. If the object exposes a #call method, it will be called once and
  #   must handle processing all the data it is provided.
  # @param name [String] A human-friendly name for the relay used in debug output.
  # @param on_exit [#call] A callback to be invoked when sink can no longer be read from.
  def add_relay(sock, sink: nil, name: nil, on_exit: nil)
    @mutex.synchronize do
      # An external caller that arrives during worker teardown waits until the
      # scheduler is reusable. A callback on the worker itself must remain
      # nonblocking; the scheduler's final run will process its accepted work.
      while @tearing_down && Thread.current != @thread
        @teardown_condition.wait(@mutex)
      end

      start_gate = start unless running?

      begin
        @scheduler.schedule_fiber do
          relay_fiber(sock, sink, name, on_exit: on_exit)
        end
      ensure
        start_gate << true if start_gate
      end
    end
  end

  # Write all data to the specified IO. This is intended to be used in scenarios
  # where partial writes are possible but not desirable.
  #
  # @param io [#write] An object to write the data to. It must return a number indicating
  #   how many bytes of the provided data were processed.
  # @param data [String] The data that should be written.
  def self.io_write_all(io, data)
    offset = 0
    while offset < data.bytesize
      written = io.write(data.byteslice(offset..-1))
      offset += written
    end
    data.bytesize
  end

  private

  def running?
    @running
  end

  def start
    return nil if running?

    start_gate = Queue.new
    @running = true
    @thread = Thread.new do
      start_gate.pop
      run
    end
    start_gate
  rescue StandardError
    @running = false
    raise
  end

  def run
    teardown_started = false
    old_scheduler = Fiber.scheduler
    # A fiber scheduler can be set per-thread
    Fiber.set_scheduler(@scheduler)

    loop do
      # Run the scheduler (blocks here)
      @scheduler.run

      # #add_relay schedules and tests @running while holding this same lock.
      # If it won the race after the scheduler observed an empty queue, process
      # its accepted work before committing this worker to teardown.
      teardown_started = @mutex.synchronize do
        if @scheduler.work_pending?
          false
        else
          @tearing_down = true
          true
        end
      end
      break if teardown_started
    end
  ensure
    # On an exceptional exit, commit to teardown before removing the scheduler.
    # External submissions then wait; callbacks on this worker remain able to
    # schedule work for the scheduler's final run.
    @mutex.synchronize { @tearing_down = true } unless teardown_started

    begin
      Fiber.set_scheduler(old_scheduler)
    ensure
      begin
        @scheduler.reset!
      ensure
        @mutex.synchronize do
          @running = false
          @tearing_down = false
          @teardown_condition.broadcast
        end
      end
    end
  end

  def relay_fiber(sock, sink, name, on_exit: nil)
    loop do
      break if sock.closed?

      buf = sock.readpartial(32_768)
      write_to_sink(sink, buf)
    end
  rescue EOFError
    nil
  rescue => e
    message = "#{self.class.name}#relay_fiber(name: #{name}): #{e.class} #{e}"
    if defined?(elog)  # elog is defined by framework, otherwise use stderr
      elog(message, error: e)
    else
      $stderr.puts message
    end
  ensure
    unless sock.closed?
      sock.close rescue nil
    end

    on_exit.call if on_exit
  end

  def write_to_sink(sink, data)
    if sink.respond_to?(:write)
      self.class.io_write_all(sink, data)

    elsif sink.respond_to?(:call)
      sink.call(data)

    else
      raise ArgumentError, "Unsupported sink type: #{sink.inspect}"
    end
  end
end

end
end
