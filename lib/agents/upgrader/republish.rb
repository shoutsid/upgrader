# frozen_string_literal: true

require "digest"
require "json"

module Agents
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
    #
    # **`apply_presentations` is the cheap half.** A lead the consultant wrote is a body-only update
    # of a request whose branch is already delivered; it does not push, re-commit or move the base.
    # It also refuses to overwrite a body a person edited, which is why the delivery records the
    # digest of the bytes the walker wrote.
    class Republish
      def initialize(home:, token: nil, out: nil, report_base: nil, ledger: nil, publish_class: Publish,
        corpus: nil)
        @home = home
        @token = token
        @out = out
        @report_base = report_base
        @ledger = ledger
        @publish_class = publish_class
        @corpus = corpus
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

          presentation = presentation_for(entry)
          project = Project.find_by_repository(entry.repo)
          base_ref = delivery["base_ref"].to_s
          base_ref = project.base_ref if base_ref.empty? && project && !project.base_ref.to_s.empty?
          chain = delivery.key?("chain") ? delivery["chain"] != false :
            (project.nil? ? true : project.delivery.chain)
          expected = expected_digest(delivery)
          publisher = @publish_class.new(
            root: delivery["root"], repository: entry.repo,
            from_version: entry.from_version, to_version: entry.to_version,
            record: record, commit: delivery["commit"].to_s, token: @token, out: @out,
            branch_pattern: delivery["branch_pattern"], report_base: @report_base,
            base_ref: base_ref, chain: chain,
            editorial: editorial_for(presentation),
            body_override: override_for(presentation),
            expected_body_digest: expected,
            base: delivery["base"].to_s
          )
          result = publisher.call
          # **A rewritten body is a new delivery fact.** The service's rendered review brief is a
          # snapshot of the PR body; leaving the old brief behind after a republish would make the
          # site admin show text the pull request no longer carries. The run id and the rest of the
          # state survive the merge. A guard that declined to overwrite a person's edit is not a
          # rewrite and leaves the delivery alone.
          if result.published? && result.body_updated?
            body = publisher.respond_to?(:preview_body) ? publisher.preview_body.to_s :
              delivery["brief"].to_s
            state = presentation.is_a?(Hash) ? presentation["state"].to_s : ""
            acknowledged = state == "applied" || (state == "drafted" && mark_applied(entry, body))
            updated = delivery.merge(
              "branch" => result.branch.to_s.empty? ? delivery["branch"] : result.branch,
              "commit" => result.commit.to_s.empty? ? delivery["commit"] : result.commit,
              "pull_request" => result.pull_request.to_s.empty? ? delivery["pull_request"] : result.pull_request,
              "stack" => result.stack.to_s.empty? ? delivery["stack"] : result.stack,
              "brief" => body,
              "brief_digest" => Digest::SHA256.hexdigest(body)
            )
            if acknowledged && %w[drafted applied].include?(state)
              updated["presentation"] = applied_state(presentation)
            end
            persist(entry, updated)
          end
          @out&.puts("republish: #{entry.repo} #{entry.from_version}->#{entry.to_version}: #{result}")
          result
        end
      end

      # **The lead arrives after the walk has moved on.** For each delivered rung with a drafted
      # presentation, PATCH the body only if the current bytes are still the ones the walker wrote.
      # The delivery feed records `applied` or `skipped`, so the next cycle does not ask GitHub the
      # same question again.
      def apply_presentations(repository: nil)
        ledger = @ledger || Ledger.load(File.join(@home.to_s, "ledger.json"))
        ledger.entries.filter_map do |entry|
          next unless entry.verdict == Ledger::PASSED
          next if repository && Repository.name(entry.repo) != Repository.name(repository)

          delivery = entry.delivery
          next unless delivery.is_a?(Hash) && delivery["delivered"] == true
          next if %w[applied skipped none].include?(delivery.dig("presentation", "state").to_s)

          run_id = delivery["run_id"].to_s
          next if run_id.empty? || @corpus.nil? || !@corpus.respond_to?(:presentation)

          presentation = begin
            @corpus.presentation(run_id)
          rescue Corpus::Refused => e
            # The service has no presentation for this run. That is a fact about an older
            # delivery, not an outage: record it so the next cycle does not ask again.
            persist(entry, delivery.merge(
              "presentation" => { "state" => "none", "reason" => e.message.to_s[0, 300] }
            ))
            next
          rescue Corpus::Unreachable => e
            @out&.puts("presentation: #{entry.repo} could not be read: #{e.message}")
            next
          end
          next unless presentation.is_a?(Hash) && presentation["state"].to_s == "drafted"

          record = record_for(entry)
          if record.nil?
            @out&.puts("presentation: no readable record for #{entry.repo} " \
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
            base_ref: base_ref, chain: chain,
            editorial: presentation["editorial"].to_s,
            body_override: presentation["body_override"].to_s,
            expected_body_digest: expected_digest(delivery),
            base: delivery["base"].to_s
          )
          result = publisher.update_only(current_base: delivery["base"].to_s)
          if result.body_updated?
            body = publisher.preview_body.to_s
            acknowledged = mark_applied(entry, body)
            updated = delivery.merge(
              "brief" => body, "brief_digest" => Digest::SHA256.hexdigest(body)
            )
            updated["presentation"] = applied_state(presentation) if acknowledged
            persist(entry, updated)
          elsif permanent_skip?(result.reason)
            updated = delivery.merge(
              "presentation" => {
                "state" => "skipped", "reason" => result.reason.to_s[0, 300],
                "run_id" => delivery["run_id"].to_s
              }
            )
            persist(entry, updated)
          else
            # A missing token, an unreachable GitHub or a transient refusal is work again next
            # cycle. Recording it as skipped would turn a credential that was briefly absent into
            # a body this walker never updates.
            @out&.puts("presentation: #{entry.repo} #{entry.from_version}->#{entry.to_version} " \
                       "deferred: #{result.reason}")
          end
          @out&.puts("presentation: #{entry.repo} #{entry.from_version}->#{entry.to_version}: #{result}")
          result
        end
      end

      private

      def presentation_for(entry)
        run_id = entry.delivery.is_a?(Hash) ? entry.delivery["run_id"].to_s : ""
        return nil if run_id.empty? || @corpus.nil? || !@corpus.respond_to?(:presentation)

        payload = @corpus.presentation(run_id)
        payload.is_a?(Hash) ? payload : nil
      rescue Corpus::Refused, Corpus::Unreachable => e
        @out&.puts("presentation: #{entry.repo} #{entry.from_version}->#{entry.to_version} " \
                   "could not be read: #{e.message}")
        nil
      end

      def editorial_for(presentation)
        return "" unless presentation.is_a?(Hash)
        return "" unless %w[drafted applied].include?(presentation["state"].to_s)

        presentation["editorial"].to_s
      end

      # **The service's whole body wins over the lead join.** A presentation whose model wrote the
      # narrative sections carries the composed body; the walker must apply those exact bytes for
      # the service's applied digest to match. An older lead-only answer carries no override and
      # falls back to `Publish`'s editorial join.
      def override_for(presentation)
        return "" unless presentation.is_a?(Hash)
        return "" unless %w[drafted applied].include?(presentation["state"].to_s)

        presentation["body_override"].to_s
      end

      # A delivery recorded before `brief_digest` existed still has the body; its digest is the
      # same guard computed from those bytes. An empty body is an old or absent delivery, and an
      # empty digest means "no guard" rather than "the empty body is the expected one".
      def expected_digest(delivery)
        digest = delivery["brief_digest"].to_s
        return digest unless digest.empty?

        brief = delivery["brief"].to_s
        brief.empty? ? "" : Digest::SHA256.hexdigest(brief)
      end

      # A skip that will not clear on its own. The body was edited by a person, the request is
      # gone, or the repository never had one; the next cycle should not ask again. A missing token
      # or a transient GitHub refusal is not in this list.
      def permanent_skip?(reason)
        text = reason.to_s
        text.include?("was edited") || text.include?("no pull request was found") ||
          text.include?("not on github.com")
      end

      def applied_state(presentation)
        provenance = presentation.is_a?(Hash) ? presentation : {}
        {
          "state" => "applied",
          "run_id" => provenance["run_id"].to_s,
          "task_id" => provenance["task_id"].to_s,
          "model" => provenance["model"].to_s,
          "prompt_version" => provenance["prompt_version"].to_s,
          "applied_at" => Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        }
      end

      def mark_applied(entry, body)
        return true if @corpus.nil? || !@corpus.respond_to?(:presentation_applied)

        run_id = entry.delivery.is_a?(Hash) ? entry.delivery["run_id"].to_s : ""
        return true if run_id.empty?

        @corpus.presentation_applied(run_id, applied_digest: Digest::SHA256.hexdigest(body))
        true
      rescue Corpus::Refused, Corpus::Unreachable => e
        @out&.puts("presentation: #{entry.repo} could not record the applied lead: #{e.message}")
        false
      end

      def persist(entry, delivery)
        ledger = @ledger || Ledger.load(File.join(@home.to_s, "ledger.json"))
        ledger.deliver(repo: entry.repo, commit: entry.commit, from_version: entry.from_version,
          to_version: entry.to_version, state: delivery)
        Deliveries.new(home: @home, out: @out).record(repo: entry.repo,
          from_version: entry.from_version, to_version: entry.to_version, delivery: delivery)
      end

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
