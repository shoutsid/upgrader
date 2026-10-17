# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **The changes this walker will make that the service will not — and the queue for the rest.**
    #
    # `/rails/scan` locates a call site for a documented change and deliberately stops there: its
    # contract is a statement about the *ladder* — "this changed, here is where your code touches
    # it" — and a service that rewrote somebody's source would be answering a question nobody asked
    # it. A rule here is this tool's own knowledge of how to make one of those edits, the same shelf
    # as `Preflight::DECLARATION` and the applier's mechanics, applied to the call site the scan
    # *located*, through the applier's line-checked write, and judged by the application's own suite
    # on the rung that uses it.
    #
    # **A rule is an instance of a family, and the family is the reusable half.** The `subject` ties
    # an instance to the change it belongs to — the ladder's own vocabulary, so a rule whose change
    # has left is inert and said to be. The *family* is the shape of the edit (`name_moved`,
    # `option_wrapped`, `line_removed`, `call_replaced`), and the next lighthouse — a gem's own
    # upgrade, a framework nobody has walked yet — writes an instance of a family that already
    # exists rather than a new mechanism.
    #
    # **Nothing here is "never".** A change with no rule today is a *gap*, and `gap_for` says what
    # would close it, which is what the record carries into the residue: a queue with reasons rather
    # than a list a person re-derives every rung. That is the posture of the interpreter matrix's own
    # refusal one layer down (`Step#no_interpreter_stamp` names the floor rather than the machine, so
    # a grown matrix re-opens the verdict): a permanent refusal is the settled-work trap with the sign
    # flipped, and a walk that hands over the same list for ever has learned nothing.
    #
    # Four things keep a rule honest:
    #
    # * **It names the change it belongs to**, so a rule whose change has left the ladder is inert
    #   rather than quietly editing code for a change nobody documents any more.
    # * **Its provenance is the change's own** (the guide's chapter), carried into the applied edit,
    #   the record and the patch.
    # * **It is conservative about what it cannot see.** `confirm: t(:x, count: 1)` has an argument
    #   list inside it and `MultiJson.dump(x, pretty: true)` has options that change what the call
    #   means; both simply do not match, so the line stays a *located* decision. A rule that guessed
    #   would cut a line in half, which the suite would report as the application's breakage.
    # * **A note that forbids a swap is read as what it forbids, not as a verdict.** `MultiJson`'s
    #   note says "do not swap it mechanically for JSON.dump/JSON.load — those serialise arbitrary
    #   Ruby objects and are not the same thing", and it is right about the *names*; the ladder's own
    #   replacement (`obj.to_json` and `JSON.parse`) is a different edit, and it is mechanical for a
    #   call that takes one argument.
    module Rewrites
      # One rule: the family it is an instance of, the change it belongs to, what it matches, and what
      # it writes. `replace` is a `String#sub` replacement, so it may use named backreferences —
      # which is how a rule moves a value rather than guessing at it.
      Rule = Struct.new(:family, :subject, :pattern, :replace, keyword_init: true) do
        # The line with this rule applied, or nil when it does not match or changes nothing.
        #
        # The match runs against the *masked* line (strings and comments blanked) and the write
        # against the raw one, at the same offsets — the shape the service's own scanner uses, and
        # the reason the mask preserves every byte's position: a pattern that matched inside a string
        # would rewrite a log message.
        def after(line, masked)
          found = pattern.match(masked)
          return nil if found.nil?

          region = line[found.begin(0)...found.end(0)]
          written = region.sub(pattern, replace)
          text = "#{line[0, found.begin(0)]}#{written}#{line[found.end(0)..]}"
          text == line ? nil : text
        end
      end

      Result = Struct.new(:edits, :applied, :left, keyword_init: true) do
        def to_s
          return "no rule applies" if edits.empty?

          "#{edits.size} edit(s) by this tool's own rules (#{applied.uniq.join(", ")})"
        end
      end

      # **What would close each gap**, by the change's subject. A gap is not a verdict: it is the
      # sentence the residue carries so the next lighthouse — or the next agent — starts from what is
      # missing rather than from scratch. A subject with no entry here still gets a gap (the generic
      # one below), because "nobody has looked at this shape yet" is itself information.
      GENERIC_GAP = "no rule yet: this shape is not one of the families here (name_moved, " \
                    "option_wrapped, line_removed, call_replaced), and it is carried as a located " \
                    "decision until one is written"

      GAPS = {
        "default_scope" => "a rule would need the callers that chain conditions onto the scope, and " \
                           "whether the merge changes what they read — the candidate patch " \
                           "(`unscope`, `rewhere`, `unscoped`) depends on them",
        "json and hstore columns" => "a rule would need the column's usages to tell a symbol key " \
                                     "from a string one; the patch is per call site",
        "alias_attribute" => "a rule would need the attribute's own definition to write the " \
                             "explicit method the new release wants",
        "after_commit / after_rollback" => "a rule would need the callback's position to add `on:` " \
                                           "where the new release requires it",
        "sanitize / strip_tags" => "a rule would need the helper's arguments to choose the " \
                                   "replacement form",
        "return false from a before callback" => "a rule would need the block's body: " \
                                                 "`{ return false }` is `{ false }`, anything longer " \
                                                 "is a named method",
        "belongs_to" => "a rule would need each association's callers to know whether absence is " \
                        "legal; `optional: true` is a fact about the application, not about the line",
        "params as a Hash" => "a rule would need the parameter's uses: `permit(...).to_h` is the " \
                              "patch where the value is read as a hash and nothing else",
        "Rails.application.secrets" => "a rule would need the application's own secret handling, " \
                                       "which is a deployment fact rather than a repository one",
        "has_many_attached assignment" => "a rule would need the assignment's shape to add the `=` " \
                                          "the new release wants",
        "format.any" => "a rule would need the block's body to choose the replacement form",
        "button_to" => "a rule would need the call's options to move them the way the new release " \
                       "wants",
        "Active Storage variant processor" => "a rule would need the application's configured " \
                                              "processor, which is a deployment fact",
        "Rails.logger" => "a rule would need to know whether the application wants the old logger's " \
                          "output as well: `broadcast_to` is a choice",
        "config.secret_token" => "a rule would need the deployment's own secret handling; the line " \
                                 "names a setting whose value must not come from the repository",
        "find_all_by_*" => "a rule per argument shape (the attribute names move into `where`), which " \
                           "is why the generic one is not written: `find_all_by_a_and_b` is not a " \
                           "rename",
        "find(:all, ...)" => "a rule would need the condition arguments to rebuild them as a " \
                             "`where` chain",
        "scope :name, where(...)" => "a rule would need the second argument's extent to wrap it in " \
                                     "a lambda without cutting the line",
        "render :text" => "the 4.1 migration is the *spelling* — `render :text => x` becomes " \
                          "`render text: x`, which is the same response — and the choice between " \
                          "`plain:`, `html:` and `body:` belongs to the 5.0 rung, where `:text` is " \
                          "gone. A rule here would be choosing a content type for a response that " \
                          "still has one",
        "assert_tag" => "a rule would need to know whether the test file is this application's or a " \
                        "gem's, because renaming an assertion helper is part of the move while " \
                        "weakening an assertion never is"
      }.freeze

      # The families. Each returns a `Rule` whose `subject` names the change it belongs to.
      #
      # A name that became another name, optionally on a receiver. The lookbehind is what keeps
      # `ActiveSupport::HashWithIndifferentAccess` from becoming
      # `ActiveSupport::ActiveSupport::…`, and it is the whole of that rule.
      def self.name_moved(subject:, from:, to:, receiver: nil)
        if receiver
          # **The receiver is captured, not looked behind.** A rule re-matches its *region* of the raw
          # line (the match itself was made against the masked one, where a string's contents are
          # blanked), and a lookbehind is context the region does not contain — the first version of
          # this wrote `type = media_type`, dropping `request.`. A capture travels with the region.
          Rule.new(family: :name_moved, subject: subject,
            pattern: /(?<receiver>\b#{Regexp.escape(receiver)}\.)#{Regexp.escape(from)}\b/,
            replace: "\\k<receiver>#{to}")
        else
          Rule.new(family: :name_moved, subject: subject,
            pattern: /(?<!::)\b#{Regexp.escape(from)}\b/, replace: to)
        end
      end

      # An option that became a nested one: the value is captured, never guessed, and the lookahead
      # requires it to end where an argument ends — a comma, the call's closing parenthesis, or the
      # line. A first version of this pattern matched the `t` of `confirm: t(:x, count: 1)` and
      # produced `data: { confirm: t }(:x, count: 1)`, which is why the lookahead is here.
      def self.option_wrapped(subject:, option:, wrapper:)
        head = /(?::\s*#{Regexp.escape(option)}\s*=>|\b#{Regexp.escape(option)}:)\s*/
        value = /(?<value>"[^"]*"|'[^']*'|:[A-Za-z_]\w*|[A-Za-z_]\w*(?:\.\w+)*)(?=\s*[,)]|\s*\z)/
        Rule.new(family: :option_wrapped, subject: subject,
          pattern: Regexp.new("#{head.source}#{value.source}"), replace: wrapper)
      end

      # A whole line that is nothing but the call, removed: the edit *is* the line, so anything else
      # on it — a statement after it, a mention inside a string — simply does not match.
      def self.line_removed(subject:, call:)
        Rule.new(family: :line_removed, subject: subject,
          pattern: /\A\s*#{Regexp.escape(call)}\s*(\(?\s*["'][^"']*["']\s*\)?)?\s*\z/,
          replace: "")
      end

      # A call that becomes another call, with its arguments carried across. `args` is the point of
      # the family: `MultiJson.dump(x)` is `x.to_json`, and `MultiJson.dump(x, pretty: true)` is not —
      # the options are part of what the call means, so a call with them does not match.
      def self.call_replaced(subject:, from:, to:, args: 1)
        captured = (1..args).map { |index| "(?<a#{index}>[^,()]+)" }.join("\\s*,\\s*")
        Rule.new(family: :call_replaced, subject: subject,
          pattern: Regexp.new("\\b#{Regexp.escape(from)}\\s*\\(\\s*#{captured}\\s*\\)"), replace: to)
      end

      # **The rules, by the subject the ladder and the scan both use.** Each is here because its own
      # note sanctions the shape, and `MultiJson` is here because its note forbids a *different* edit
      # than the one written.
      RULES = [
        # `link_to 'Delete', path, confirm: 'Sure?'` becomes `data: {confirm: 'Sure?'}`, and the
        # helpers built on link_to go the same way.
        option_wrapped(subject: ":confirm option on link_to", option: "confirm",
          wrapper: 'data: { confirm: \k<value> }'),
        # The top-level constant is soft-deprecated — no warning, and it still works — so this is the
        # step to move the references rather than the step that breaks them.
        name_moved(subject: "HashWithIndifferentAccess", from: "HashWithIndifferentAccess",
          to: "ActiveSupport::HashWithIndifferentAccess"),
        # The receiver is named, because `response.content_type` is a different method that did not
        # change.
        name_moved(subject: "request.content_type", from: "content_type", to: "media_type",
          receiver: "request"),
        # **The note is the licence**: "every use of it can be deleted".
        line_removed(subject: "require_dependency", call: "require_dependency"),
        # **The note forbids the *names*, not the edit.** `MultiJson.dump` is not `JSON.dump`; the
        # ladder's own replacement is `obj.to_json`, which is the same operation for a call that takes
        # one argument. Single-quoted, because a double-quoted `\k` is Ruby's own escape and arrives
        # as a bare `k` — measured by this rule's first test, which is why it asserts the written line.
        call_replaced(subject: "MultiJson", from: "MultiJson.dump", to: '\k<a1>.to_json'),
        call_replaced(subject: "MultiJson", from: "MultiJson.load", to: 'JSON.parse(\k<a1>)')
      ].freeze

      # The edits to hand the applier, the subjects a rule *applied*, and the subjects it left —
      # `left` is a subject whose rule exists but whose line the rule would not touch, and it is
      # carried so that a refusal is visible rather than silent.
      def self.apply(manual, rules: RULES)
        # **A subject may have more than one rule, and the first that matches wins.** `MultiJson` is
        # two edits (`dump` and `load`), and a lookup that kept only the last one silently dropped
        # half of it — measured by this file's own test, which is why the rules are grouped rather
        # than indexed.
        by_subject = rules.group_by(&:subject)
        edits = []
        applied = []
        left = []
        Array(manual).each do |entry|
          subject = entry["subject"].to_s
          candidates = by_subject[subject].to_a
          if candidates.empty?
            left << subject
            next
          end

          text = entry["text"].to_s
          masked = mask(text)
          after = candidates.filter_map { |rule| rule.after(text, masked) }.first
          if after.nil?
            left << subject
            next
          end

          edits << edit(entry, after)
          applied << subject
        end
        Result.new(edits: edits, applied: applied, left: left)
      end

      # The rules that name no change in the rung's own plan: a rule that outlives its change is dead
      # weight, and a walker that kept applying it would be editing code for a change the ladder no
      # longer documents. Reported rather than removed, because removing one is a decision about this
      # file rather than about a rung.
      def self.inert(changes, rules: RULES)
        subjects = Array(changes).map { |change| change["subject"].to_s }
        rules.map(&:subject).uniq.reject { |subject| subjects.include?(subject) }
      end

      # **What would close this change's gap**, for the residue to carry. A change a rule covers needs
      # nothing; one that does not is a queue entry with a reason, and a subject nobody has looked at
      # yet says so in the generic sentence rather than reading as a verdict.
      def self.gap_for(subject, rules: RULES)
        name = subject.to_s
        return nil if rules.any? { |rule| rule.subject == name }

        GAPS.fetch(name, GENERIC_GAP)
      end

      # A line with its strings' contents and its trailing comment blanked, every other byte exactly
      # where it was. **A deliberate, narrow mirror of the service's mask**
      # (`Upgrade::Scanner.mask`): a client may not depend on the service's package, and the two have
      # to agree about *offsets* rather than about style, which is why the quotes stay and only their
      # contents go.
      def self.mask(line)
        masked = +""
        quote = nil
        index = 0
        while index < line.length
          char = line[index]
          if quote
            if char == quote && line[index - 1] != "\\"
              quote = nil
              masked << char
            else
              masked << " "
            end
          elsif char == "#"
            masked << (" " * (line.length - index))
            break
          elsif char == '"' || char == "'"
            quote = char
            masked << char
          else
            masked << char
          end
          index += 1
        end
        masked
      end

      # The scan's own entry, plus what the applier needs to accept it: `automatic` is what the applier
      # checks, and this edit *is* a rewrite — the walker's rather than the service's — so `origin` is
      # what tells the two apart in the record and the patch.
      def self.edit(entry, after)
        {
          "path" => entry["path"], "line" => entry["line"], "text" => entry["text"],
          "after" => after, "automatic" => true, "origin" => "rule",
          "subject" => entry["subject"], "kind" => entry["kind"],
          "replacement" => entry["replacement"], "note" => entry["note"],
          "source" => entry["source"]
        }
      end
      private_class_method :edit
    end
  end
end
