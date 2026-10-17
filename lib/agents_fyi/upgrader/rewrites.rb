# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **The changes this walker will make that the service will not.**
    #
    # `/rails/scan` locates a call site for a documented change and deliberately stops there: its
    # contract is a statement about the *ladder* — "this changed, here is where your code touches
    # it" — and a service that rewrote somebody's source would be answering a question nobody asked
    # it. A rule here is this tool's own knowledge of how to make one of those edits, the same shelf
    # as `Preflight::DECLARATION` and the applier's mechanics, applied to the call site the scan
    # *located*, through the applier's line-checked write, and judged by the application's own suite
    # on the rung that uses it.
    #
    # Four things keep a rule honest:
    #
    # * **It names the change it belongs to** — the `subject` the plan and the scan both use — so a
    #   rule whose change has left the ladder is *inert* and said to be, rather than quietly editing
    #   code for a change nobody documents any more.
    # * **Its provenance is the change's own** (`source`, the guide's chapter), carried into the
    #   applied edit, the record and the patch. A rewrite a reader cannot check is a rewrite nobody
    #   should trust.
    # * **It is conservative about values whose end it cannot see.** `confirm: t(:x, count: 1)` has
    #   an argument list inside it, and a rule that guessed where the value stops would cut the line
    #   in half: the option's own pattern simply does not match, so the line stays a decision —
    #   a *located* one, which is the honest answer.
    # * **A change the corpus's own note forbids rewriting is not here.** `MultiJson`'s note says
    #   "do not swap it mechanically for JSON.dump/JSON.load — those serialise arbitrary Ruby
    #   objects and are not the same thing", and a note like that is a refusal, not a suggestion.
    #
    # **What is deliberately absent, and why** — measured on the ladder's 95 changes, not guessed
    # (77 of them are carried rather than rewritten; see `docs/upgrades.md`):
    #
    # * `render :text` — the ladder's replacement (`render plain:`/`render html:`/`render body:`) is
    #   the 5.1 spelling, and a rung that stops at 4.1 would not compile it. The rule waits until
    #   the target spelling is checked against the release the rung moves to.
    # * mutator methods on a Relation — the scan's pattern matches `Array#map!` as well, and
    #   rewriting an array is not this change. Locate-only.
    # * `default_scope`, `store_accessor`, `set_callback`, `MultiJson`, `find_all_by_*`,
    #   `attr_accessible` — no source form exists, or the form depends on the application.
    # * `require_dependency` — "every use of it can be deleted" is the note's own licence, but a
    #   *removal* is a different edit shape; it is the next rule rather than this one.
    module Rewrites
      # One rule: the change it makes, what it matches, and what it writes.
      #
      # `replace` is a `String#sub` replacement, so it may use named backreferences
      # (`\k<value>`) — which is how the option rule moves a value rather than guessing at it.
      Rule = Struct.new(:subject, :pattern, :replace, keyword_init: true) do
        # The line with this rule applied, or nil when it does not match or changes nothing.
        #
        # The match runs against the *masked* line (strings and comments blanked) and the write
        # against the raw one, at the same offsets — which is the shape the service's own scanner
        # uses, and the reason the mask preserves every byte's position: a pattern that matched
        # inside a string would rewrite a log message.
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

      # **The rules, by the subject the ladder and the scan both use.** Each is here because its
      # own note sanctions the shape — the note is the authority, and one of them (`MultiJson`)
      # refuses in so many words, which is why it is not here.
      RULES = [
        # `link_to 'Delete', path, confirm: 'Sure?'` becomes `data: {confirm: 'Sure?'}`, and the
        # helpers built on link_to go the same way. The value is captured, never guessed: a string,
        # a symbol, an identifier or a dotted reader.
        #
        # **The lookahead is the safety, and it was measured rather than imagined.** A first
        # version of this pattern matched the `t` of `confirm: t(:sure, count: 1)` and produced
        # `data: { confirm: t }(:sure, count: 1)` — a line cut in half, which the suite would have
        # reported as the application's breakage. The value has to end where an argument ends: a
        # comma, the call's closing parenthesis, or the line.
        Rule.new(
          subject: ":confirm option on link_to",
          pattern: /(?::\s*confirm\s*=>|\bconfirm:)\s*(?<value>"[^"]*"|'[^']*'|:[A-Za-z_]\w*|[A-Za-z_]\w*(?:\.\w+)*)(?=\s*[,)]|\s*\z)/,
          replace: 'data: { confirm: \k<value> }'
        ),
        # The top-level constant is soft-deprecated — no warning, and it still works — so this is
        # the step to move the references rather than the step that breaks them. A reference that
        # is already qualified is not touched: `(?<!::)` is the whole of that rule.
        Rule.new(
          subject: "HashWithIndifferentAccess",
          pattern: /(?<!::)\bHashWithIndifferentAccess\b/,
          replace: "ActiveSupport::HashWithIndifferentAccess"
        ),
        # `request.content_type` now returns the header as sent, charset included, where it used to
        # strip to the MIME type; `media_type` is the old value. The pattern names the receiver,
        # because `response.content_type` is a different method that did not change.
        Rule.new(
          subject: "request.content_type",
          pattern: /\brequest\.content_type\b/,
          replace: "request.media_type"
        )
      ].freeze

      class << self
        # The edits to hand the applier, the subjects a rule *applied*, and the subjects it left —
        # `left` is a subject whose rule exists but whose line the rule would not touch, and it is
        # carried so that a refusal is visible rather than silent.
        def apply(manual, rules: RULES)
          by_subject = rules.to_h { |rule| [rule.subject, rule] }
          edits = []
          applied = []
          left = []
          Array(manual).each do |entry|
            subject = entry["subject"].to_s
            rule = by_subject[subject]
            if rule.nil?
              left << subject
              next
            end

            text = entry["text"].to_s
            after = rule.after(text, mask(text))
            if after.nil?
              left << subject
              next
            end

            edits << edit(entry, after)
            applied << subject
          end
          Result.new(edits: edits, applied: applied, left: left)
        end

        # The rules that name no change in the rung's own plan: a rule that outlives its change is
        # dead weight, and a walker that kept applying it would be editing code for a change the
        # ladder no longer documents. Reported rather than removed, because removing one is a
        # decision about this file rather than about a rung.
        def inert(changes, rules: RULES)
          subjects = Array(changes).map { |change| change["subject"].to_s }
          rules.map(&:subject).reject { |subject| subjects.include?(subject) }
        end

        # A line with its strings' contents and its trailing comment blanked, every other byte
        # exactly where it was. **A deliberate, narrow mirror of the service's mask**
        # (`Upgrade::Scanner.mask`): a client may not depend on the service's package, and the two
        # have to agree about *offsets* rather than about style, which is why the quotes stay and
        # only their contents go.
        def mask(line)
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

        private

        # The scan's own entry, plus what the applier needs to accept it: `automatic` is what the
        # applier checks, and this edit *is* a rewrite — the walker's rather than the service's —
        # so `origin` is what tells the two apart in the record and the patch.
        def edit(entry, after)
          {
            "path" => entry["path"], "line" => entry["line"], "text" => entry["text"],
            "after" => after, "automatic" => true, "origin" => "rule",
            "subject" => entry["subject"], "kind" => entry["kind"],
            "replacement" => entry["replacement"], "note" => entry["note"],
            "source" => entry["source"]
          }
        end
      end
    end
  end
end
