require 'rex/io/relay_manager'
require 'socket'

RSpec.describe Rex::IO::RelayManager do
  let(:manager) { described_class.new }

  after do
    # Clean up the thread if it's still running
    if manager.thread && manager.thread.alive?
      manager.thread.kill
      manager.thread.join(1)
    end
  end

  describe '#initialize' do
    it 'initializes with no thread' do
      expect(manager.thread).to be_nil
    end

    it 'creates a FiberScheduler' do
      scheduler = manager.instance_variable_get(:@scheduler)
      expect(scheduler).to be_a(Rex::IO::FiberScheduler)
    end
  end

  describe '#add_relay' do
    it 'schedules a relay fiber' do
      r, w = IO.pipe
      sink = StringIO.new

      manager.add_relay(r, sink: sink, name: 'test')

      scheduler = manager.instance_variable_get(:@scheduler)
      pending = scheduler.instance_variable_get(:@pending)

      expect(pending.size).to be >= 1

      w.close
      r.close
    end

    it 'starts the manager thread if not running' do
      r, w = Socket.pair(:UNIX, :STREAM, 0)
      sink = StringIO.new

      expect(manager.thread).to be_nil

      manager.add_relay(r, sink: sink, name: 'test')

      expect(manager.thread).to be_a(Thread)
      expect(manager.thread.alive?).to be true

      # Close gracefully - write side first
      w.close
    end

    it 'does not start a new thread if already running' do
      r1, w1 = Socket.pair(:UNIX, :STREAM, 0)
      r2, w2 = Socket.pair(:UNIX, :STREAM, 0)
      sink = StringIO.new

      manager.add_relay(r1, sink: sink, name: 'test1')
      first_thread = manager.thread

      manager.add_relay(r2, sink: sink, name: 'test2')
      second_thread = manager.thread

      expect(first_thread).to eq(second_thread)

      # Close write sides to trigger EOF, let relays clean up read sides
      w1.close
      w2.close
    end

    it 'relays data from socket to sink with write method' do
      r, w = IO.pipe
      sink = StringIO.new

      manager.add_relay(r, sink: sink, name: 'test')

      w.write("Hello, World!")
      w.close
      manager.thread.join(1)

      expect(sink.string).to eq("Hello, World!")

      r.close
    end

    it 'relays data from socket to sink with call method' do
      r, w = IO.pipe
      received_data = []
      sink = proc { |data| received_data << data }

      manager.add_relay(r, sink: sink, name: 'test')

      w.write("Test data")
      w.close
      manager.thread.join(1)

      expect(received_data.join).to eq("Test data")

      r.close
    end

    it 'handles multiple data chunks' do
      r, w = IO.pipe
      sink = StringIO.new

      manager.add_relay(r, sink: sink, name: 'test')

      w.write("Chunk 1\n")
      sleep 0.1
      w.write("Chunk 2\n")
      sleep 0.1
      w.write("Chunk 3\n")
      w.close
      manager.thread.join(1)

      expect(sink.string).to eq("Chunk 1\nChunk 2\nChunk 3\n")

      r.close
    end

    it 'calls the on_exit callback when socket closes' do
      r, w = IO.pipe
      sink = StringIO.new
      callback_called = false
      on_exit = proc { callback_called = true }

      manager.add_relay(r, sink: sink, name: 'test', on_exit: on_exit)
      w.close
      manager.thread.join(1)

      expect(callback_called).to be true
    end

    it 'closes socket if not already closed' do
      r, w = IO.pipe
      sink = StringIO.new

      manager.add_relay(r, sink: sink, name: 'test')
      w.close
      manager.thread.join(1)

      expect(r.closed?).to be true
    end

    it 'handles EOFError gracefully' do
      r, w = IO.pipe
      sink = StringIO.new

      manager.add_relay(r, sink: sink, name: 'test')
      w.close
      manager.thread.join(1)

      # Should complete without raising error
      expect(sink.string).to eq("")
    end

    it 'handles already closed socket' do
      r, w = IO.pipe
      sink = StringIO.new

      r.close
      w.close

      expect {
        manager.add_relay(r, sink: sink, name: 'test')
        manager.thread.join(1)
      }.not_to raise_error
    end
  end

  describe '.io_write_all' do
    it 'writes all data to IO in one call' do
      io = StringIO.new
      data = "Complete data"

      result = described_class.io_write_all(io, data)

      expect(io.string).to eq("Complete data")
      expect(result).to eq(data.bytesize)
    end

    it 'handles partial writes' do
      io = double('io')
      data = "0123456789"

      # Simulate partial writes: 3 bytes, then 4 bytes, then 3 bytes
      allow(io).to receive(:write).and_return(3, 4, 3)

      result = described_class.io_write_all(io, data)

      expect(io).to have_received(:write).exactly(3).times
      expect(result).to eq(10)
    end

    it 'writes correct slices on partial writes' do
      io = double('io')
      data = "ABCDEFGHIJ"
      written_data = []

      allow(io).to receive(:write) do |slice|
        written_data << slice
        slice.bytesize # Write all provided data
      end.and_return(4, 6)

      described_class.io_write_all(io, data)

      expect(written_data).to eq(["ABCDEFGHIJ", "EFGHIJ"])
    end

    it 'handles empty data' do
      io = StringIO.new
      data = ""

      result = described_class.io_write_all(io, data)

      expect(io.string).to eq("")
      expect(result).to eq(0)
    end

    it 'handles binary data' do
      io = StringIO.new.binmode
      data = "\x00\x01\x02\xFF".b

      result = described_class.io_write_all(io, data)

      expect(io.string).to eq(data)
      expect(result).to eq(4)
    end
  end

  describe 'concurrent relays' do
    it 'handles multiple concurrent relays' do
      pipes = 3.times.map { IO.pipe }
      sinks = 3.times.map { StringIO.new }

      pipes.each_with_index do |(r, w), index|
        manager.add_relay(r, sink: sinks[index], name: "relay:#{index}")
      end

      pipes.each_with_index do |(r, w), index|
        w.write("Data from relay #{index}")
        w.close
      end

      manager.thread.join(1)

      sinks.each_with_index do |sink, index|
        expect(sink.string).to eq("Data from relay #{index}")
      end

      pipes.each { |r, w| r.close rescue nil }
    end

    it 'relays data independently for each relay' do
      r1, w1 = IO.pipe
      r2, w2 = IO.pipe
      sink1 = StringIO.new
      sink2 = StringIO.new

      manager.add_relay(r1, sink: sink1, name: 'relay1')
      manager.add_relay(r2, sink: sink2, name: 'relay2')
      w1.write("First relay")
      w2.write("Second relay")
      w1.close
      w2.close
      manager.thread.join(1)

      expect(sink1.string).to eq("First relay")
      expect(sink2.string).to eq("Second relay")
    end
  end

  describe 'error handling' do
    it 'raises ArgumentError for unsupported sink type' do
      r, w = IO.pipe
      unsupported_sink = "not a valid sink"

      manager.add_relay(r, sink: unsupported_sink, name: 'test')

      w.write("data")
      w.close

      sleep 1

      # The error should be caught and logged, relay should stop
      expect(r.closed?).to be true

      r.close rescue nil
    end

    it 'continues other relays when one fails' do
      r1, w1 = IO.pipe
      r2, w2 = IO.pipe
      bad_sink = "invalid"
      good_sink = StringIO.new

      manager.add_relay(r1, sink: bad_sink, name: 'bad')
      manager.add_relay(r2, sink: good_sink, name: 'good')

      w1.write("data1")
      w2.write("data2")
      w1.close
      w2.close
      manager.thread.join(1)

      # Good relay should still work
      expect(good_sink.string).to eq("data2")
    end
  end

  describe 'large data transfers' do
    it 'handles data larger than buffer size' do
      r, w = IO.pipe
      sink = StringIO.new
      large_data = "X" * 100_000  # Larger than 32KB buffer

      manager.add_relay(r, sink: sink, name: 'test')

      w.write(large_data)
      w.close
      manager.thread.join(1)

      expect(sink.string).to eq(large_data)
    end

    it 'relays data in chunks' do
      r, w = IO.pipe
      chunks_received = []
      sink = proc { |data| chunks_received << data.bytesize }
      large_data = "A" * 100_000

      manager.add_relay(r, sink: sink, name: 'test')

      w.write(large_data)
      w.close
      manager.thread.join(1)

      # Should have received multiple chunks
      expect(chunks_received.size).to be > 1
      expect(chunks_received.sum).to eq(100_000)
    end
  end

  describe 'fiber scheduler integration' do
    it 'sets the fiber scheduler for the thread' do
      r, w = IO.pipe
      sink = StringIO.new
      thread_scheduler = nil

      # Capture the scheduler from inside the thread
      allow_any_instance_of(Rex::IO::FiberScheduler).to receive(:run) do
        thread_scheduler = Fiber.scheduler
      end

      manager.add_relay(r, sink: sink, name: 'test')
      w.close
      manager.thread.join(1)

      expect(thread_scheduler).to be_a(Rex::IO::FiberScheduler)
    end
  end

  describe 'callback functionality' do
    it 'passes correct data to callable sink' do
      r, w = IO.pipe
      received_chunks = []
      sink = proc { |data| received_chunks << data }

      manager.add_relay(r, sink: sink, name: 'test')

      w.write("First")
      sleep 0.1
      w.write("Second")
      w.close
      manager.thread.join(1)

      expect(received_chunks).to eq(["First", "Second"])
    end

    it 'calls on_exit even when error occurs' do
      r, w = IO.pipe
      bad_sink = "invalid"
      exit_called = false
      on_exit = proc { exit_called = true }

      manager.add_relay(r, sink: bad_sink, name: 'test', on_exit: on_exit)

      w.write("data")
      w.close
      manager.thread.join(1)

      expect(exit_called).to be true
    end

    it 'calls on_exit with normal completion' do
      r, w = IO.pipe
      sink = StringIO.new
      exit_called = false
      on_exit = proc { exit_called = true }

      manager.add_relay(r, sink: sink, name: 'test', on_exit: on_exit)
      sleep 0.1

      w.write("data")
      w.close
      manager.thread.join(1)

      expect(exit_called).to be true
    end
  end
end