require 'fiber'
require 'io/nonblock'
require 'rex/compat'

module Rex
module IO

  # This fiber scheduler is heavily base on
  # https://blog.monotone.dev/ruby/2020/12/25/ruby-3-fiber.html
  class FiberScheduler
    def initialize
      @readable = {}
      @writable = {}
      @waiting = {}
      @ready = []
      @pending = []
      @blocking = 0
      @urgent = Rex::Compat.pipe
      @mutex = Mutex.new
    end

    # This allows the fiber to be scheduled in the #run thread from another thread
    def schedule_fiber(&block)
      @mutex.synchronize do
        @pending << block
      end
      # Wake up the scheduler
      @urgent.last.write_nonblock('.') rescue nil
    end

    def run
      while @readable.any? or @writable.any? or @waiting.any? or @blocking.positive? or @ready.any? or @pending.any?
        # Start any pending fibers
        pending_blocks = []
        @mutex.synchronize do
          pending_blocks = @pending.dup
          @pending.clear
        end

        pending_blocks.each do |block|
          fiber = Fiber.new(blocking: false, &block)
          fiber.resume
        end

        begin
          readable, writable = ::IO.select(@readable.keys + [@urgent.first], @writable.keys, [], 0.1)
        rescue ::IOError
          cleanup_closed_ios
          next
        end

        # Drain the urgent pipe
        if readable&.include?(@urgent.first)
          @urgent.first.read_nonblock(1024) rescue nil
        end

        readable&.each do |io|
          next if io == @urgent.first

          if fiber = @readable.delete(io)
            fiber.resume
          end
        end

        writable&.each do |io|
          if fiber = @writable.delete(io)
            fiber.resume
          end
        end

        @waiting.keys.each do |fiber|
          if current_time > @waiting[fiber]
            @waiting.delete(fiber)
            fiber.resume
          end
        end

        ready, @ready = @ready, []
        ready.each do |fiber|
          fiber.resume
        end
      end
    end

    def io_wait(io, events, timeout)
      unless (events & ::IO::READABLE).zero?
        @readable[io] = Fiber.current
      end
      unless (events & ::IO::WRITABLE).zero?
        @writable[io] = Fiber.current
      end

      Fiber.yield
      events
    end

    def kernel_sleep(duration = nil)
      block(:sleep, duration)
      true
    end

    def block(blocker, timeout = nil)
      if timeout
        @waiting[Fiber.current] = current_time + timeout
        begin
          Fiber.yield
        ensure
          @waiting.delete(Fiber.current)
        end
      else
        @blocking += 1
        begin
          Fiber.yield
        ensure
          @blocking -= 1
        end
      end
    end

    def unblock(blocker, fiber)
      @ready << fiber
      io = @urgent.last
      io.write_nonblock('.')
    end

    def close
      run
      @urgent.each(&:close)
      @urgent = nil
    end

    def closed?
      @urgent.nil?
    end

    def reset!
      @mutex.synchronize do
        @readable.clear
        @writable.clear
        @waiting.clear
        @ready.clear
        @pending.clear
        @blocking = 0
        @urgent = Rex::Compat.pipe
      end
    end

    def fiber(&block)
      fiber = Fiber.new(blocking: false, &block)
      fiber.resume
      fiber
    end

    private

    def current_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def cleanup_closed_ios
      @readable.delete_if { |io, _| io.closed? rescue true }
      @writable.delete_if { |io, _| io.closed? rescue true }
      @waiting.delete_if { |fiber, _| !fiber || !fiber.alive? rescue true }
    end
  end

end
end