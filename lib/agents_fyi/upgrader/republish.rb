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
          chain = delivery.key?("chain") ? delivery["chain"] != false :
            (project.nil? ? true : project.delivery.chain)
          publisher = @publish_class.new(
            root: delivery["root"], repository: entry.repo,
            from_version: entry.from_version, to_version: entry.to_version,
            record: record, commit: delivery["commit"].to_s, token: @token, out: @out,
            branch_pattern: delivery["branch_pattern"], report_base: @report_base,
            base_ref: base_ref, chain: chain
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
              "stack" => result.stack.to_s.empty? ? delivery["stack"] : result.stack,
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

      # **The record's own reader and its own path rule, not a second of either.** This used to
      # rebuild the record by hand and dropped `commits`, `accepted_decisions`, `checks`,
      # `app_update`, `toolchain` and `baseline`/`suite` along the way: a republished body said "this
      # record does not carry a concern-commit series" about a record that carried one, and lost the
      # accepted decision's question and answer. `Record.from_h` is the inverse of `to_h` and is what
      # a replay is for, and `Record.path_for` is the one answer to which file a move's record is —
      # the delivery recovery reads the same file by the same name.
      def record_for(entry)
        Record.stored(@home, entry.repo, entry.from_version, entry.to_version)
      rescue JSON::ParserError, ArgumentError, TypeError => e
        path = Record.path_for(@home, entry.repo, entry.from_version, entry.to_version)
        @out&.puts("republish: #{path} could not be read: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
