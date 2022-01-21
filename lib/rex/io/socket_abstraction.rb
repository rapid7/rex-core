# -*- coding: binary -*-

require 'socket'
require 'fcntl'

module Rex
  module IO
    ###
    #
    # This class provides an abstraction to a stream based
    # connection through the use of a streaming socketpair.
    #
    ###
    module SocketAbstraction
      ###
      #
      # Extension information for required Stream interface.
      #
      ###
      module Ext
        #
        # Initializes peer information.
        #
        def initinfo(peer, local)
          @peer = peer
          @local = local
        end

        #
        # Symbolic peer information.
        #
        def peerinfo
          (@peer || 'Remote Pipe')
        end

        #
        # Symbolic local information.
        #
        def localinfo
          (@local || 'Local Pipe')
        end
      end

      #
      # Override this method to init the abstraction
      #
      def initialize_abstraction
        self.lsock, self.rsock = Rex::Compat.pipe
      end

      #
      # This method cleans up the abstraction layer.
      #
      def cleanup_abstraction
        lsock.close if lsock and !lsock.closed?

        monitor_thread.join if monitor_thread&.alive?

        rsock.close if rsock and !rsock.closed?

        self.lsock = nil
        self.rsock = nil
      end

      #
      # Low-level write to the local side.
      #
      def syswrite(buffer)
        lsock.syswrite(buffer)
      end

      #
      # Low-level read from the local side.
      #
      def sysread(length)
        lsock.sysread(length)
      end

      #
      # Shuts down the local side of the stream abstraction.
      #
      def shutdown(how)
        lsock.shutdown(how)
      end

      #
      # Closes both sides of the stream abstraction.
      #
      def close
        cleanup_abstraction
        super
      end

      #
      # Symbolic peer information.
      #
      def peerinfo
        'Remote-side of Pipe'
      end

      #
      # Symbolic local information.
      #
      def localinfo
        'Local-side of Pipe'
      end

      #
      # The left side of the stream.
      #
      attr_reader :lsock
      #
      # The right side of the stream.
      #
      attr_reader :rsock

      module MonitoredRSock
        def close
          @close_requested = true
          @monitor_thread.join
          nil
        end

        def sysclose
          self.class.instance_method(:close).bind(self).call
        end

        attr_reader :close_requested
        attr_writer :monitor_thread
      end

      protected

      def monitor_rsock(threadname = 'SocketMonitorRemote')
        rsock.extend(MonitoredRSock)
        rsock.monitor_thread = self.monitor_thread = Rex::ThreadFactory.spawn(threadname, false) do
          loop do
            closed = rsock.nil? || rsock.close_requested

            if closed
              wlog('monitor_rsock: the remote socket has been closed, exiting loop')
              break
            end

            buf = nil

            begin
              s = Rex::ThreadSafe.select([rsock], nil, nil, 0.2)
              next if s.nil? || s[0].nil?
            rescue Exception => e
              wlog("monitor_rsock: exception during select: #{e.class} #{e}")
              closed = true
            end

            unless closed
              begin
                buf = rsock.sysread(32_768)
                if buf.nil?
                  closed = true
                  wlog('monitor_rsock: closed remote socket due to nil read')
                end
              rescue EOFError => e
                closed = true
                dlog('monitor_rsock: EOF in rsock')
              rescue ::Exception => e
                closed = true
                wlog("monitor_rsock: exception during read: #{e.class} #{e}")
              end
            end

            unless closed
              total_sent = 0
              total_length = buf.length
              while total_sent < total_length
                begin
                  data = buf[total_sent, buf.length]

                  # Note that this must be write() NOT syswrite() or put() or anything like it.
                  # Using syswrite() breaks SSL streams.
                  sent = write(data)

                  # sf: Only remove the data off the queue is write was successful.
                  #     This way we naturally perform a resend if a failure occurred.
                  #     Catches an edge case with meterpreter TCP channels where remote send
                  #     fails gracefully and a resend is required.
                  if sent.nil?
                    closed = true
                    wlog('monitor_rsock: failed writing, socket must be dead')
                    break
                  elsif sent > 0
                    total_sent += sent
                  end
                rescue ::IOError, ::EOFError => e
                  closed = true
                  wlog("monitor_rsock: exception during write: #{e.class} #{e}")
                  break
                end
              end
            end

            next unless closed

            begin
              close_write if respond_to?('close_write')
            rescue StandardError
            end

            break
          end

          rsock.sysclose
        end
      end

      attr_accessor :monitor_thread
      attr_writer :lsock, :rsock
    end
  end
end
