# frozen_string_literal: true

require "fileutils"

module AgentsFyi
  module Upgrader
    # **An accepted decision's effects, applied to the working tree — before anything is scanned.**
    #
    # A decision that lived only in the site admin would be a note with a nicer form. The point of
    # making it a row (see `docs/design-notes.md`) is that its *effect* is machinery: every
    # later walk of the same project applies it, in a declared order, and a rung that passes with it
    # in force is the evidence that the answer was right.
    #
    # What arrives here is the accepted decisions a project declares
    # (`Project#decisions`, rendered by the site admin from `decision_questions`/`answers`/`effects`):
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
    # **A `rule` effect is the walk's own behaviour, and it is typed.** `skip` and `expect` change
    # what the walk does — leave a change alone, accept a known failure — while `rewrite`, `insert`
    # and `config` are tree edits that go through the same line-checked applier as every other
    # effect. The rule's payload names its `kind` and the `change_key` it belongs to, so a run that
    # fails can be read against the decision that authorized it.
    class Effects
      # The kinds the schema declares (`Decision::EFFECT_KINDS`), read here as strings because a
      # declaration is JSON.
      KINDS = %w[patch config gem file delete chmod rule].freeze

      # **A `rule` is a typed effect, and these are its five kinds** (ADR 0011). It is one effect
      # kind in the schema because the schema's enum is frozen, and a `kind` in its payload is what
      # says whether the walk skips a change, accepts a known failure, or makes one of the three
      # tree edits. A rule that cannot say which is refused rather than guessed at.
      RULE_KINDS = %w[rewrite insert config skip expect patch gem].freeze

      # **The order effects are applied in, and it is a decision.** A config change goes first because
      # it is the least specific; a gem move before a file/delete/chmod; a patch last of the tree
      # edits, so its `find` sees the file the earlier effects left rather than the one it replaced.
      # Ties keep the declaration's order. A rule sorts by the edit it *is*: a rule config goes with
      # config, a rule rewrite/insert goes with patch, and skip/expect touch no tree at all.
      ORDER = %w[config gem file delete chmod patch rule].freeze

      # The `applies_when` keys this build honours. A version comparison is `Gem::Version`'s, the same
      # rule the corpus orders releases by, so `6.0.0` and `6.0.0.rc1` are not one rung.
      CONDITIONS = %w[rung_gte rung_lt].freeze

      # **Each kind reads its own payload.** A typo in a field is refused with the vocabulary for that
      # kind rather than with a union of every field, so an operator is told which key the effect
      # actually understands. A rule's payload is read one layer further, by its own `kind`.
      FIELDS = {
        "patch" => %w[path find replace],
        "config" => %w[path find replace],
        "gem" => %w[name requirement action path],
        "file" => %w[path content mode],
        "delete" => %w[path],
        "chmod" => %w[path mode]
      }.freeze

      # **The service's rule shape, read as the service writes it.** A `rule` effect's payload is
      # `{change_key, kind, payload, guard}` and the mechanism's own fields are the inner `payload`
      # (`Decision::RuleEffect` is the one place that shape is decided). A flat declaration from
      # before the nesting existed is read as an inner payload too, because a saved declaration
      # must not become unreadable when the writer learns a new shape.
      RULE_OUTER_FIELDS = %w[change_key kind payload guard action].freeze
      RULE_FIELDS = {
        "rewrite" => %w[old new],
        "insert" => %w[path after text template],
        "config" => %w[key file value path find replace],
        "skip" => %w[change_key],
        "expect" => %w[change_key failure],
        "patch" => %w[path find replace detect],
        "gem" => %w[name action requirement replacement path]
      }.freeze

      # A rewrite reads the application's own Ruby source, and a rule that globbed a tree rather
      # than a source would be an unbounded read on every rung. The bound is stated and the globs
      # are the same roots `Rewrites` reads, so a project's `source_roots` scopes it too.
      RULE_SOURCE_SUFFIXES = %w[.rb .rake .ru].freeze
      MAX_RULE_FILES = 500

      Effect = Struct.new(:decision, :question, :answer, :kind, :payload, :applies_when, :order,
        :id, keyword_init: true)

      Result = Struct.new(:applied, :refused, :rules, keyword_init: true) do
        def empty? = applied.empty? && refused.empty? && rules.empty?

        def to_s
          "#{applied.length} effect(s) applied" \
            "#{rules.empty? ? "" : ", #{rules.length} rule(s) fired"}" \
            "#{refused.empty? ? "" : ", #{refused.length} refused"}"
        end
      end

      def initialize(root:, rung: nil, source_roots: [])
        @root = File.expand_path(root)
        @root_real = Sealed.resolved(@root)
        @rung = rung.to_s
        # The project's own source roots, so a rewrite rule reads the same scope the scan and
        # `Rewrites` read. Empty is the Rails defaults, which is what a declaration written before
        # `source_roots` existed means.
        @source_roots = Array(source_roots).map(&:to_s).reject(&:empty?)
      end

      # `decisions` is the declaration's list. Returns the edits this applied, in the shape the record
      # and the run already carry, so a decision's change is indistinguishable from the ladder's in
      # `applied` except by its `origin` — which is the point: one list of what was written.
      def apply(decisions)
        applied = []
        refused = []
        fired = []
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

        effects.sort_by { |effect| [sort_index(effect), effect.order] }.each do |effect|
          if conditions_refused?(effect)
            refused << refusal(effect.decision, effect,
              "`#{effect.decision["id"]}` applies when #{JSON.generate(effect.applies_when)}, which " \
              "names a condition this build does not know (known: #{CONDITIONS.join(", ")})")
            next
          end
          next unless applies?(effect)

          case effect.kind
          when "patch", "config" then apply_text(effect, applied, refused)
          when "gem" then apply_gem(effect, applied, refused)
          when "file" then apply_file(effect, applied, refused)
          when "delete" then apply_delete(effect, applied, refused)
          when "chmod" then apply_chmod(effect, applied, refused)
          when "rule" then apply_rule(effect, applied, refused, fired)
          end
        end

        Result.new(applied: applied, refused: refused, rules: fired)
      end

      # **The origin grammar, in one place.** An applied edit's `origin` names the decision that
      # authorized it and — once the declaration carries the effect's row id — the effect within
      # that answer (`decision:<question_id>:<effect_id>`). ADR 0012 verifies a decision effect by
      # effect: the service stores the pair in `upgrade_run_effects` and links only the answers
      # whose effects were in the tree the gate measured, so the run body reads this parse rather
      # than splitting on colons itself. The two-segment form stays readable because a declaration
      # written before the column has no effect id — and a reader that took the last segment as the
      # decision would call that applied effect a question nobody can find.
      def self.evidence(origin)
        text = origin.to_s
        return [nil, nil] unless text.start_with?("decision:")

        decision_id, effect_id = text.delete_prefix("decision:").split(":", 2)
        [decision_id, effect_id]
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
        # A tree effect's payload is read by its own kind; a `rule`'s payload is read by its own
        # `kind`, one layer down, and the refusal names that vocabulary rather than the outer one.
        allowed = FIELDS[kind]
        if kind == "rule"
          normalized, problem = normalize_rule(decision, payload)
          return problem if problem
          payload = normalized
        else
          unknown = payload.keys - allowed
          unless unknown.empty?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s #{kind} effect carries #{unknown.sort.join(", ")}, which this " \
              "build does not read (known: #{allowed.join(", ")})")
          end
        end

        applies_when = effect["applies_when"]
        applies_when = {} unless applies_when.is_a?(Hash)

        Effect.new(decision: decision, question: decision["question"], answer: decision["answer"],
          kind: kind, payload: payload, applies_when: applies_when, order: order,
          id: effect["id"].to_s)
      end

      # The origin an edit or a fired rule carries. An effect with no id keeps the decision-only
      # form, which is what every declaration written before the service sent effect ids has.
      def origin_for(effect)
        decision_id = effect.decision["id"].to_s
        effect_id = effect.id.to_s
        effect_id.empty? ? "decision:#{decision_id}" : "decision:#{decision_id}:#{effect_id}"
      end

      # **A rule says which of the five it is, and what change it is about.** The key is what joins
      # the rule to the ladder change and the reports about it, so a rule without one is a rule
      # nothing could retire or promote; the kind is what decides which payload the rest of the
      # fields are, and an unknown one is refused rather than read as a tree edit.
      #
      # Returns `[normalized, nil]` or `[nil, refusal]`. The normalized shape is the service's:
      # the outer fields, with the mechanism's own payload nested under `payload`, so the code
      # that applies a rule and the code that records it read one shape.
      def normalize_rule(decision, outer)
        outer = {} unless outer.is_a?(Hash)
        kind = (outer["kind"] || outer["action"]).to_s
        unless RULE_KINDS.include?(kind)
          return [nil, refusal(decision, nil,
            "`#{decision["id"]}` carries a rule of kind #{kind.inspect}; known: #{RULE_KINDS.join(", ")}")]
        end

        nested = outer["payload"].is_a?(Hash)
        if nested
          unknown = outer.keys - RULE_OUTER_FIELDS
          unless unknown.empty?
            return [nil, refusal(decision, nil,
              "`#{decision["id"]}`'s #{kind} rule carries #{unknown.sort.join(", ")}, which this " \
              "build does not read (known: #{RULE_OUTER_FIELDS.join(", ")})")]
          end
          inner = outer["payload"]
        else
          # The flat shape: every mechanism field sits beside `change_key` and `kind`.
          inner = outer.reject { |key, _| %w[change_key kind action guard].include?(key) }
        end

        allowed = RULE_FIELDS.fetch(kind)
        unknown = inner.keys - allowed
        unless unknown.empty?
          return [nil, refusal(decision, nil,
            "`#{decision["id"]}`'s #{kind} rule carries #{unknown.sort.join(", ")}, which this " \
            "build does not read (known: #{allowed.join(", ")})")]
        end

        change_key = outer["change_key"].to_s.strip
        if change_key.empty?
          return [nil, refusal(decision, nil,
            "`#{decision["id"]}`'s #{kind} rule has no `change_key`, so nothing could join it to a " \
            "change or retire it when a run fails")]
        end

        problem = rule_payload_problem(kind, inner, change_key, decision)
        return [nil, problem] if problem

        # **A guard this build cannot read refuses rather than applies.** `applies_when` is the
        # condition the walk understands; the service's rule shape also carries a `guard`, and a
        # guard silently dropped would apply a rule outside the window its author scoped it to.
        # An empty guard is no guard, the same way an empty `applies_when` is every rung.
        guard = outer["guard"]
        guard = nil if guard.is_a?(String) && guard.strip.empty?
        guard = nil if guard.is_a?(Hash) && guard.empty?
        unless guard.nil?
          return [nil, refusal(decision, nil,
            "`#{decision["id"]}`'s #{kind} rule carries a guard, and this build has no guard " \
            "vocabulary — use `applies_when` for the rung window, or remove the guard")]
        end

        [{ "change_key" => change_key, "kind" => kind, "payload" => inner, "guard" => nil }, nil]
      end

      # The mechanism's own requirements, one case per kind. The inner `change_key` on skip/expect
      # is the service's spelling of "this rule is about that change"; when it is present it must
      # agree with the outer key, because two keys for one rule is two rules.
      def rule_payload_problem(kind, inner, change_key, decision)
        case kind
        when "rewrite"
          if inner["old"].to_s.strip.empty?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s rewrite rule needs `old`, the whole token it replaces")
          end
          unless inner["new"].is_a?(String)
            return refusal(decision, nil,
              "`#{decision["id"]}`'s rewrite rule needs `new`, the token it writes (use \"\" for a removal)")
          end
        when "insert"
          if inner["path"].to_s.strip.empty?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s insert rule needs `path`, the file the line goes into")
          end
          if inner["text"].nil? && inner["template"].nil?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s insert rule needs `text` (the line to write) or `template`")
          end
          if inner["text"].nil? && !inner["template"].is_a?(String)
            return refusal(decision, nil,
              "`#{decision["id"]}`'s insert rule's `template` must be a name")
          end
          if !inner["text"].nil? && !inner["text"].is_a?(String)
            return refusal(decision, nil,
              "`#{decision["id"]}`'s insert rule's `text` must be a string")
          end
          after = inner["after"]
          unless after.nil? || after.is_a?(String) || after.is_a?(Integer)
            return refusal(decision, nil,
              "`#{decision["id"]}`'s insert rule's `after` must be a line or a line number")
          end
        when "config"
          if inner.key?("key") || inner.key?("file")
            if inner["key"].to_s.strip.empty? || inner["file"].to_s.strip.empty? || !inner.key?("value")
              return refusal(decision, nil,
                "`#{decision["id"]}`'s config rule needs `key`, `file` and `value`")
            end
          elsif inner["path"].to_s.strip.empty? || inner["find"].to_s.empty?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s config rule needs `key`/`file`/`value`, or the `path`/`find` " \
              "a config effect carries")
          end
        when "skip"
          declared = inner["change_key"].to_s.strip
          if !declared.empty? && declared != change_key
            return refusal(decision, nil,
              "`#{decision["id"]}`'s skip rule names #{declared.inspect} inside its payload and " \
              "#{change_key.inspect} outside it; one rule cannot be about two changes")
          end
        when "expect"
          declared = inner["change_key"].to_s.strip
          if !declared.empty? && declared != change_key
            return refusal(decision, nil,
              "`#{decision["id"]}`'s expect rule names #{declared.inspect} inside its payload and " \
              "#{change_key.inspect} outside it; one rule cannot be about two changes")
          end
          if inner["failure"].to_s.strip.empty?
            return refusal(decision, nil,
              "`#{decision["id"]}`'s expect rule has no `failure`, so it would accept every failure " \
              "this rung produced")
          end
        when "patch"
          if inner["path"].to_s.strip.empty?
            return refusal(decision, nil, "`#{decision["id"]}`'s patch rule needs `path`")
          end
          if inner["find"].to_s.empty?
            return refusal(decision, nil, "`#{decision["id"]}`'s patch rule needs `find`")
          end
          unless inner["replace"].is_a?(String)
            return refusal(decision, nil,
              "`#{decision["id"]}`'s patch rule needs `replace` (use \"\" for a removal)")
          end
        when "gem"
          if inner["name"].to_s.strip.empty?
            return refusal(decision, nil, "`#{decision["id"]}`'s gem rule needs `name`")
          end
          action = inner["action"].to_s.strip
          unless action.empty? || %w[add remove update].include?(action)
            return refusal(decision, nil,
              "`#{decision["id"]}`'s gem rule asks to #{action.inspect}; known actions: add, remove, update")
          end
        end

        nil
      end

      # The ORDER position of an effect, with a rule sorted by the edit it actually is. A rule
      # config is a config edit, a rule rewrite/insert is a patch-shaped edit, and skip/expect
      # touch no tree — so they stay last, where the old named `rule` refusal used to sit.
      def sort_index(effect)
        return ORDER.index(effect.kind) unless effect.kind == "rule"

        case (effect.payload["kind"] || effect.payload["action"]).to_s
        when "config" then ORDER.index("config")
        when "rewrite", "insert", "patch" then ORDER.index("patch")
        when "gem" then ORDER.index("gem")
        else ORDER.index("rule")
        end
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

      # **One rule effect, dispatched by its own kind.** `skip` and `expect` change what the walk
      # does rather than the tree, so they are recorded as fired and the step reads them; the other
      # three are edits and go through the same line-checked applier every mechanical edit does.
      def apply_rule(effect, applied, refused, fired)
        kind = effect.payload["kind"].to_s
        case kind
        when "skip", "expect"
          fired << rule_entry(effect, kind)
        when "rewrite" then apply_rule_rewrite(effect, applied, refused, fired)
        when "insert" then apply_rule_insert(effect, applied, refused, fired)
        when "config" then apply_rule_config(effect, applied, refused, fired)
        when "patch" then apply_rule_patch(effect, applied, refused, fired)
        when "gem" then apply_rule_gem(effect, applied, refused, fired)
        end
      end

      # **A patch rule is the same exact-find applier a patch effect uses.** The rule exists so a
      # fix earned on one project can travel to another; the edit it makes is not a new kind of
      # edit. `detect` is a gate the gate checks before the applier runs, so a patch written for a
      # different surrounding code refuses rather than replacing a coincidental match.
      def apply_rule_patch(effect, applied, refused, fired)
        inner = rule_inner(effect)
        detect = inner["detect"].to_s
        unless detect.empty?
          full, unsafe = Sealed.path(@root, inner["path"].to_s, root_real: @root_real)
          return refused << refusal(effect.decision, effect, unsafe) if full.nil?
          unless File.file?(full) && File.binread(full).include?(detect.b)
            return refused << refusal(effect.decision, effect,
              "#{inner["path"]} does not contain this patch rule's `detect` text, so the edit is " \
              "for different surrounding code and was not applied")
          end
        end

        temp = effect.dup
        temp.payload = { "path" => inner["path"], "find" => inner["find"],
                          "replace" => inner["replace"] }
        before = applied.length
        apply_text(temp, applied, refused)
        fired << rule_entry(effect, "patch") if applied.length > before
      end

      # **A gem rule is a Gemfile operation, reused rather than re-derived.** A promoted pin that
      # moved a gem on one application is the same `add`/`remove`/`update` the declaration already
      # carries; the rule only makes it travel.
      def apply_rule_gem(effect, applied, refused, fired)
        inner = rule_inner(effect)
        temp = effect.dup
        temp.payload = inner
        before = applied.length
        apply_gem(temp, applied, refused)
        fired << rule_entry(effect, "gem") if applied.length > before
      end

      # The mechanism's own payload, nested under the rule's outer fields.
      def rule_inner(effect)
        payload = effect.payload["payload"]
        payload.is_a?(Hash) ? payload : {}
      end

      def rule_change_key(effect)
        effect.payload["change_key"].to_s
      end

      # A literal whole-token rename, over the application's Ruby source. The token is matched in
      # the *masked* line (strings and comments blanked) and written into the raw one at the same
      # offsets — the service scanner's own rule, so a rule cannot rename a word inside a log
      # message or a comment. The applier re-checks every line before it writes, as it does for the
      # ladder's own rewrites.
      def apply_rule_rewrite(effect, applied, refused, fired)
        inner = rule_inner(effect)
        old = inner["old"].to_s
        new = inner["new"].to_s
        rule = Rewrites::Rule.new(subject: rule_change_key(effect),
          pattern: /\b#{Regexp.escape(old)}\b/, replace: new, all: true)
        edits = source_files.flat_map do |path, lines|
          lines.each_with_index.filter_map do |line, index|
            after = rule.after(line, Rewrites.mask(line))
            next if after.nil?

            rule_edit(effect, path: path, line: index + 1, text: line, after: after)
          end
        end
        return if edits.empty?

        result = Applier.new(@root).apply(edits)
        applied.concat(result.applied)
        refused.concat(result.refused)
        fired << rule_entry(effect, "rewrite") unless result.applied.empty?
      end

      # **An insertion is a replacement of the anchor line with itself plus the new text**, so it
      # goes through the same line-checked applier rather than writing around it. The anchor is the
      # text of a line, or a line number; absent or ambiguous is refused with the count, because
      # "insert somewhere near here" is the guess this tool does not make.
      def apply_rule_insert(effect, applied, refused, fired)
        inner = rule_inner(effect)
        path = inner["path"].to_s
        full, unsafe = Sealed.path(@root, path, root_real: @root_real)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?
        unless File.file?(full)
          return refused << refusal(effect.decision, effect,
            "#{path} is not a file in this working copy, so there is no line to insert after")
        end

        text = inner["text"]
        if text.nil?
          return refused << refusal(effect.decision, effect,
            "`#{effect.decision["id"]}`'s insert rule names the template #{inner["template"].inspect}, " \
            "and this build carries no template vocabulary — write the line as `text`")
        end

        lines = File.binread(full).split("\n", -1).map { |line| line.delete_suffix("\r") }
        anchor = inner["after"]
        index = if anchor.nil?
          # Append after the last real line, not after the empty string `split` leaves when the
          # file ends in a newline — that would put a blank line before the inserted text.
          lines.last == "" ? lines.size - 2 : lines.size - 1
        elsif anchor.is_a?(Integer) || anchor.to_s.match?(/\A\d+\z/)
          anchor.to_i - 1
        else
          found = lines.each_index.select { |position| lines[position].include?(anchor.to_s) }
          if found.empty?
            return refused << refusal(effect.decision, effect,
              "#{path} does not contain the line this rule inserts after (#{anchor.to_s.inspect})")
          end
          if found.length > 1
            return refused << refusal(effect.decision, effect,
              "#{path} contains the line this rule inserts after more than once " \
              "(#{found.length} times), so this tool will not guess which one it meant")
          end

          found.first
        end
        if index.negative? || index >= lines.size
          return refused << refusal(effect.decision, effect,
            "#{path} has #{lines.size} line(s), so line #{anchor} is not in it")
        end

        edit = rule_edit(effect, path: path, line: index + 1, text: lines[index],
          after: "#{lines[index]}\n#{text}")
        result = Applier.new(@root).apply([edit])
        applied.concat(result.applied)
        refused.concat(result.refused)
        fired << rule_entry(effect, "insert") unless result.applied.empty?
      end

      # **A rule's config edit goes through the existing config path.** The service's rule shape
      # names a setting (`key`/`file`/`value`); this turns the one line the setting is on into the
      # same `find`/`replace` a config effect carries, so the exactly-once reader and the record
      # are the ones every other config edit uses. A flat legacy payload already carries
      # `path`/`find`/`replace`, and is passed through unchanged.
      def apply_rule_config(effect, applied, refused, fired)
        inner = rule_inner(effect)
        temp = effect.dup
        if inner.key?("key") || inner.key?("file")
          path = inner["file"].to_s
          full, unsafe = Sealed.path(@root, path, root_real: @root_real)
          return refused << refusal(effect.decision, effect, unsafe) if full.nil?
          unless File.file?(full)
            return refused << refusal(effect.decision, effect,
              "#{path} is not a file in this working copy, so the setting cannot be changed")
          end

          lines = File.binread(full).split("\n", -1).map { |line| line.delete_suffix("\r") }
          key = inner["key"].to_s
          pattern = /^\s*#{Regexp.escape(key)}(?:\s*=|:|\s|$)/
          found = lines.each_index.select { |position| lines[position].match?(pattern) }
          if found.empty?
            return refused << refusal(effect.decision, effect,
              "#{path} does not contain the setting #{key.inspect}")
          end
          if found.length > 1
            return refused << refusal(effect.decision, effect,
              "#{path} contains the setting #{key.inspect} more than once (#{found.length} times), " \
              "so this tool will not guess which one it meant")
          end

          old = lines[found.first]
          fresh = config_line(old, key, inner["value"])
          return if fresh == old

          temp.payload = { "path" => path, "find" => old, "replace" => fresh }
        else
          temp.payload = inner
        end

        before = applied.length
        apply_text(temp, applied, refused)
        fired << rule_entry(effect, "config") if applied.length > before
      end

      # The line with its setting's value replaced, preserving the indentation and the `=` or
      # space the application already writes. A line that is only the key gains the value after a
      # space; a line with a trailing comment keeps it, because the comment is the application's
      # explanation of the setting and not part of the value.
      def config_line(line, key, value)
        # `Rewrites.comment_start` is quote-aware, so a `#` inside the value is not mistaken for
        # the application's comment; the comment itself is the explanation of the setting and is
        # kept, with one space before it.
        stop = Rewrites.comment_start(line)
        comment = stop ? line[stop..] : ""
        body = stop ? line[0...stop].rstrip : line
        written = if (found = body.match(/^(\s*#{Regexp.escape(key)}\s*=\s*)(.*)$/))
          "#{found[1]}#{value}"
        elsif (found = body.match(/^(\s*#{Regexp.escape(key)}\s+)(.*)$/))
          "#{found[1]}#{value}"
        else
          "#{body} #{value}"
        end
        comment.empty? ? written : "#{written} #{comment}"
      end

      def rule_edit(effect, path:, line:, text:, after:)
        {
          "path" => path, "line" => line, "text" => text, "after" => after,
          "automatic" => true, "origin" => origin_for(effect),
          "subject" => rule_change_key(effect), "kind" => "rule",
          "replacement" => rule_inner(effect)["new"], "note" => effect.answer.to_s
        }
      end

      # One fired rule, as the record and the run read it. The decision id is the field the service
      # retires a rule by, and it is already in the run body's `decisions` list — no new public field.
      def rule_entry(effect, kind)
        {
          "decision_id" => effect.decision["id"].to_s,
          # The effect's own row, so the run body can name which of an answer's effects fired.
          "effect_id" => effect.id.to_s,
          "change_key" => rule_change_key(effect),
          "kind" => kind,
          "payload" => rule_inner(effect),
          "guard" => effect.payload["guard"],
          "question" => effect.question.to_s,
          "answer" => effect.answer.to_s
        }
      end

      # The files a rewrite rule reads: the project's source roots (or the Rails defaults), the
      # suffixes this walker scans, and a stated bound. A glob that matched more than the bound is
      # truncated rather than silently read in part, and the rule's own applied count is the answer
      # to "did it find anything".
      def source_files
        roots = @source_roots.empty? ? Rewrites::DEFAULT_SOURCE_ROOTS : @source_roots
        patterns = roots.flat_map do |root|
          RULE_SOURCE_SUFFIXES.map { |suffix| File.join(root, "**", "*#{suffix}") }
        end
        Dir.glob(patterns, base: @root).uniq.sort.first(MAX_RULE_FILES).filter_map do |path|
          full = File.join(@root, path)
          next unless File.file?(full)

          lines = File.binread(full).force_encoding("UTF-8").scrub.lines.map(&:chomp)
          [path, lines]
        rescue SystemCallError
          nil
        end
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
          after: replace, subject: effect.question.to_s, origin: origin_for(effect),
          note: effect.answer.to_s)
      end

      # **A gem decision is an operation, not a text diff.** `add` appends, `remove` deletes the
      # declaration, and `update` rewrites one line; a name that is already there (for add), absent
      # (for remove/update) or declared more than once (for update) is refused rather than guessed.
      def apply_gem(effect, applied, refused)
        payload = effect.payload
        name = payload["name"].to_s.strip
        return refused << refusal(effect.decision, effect,
          "`#{effect.decision["id"]}` is a gem effect with no `name`, so there is nothing to change") if name.empty?

        action = payload["action"].to_s.strip
        action = "add" if action.empty?
        unless %w[add remove update].include?(action)
          return refused << refusal(effect.decision, effect,
            "`#{effect.decision["id"]}`'s gem effect asks to #{action.inspect}; known actions: add, remove, update")
        end

        path = payload["path"].to_s.strip
        path = "Gemfile" if path.empty?
        full, unsafe = Sealed.path(@root, path, root_real: @root_real)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?
        unless File.file?(full)
          return refused << refusal(effect.decision, effect,
            "#{path} is not a file in this working copy")
        end

        lines = File.binread(full).lines
        matcher = /^\s*gem\s+["']#{Regexp.escape(name)}["']/
        indexes = lines.each_index.select { |index| lines[index].match?(matcher) }
        requirement = payload["requirement"].to_s.strip
        old = nil
        fresh = nil
        line_number = nil

        case action
        when "add"
          unless indexes.empty?
            return refused << refusal(effect.decision, effect,
              "#{path} already declares the gem #{name}, so adding it would declare it twice")
          end
          lines << "\n" if !lines.empty? && !lines.last.end_with?("\n")
          line = requirement.empty? ? %(gem "#{name}") : %(gem "#{name}", "#{requirement}")
          lines << "#{line}\n"
          fresh = line
          line_number = lines.length
        when "remove"
          if indexes.empty?
            return refused << refusal(effect.decision, effect,
              "#{path} does not declare the gem #{name}, so there is nothing to remove")
          end
          old = indexes.map { |index| lines[index] }.join
          indexes.reverse_each { |index| lines.delete_at(index) }
          line_number = indexes.first + 1
        when "update"
          if indexes.length != 1
            return refused << refusal(effect.decision, effect,
              "#{path} declares the gem #{name} #{indexes.length} time(s), and an update needs exactly one")
          end
          if requirement.empty?
            return refused << refusal(effect.decision, effect,
              "updating the gem #{name} needs a `requirement`")
          end
          index = indexes.first
          indent = lines[index][/^\s*/]
          old = lines[index]
          fresh = %(#{indent}gem "#{name}", "#{requirement}"\n)
          lines[index] = fresh
          line_number = index + 1
        end

        File.binwrite(full, lines.join)
        applied << Applier::Applied.new(path: path, line: line_number, text: old.to_s,
          after: fresh.to_s, subject: effect.question.to_s, origin: origin_for(effect),
          note: effect.answer.to_s)
      end

      # A new file is its own effect because it has no `find`; an existing path is refused so a
      # decision cannot silently overwrite the application's own file.
      def apply_file(effect, applied, refused)
        payload = effect.payload
        path = payload["path"].to_s
        return refused << refusal(effect.decision, effect,
          "`#{effect.decision["id"]}` is a file effect with no `path`") if path.empty?

        full, unsafe = safe_create_path(path)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?
        if File.exist?(full)
          return refused << refusal(effect.decision, effect,
            "#{path} already exists; a file effect creates a new file, and an existing one is a patch")
        end

        content = payload["content"].to_s
        FileUtils.mkdir_p(File.dirname(full))
        # Resolve once more after creating the directories: a symlink in the parent chain is the
        # escape `Sealed` exists for, and the first check may only have reached the nearest ancestor.
        full, unsafe = Sealed.path(@root, path, root_real: @root_real)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?

        File.binwrite(full, content)
        mode = payload["mode"].to_s
        File.chmod(Integer(mode, 8), full) unless mode.empty?
        applied << Applier::Applied.new(path: path, line: 1, text: "", after: content,
          subject: effect.question.to_s, origin: origin_for(effect),
          note: effect.answer.to_s)
      rescue ArgumentError
        refused << refusal(effect.decision, effect,
          "#{path} has mode #{effect.payload["mode"].inspect}, which is not an octal mode")
      end

      def apply_delete(effect, applied, refused)
        path = effect.payload["path"].to_s
        return refused << refusal(effect.decision, effect,
          "`#{effect.decision["id"]}` is a delete effect with no `path`") if path.empty?

        full, unsafe = Sealed.path(@root, path, root_real: @root_real)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?
        unless File.file?(full)
          return refused << refusal(effect.decision, effect,
            "#{path} is not a file in this working copy, so there is nothing to delete")
        end

        File.delete(full)
        applied << Applier::Applied.new(path: path, line: nil, text: "(deleted file)", after: "",
          subject: effect.question.to_s, origin: origin_for(effect),
          note: effect.answer.to_s)
      end

      def apply_chmod(effect, applied, refused)
        payload = effect.payload
        path = payload["path"].to_s
        return refused << refusal(effect.decision, effect,
          "`#{effect.decision["id"]}` is a chmod effect with no `path`") if path.empty?

        full, unsafe = Sealed.path(@root, path, root_real: @root_real)
        return refused << refusal(effect.decision, effect, unsafe) if full.nil?
        unless File.file?(full)
          return refused << refusal(effect.decision, effect,
            "#{path} is not a file in this working copy")
        end

        mode = Integer(payload["mode"].to_s, 8)
        unless mode.between?(0, 0o7777)
          return refused << refusal(effect.decision, effect,
            "mode #{payload["mode"].inspect} is outside 0000..7777")
        end
        before = format("%04o", File.stat(full).mode & 0o7777)
        File.chmod(mode, full)
        applied << Applier::Applied.new(path: path, line: nil, text: "mode #{before}",
          after: "mode #{format("%04o", mode)}", subject: effect.question.to_s,
          origin: origin_for(effect), note: effect.answer.to_s)
      rescue ArgumentError
        refused << refusal(effect.decision, effect,
          "#{path} has mode #{payload["mode"].inspect}, which is not an octal mode")
      end

      # A file effect creates a path whose parent may not exist yet, which `Sealed.path` cannot
      # resolve. Check the spelling and the nearest existing ancestor *before* creating anything;
      # `apply_file` resolves again after `mkdir_p`.
      def safe_create_path(path)
        full = File.expand_path(path, @root)
        unless full.start_with?("#{@root}#{File::SEPARATOR}")
          return [nil, "#{path} resolves outside the working copy"]
        end
        return [nil, "#{path} is the working copy itself, not a file in it"] if full == @root

        ancestor = File.dirname(full)
        ancestor = File.dirname(ancestor) until File.exist?(ancestor) || ancestor == File.dirname(ancestor)
        real = File.realpath(ancestor)
        unless Sealed.inside?(@root_real, real)
          return [nil, "#{path} is under #{real}, which is outside the working copy"]
        end

        [full, nil]
      rescue SystemCallError => e
        [nil, "#{path} could not be resolved (#{e.class}: #{e.message})"]
      end

      def refusal(decision, effect, reason)
        path = effect&.payload&.fetch("path", nil)
        path = "Gemfile" if path.to_s.empty? && effect&.kind == "gem"
        Applier::Refused.new(
          path: path,
          line: nil, text: nil, found: nil, reason: reason,
          subject: (decision["question"] || decision["id"]).to_s,
          kind: effect&.kind, replacement: nil, source: "an accepted decision",
          note: "answered by #{decision["accepted_by"]}"
        )
      end
    end
  end
end
