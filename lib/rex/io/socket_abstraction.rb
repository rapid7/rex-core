# -*- coding: binary -*-

require 'socket'

require 'rex/io/relay_manager'

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

        monitor_thread.join if monitor_thread&.alive? && monitor_thread&.object_id != Thread.current.object_id

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

      protected

      def monitor_rsock(name = 'MonitorRemote')
        if respond_to?(:close_write)
          on_exit = method(:close_write)
        else
          on_exit = nil
        end

        monitor_sock(rsock, sink: self, name: name, on_exit: on_exit)
      end

      def monitor_sock(sock, sink:, name:, on_exit: nil)
        @relay_manager ||= Rex::IO::RelayManager.new
        @relay_manager.add_relay(sock, sink: sink, name: name, on_exit: on_exit)
      end

      def monitor_thread
        @relay_manager.thread
      end

      attr_writer :lsock, :rsock
    end
  end
end
