# frozen_string_literal: true

require "fileutils"
require "json"

module Agents
  module Upgrader
    # **What became of each passed rung's branch and pull request, written where the site admin reads
    # it.**
    #
    # The ledger holds this too — `delivery` on the rung's entry — but the ledger is the loop's own
    # book and is deliberately not mounted into the service (`Progress` says why). This is the
    # read-only projection of the same fact, beside the progress file: the site admin's walk view joins
    # it to the runs the corpus already holds, and a rung whose branch never arrived says so instead
    # of looking delivered.
    #
    # A list rather than a map keyed by a joined string: the site admin matches `(repo, from, to)` and
    # splitting a key to find out is the shape this avoids. A later attempt at the same move replaces
    # its own entry; nothing else is touched.
    class Deliveries
      FILE = "deliveries.json"

      # The site admin reads `<UPGRADER_STATE_DIR>/deliveries.json`, which is this directory mounted
      # read-only. Named here once so the writer cannot drift from `Progress`'s directory.
      def self.path(home) = File.join(Progress.dir(home), FILE)

      def initialize(home:, out: nil)
        @home = home
        @out = out
      end

      def path = self.class.path(@home)

      # One move's delivery, replacing whatever this file said about it before. `delivery` is the
      # publisher's result plus the produced commit and the reason; the three identity fields are
      # added here so the reader never has to infer them from a key.
      def record(repo:, from_version:, to_version:, delivery:)
        entries = read.reject { |entry| identity(entry) == [repo.to_s, from_version.to_s, to_version.to_s] }
        entries << delivery.merge(
          "repo" => repo.to_s, "from_version" => from_version.to_s,
          "to_version" => to_version.to_s, "updated_at" => now
        )
        write(entries)
      end

      def entries = read

      private

      def identity(entry)
        [entry["repo"].to_s, entry["from_version"].to_s, entry["to_version"].to_s]
      end

      def now = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")

      def read
        return [] unless File.file?(path)

        payload = JSON.parse(File.read(path))
        entries = payload.is_a?(Hash) ? payload["deliveries"] : nil
        entries.is_a?(Array) ? entries : []
      rescue JSON::ParserError, SystemCallError
        []
      end

      # Written whole or not at all, the same rule the progress file follows: the reader is another
      # process, and a half-written list is a site admin error rather than a stale line.
      def write(entries)
        FileUtils.mkdir_p(File.dirname(path))
        body = JSON.pretty_generate("deliveries" => entries.sort_by { |entry| identity(entry) })
        temporary = "#{path}.#{Process.pid}.tmp"
        File.write(temporary, body)
        File.rename(temporary, path)
      rescue SystemCallError => e
        # A delivery feed that cannot be written is not a reason to fail the delivery: the branch
        # and the record are the product, and this is the operator's view of them.
        @out&.puts("  deliveries: not written: #{e.class}: #{e.message}")
      end
    end
  end
end
