# frozen_string_literal: true

require "fileutils"
require "json"

module AgentsFyi
  module Upgrader
    # **What the loop is doing right now, written where an operator can read it.**
    #
    # A step is a bundle resolve, an `app:update` and a whole test suite, so a walker can be busy
    # for forty minutes on one rung — and until this existed the only live signal was the
    # container's stdout, which means "is it working?" was answered by reading logs and inspecting
    # processes. Measured on the deployment: the loop sat in a pipe read with no child for long
    # enough that the question was asked, and nothing but `docker logs` could answer it.
    #
    # Four decisions shape it:
    #
    # * **A file, not an API call.** The obvious design is a progress endpoint, and it is closed:
    #   the service's public surface is reconciled against frozen recordings, so neither a new route
    #   nor a new `upgrade_verdict` value can be added. A file the *site admin* reads is outside that
    #   contract, which is the only place left — and it is the operator's own view, which is who is
    #   asking.
    # * **A timeline, not one stage.** The first version wrote only the stage in flight, so a reader
    #   could not tell a step that had run four stages from one that had just started — and the
    #   question a person actually asks mid-run is "how far did it get". `events` is that, bounded
    #   because a pathological step could otherwise grow the file without limit.
    # * **Written atomically.** The reader is another process on another container: a half-written
    #   JSON file read at the wrong moment would be a site admin error rather than a stale line, so
    #   the write goes to a temporary name and is renamed into place, which is atomic on one
    #   filesystem.
    # * **Every field the reader needs to judge it, and no clock.** `started_at` is when the *stage*
    #   began and `updated_at` when this file was last written, both as instants; how long that is,
    #   and whether it is long enough to call stalled, is the reader's arithmetic against its own
    #   clock. A file that carried "3 minutes" would be wrong the moment it was read.
    #
    # **No command output lives here.** This file is written for a page a person reads, and a suite's
    # output can contain whatever it printed. The run record carries the evidence.
    class Progress
      FILE = "progress.json"

      # Its own directory, so the operator's view can be mounted without the walker's state.
      DIR = "state"

      # Bumped when the shape changes. A reader that knows one version and is handed another treats
      # the unknown fields as absent rather than guessing what they mean.
      VERSION = 2

      # The timeline's bound. A step runs a few dozen commands; a hundred leaves room for retries
      # and a repair, and a file that grew past it would be a log rather than a status.
      MAX_EVENTS = 100

      # The statuses an event may carry. `started` is the only open one.
      STATUSES = %w[started passed failed skipped].freeze

      # Where the file lives, given the walker's home. Named here and read by nothing else: the
      # service is told the *directory* and joins this name to it, so the two cannot drift.
      def self.path(home) = File.join(home.to_s, DIR, FILE)

      # The directory the service is pointed at, which is this one mounted read-only.
      def self.dir(home) = File.join(home.to_s, DIR)

      def initialize(home:, out: nil)
        @home = home
        @out = out
        @events = []
        @attempts = Hash.new(0)
        @fields = {}
      end

      # A stage has begun. `detail` is what the step was asked to do — the application's own
      # command, not the machine's wrapper — because that is what a reader is asking about.
      #
      # A new stage closes any event still open. That is not a guess at the exit code: an event with
      # no finish is recorded as `skipped` with no code, because "we never heard how it ended" is the
      # only true sentence and inventing `0` would read as a pass.
      def stage(repo:, from:, to:, stage:, detail:, note: "", commit: nil, era: nil, kind: nil)
        close_open_events
        record_start(stage, detail)
        @fields = {
          "version" => VERSION, "repo" => repo, "commit" => commit,
          "from_version" => from, "to_version" => to, "era" => era, "kind" => kind.to_s,
          "stage" => stage.to_s, "detail" => detail.to_s, "note" => note.to_s,
          "started_at" => now
        }
        write
      end

      # A command finished. `stage` names the event this closes; a stage announced twice (a retry)
      # closes its own most recent open event, which is what makes the attempt sequence readable.
      def finish(stage:, status:, exit_code: nil, duration_ms: nil, detail: nil)
        event = @events.reverse.find do |entry|
          entry["stage"] == stage.to_s && entry["finished_at"].nil?
        end
        event ||= begin
          record_start(stage, detail.to_s)
          @events.last
        end
        # An unknown status is not evidence the stage passed. `skipped` is the honest default for
        # a writer that named a state this reader does not know.
        event["status"] = STATUSES.include?(status.to_s) ? status.to_s : "skipped"
        event["exit_code"] = exit_code
        event["duration_ms"] = duration_ms.nil? ? nil : duration_ms.to_i
        event["finished_at"] = now
        event["detail"] = detail.to_s if detail
        trim!
        write
      end

      # The loop between steps: planning the next rung, cloning, or waiting out its interval. Its
      # own shape because there is no move yet, and a reader showing "4.0.0 -> 4.1.0" while the
      # loop is asleep would be describing work that is not happening.
      def cycle(note:, repo: nil, commit: nil)
        close_open_events
        @fields = {
          "version" => VERSION, "repo" => repo, "commit" => commit, "kind" => "",
          "stage" => "cycle", "detail" => note.to_s, "note" => "", "started_at" => now
        }
        write
      end

      # Nothing is in flight — the loop is between cycles with no move chosen, or has stopped.
      def clear
        File.delete(path) if File.exist?(path)
        @events = []
        @fields = {}
      rescue SystemCallError
        nil
      end

      def path = self.class.path(@home)

      def events = @events.dup

      private

      def now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      def record_start(stage, detail)
        @attempts[stage.to_s] += 1
        @events << {
          "stage" => stage.to_s, "detail" => detail.to_s, "status" => "started",
          "started_at" => now, "finished_at" => nil, "exit_code" => nil, "duration_ms" => nil,
          "attempt" => @attempts[stage.to_s]
        }
        trim!
      end

      def close_open_events
        @events.each do |event|
          next unless event["finished_at"].nil?

          event["status"] = "skipped"
          event["finished_at"] = now
        end
      end

      def trim!
        @events = @events.last(MAX_EVENTS)
      end

      # Written whole or not at all. The temporary name is this process's own, so two writers
      # cannot collide on it, and the rename is what a reader sees as the whole file.
      def write
        FileUtils.mkdir_p(File.dirname(path))
        body = JSON.generate(@fields.merge("events" => @events, "updated_at" => now))
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, body)
        File.rename(temporary, path)
      rescue SystemCallError => e
        # A progress file that cannot be written is not a reason to stop a walk: it is the
        # operator's view, and the record is the product. Said out loud rather than swallowed,
        # because a site admin that shows nothing is indistinguishable from a loop that is idle.
        @out&.puts("  progress: not written: #{e.class}: #{e.message}")
      end
    end
  end
end
