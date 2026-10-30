# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Agents
  module Upgrader
    # **A model that has told us when it will answer again.** A free tier is useful until it is
    # spent; then every call to it is a wait against a provider rather than work against the
    # application. This is the small record that makes the next step start with the paid model
    # instead of spending the free tier's deadline again.
    #
    # It is deliberately a file beside the ledger rather than a service row: the upgrader owns the
    # credential and the model chain, the service has no route to a provider, and a walker restarted
    # tomorrow must still know what the provider said today. The file is written atomically so a
    # killed process cannot leave a half document that reads as "no model is limited".
    #
    # What is read:
    #
    # * a limit sentence (`rate limit`, `usage limit`, `quota`, `too many requests`, `429`);
    # * the reset the provider names — an ISO timestamp, a clock time, "in 30 minutes", a
    #   `retry-after` value — through `Time.parse`, which is Ruby's own reading of the same words;
    # * when no reset is named, an **indefinite** hold until an operator clears the entry. That is
    #   a fact about the sentence, not a guess about the provider: the live free tier answered
    #   `Free usage limit reached` and named no reset at all, and a guessed hourly cooldown spends
    #   the paid fallback's deadline every hour to re-learn the same sentence. The entry marks
    #   `reset_reported` false, so a reader knows the hold is the absence of a fact rather than one.
    #
    # **A free model that never answers is treated as unavailable too.** The live free tier timed
    # out at the attempt deadline with no error at all; waiting the full deadline on every later
    # step is the same cost without the sentence. A timeout is only read this way for a model whose
    # name says `free` — a paid model may be slow because it is working.
    class ModelLimits
      FILE = "repair_model_limits.json"
      ENV_PATH = "UPGRADER_REPAIR_LIMITS"
      # What `limited_until` answers for an entry whose provider named no reset. It is not a time
      # and must not be compared as one; an operator clears it by editing the state file.
      INDEFINITE = :indefinite

      LIMIT = /(?:rate|usage|free)\s*limit|quota|too many requests|\b429\b|insufficient (?:quota|credits)|exceeded.{0,40}(?:limit|quota)|out of credits/i
      RESET = /(?:resets?|reset|try again|retry|available|until)\s*(?:at|on|in|after|:)?\s*([^\n.;]+)/i
      RETRY_AFTER = /retry-after[:\s]+(\d+)/i
      ABSOLUTE = /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?/
      DURATION = /(\d+)\s*(second|minute|hour|day)s?/i

      Entry = Struct.new(:model, :until_time, :reason, :reset_reported, keyword_init: true) do
        def until_iso = until_time&.utc&.iso8601
        def indefinite? = until_time.nil? && !reset_reported

        def to_h
          { "until" => until_iso, "reason" => reason, "reset_reported" => reset_reported }
        end
      end

      def initialize(home:, env: {}, now: nil)
        @home = home.to_s
        @env = env.to_h
        @now = now || -> { Time.now.utc }
        @path = path_for
        @entries = load
      end

      attr_reader :path

      # The reset time for a model, or nil when it is available. An expired entry is removed as it
      # is read, so a free tier that has reset is tried again without a second command.
      def limited_until(model)
        key = model.to_s
        entry = @entries[key]
        return nil if entry.nil?

        # A hold with no time is the provider's own sentence: it was limited, and it did not say
        # when that ends. Nothing in this process can decide that for it, so the entry stays until
        # an operator removes it.
        if entry["until"].to_s.strip.empty?
          return INDEFINITE if entry["reset_reported"] == false

          @entries.delete(key)
          save!
          return nil
        end

        deadline = parse_time(entry["until"])
        if deadline.nil? || deadline <= @now.call
          @entries.delete(key)
          save!
          return nil
        end

        deadline
      end

      # **The record is only about a failed answer.** A successful call whose answer happens to
      # mention a rate limit is the model talking about somebody else's error, not this chain.
      #
      # `timed_out` is a second kind of evidence for a free model: there is no provider sentence,
      # but there is also no answer. The reason says which one it was, so the next reader does not
      # mistake a heuristic for a reported reset.
      def record(model:, output:, timed_out: false, exit_code: nil, now: nil)
        text = output.to_s
        free = model.to_s.match?(/\bfree\b/i)
        return nil if exit_code.to_i.zero? && !timed_out
        # **A paid model's timeout is a measured attempt, not the provider's sentence.** The
        # agent may have been mid-answer, and a limit-looking word in its own tool output is not
        # a limit the provider reported: measured live, a timed-out paid attempt was held
        # indefinitely because the stream mentioned a 429 the model was reading, which then
        # blocked every later repair. Only a free model's silence is the availability fact.
        return nil if timed_out && !free
        return nil unless (timed_out && free) || text.match?(LIMIT)

        moment = (now || @now.call).utc
        reset = extract_reset(text, moment)
        reported = !reset.nil?
        deadline = reset
        reason = if reported
          "the provider reported a limit and named the reset"
        elsif timed_out && free
          "the free model did not answer before the deadline; no reset was reported, so the " \
            "model is held until an operator clears the entry"
        else
          "the provider reported a limit without a reset time, so the model is held until an " \
            "operator clears the entry"
        end

        @entries[model.to_s] = {
          "until" => deadline&.utc&.iso8601,
          "reason" => reason,
          "reset_reported" => reported,
          "reported_at" => moment.iso8601,
          "sentence" => text.to_s[-400..].to_s
        }
        save!
        Entry.new(model: model.to_s, until_time: deadline&.utc, reason: reason,
          reset_reported: reported)
      end

      def entry_for(model)
        @entries[model.to_s]
      end

      private

      def path_for
        explicit = @env[ENV_PATH].to_s.strip
        return explicit unless explicit.empty?

        base = @home.empty? ? Dir.tmpdir : @home
        File.join(base, FILE)
      end

      def load
        return {} unless File.file?(@path)

        document = JSON.parse(File.read(@path, encoding: "utf-8"))
        models = document.is_a?(Hash) ? document["models"] : nil
        models.is_a?(Hash) ? models : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      # **Atomic, like the walker control.** A half-written state file is read as "nothing is
      # limited", which is the expensive direction: it spends the free deadline again.
      def save!
        FileUtils.mkdir_p(File.dirname(@path))
        temp = "#{@path}.tmp-#{Process.pid}"
        File.write(temp, "#{JSON.pretty_generate("models" => @entries)}\n")
        File.rename(temp, @path)
        true
      rescue SystemCallError
        false
      ensure
        File.delete(temp) if temp && File.exist?(temp)
      end

      def parse_time(value)
        Time.iso8601(value.to_s).utc
      rescue ArgumentError
        begin
          Time.parse(value.to_s).utc
        rescue ArgumentError
          nil
        end
      end

      # The provider's reset, in the several shapes providers use. A relative duration is read
      # first so "in 2 hours" is a duration rather than a time named 2 — `Time.parse("2 hours")`
      # would answer something true to Ruby and false to the reader.
      def extract_reset(text, now)
        if (match = text.match(RETRY_AFTER))
          return now + match[1].to_i
        end

        candidates = []
        text.scan(ABSOLUTE) { |match| candidates << match }
        text.scan(RESET) { |match| candidates << match[0].to_s.strip }

        candidates.each do |candidate|
          if (match = candidate.match(DURATION))
            return now + match[1].to_i * seconds_in(match[2])
          end

          begin
            candidate_time = Time.parse(candidate, now).utc
            # A clock time with no date is the next occurrence of that clock time. `Time.parse`
            # fills in today, which is in the past for half the day.
            candidate_time += 86_400 if candidate_time <= now && !candidate.match?(ABSOLUTE)
            return candidate_time if candidate_time > now
          rescue ArgumentError
            next
          end
        end
        nil
      end

      def seconds_in(unit)
        { "second" => 1, "minute" => 60, "hour" => 3600, "day" => 86_400 }
          .fetch(unit.to_s.downcase, 60)
      end
    end
  end
end
