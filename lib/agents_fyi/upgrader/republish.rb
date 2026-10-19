# frozen_string_literal: true

require "json"

module AgentsFyi
  module Upgrader
    # **Rewrite the bodies of already-delivered rungs from their own records.**
    #
    # A pull request's body is composed at publish time, so a body that was a wall of bullets stays
    # one after the publisher learns to summarize. This is the maintenance path: for every passed
    # ledger entry whose delivery completed, load the record the step wrote and publish again — the
    # GitHub half finds the open request and PATCHes its title, body and base, exactly as a re-run
    # would. It does not walk, does not read the ladder and does not touch the branches' commits.
    #
    # It lives in the client because only the client can reach GitHub and the records; the service's
    # contract is frozen and a republish is not a corpus write. The record is rebuilt from the JSON
    # (`Record#to_h`) rather than kept in memory: the body reads the brief, the stages, the applied
    # edits and the decisions, and the record file carries all of them.
    class Republish
      def initialize(home:, token: nil, out: nil, report_base: nil, ledger: nil, publish_class: Publish)
        @home = home
        @token = token
        @out = out
        @report_base = report_base
        @ledger = ledger
        @publish_class = publish_class
      end

      def call
        entries = (@ledger || Ledger.load(File.join(@home.to_s, "ledger.json"))).entries
        entries.filter_map do |entry|
          next unless entry.verdict == Ledger::PASSED

          delivery = entry.delivery
          next unless delivery.is_a?(Hash) && delivery["delivered"] == true

          record = record_for(entry)
          if record.nil?
            @out&.puts("republish: no readable record for #{entry.repo} " \
                       "#{entry.from_version}->#{entry.to_version}")
            next
          end

          result = @publish_class.new(
            root: delivery["root"], repository: entry.repo,
            from_version: entry.from_version, to_version: entry.to_version,
            record: record, commit: delivery["commit"].to_s, token: @token, out: @out,
            branch_pattern: delivery["branch_pattern"], report_base: @report_base
          ).call
          @out&.puts("republish: #{entry.repo} #{entry.from_version}->#{entry.to_version}: #{result}")
          result
        end
      end

      private

      def record_for(entry)
        stem = "#{entry.repo.gsub(/[^A-Za-z0-9._-]/, "-")}-#{entry.from_version}-#{entry.to_version}"
        path = File.join(@home.to_s, "records", "#{stem}.json")
        return nil unless File.file?(path)

        source = JSON.parse(File.read(path))
        Record.new(
          repository: source["repository"], commit: source["commit"], worktree: source["worktree"],
          from_version: source["from_version"], to_version: source["to_version"], name: source["name"],
          requires_ruby: source["requires_ruby"], interpreter: source["interpreter"],
          image: source["image"], machine: source["machine"], era: source["era"],
          verdict: source["verdict"], why: source["why"], brief: brief(source["brief"]),
          stages: members(Record::Command, source["stages"]),
          applied: members(Applier::Applied, source["applied"]),
          refused: members(Applier::Refused, source["refused"]),
          decisions: members(Record::Decision, source["decisions"]),
          patch: source["patch"].to_s
        )
      rescue JSON::ParserError, ArgumentError, TypeError => e
        @out&.puts("republish: #{path} could not be read: #{e.class}: #{e.message}")
        nil
      end

      def brief(source)
        return nil unless source.is_a?(Hash)

        Brief::Result.new(
          sections: Array(source["sections"]).map do |section|
            Brief::Section.new(
              key: section["key"], title: section["title"], question: section["question"],
              state: section["state"], note: section["note"], total: section["total"],
              items: members(Brief::Item, section["items"])
            )
          end,
          asked: source["asked"], truncated: source["truncated"], unavailable: source["unavailable"]
        )
      end

      # The struct's own members, so a key the record gained (`identifying` on a brief item, say)
      # does not make the whole record unreadable.
      def members(struct, rows)
        keys = struct.members.map(&:to_s)
        Array(rows).select { |row| row.is_a?(Hash) }.map do |row|
          struct.new(**row.select { |key, _| keys.include?(key) }.transform_keys(&:to_sym))
        end
      end
    end
  end
end
