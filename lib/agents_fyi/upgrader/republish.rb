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
        ledger = @ledger || Ledger.load(File.join(@home.to_s, "ledger.json"))
        ledger.entries.filter_map do |entry|
          next unless entry.verdict == Ledger::PASSED

          delivery = entry.delivery
          next unless delivery.is_a?(Hash) && delivery["delivered"] == true

          record = record_for(entry)
          if record.nil?
            @out&.puts("republish: no readable record for #{entry.repo} " \
                       "#{entry.from_version}->#{entry.to_version}")
            next
          end

          project = Project.find_by_repository(entry.repo)
          base_ref = delivery["base_ref"].to_s
          base_ref = project.base_ref if base_ref.empty? && project && !project.base_ref.to_s.empty?
          publisher = @publish_class.new(
            root: delivery["root"], repository: entry.repo,
            from_version: entry.from_version, to_version: entry.to_version,
            record: record, commit: delivery["commit"].to_s, token: @token, out: @out,
            branch_pattern: delivery["branch_pattern"], report_base: @report_base,
            base_ref: base_ref
          )
          result = publisher.call
          # **A rewritten body is a new delivery fact.** The service's rendered review brief is a
          # snapshot of the PR body; leaving the old brief behind after a republish would make the
          # site admin show text the pull request no longer carries. The run id and the rest of the
          # state survive the merge.
          if result.published?
            updated = delivery.merge(
              "branch" => result.branch.to_s.empty? ? delivery["branch"] : result.branch,
              "commit" => result.commit.to_s.empty? ? delivery["commit"] : result.commit,
              "pull_request" => result.pull_request.to_s.empty? ? delivery["pull_request"] : result.pull_request,
              "brief" => publisher.respond_to?(:preview_body) ? publisher.preview_body.to_s : delivery["brief"].to_s
            )
            ledger.deliver(repo: entry.repo, commit: entry.commit, from_version: entry.from_version,
              to_version: entry.to_version, state: updated)
            Deliveries.new(home: @home, out: @out).record(repo: entry.repo,
              from_version: entry.from_version, to_version: entry.to_version, delivery: updated)
          end
          @out&.puts("republish: #{entry.repo} #{entry.from_version}->#{entry.to_version}: #{result}")
          result
        end
      end

      private

      def record_for(entry)
        path = File.join(@home.to_s, "records",
          "#{Record.stem(entry.repo, entry.from_version, entry.to_version)}.json")
        unless File.file?(path)
          # A record written before the stem became readable, or by a build that still used
          # the raw repository string. The fallback is read-only; a republish never writes a
          # record.
          legacy = "#{entry.repo.gsub(/[^A-Za-z0-9._-]/, "-")}-" \
                   "#{entry.from_version}-#{entry.to_version}"
          path = File.join(@home.to_s, "records", "#{legacy}.json")
        end
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
        Array(rows).grep(Hash).map do |row|
          struct.new(**row.select { |key, _| keys.include?(key) }.transform_keys(&:to_sym))
        end
      end
    end
  end
end
