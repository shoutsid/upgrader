# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **An accepted decision's effects, applied to the working tree — before anything is scanned.**
    #
    # A decision that lived only in the console would be a note with a nicer form. The point of
    # making it a row (`docs/refactor/adr/0008`, decision 3) is that its *effect* is machinery: every
    # later walk of the same project applies it, in a declared order, and a rung that passes with it
    # in force is the evidence that the answer was right.
    #
    # What arrives here is the accepted decisions a project declares
    # (`Project#decisions`, rendered by the console from `decision_questions`/`answers`/`effects`):
    #
    #     { "id" => "…", "question" => "…", "answer" => "…", "accepted_by" => "operator:…",
    #       "effects" => [{ "kind" => "patch",
    #                       "payload" => { "path" => "app/views/…", "find" => "…", "replace" => "…" },
    #                       "applies_when" => { "rung_gte" => "6.0.0" } }] }
    #
    # Three rules make it safe to run on every rung:
    #
    # * **An answer nobody accepted is not applied.** `accepted_by` is checked here as well as in the
    #   service, because a declaration is a file and a file can carry anything.
    # * **A condition nobody understands refuses rather than applies.** An effect whose `applies_when`
    #   names a key this build does not know is refused with that sentence; the tempting alternative
    #   — treat an unknown condition as true — applies an effect the operator scoped to one rung to
    #   every rung after it.
    # * **A `find` that is not there exactly once is a refusal, not a silent no-op.** It says how many
    #   times the text occurs, because the two mistakes are different: absent is an application that
    #   moved on, twice is a patch that would have edited the wrong site.
    #
    # `rule` effects are the walk's own behaviour rather than the tree's, and this build applies none
    # of them: a rule is refused by name so it is visible in the run rather than quietly absent.
    class Effects
      # The kinds the schema declares (`Decision::EFFECT_KINDS`), read here as strings because a
      # declaration is JSON.
      KINDS = %w[patch config rule].freeze

      # **The order effects are applied in, and it is a decision.** A config change goes first because
      # it is the least specific — a config file that enables a feature should be right before a patch
      # touches the code that reads it — and a patch after it, so a patch's `find` sees the file the
      # config change left rather than the one it replaced. Ties keep the declaration's order.
      ORDER = %w[config patch rule].freeze

      # The `applies_when` keys this build honours. A version comparison is `Gem::Version`'s, the same
      # rule the corpus orders releases by, so `6.0.0` and `6.0.0.rc1` are not one rung.
      CONDITIONS = %w[rung_gte rung_lt].freeze

      # What an effect's own fields may be called. An unknown key is a refusal: a declaration whose
      # `replac` is a typo would otherwise apply nothing and look applied.
      FIELDS = %w[path find replace].freeze

      Effect = Struct.new(:decision, :question, :answer, :kind, :payload, :applies_when, :order,
        keyword_init: true)

      Result = Struct.new(:applied, :refused, keyword_init: true) do
        def empty? = applied.empty? && refused.empty?

        def to_s
          "#{applied.length} effect(s) applied" \
            "#{refused.empty? ? "" : ", #{refused.length} refused"}"
        end
      end

      def initialize(root:, rung: nil)
        @root = File.expand_path(root)
        @root_real = Sealed.resolved(@root)
        @rung = rung.to_s
      end

      # `decisions` is the declaration's list. Returns the edits this applied, in the shape the record
      # and the run already carry, so a decision's change is indistinguishable from the ladder's in
      # `applied` except by its `origin` — which is the point: one list of what was written.
      def apply(decisions)
        applied = []
        refused = []
        effects = []

        Array(decisions).each_with_index do |decision, index|
          next unless decision.is_a?(Hash)

          if decision["accepted_by"].to_s.strip.empty?
            refused << refusal(decision, nil,
              "`#{decision["id"]}` has no `accepted_by`, so it is a proposal rather than a decision " \
              "and this tool does not apply it")
            next
          end

          Array(decision["effects"]).each_with_index do |effect, position|
            parsed = parse(decision, effect, order: [index, position])
            if parsed.is_a?(Applier::Refused)
              refused << parsed
            else
              effects << parsed
            end
          end
        end

        effects.sort_by { |effect| [ORDER.index(effect.kind), effect.order] }.each do |effect|
          if conditions_refused?(effect)
            refused << refusal(effect.decision, effect,
              "`#{effect.decision["id"]}` applies when #{JSON.generate(effect.applies_when)}, which " \
              "names a condition this build does not know (known: #{CONDITIONS.join(", ")})")
            next
          end
          next unless applies?(effect)

          case effect.kind
          when "patch", "config" then apply_text(effect, applied, refused)
          else
            # `rule` is deliberately not a tree edit: a rule changes what the walk *does*, and this
            # build has no vocabulary for one. Refused by name rather than dropped, because an effect
            # that vanishes is a decision nobody can see was ignored.
            refused << refusal(effect.decision, effect,
              "`#{effect.decision["id"]}` is a `rule` effect, and this build applies no rules — the " \
              "walk's rules are its own, not a declaration's")
          end
        end

        Result.new(applied: applied, refused: refused)
      end

      private

      def parse(decision, effect, order:)
        unless effect.is_a?(Hash)
          return refusal(decision, nil, "`#{decision["id"]}` carries an effect that is not an object")
        end

        kind = effect["kind"].to_s
        unless KINDS.include?(kind)
          return refusal(decision, nil,
            "`#{decision["id"]}` carries an effect of kind #{kind.inspect}; known: #{KINDS.join(", ")}")
        end

        payload = effect["payload"]
        payload = {} unless payload.is_a?(Hash)
        # A tree effect's payload is located by text, so its keys are checked against that vocabulary.
        # A `rule`'s payload describes the walk rather than a file, and this build applies no rules, so
        # its keys are the rule's business and the refusal names the kind instead.
        unless kind == "rule"
          unknown = payload.keys - FIELDS
          unless unknown.empty?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s #{kind} effect carries #{unknown.sort.join(", ")}, which this " \
              "build does not read (known: #{FIELDS.join(", ")})")
          end
        end

        applies_when = effect["applies_when"]
        applies_when = {} unless applies_when.is_a?(Hash)

        Effect.new(decision: decision, question: decision["question"], answer: decision["answer"],
          kind: kind, payload: payload, applies_when: applies_when, order: order)
      end

      def conditions_refused?(effect)
        !(effect.applies_when.keys - CONDITIONS).empty?
      end

      # Whether this rung is inside the effect's window. No conditions is "every rung", which is what
      # a decision whose answer outlives the rung it was made at means.
      def applies?(effect)
        return true if effect.applies_when.empty?

        effect.applies_when.all? do |key, value|
          case key
          when "rung_gte" then version(@rung) >= version(value)
          when "rung_lt" then version(@rung) < version(value)
          else false
          end
        end
      rescue ArgumentError
        false
      end

      def version(text)
        Gem::Version.new(text.to_s)
      end

      def apply_text(effect, applied, refused)
        find = effect.payload["find"].to_s
        replace = effect.payload["replace"].to_s
        if find.empty?
          return refused << refusal(effect.decision, effect,
            "`#{effect.decision["id"]}`'s #{effect.kind} effect has no `find`, so there is nothing " \
            "to locate and nothing was written")
        end

        full, unsafe = Sealed.path(@root, effect.payload["path"].to_s, root_real: @root_real)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?

        unless File.file?(full)
          return refused << refusal(effect.decision, effect,
            "#{effect.payload["path"]} is not a file in this working copy")
        end

        content = File.binread(full)
        needle = find.b
        first = content.index(needle)
        if first.nil?
          return refused << refusal(effect.decision, effect,
            "#{effect.payload["path"]} does not contain the text this decision names " \
            "(#{find.lines.first.to_s.strip.inspect})")
        end
        again = content.index(needle, first + needle.bytesize)
        unless again.nil?
          return refused << refusal(effect.decision, effect,
            "#{effect.payload["path"]} contains the text this decision names more than once, so " \
            "this tool will not guess which site it meant")
        end

        # Compared and written as bytes: the file was read as binary and the declaration arrives as
        # UTF-8, and a byte-identical replacement is the only one that keeps the rest of the file.
        line = content[0...first].count("\n".b) + 1
        File.binwrite(full, content[0...first] + replace.b + content[(first + needle.bytesize)..].to_s)

        applied << Applier::Applied.new(path: effect.payload["path"].to_s, line: line, text: find,
          after: replace, subject: effect.question.to_s, origin: "decision:#{effect.decision["id"]}",
          note: effect.answer.to_s)
      end

      def refusal(decision, effect, reason)
        Applier::Refused.new(
          path: effect&.payload&.fetch("path", nil),
          line: nil, text: nil, found: nil, reason: reason,
          subject: (decision["question"] || decision["id"]).to_s,
          kind: effect&.kind, replacement: nil, source: "an accepted decision",
          note: "answered by #{decision["accepted_by"]}"
        )
      end
    end
  end
end
