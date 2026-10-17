# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # Whether the process that owns something this tool left behind is still running.
    #
    # **Two things are reaped by this rule, and they have to agree**: a step's container, and the
    # bundle its run installed. Both carry the pid of the process that owns them (a label on the
    # container, the run id in a run directory's name), and both are removed when that process is
    # gone — a walker that is *killed* runs no cleanup at all, which is what leaves them.
    #
    # `EPERM` means the process exists and belongs to somebody else; `ESRCH` and an unparseable
    # pid mean it does not. The check errs toward *keeping*: a pid reused by an unrelated process
    # keeps a stale container or bundle rather than removing a live one.
    module Processes
      def self.alive?(pid)
        Process.kill(0, Integer(pid))
        true
      rescue Errno::EPERM
        true
      rescue Errno::ESRCH, ArgumentError, TypeError
        false
      end
    end
  end
end
