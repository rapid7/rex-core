require 'rex/compat'
require 'rex/io/fiber_scheduler'

RSpec.describe Rex::IO::FiberScheduler do
  let(:scheduler) { described_class.new }

  after do
    if scheduler && !scheduler.closed?
      scheduler.close
    end
  end

  describe '#initialize' do
    it 'initializes with empty state' do
      expect(scheduler.instance_variable_get(:@readable)).to eq({})
      expect(scheduler.instance_variable_get(:@writable)).to eq({})
      expect(scheduler.instance_variable_get(:@waiting)).to eq({})
      expect(scheduler.instance_variable_get(:@ready)).to eq([])
      expect(scheduler.instance_variable_get(:@pending)).to eq([])
      expect(scheduler.instance_variable_get(:@blocking)).to eq(0)
    end

    it 'creates an urgent pipe for signaling' do
      urgent = scheduler.instance_variable_get(:@urgent)
      expect(urgent).to be_a(Array)
      expect(urgent.first).to be_a(IO)
      expect(urgent.last).to be_a(IO)
    end

    it 'creates a mutex for thread safety' do
      mutex = scheduler.instance_variable_get(:@mutex)
      expect(mutex).to be_a(Mutex)
    end
  end

  describe '#fiber' do
    it 'creates and resumes a new non-blocking fiber' do
      executed = false
      fiber = scheduler.fiber { executed = true }

      expect(fiber).to be_a(Fiber)
      expect(executed).to be true
    end

    it 'returns the fiber' do
      fiber = scheduler.fiber { :result }
      expect(fiber).to be_a(Fiber)
    end
  end

  describe '#schedule_fiber' do
    it 'schedules a fiber for later execution' do
      executed = false

      scheduler.schedule_fiber { executed = true }

      expect(executed).to be false
      pending = scheduler.instance_variable_get(:@pending)
      expect(pending.size).to eq(1)
    end

    it 'wakes up the scheduler via urgent pipe' do
      urgent_pipe = scheduler.instance_variable_get(:@urgent)

      scheduler.schedule_fiber { :test }

      # The urgent pipe should have data
      readable, = IO.select([urgent_pipe.first], nil, nil, 0)
      expect(readable).to include(urgent_pipe.first)
    end

    it 'is thread-safe' do
      counter = Mutex.new
      completed = []

      threads = 10.times.map do
        Thread.new do
          100.times do |i|
            scheduler.schedule_fiber do
              scheduler.kernel_sleep(0.1)
              counter.synchronize { completed << true }
            end
          end
        end
      end

      threads.each(&:join)

      # All fibers should be scheduled
      pending = scheduler.instance_variable_get(:@pending)
      expect(pending.size).to eq(1000)

      # Now run them concurrently
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      scheduler.run
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

      # If sequential, would take 100 seconds (1000 * 0.1)
      # Concurrent should be much faster (slightly more than 0.1)
      expect(elapsed).to be > 0.1
      expect(elapsed).to be < 1.0
      expect(completed.size).to eq(1000)
    end
  end

  describe '#run' do
    it 'processes pending fibers' do
      results = []

      scheduler.schedule_fiber { results << 1 }
      scheduler.schedule_fiber { results << 2 }
      scheduler.schedule_fiber { results << 3 }

      run_thread = Thread.new { scheduler.run }
      run_thread.join(1)

      expect(results).to contain_exactly(1, 2, 3)
    end

    it 'exits when all work is complete' do
      scheduler.schedule_fiber { :done }

      expect { scheduler.run }.not_to raise_error
    end

    it 'processes readable IO events' do
      r, w = Rex::Compat.pipe
      result = nil

      scheduler.schedule_fiber do
        scheduler.io_wait(r, IO::READABLE, nil)
        result = r.read_nonblock(100)
      end

      run_thread = Thread.new { scheduler.run }

      w.write("test data")
      w.close
      run_thread.join(1)

      expect(result).to eq("test data")

      r.close
    end

    it 'processes writable IO events' do
      r, w = Rex::Compat.pipe
      result = nil

      scheduler.schedule_fiber do
        scheduler.io_wait(w, IO::WRITABLE, nil)
        result = :written
        w.write("data")
      end

      run_thread = Thread.new { scheduler.run }
      run_thread.join(1)

      expect(result).to eq(:written)

      r.close
      w.close
    end

    it 'processes waiting fibers after timeout' do
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      resume_time = nil

      scheduler.schedule_fiber do
        scheduler.kernel_sleep(0.2)
        resume_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      scheduler.run

      elapsed = resume_time - start_time
      expect(elapsed).to be >= 0.2
      expect(elapsed).to be < 0.5
    end

    it 'processes ready fibers' do
      result = nil

      scheduler.schedule_fiber do
        fiber = Fiber.current
        scheduler.schedule_fiber do
          scheduler.unblock(:test, fiber)
        end
        scheduler.block(:test)
        result = :unblocked
      end

      scheduler.run

      expect(result).to eq(:unblocked)
    end

    it 'handles blocking count correctly' do
      blocking_count = nil
      block_started = false
      mutex = Mutex.new
      cv = ConditionVariable.new

      scheduler.schedule_fiber do
        fiber = Fiber.current
        scheduler.schedule_fiber do
          # Wait until we've checked the blocking count
          mutex.synchronize do
            cv.wait(mutex) until block_started
          end
          scheduler.unblock(:test, fiber)
        end

        # Signal that we're about to block
        mutex.synchronize do
          block_started = true
          cv.signal
        end

        scheduler.block(:test)
        blocking_count = scheduler.instance_variable_get(:@blocking)
      end

      run_thread = Thread.new { scheduler.run }

      # Wait for the fiber to signal it's blocking
      mutex.synchronize do
        cv.wait(mutex) until block_started
      end

      # Now we know for sure the fiber is blocked
      expect(scheduler.instance_variable_get(:@blocking)).to eq(1)

      # Signal the unblocking fiber to proceed
      mutex.synchronize { cv.signal }

      # Wait for completion
      run_thread.join

      # After unblocking, count should be back to 0
      expect(blocking_count).to eq(0)
    end
  end

  describe '#io_wait' do
    it 'registers fiber for readable IO' do
      r, w = Rex::Compat.pipe
      registered = false
      mutex = Mutex.new
      cv = ConditionVariable.new

      scheduler.schedule_fiber do
        mutex.synchronize do
          registered = true
          cv.signal
        end
        scheduler.io_wait(r, IO::READABLE, nil)
        r.read_nonblock(100)
        r.close
      end

      run_thread = Thread.new { scheduler.run }

      # Wait for fiber to register
      mutex.synchronize do
        cv.wait(mutex) until registered
      end

      readable = scheduler.instance_variable_get(:@readable)
      expect(readable.keys).to include(r)

      # Write data then close to trigger completion
      w.write("test data")
      w.close

      run_thread.join(2)
    end

    it 'registers fiber for writable IO' do
      r, w = Rex::Compat.pipe
      fiber_resumed = false

      scheduler.schedule_fiber do
        scheduler.io_wait(w, IO::WRITABLE, nil)
        fiber_resumed = true
      end

      run_thread = Thread.new { scheduler.run }
      run_thread.join(2)

      # The fiber should have been resumed since pipes are immediately writable
      expect(fiber_resumed).to be true

      r.close rescue nil
      w.close rescue nil
    end

    it 'returns events mask' do
      r, w = Rex::Compat.pipe
      events = nil

      scheduler.schedule_fiber do
        events = scheduler.io_wait(r, IO::READABLE, nil)
        r.read_nonblock(100)
        r.close
      end

      run_thread = Thread.new { scheduler.run }
      sleep 0.1

      w.write("data")
      w.close

      run_thread.join(2)

      expect(events).to eq(IO::READABLE)
    end
  end

  describe '#kernel_sleep' do
    it 'blocks for specified duration' do
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end_time = nil

      scheduler.schedule_fiber do
        scheduler.kernel_sleep(0.2)
        end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      scheduler.run

      elapsed = end_time - start_time
      expect(elapsed).to be >= 0.2
      expect(elapsed).to be < 0.5
    end

    it 'returns true' do
      result = nil

      scheduler.schedule_fiber do
        result = scheduler.kernel_sleep(0.1)
      end

      scheduler.run

      expect(result).to be true
    end

    it 'handles nil duration as indefinite block' do
      blocked = false

      scheduler.schedule_fiber do
        fiber = Fiber.current
        scheduler.schedule_fiber do
          sleep 0.1
          scheduler.unblock(:sleep, fiber)
        end
        scheduler.kernel_sleep(nil)
        blocked = true
      end

      scheduler.run

      expect(blocked).to be true
    end
  end

  describe '#block' do
    it 'increments blocking count for indefinite block' do
      block_started = false
      unblock_ready = false
      mutex = Mutex.new
      cv = ConditionVariable.new

      scheduler.schedule_fiber do
        fiber = Fiber.current
        scheduler.schedule_fiber do
          # Wait for signal to unblock
          mutex.synchronize do
            cv.wait(mutex) until unblock_ready
          end
          scheduler.unblock(:test, fiber)
        end

        # Signal that we're about to block
        mutex.synchronize do
          block_started = true
          cv.signal
        end

        scheduler.block(:test)
      end

      run_thread = Thread.new { scheduler.run }

      # Wait for fiber to be blocked
      mutex.synchronize do
        cv.wait(mutex) until block_started
      end

      expect(scheduler.instance_variable_get(:@blocking)).to eq(1)

      # Signal unblock and wait for completion
      mutex.synchronize do
        unblock_ready = true
        cv.signal
      end

      run_thread.join(2)

      expect(scheduler.instance_variable_get(:@blocking)).to eq(0)
    end

    it 'uses waiting queue for timed block' do
      block_started = false
      mutex = Mutex.new
      cv = ConditionVariable.new

      scheduler.schedule_fiber do
        # Signal that we're about to block
        mutex.synchronize do
          block_started = true
          cv.signal
        end

        scheduler.block(:test, 0.2)
      end

      run_thread = Thread.new { scheduler.run }

      # Wait for fiber to start blocking
      mutex.synchronize do
        cv.wait(mutex) until block_started
      end

      waiting = scheduler.instance_variable_get(:@waiting)
      expect(waiting.size).to eq(1)

      # Wait for the block to complete naturally
      run_thread.join(1)
    end

    it 'resumes after timeout' do
      resumed = false

      scheduler.schedule_fiber do
        scheduler.block(:test, 0.15)
        resumed = true
      end

      scheduler.run

      expect(resumed).to be true
    end

    it 'cleans up waiting queue after resume' do
      scheduler.schedule_fiber do
        scheduler.block(:test, 0.1)
      end

      scheduler.run

      waiting = scheduler.instance_variable_get(:@waiting)
      expect(waiting).to be_empty
    end
  end

  describe '#unblock' do
    it 'adds fiber to ready queue' do
      fiber = Fiber.new(blocking: false) { Fiber.yield }
      fiber.resume

      scheduler.unblock(:test, fiber)

      ready = scheduler.instance_variable_get(:@ready)
      expect(ready).to include(fiber)
    end

    it 'signals via urgent pipe' do
      fiber = Fiber.new(blocking: false) { Fiber.yield }
      fiber.resume

      urgent_pipe = scheduler.instance_variable_get(:@urgent)

      scheduler.unblock(:test, fiber)

      readable, = IO.select([urgent_pipe.first], nil, nil, 0.1)
      expect(readable).to include(urgent_pipe.first)
    end

    it 'allows blocked fiber to resume' do
      result = nil

      scheduler.schedule_fiber do
        fiber = Fiber.current
        scheduler.schedule_fiber do
          sleep 0.1
          scheduler.unblock(:test, fiber)
        end
        scheduler.block(:test)
        result = :resumed
      end

      scheduler.run

      expect(result).to eq(:resumed)
    end
  end

  describe '#close' do
    it 'completes remaining work' do
      result = nil

      scheduler.schedule_fiber { result = :done }
      scheduler.close

      expect(result).to eq(:done)
    end

    it 'closes urgent pipe' do
      urgent = scheduler.instance_variable_get(:@urgent)
      original_pipes = urgent.dup

      scheduler.close

      original_pipes.each do |pipe|
        expect(pipe.closed?).to be true
      end
    end

    it 'sets urgent to nil' do
      scheduler.close
      expect(scheduler.instance_variable_get(:@urgent)).to be_nil
    end
  end

  describe 'integration scenarios' do
    it 'handles multiple concurrent fibers with IO' do
      results = []
      pipes = 3.times.map { Rex::Compat.pipe }

      pipes.each_with_index do |(r, w), index|
        scheduler.schedule_fiber do
          scheduler.io_wait(r, IO::READABLE, nil)
          data = r.read_nonblock(100)
          results << "fiber#{index}: #{data}"
        end
      end

      run_thread = Thread.new { scheduler.run }

      pipes.each_with_index do |(r, w), index|
        w.write("data#{index}")
        w.close
      end

      run_thread.join

      expect(results.size).to eq(3)
      expect(results).to include("fiber0: data0", "fiber1: data1", "fiber2: data2")

      pipes.each { |r, w| r.close rescue nil }
    end

    it 'handles mixed blocking and IO operations' do
      results = []

      scheduler.schedule_fiber do
        results << :start
        scheduler.kernel_sleep(0.1)
        results << :after_sleep
      end

      r, w = Rex::Compat.pipe
      scheduler.schedule_fiber do
        scheduler.io_wait(r, IO::READABLE, nil)
        results << :after_io
        r.close
      end

      run_thread = Thread.new { scheduler.run }

      w.write("data")
      w.close

      run_thread.join

      expect(results).to include(:start, :after_sleep, :after_io)
    end

    it 'handles nested fiber scheduling' do
      results = []

      scheduler.schedule_fiber do
        results << 1
        scheduler.schedule_fiber do
          results << 2
          scheduler.schedule_fiber do
            results << 3
          end
        end
      end

      scheduler.run

      expect(results).to eq([1, 2, 3])
    end
  end
end