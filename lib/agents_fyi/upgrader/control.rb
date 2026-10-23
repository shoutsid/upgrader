# frozen_string_literal: true

require "json"

module AgentsFyi
  module Upgrader
    # **The site admin's stop switch, read where the work actually happens.**
    #
    # The service cannot signal this container: it has no route to the runtime, and a container
    # stop waits out the command in flight — a bundle resolve or an application's suite — which is
    # the hang this exists to remove. The control is a file the service writes into the projects
    # volume both containers already mount (see `Upgrade::WalkerControl`), and this class is the
    # walker's side of it.
    #
    # **`check!` is called before every command, not only between cycles.** A step is the unit
    # that must not be interrupted halfway (`Step`'s own contract), but a cycle may chain three
    # rungs and a rung is hours; checking only at the cycle would make a stop take the same hours.
    # A command is the boundary the record already measures, so a stop lands here: the command in
    # flight finishes, the next one never starts, the step records nothing, the ledger keeps the
    # rung unsettled, and `Serve` idles until the switch says running again.
    #
    # An absent file — a deployment that has not mounted the volume, or a walk run by hand — means
    # running, which is what every walk was before this existed. A file that cannot be read is also
    # running: a corrupt operator file must not silently halt a deployment, and the site admin's
    # page is where that problem is shown.
    class Control
      FILE = ".walker-control.json"
      # **The service's other write: a project was queued.** It is a dotfile in the same
      # directory and a marker rather than a command — the reader only needs its mtime, and
      # nothing has to be deleted or acknowledged for a wake not to be lost.
      WAKE_FILE = ".walker-wake.json"

      # The stop, as an exception rather than a return value: it has to unwind from `Step#command`
      # through pipelines that have no "aborted" branch, and a sentinel return would be read by
      # some caller as a failed command — a record that says the move failed when nobody tried it.
      class Stopped < StandardError; end

      # `path:` is injectable for the suite; `started` is the deployment's environment in the
      # container, where `UPGRADER_PROJECTS_DIR` is already the volume both processes share.
      def initialize(home:, path: nil)
        dir = ENV["UPGRADER_PROJECTS_DIR"].to_s
        dir = File.join(home.to_s, "projects") if dir.empty?
        @path = path || ENV["UPGRADER_CONTROL"] || File.join(dir, FILE)
        @wake_path = ENV["UPGRADER_WAKE"] || File.join(File.dirname(@path), WAKE_FILE)
        @mtime = nil
        @document = nil
      end

      attr_reader :path, :wake_path

      def stopped?
        document["state"] == "stopped"
      end

      # The reason the site admin wrote, for the line the operator reads. Empty when the request
      # carried none, which is a stop somebody made without explaining it rather than no stop.
      def reason = document["reason"].to_s

      # Called at the boundaries — before a command, before a suite, before a repair attempt.
      def check!
        return unless stopped?

        sentence = reason.empty? ? "the walker was stopped from the site admin" : "the walker is stopped: #{reason}"
        raise Stopped, sentence
      end

      # **Did a project arrive while this process was resting?** The marker's mtime is compared
      # with the moment the current cycle began, not with the nap's start: a queue write that
      # landed while the cycle was reading its feed happened after the read and would otherwise
      # be followed by the full wait. An absent or unreadable marker is no wake, which is the
      # direction that keeps the loop's own interval as the fallback.
      def wake_since?(moment)
        stat = File.stat(@wake_path)
        # `>=` rather than `>`: a filesystem with one-second mtime granularity can round a
        # marker written just after the cycle's start down to the same second, and a lost wake
        # costs the whole interval while an equal one costs one extra empty cycle.
        stat.file? && stat.mtime >= moment
      rescue SystemCallError
        false
      end

      private

      # The file is reread only when its mtime moves, because `check!` runs before every command a
      # step makes and a step can make dozens. A 20-byte read is cheap; a stat is cheaper, and a
      # stop still lands at the next command.
      def document
        stat = File.stat(@path)
        return @document = {} unless stat.file?

        if @document.nil? || @mtime != stat.mtime.to_f
          parsed = JSON.parse(File.read(@path))
          @document = parsed.is_a?(Hash) ? parsed : {}
          @mtime = stat.mtime.to_f
        end
        @document
      rescue SystemCallError, JSON::ParserError
        @document = {}
        @mtime = nil
        @document
      end
    end
  end
end
