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
    # Three decisions shape it:
    #
    # * **A file, not an API call.** The obvious design is a progress endpoint, and it is closed:
    #   the service's public surface is reconciled against a frozen recording
    #   (`test/agents_fyi/fixtures/discovery_golden.json` holds the endpoints, and the verdicts a
    #   run may carry are pinned by `upgrades_golden.json`), so neither a new route nor a new
    #   `upgrade_verdict` value can be added. A file the *console* reads is outside that contract,
    #   which is the only place left — and it is the operator's own view, which is who is asking.
    # * **Written atomically.** The reader is another process on another container: a half-written
    #   JSON file read at the wrong moment would be a console error rather than a stale line, so
    #   the write goes to a temporary name and is renamed into place, which is atomic on one
    #   filesystem.
    # * **Every field the reader needs to judge it, and no clock.** `started_at` is when the
    #   *stage* began and `updated_at` when this file was last written, both as instants; how long
    #   that is, and whether it is long enough to call stalled, is the reader's arithmetic against
    #   its own clock. A file that carried "3 minutes" would be wrong the moment it was read.
    class Progress
      FILE = "progress.json"

      # **Its own directory, so the operator's view can be mounted without the walker's state.**
      # The console reads this through a *separate* volume (`upgrader_state`) rather than the one
      # holding the ledger, the bundles and the working copies: the ledger is one loop's book and a
      # second reader of it would be a second author, while this file is written to be read.
      DIR = "state"

      # Where the file lives, given the walker's home. Named here and read by nothing else: the
      # console is told the *directory* and joins this name to it, so the two cannot drift.
      def self.path(home) = File.join(home.to_s, DIR, FILE)

      # The directory the console is pointed at, which is this one mounted read-only.
      def self.dir(home) = File.join(home.to_s, DIR)

      def initialize(home:, out: nil)
        @home = home
        @out = out
      end

      # A stage has begun. `detail` is what the step was asked to do — the application's own
      # command, not the machine's wrapper — because that is what a reader is asking about.
      def stage(repo:, from:, to:, stage:, detail:, note: "", commit: nil, era: nil)
        write(
          "repo" => repo, "commit" => commit, "from_version" => from, "to_version" => to,
          "era" => era, "stage" => stage.to_s, "detail" => detail.to_s, "note" => note.to_s,
          "started_at" => now
        )
      end

      # The loop between steps: planning the next rung, cloning, or waiting out its interval. Its
      # own shape because there is no move yet, and a reader showing "4.0.0 -> 4.1.0" while the
      # loop is asleep would be describing work that is not happening.
      def cycle(note:, repo: nil, commit: nil)
        write("repo" => repo, "commit" => commit, "stage" => "cycle", "detail" => note.to_s,
          "note" => "", "started_at" => now)
      end

      # Nothing is in flight — the loop is between cycles with no move chosen, or has stopped.
      def clear
        File.delete(path) if File.exist?(path)
      rescue SystemCallError
        nil
      end

      def path = self.class.path(@home)

      private

      def now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      # Written whole or not at all. The temporary name is this process's own, so two writers
      # cannot collide on it, and the rename is what a reader sees as the whole file.
      def write(fields)
        FileUtils.mkdir_p(File.dirname(path))
        body = JSON.generate(fields.merge("updated_at" => now))
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, body)
        File.rename(temporary, path)
      rescue SystemCallError => e
        # A progress file that cannot be written is not a reason to stop a walk: it is the
        # operator's view, and the record is the product. Said out loud rather than swallowed,
        # because a console that shows nothing is indistinguishable from a loop that is idle.
        @out&.puts("  progress: not written: #{e.class}: #{e.message}")
      end
    end
  end
end
