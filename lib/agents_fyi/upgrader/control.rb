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
        @mtime = nil
        @document = nil
      end

      attr_reader :path

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
