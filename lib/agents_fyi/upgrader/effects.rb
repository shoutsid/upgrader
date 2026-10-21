# frozen_string_literal: true

require "fileutils"

module AgentsFyi
  module Upgrader
    # **An accepted decision's effects, applied to the working tree — before anything is scanned.**
    #
    # A decision that lived only in the site admin would be a note with a nicer form. The point of
    # making it a row (`docs/refactor/adr/0008`, decision 3) is that its *effect* is machinery: every
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
    # `rule` effects are the walk's own behaviour rather than the tree's, and this build applies none
    # of them: a rule is refused by name so it is visible in the run rather than quietly absent.
    class Effects
      # The kinds the schema declares (`Decision::EFFECT_KINDS`), read here as strings because a
      # declaration is JSON.
      KINDS = %w[patch config gem file delete chmod rule].freeze

      # **The order effects are applied in, and it is a decision.** A config change goes first because
      # it is the least specific; a gem move before a file/delete/chmod; a patch last of the tree
      # edits, so its `find` sees the file the earlier effects left rather than the one it replaced.
      # Ties keep the declaration's order.
      ORDER = %w[config gem file delete chmod patch rule].freeze

      # The `applies_when` keys this build honours. A version comparison is `Gem::Version`'s, the same
      # rule the corpus orders releases by, so `6.0.0` and `6.0.0.rc1` are not one rung.
      CONDITIONS = %w[rung_gte rung_lt].freeze

      # **Each kind reads its own payload.** A typo in a field is refused with the vocabulary for that
      # kind rather than with a union of every field, so an operator is told which key the effect
      # actually understands.
      FIELDS = {
        "patch" => %w[path find replace],
        "config" => %w[path find replace],
        "gem" => %w[name requirement action path],
        "file" => %w[path content mode],
        "delete" => %w[path],
        "chmod" => %w[path mode]
      }.freeze

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
          when "gem" then apply_gem(effect, applied, refused)
          when "file" then apply_file(effect, applied, refused)
          when "delete" then apply_delete(effect, applied, refused)
          when "chmod" then apply_chmod(effect, applied, refused)
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
        # A tree effect's payload is read by its own kind; a `rule`'s payload describes the walk
        # rather than a file, and this build applies no rules, so its keys are the rule's business and
        # the refusal names the kind instead.
        allowed = FIELDS[kind]
        if kind != "rule"
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
          after: fresh.to_s, subject: effect.question.to_s, origin: "decision:#{effect.decision["id"]}",
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
          subject: effect.question.to_s, origin: "decision:#{effect.decision["id"]}",
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
          subject: effect.question.to_s, origin: "decision:#{effect.decision["id"]}",
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
          origin: "decision:#{effect.decision["id"]}", note: effect.answer.to_s)
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
