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
    # `option_wrapped`, `line_removed`, `call_replaced`, `finder_moved`, `option_added`,
    # `argument_wrapped`, `argument_dropped`, `block_value`, `value_moved`, `line_replaced`,
    # `query_materialised`, `superclass_moved`), and the next lighthouse — a gem's own upgrade, a
    # framework nobody has walked yet — writes an instance of a family that already exists rather
    # than a new mechanism. A gem-driven edit whose shape is none of those is a
    # `Companions::Insert` (a line the file does not have yet), which is a question about the file
    # rather than about the line.
    #
    # **Nothing here is "never".** A change with no rule today is a *gap*, and `gap_for` says what
    # would close it, which is what the record carries into the residue: a queue with reasons rather
    # than a list a person re-derives every rung. That is the posture of the interpreter matrix's own
    # refusal one layer down (`Step#no_interpreter_stamp` names the floor rather than the machine, so
    # a grown matrix re-opens the verdict): a permanent refusal is the settled-work trap with the sign
    # flipped, and a walk that hands over the same list for ever has learned nothing.
    #
    # **And a subject a rule covers *partly* still has a gap** (`PARTIAL`): a rule for one spelling of
    # a change whose note names four would otherwise turn the residue's sentence about the other three
    # into silence.
    #
    # Five things keep a rule honest:
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
    # * **A rule's edit carries the change's note into the record.** A rule that applied a change
    #   withdraws its decision — correctly, it is no longer one — and the note is where the ladder's
    #   own caveat lives ("`where` returns a relation, not an array: add `.to_a` where an Array is
    #   expected"). Losing it with the decision would trade a decision a reviewer can read for a diff
    #   they cannot explain.
    module Rewrites
      # One rule: the family it is an instance of, the change it belongs to, what it matches, what it
      # writes, and the two things a family may need beyond a pattern.
      #
      # `replace` is a `String#sub` replacement, so it may use named backreferences — which is how a
      # rule moves a value rather than guessing at it — or a `Proc`, for a family whose edit depends
      # on what it matched (a dynamic finder's attributes, a block's body). **The `Proc` receives the
      # `MatchData`**, rather than reading `$~`: that variable is frame-local, so a lambda defined in a
      # family and called from `String#sub` sees *the family's* frame, which has never held a match —
      # and every capture comes back nil, which is a rule that silently refuses every line it was
      # written for.
      #
      # * `context` — **a rule that has to read the rest of the file.** `belongs_to` is the case that
      #   made this a field: whether an association is required is not a fact about the `belongs_to`
      #   line, because the model may already say `validates_presence_of :user`, in which case the new
      #   default agrees with the application and there is nothing to add. It receives the file's
      #   lines and the match, and answers whether the edit is the right one.
      # * `scaffold` — **a file the edit depends on.** A model cannot inherit from `ApplicationRecord`
      #   before that class exists, so the rule that renames the superclass carries the file that
      #   defines it.
      # * `already` — **the appendage's own guard.** A rule whose edit *adds* something (an option, a
      #   conversion on a call's result) has to refuse a line that already has it, or a second walk
      #   appends a second one. `already` is a pattern over the whole line that means "this edit is
      #   made", and it is a field rather than a trick inside each pattern because it is the same
      #   question every appending rule asks.
      Rule = Struct.new(:family, :subject, :pattern, :replace, :context, :scaffold, :already, :file,
        :all, :rung, keyword_init: true) do
        # The line with this rule applied, or nil when it does not match or changes nothing.
        #
        # The match runs against the *masked* line (strings and comments blanked) and the write
        # against the raw one, at the same offsets — the shape the service's own scanner uses, and
        # the reason the mask preserves every byte's position: a pattern that matched inside a string
        # would rewrite a log message.
        # **A rule whose own idempotence guard matches has nothing to do, and that is an answer about the
        # application rather than a refusal.** The guard exists so a second walk does not add an option
        # twice; the same question — is the new form already here — is what a residue wants to know, and the
        # two are the same pattern. `after` uses it to stop the edit; the caller uses it to stop the
        # *decision*.
        # **The guard reads what the pattern reads.** `already` is matched against the same text the pattern is —
        # masked, unless the rule named a file whose contents are not Ruby — and a guard that read the *raw*
        # line instead was measured dropping a change silently: `<%= link_to …, confirm: "Sure?" # data: {
        # confirm: x } %>` needs the edit, and the comment mentioning the wrapper made it "satisfied", so the
        # residue said nothing and the line stayed unmigrated. A comment is not evidence of anything; that is
        # the whole reason the mask exists.
        def satisfied?(line, masked) = !already.nil? && already.match?(file ? line : masked)

        def after(line, masked, lines: nil, tree: {})
          return nil if already && already.match?(file ? line : masked)

          found = pattern.match(masked)
          return nil if found.nil?
          # **A match that reaches into a comment is not a match.** `.` matches a blanked comment
          # byte, so a family that runs to the end of the line (`argument_wrapped`) would wrap the
          # comment too — `scope :active, where(a: 1) # the actives` came out as `-> { where(a: 1) #
          # the actives }`, where the closing brace is inside the comment and the file no longer
          # parses. Blanking the comment is not enough on its own; this is the other half.
          stop = Rewrites.comment_start(line)
          return nil if stop && found.end(0) > stop
          # The context gets the file's lines, the match, and the **raw** line: a question about what a
          # literal *is* (`ActiveSupport::Dependencies.constantize("User")` is not the same call with a
          # symbol) cannot be asked of the masked one, where the string's contents are blanked.
          # **The fourth argument is the whole tree**, because a rule's condition can be about another
          # file: whether a Gemfile line may go depends on whether the models still call what the gem
          # provided, and that is not a fact about the Gemfile.
          return nil if context && !context.call(Array(lines), found, line, tree)

          # **Every match on the line, for a family whose change is a *respelling*.** One string key
          # rewritten and the second left behind is a line that is half-fixed while the change is reported
          # as applied — `Rails.application.secrets["smtp"]["address"]` is the case that found it, and the
          # half-fixed half is a `nil` where the change says a `nil` or a raise. `all` is opt-in because it
          # is wrong for the families that *append*: `option_added` would add its option twice.
          spans = all ? matches(masked) : [found]
          return nil if stop && spans.any? { |span| span.end(0) > stop }

          text = line.dup
          spans.reverse_each do |span|
            region = line[span.begin(0)...span.end(0)]
            # The region's own match, because the write is against the *raw* line: a capture the masked
            # line matched inside a string is a different one here, and a family that re-matched for
            # itself could see a different extent than the one being replaced.
            own = pattern.match(region)
            written =
              if replace.respond_to?(:call)
                own ? replace.call(own) : region
              else
                region.sub(pattern, replace)
              end
            text[span.begin(0)...span.end(0)] = written
          end
          text == line ? nil : text
        end

        # Every match of this rule's pattern in the masked line, left to right. `Regexp#match` with a
        # position is what makes it one pass rather than a scan that re-finds its own first match.
        def matches(masked)
          found = []
          position = 0
          while (span = pattern.match(masked, position))
            found << span
            position = span.end(0) > span.begin(0) ? span.end(0) : span.begin(0) + 1
          end
          found
        end
      end

      # A file a rule's edit depends on. Written only when the rule applied and the file is not
      # already there, and written by `Step` rather than the applier — a *new* file has no line to
      # re-check, which is the applier's whole contract, and `Defaults` already writes the files its
      # own edits depend on for the same reason.
      Scaffold = Struct.new(:path, :content, keyword_init: true)

      # **A change whose fix is a gem rather than an edit to a call site.** `assigns` and
      # `assert_template` moved out of Rails into `rails-controller-testing`, and every one of the
      # application's nineteen call sites keeps working once it is declared — so the "edit" is a
      # Gemfile line and the located lines are *handled* rather than rewritten. That is a different
      # kind of knowledge from a `Rule`: there is no pattern to match and no line to rewrite, which is
      # why it is a `Bridge` and not a rule with an empty replacement. The declaration goes through
      # the preflight's own reader (one question, one pattern, so the two can never disagree about
      # which line a gem is on) and lands in the record as the same `Preflight::Repair` a digest move
      # does.
      #
      # `group` is the environment the gem belongs in, and it is the one field here with a cost: a gem
      # declared at the top level is installed in production, so `rails-controller-testing` belongs in
      # the block that declares `:test` — and a Gemfile with no such block is left as a decision
      # rather than guessed at.
      # **A change whose edit is a judgement but whose *evidence* is a fact about the tree.** A rule makes
      # the edit and a bridge declares a gem; a survey neither — it reads the application and says *where*
      # the change lands, which is the difference between a residue that says "needs a person" and one
      # that says "needs a person, and these three lines are why".
      #
      # `default_scope` is the case that made this: 4.1 merges a default scope with the conditions a
      # caller chains rather than letting them override it, so a caller that chains a condition on the
      # same column reads differently — and rewriting it would be guessing which of `unscope`, `rewhere`
      # and `unscoped` the application meant. Naming the callers is not guessing, and a survey is where
      # that difference lives. It makes no edit at all, which is also why a wrong finding here is noise
      # rather than breakage.
      #
      # `read` receives the tree (path → lines, the same shape `apply` takes) and the entries the scan
      # *located* for the subject, and returns `[path, line, text]` findings.
      Survey = Struct.new(:subject, :read, :sentence, keyword_init: true)

      # What a survey came back with: the sentence saying what it looked for, and the lines it found. An
      # empty `findings` is an *observation* — this application has no such line — and the sentence is
      # what keeps it from reading as a verdict about the change.
      Found = Struct.new(:sentence, :findings, keyword_init: true)

      # **A file that says a bridge applies.** A bridge's usual evidence is a call site the scan located;
      # `sprockets-rails`'s is not, because no pattern in the ladder locates it — the application's own
      # `require "sprockets/railtie"` is the fact, and it is a fact about the tree.
      #
      # The pattern is matched against the file's own bytes rather than a masked line, and that is the
      # opposite of every rule here for a reason: what is being looked for is usually *inside a string*
      # (`require "bootsnap/setup"`, `require "sprockets/railtie"`), which is exactly what the mask
      # blanks. A comment that mentions the name is therefore evidence too, and the cost of that false
      # positive is a gem declared for an application that does not load it.
      Evidence = Struct.new(:path, :pattern, :why, keyword_init: true)

      # `floor` and `requirement` are the two ways a bridge carries a version, and **they differ in what
      # presence means**. A *floor* is a condition on a gem the application may already have — absent,
      # nothing is owed, because Rails does not install Spring. A *requirement* is what the bridge's own
      # declaration must carry, because the rung is what needs the gem: `bootsnap` is written into
      # `config/boot.rb` by the same `app:update`, so the line is inserted here and has to name a release
      # the era can run. A bridge with neither is whole when the gem is declared.
      Bridge = Struct.new(:subject, :gems, :group, :why, :evidence, :floor, :requirement,
        keyword_init: true)

      # The changes whose note's own replacement is a gem, and where the gem is the **whole** of the
      # fix: the call sites keep working and nothing else is owed. That distinction is what keeps
      # `attr_accessible` out of this table — the note's own words are "the protected_attributes gem
      # keeps the old list working as a bridge, and Rails 5 removes that bridge", so declaring it would
      # silence a decision whose real work (moving each list into a controller) is the 5.0 rung's. Each
      # is here because the note names the gem *as* the fix — `sanitize / strip_tags` is not, because its note offers
      # `rails-deprecated_sanitizer` only "if the difference matters", which is a decision about what
      # the application's HTML allows rather than a declaration a walker may make. That one stays a
      # gap, and so does `the protected_attributes gem`, which is a removal rather than an addition.
      BRIDGES = [
        # "Both gems are drop-in, so this is a Gemfile line rather than a code change — but an
        # application that used them loses the caching entirely without it."
        Bridge.new(subject: "caches_action / caches_page",
          gems: %w[actionpack-action_caching actionpack-page_caching], group: nil,
          why: "the caching left Action Pack and both gems are drop-in, and without them the application loses it entirely; the change names both, so both are declared — a line a reviewer can delete if this application used only one"),
        Bridge.new(subject: "ActiveResource", gems: %w[activeresource], group: nil,
          why: "ActiveResource left the framework; the gem is the same library"),
        Bridge.new(subject: "Observers and sweepers", gems: %w[rails-observers], group: nil,
          why: "observers and sweepers left the framework; the gem restores them"),
        Bridge.new(subject: "respond_with / class-level respond_to", gems: %w[responders], group: nil,
          why: "the class-level form and respond_with left the framework; instance-level respond_to is unaffected"),
        # "content_tag, or the record_tag_helper gem" — the gem is the behaviour-preserving half, and
        # the rewrite is a choice about the view.
        Bridge.new(subject: "content_tag_for / div_for", gems: %w[record_tag_helper], group: nil,
          why: "the helpers left the framework; the gem restores them, where rewriting the views would be a choice about how much of the view is being changed"),
        # **The one with a group.** A controller-testing helper declared at the top level is
        # installed in production.
        Bridge.new(subject: "assigns / assert_template", gems: %w[rails-controller-testing],
          group: :test,
          why: "the helpers left the framework for a test-only gem; every call site keeps working once it is declared in the test group"),
        Bridge.new(subject: "to_xml", gems: %w[activemodel-serializers-xml], group: nil,
          why: "the serialiser left the framework; the gem is the same one"),
        Bridge.new(subject: "Active Storage variants", gems: %w[image_processing], group: nil,
          why: "image_processing is what the macros are built on now; which processor it uses behind that is the application's configuration"),

        # **Two bridges whose evidence is the tree rather than a call site**, because the change has no
        # pattern for the scan to find. Each is conditional in a way that a wrong guess would make worse
        # than leaving it: `bootsnap` is *required* by a file `app:update` wrote, and `sprockets-rails`
        # is only wanted by an application that still asks for the pipeline.
        # **`:rung` is evidence too, and it is the only kind that fits here.** `app:update` writes the
        # `require` into `config/boot.rb` *after* the install, so the tree cannot say it yet — and the
        # gem has to be declared *before* the pin's install, or the suite that runs after `app:update`
        # boots into a `LoadError`. What is true at apply time is the rung: 5.2's `app:update` writes
        # that line, so an application walking this rung needs the gem. An application that already has
        # it, or that never walks this rung, is not touched.
        Bridge.new(subject: "bootsnap", gems: %w[bootsnap], group: nil, evidence: :rung,
          requirement: "= 1.4.5",
          why: "this rung's `app:update` writes `require \"bootsnap/setup\"` into config/boot.rb, and " \
               "the gem has to be declared before the install that follows or the application boots " \
               "into a LoadError. **The release is pinned, and by the interpreter rather than by the " \
               "rung**: bootsnap raised its own floor to Ruby 2.3 at 1.4.6 — measured with `Gem::Package` " \
               "over 1.0.0 (`>= 2.3.0`), 1.1.0–1.4.5 (all `>= 2.0.0`) and 1.4.6, 1.4.7, 1.4.9, 1.5.0 " \
               "(`>= 2.3.0`) — and a line with no requirement resolves to the newest, so the 5.2 rung's " \
               "pin failed on `bootsnap was resolved to 1.10.3, which depends on ruby (>= 2.3.0)` " \
               "against the 2.2 era's 2.2.9. 1.4.5 is the newest release every era here can run"),
        Bridge.new(subject: "sprockets-rails", gems: %w[sprockets-rails], group: nil,
          why: "the application still asks for the asset pipeline's railtie, and Rails 7 no longer " \
               "depends on the gem",
          evidence: Evidence.new(path: "config/application.rb", pattern: /sprockets\/railtie/,
            why: "config/application.rb requires sprockets/railtie, so this application is still " \
                 "using the asset pipeline")),

        # **A floor is a bridge whose work is a version rather than a presence.** The change's own words
        # are "Spring 3.0.0 or newer", and an older Spring raises `undefined method 'mechanism=' for
        # ActiveSupport::Dependencies` before the application boots — which reads as an application
        # error rather than as a stale development dependency. It is selected by the rung, because what
        # the change says is a fact about the release rather than about a line of the application's, and
        # a Gemfile that already asks for a version is left as a decision.
        Bridge.new(subject: "Spring", gems: %w[spring], evidence: :rung, floor: ">= 3.0.0",
          why: "an older Spring raises `undefined method 'mechanism='` before the application boots, " \
               "which reads as an application error; the change's own answer is Spring 3.0.0 or newer")
      ].freeze

      # **A concern the release stopped including, and the file it has to be included in.** The class
      # line is the located line, so the edit is that line and the one under it — which is why the write
      # is a two-line string: the applier replaces a line, and a line that gains a line under it is the
      # whole edit.
      #
      # **The rule is narrow on purpose.** 7.1's note conditions the include on a controller "that
      # streams", and whether a controller streams is not a fact about its class line — so the rule asks
      # the *file* instead, through `context`: a subclass whose own file calls the method the concern
      # provides is one that streams. A controller that streams through a helper defined elsewhere is not
      # matched and stays a decision, which is the refusal this family's PARTIAL states.
      #
      # **The idempotence check is the context's, not `already`'s**, and that is worth saying: `already`
      # is a guard on the *line*, and what says this file is done is on the line *under* the class.
      def self.concern_included(subject:, superclass:, concern:, marker:)
        Rule.new(family: :concern_included, subject: subject,
          pattern: /\A(?<indent>\s*)class\s+(?<name>[A-Z]\w*(?:::\w+)*)\s*<\s*#{Regexp.escape(superclass)}\b(?<rest>[^\n]*)\z/,
          replace: "\\k<indent>class \\k<name> < #{superclass}\\k<rest>\n\\k<indent>  include #{concern}",
          context: lambda do |lines, _found, _raw, _tree|
            lines.any? { |line| line.match?(/#{marker}/) } &&
              lines.none? { |line| line.match?(/\binclude\s+#{Regexp.escape(concern)}\b/) }
          end)
      end

      # **A key whose spelling the release changed, in either direction.** Two instances now: the 4.1
      # json/hstore change makes a *column* string-keyed, so `self.settings[:theme]` is
      # `self.settings["theme"]`; the 5.1 secrets change makes nested keys *symbols*, so `secrets["smtp"]` is
      # `secrets[:smtp]`. The family is the shape of the edit — the key's spelling and nothing else — and the
      # key is read out of the **raw** line, because what is inside a string is what the mask blanks.
      #
      # `receiver` is a pattern the key has to hang off, and it is what makes the json direction safe: a
      # column's accessor is *provably* the column when the receiver is `self` and the same file declares the
      # `store_accessor`, while a bare name could be a local. `context` is where that second half is asked.
      def self.key_respelled(subject:, to:, receiver: nil, context: nil, all: false, file: nil)
        key =
          if to == :symbol
            /(?<head>\[\s*)["'](?<name>[^"']*)["'](?<tail>\s*\])/
          else
            /(?<head>\[\s*):(?<name>\w+)(?<tail>\s*\])/
          end
        # The group is always *there*, empty when the rule has no receiver: `match[:receiver]` raises when a
        # pattern has no such group, and a rule that reads its own replacement is the wrong place to find out.
        prefix = receiver ? "(?<receiver>#{receiver})\\s*" : "(?<receiver>)"
        Rule.new(family: :key_respelled, subject: subject, context: context, all: all, file: file,
          pattern: Regexp.new("#{prefix}#{key.source}"),
          replace: lambda do |match|
            name = match[:name].to_s
            written =
              if to == :symbol
                name.match?(/\A[a-zA-Z_]\w*\z/) ? ":#{name}" : ":#{name.inspect}"
              else
                name.inspect
              end
            "#{match[:receiver]}#{match[:head]}#{written}#{match[:tail]}"
          end)
      end

      # **A survey whose whole evidence is the call sites.** A decision names *one* line, so a change with
      # five call sites has four the residue never shows — and for these changes the list *is* the work:
      # the sanitizer calls to review, the tests to rewrite, the models whose lists have to become strong
      # parameters. It is a family the way a rule is, so the next such change is one line rather than a
      # new lambda.
      def self.survey_calls(subject:, sentence:)
        Survey.new(subject: subject, sentence: sentence,
          read: lambda do |_tree, located|
            located.map { |entry| [entry["path"], entry["line"].to_i, entry["text"].to_s] }
          end)
      end

      # **A survey's fact still belongs in the residue when the change has no call site here.** A survey
      # whose sentence promises two things — the call sites, and an application-wide fact — reported only
      # the first when the application had none: measured at the 6.0 rung, `force_ssl in a controller`
      # read "none found" while its own sentence asked whether `config.force_ssl` is set anywhere, and the
      # setting *is* mentioned in `config/environments/production.rb` (commented). The mention stands in
      # for the call site, with the fact as its text; when the application mentions the setting nowhere
      # either, "none found" is the whole truth and this returns nothing.
      def self.survey_beside(located, mentions, beside)
        unless located.empty?
          return located.map do |entry|
            [entry["path"], entry["line"].to_i, "#{entry["text"].to_s.strip} (#{beside})"]
          end
        end

        mentions.map { |path, line, _text| [path, line, beside] }
      end

      # The lines that mention a setting, in the order a file has them.
      def self.setting_mentions(tree, pattern)
        tree.flat_map do |path, lines|
          lines.each_with_index.filter_map do |line, index|
            [path, index + 1, line.strip] if line.match?(pattern)
          end
        end
      end

      # **A survey whose evidence is a setting's own lines.** A change with no call site and no detect — a
      # default that flipped, a cookie serialiser, a cache format — has nothing for the scan to locate, so
      # the residue would be the note alone. What a person needs is whether *this* application touches the
      # setting at all, and that is a line in a config file.
      #
      # The match is on the setting's **last segment** as a whole word, because the same setting is
      # spelled differently everywhere it can live (`config.i18n.enforce_available_locales`,
      # `Rails.application.config.i18n.enforce_available_locales`) and the question is only whether the
      # application mentions it. A mention in a comment is therefore a finding too, which is the same
      # false positive `Evidence` accepts and for the same reason: a survey costs a reader a glance.
      def self.survey_setting(subject:, setting:, sentence:)
        name = setting.split(".").last
        Survey.new(subject: subject, sentence: sentence,
          read: lambda do |tree, _located|
            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next unless line.match?(/\b#{Regexp.escape(name)}\b/)

                [path, index + 1, line]
              end
            end
          end)
      end

      # **The surveys, by the subject the ladder and the scan both use.** Each is here because its
      # change's *fix* is a decision and its *evidence* is a fact: which call sites read differently,
      # which assignments the new behaviour changes, which alias the deprecation warned about.
      SURVEYS = [
        # "A default scope is now merged with the conditions a caller chains, rather than being
        # overridden by them. A scope that relied on overriding it silently reads differently."
        #
        # The evidence is a caller that names the model *or* lives in the model's own file, and chains a
        # condition on a column the scope constrains — the two halves have to meet, or every `where` in
        # the application would be a finding. The class name comes from the located declaration's own
        # file, because a scope is declared inside the class it scopes.
        Survey.new(subject: "default_scope",
          sentence: "the callers that chain a condition on the same column, and so read differently",
          read: lambda do |tree, located|
            columns = located.flat_map { |entry| Rewrites.scope_columns(entry["text"].to_s) }.uniq
            file = located.first&.[]("path")
            model = tree[file].to_a.filter_map { |line| line[/\Aclass\s+(\w+)/, 1] }.first
            next [] if columns.empty? || model.nil?

            declared = located.map { |entry| [entry["path"], entry["line"].to_i] }
            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next if declared.include?([path, index + 1])
                next unless path == file || line.match?(/\b#{Regexp.escape(model)}\b/)
                next if Rewrites.scope_columns(line).none? { |column| columns.include?(column) }

                [path, index + 1, line]
              end
            end
          end),

        # "Assigning to the collection replaces the attachments instead of appending to them, which
        # matches how a has_many association behaves. `attach` is what adds without replacing."
        Survey.new(subject: "has_many_attached assignment",
          sentence: "the lines that assign to the collection, where `attach` is what adds without " \
                    "replacing",
          read: lambda do |tree, located|
            names = located.flat_map { |entry| entry["text"].to_s.scan(/has_many_attached\s+:(\w+)/).flatten }.uniq
            next [] if names.empty?

            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next if names.none? { |name| line.match?(/\.#{Regexp.escape(name)}\s*=(?!=)/) }

                [path, index + 1, line]
              end
            end
          end),

        # "These columns now map to a string-keyed Hash rather than a HashWithIndifferentAccess, so
        # symbol access stops working — including store_accessors built on them."
        #
        # The accessors `store_accessor` defines are *methods* and are unaffected; what stops working is
        # indexing into the column with a symbol, so the evidence is a line that does exactly that.
        Survey.new(subject: "json and hstore columns",
          sentence: "the lines that index into the column with a symbol, which is what stops working — " \
                    "the ones the rule cannot prove are the column",
          read: lambda do |tree, located|
            columns = located.flat_map { |entry| entry["text"].to_s.scan(/store_accessor\s+:(\w+)/).flatten }.uniq
            next [] if columns.empty?

            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next if columns.none? { |column| line.match?(/\b#{Regexp.escape(column)}\s*\[\s*:\w+/) }

                [path, index + 1, line]
              end
            end
          end),

        # "It bypasses a custom method defined on the original attribute and reads the column directly,
        # where it used to call through. This was a deprecation warning in 7.1, so the warning is the
        # list of places to check."
        #
        # The list *is* the evidence, and it is one question per alias: does the file define the method
        # the alias names?
        Survey.new(subject: "alias_attribute",
          sentence: "the aliases whose original attribute this file defines itself — the list the " \
                    "deprecation warning pointed at",
          read: lambda do |tree, located|
            located.filter_map do |entry|
              original = entry["text"].to_s[/alias_attribute\s+:\w+\s*,\s*:(\w+)/, 1]
              lines = tree[entry["path"]].to_a
              next nil if original.nil?

              index = lines.index { |line| line.match?(/\bdef\s+#{Regexp.escape(original)}\b/) }
              next nil if index.nil?

              [entry["path"], index + 1, lines[index]]
            end
          end),

        # "Leave secret_token in place *and* add secret_key_base: a Rails 3 cookie is upgraded
        # transparently on the way in, and a cookie written by Rails 4 cannot be read by Rails 3 — so the
        # two together are what makes a rollback possible."
        #
        # **The note's answer is the opposite of a rename**, which is exactly why a rule here would be
        # wrong: the *value* is one only the application has, and rewriting the line would break the
        # rollback the note is about. What a survey can add is the fact the note turns on — whether
        # secret_key_base is set *beside* it yet — and that is a sentence a person can act on.
        Survey.new(subject: "config.secret_token",
          sentence: "the lines that set secret_token, and whether secret_key_base is set beside them",
          read: lambda do |tree, located|
            key_base = tree.any? do |_path, lines|
              lines.any? { |line| line.match?(/\bsecret_key_base\b/) }
            end
            beside = key_base ? "secret_key_base is set elsewhere" : "secret_key_base is not set anywhere"
            located.map do |entry|
              [entry["path"], entry["line"].to_i, "#{entry["text"].to_s.strip} (#{beside})"]
            end
          end),

        # **The five whose evidence is simply the call sites.** Each note names a change whose work is a
        # review or a rewrite rather than an edit this tool can make, and each decision would otherwise
        # show one of its call sites — the first — and hide the rest.
        survey_calls(subject: "attr_accessible",
          sentence: "the models whose list has to become a controller's strong parameters"),
        survey_calls(subject: "after_commit / after_rollback",
          sentence: "the callbacks whose errors now propagate instead of being swallowed"),
        survey_calls(subject: "sanitize / strip_tags",
          sentence: "the calls whose output changed, which is what has to be reviewed"),
        survey_calls(subject: "assert_tag",
          sentence: "the assertions the rule could not express as a selector, and so left as a " \
                    "decision"),
        survey_calls(subject: "format.any",
          sentence: "the blocks whose Content-Type now comes from the block rather than the request"),

        # "The controller method is deprecated and gone in 6.1. Application-wide enforcement is
        # config.force_ssl, with config.ssl_options for endpoints that have to be exempt."
        #
        # **Both facts a person needs are in the tree**: which controllers ask for it, and whether the
        # application-wide setting is already on. Moving one to the other is a decision, because a
        # controller's `force_ssl` covers *its* actions and `config.force_ssl` covers everything.
        Survey.new(subject: "force_ssl in a controller",
          sentence: "the controllers that ask for it, and whether config.force_ssl is set anywhere",
          read: lambda do |tree, located|
            mentions = Rewrites.setting_mentions(tree, /config\.force_ssl\b/)
            set = mentions.reject { |_path, _line, text| text.start_with?("#") }
            beside =
              if set.empty?
                "config.force_ssl is not set anywhere"
              else
                "config.force_ssl is set in #{set.map(&:first).uniq.sort.join(", ")}"
              end
            Rewrites.survey_beside(located, mentions, beside)
          end),

        # "All tests respect the configured adapter now. A test environment that sets something other
        # than :test and relies on the test adapter being used anyway starts behaving differently."
        #
        # So the fact is the *value*: `:test` is the one setting this change does not touch.
        Survey.new(subject: "config.active_job.queue_adapter in tests",
          sentence: "the lines that set the adapter, and which of them set something other than :test",
          read: lambda do |tree, located|
            located.map do |entry|
              text = entry["text"].to_s
              value = text[/queue_adapter\s*=\s*([^#\s]+)/, 1].to_s
              note =
                if value == ":test"
                  "the test adapter, which this change does not touch"
                else
                  "#{value} — every test now runs on it"
                end
              [entry["path"], entry["line"].to_i, "#{text.strip} (#{note})"]
            end
          end),

        # "Nested keys in secrets.yml are loaded as symbols now, so `secrets[:smtp][\"address\"]` raises or
        # returns nil where it used to work."
        #
        # The *indexing* is what breaks and the string key is what marks it, so the survey reads the tree
        # rather than the located line: the change's own detect finds the assignment, and these are lines
        # the scan did not stop on.
        Survey.new(subject: "Rails.application.secrets",
          sentence: "the lines that index into secrets with a string key, which is what stops working",
          read: lambda do |tree, _located|
            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next unless line.match?(/\bsecrets\b.*\[\s*["']/)

                [path, index + 1, line]
              end
            end
          end),

        # **The settings this application touches, for the changes that have no call site at all.** Each
        # note turns on a fact about the deployment rather than about a line of code — whether the
        # application has already chosen a test order, a cookie serialiser, a cache format — and the
        # residue would otherwise be the note alone.
        survey_calls(subject: "render :text",
          sentence: "the call sites — the 4.1 rung only deprecates `:text`, and the rule that rewrites " \
                    "them is the 5.1 rung's"),
        survey_setting(subject: "config.i18n.enforce_available_locales",
          setting: "config.i18n.enforce_available_locales",
          sentence: "the lines that set it, if the application has opted out of the new default"),
        survey_setting(subject: "cookies_serializer",
          setting: "cookies_serializer",
          sentence: "the lines that set it — `:hybrid` is the note's migration path, and it is a choice"),
        survey_setting(subject: "config.active_support.test_order",
          setting: "test_order",
          sentence: "the lines that choose an order — `:sorted` keeps today's, `:random` finds the " \
                    "tests that depend on each other now"),
        survey_setting(subject: "test order",
          setting: "test_order",
          sentence: "the lines that choose an order, which 5.0 makes random by default"),
        survey_setting(subject: "signed and encrypted cookies",
          setting: "use_authenticated_cookie_encryption",
          sentence: "the lines that set the rollback flag, which exists for the first deploy of a " \
                    "rolling upgrade"),
        survey_setting(subject: "cookies and their purpose",
          setting: "use_cookies_with_metadata",
          sentence: "the lines that set the rollback flag, which exists for the first deploy of a " \
                    "rolling upgrade"),
        survey_setting(subject: "the key generator's digest class",
          setting: "key_generator_hash_digest_class",
          sentence: "the lines that set it, and the rotator an encrypted-cookie deployment needs " \
                    "beside it"),
        survey_setting(subject: "ActiveSupport::Cache format",
          setting: "cache_format_version",
          sentence: "the lines that set it — a rolling deploy has to leave the format alone for the " \
                    "first pass and switch it after"),
        survey_setting(subject: "ActionDispatch::SSL",
          setting: "ssl_options",
          sentence: "the lines that set the options, which is what an endpoint that has to be exempt " \
                    "from the redirect uses"),
        survey_setting(subject: "autoloading during initialization",
          setting: "to_prepare",
          sentence: "the `to_prepare` blocks already in the application, which is where a reference " \
                    "made during boot belongs"),
        survey_setting(subject: "config.i18n.raise_on_missing_translations",
          setting: "raise_on_missing_translations",
          sentence: "the lines that set it, if the application raises rather than falling back"),

        # "A string assigned to a JSON/JSONB column is now returned as that string rather than parsed
        # into a Hash, and the same applies to :default in schema.rb. Pass a Hash."
        #
        # The columns *are* the evidence, and they are in `db/schema.rb` — a `.rb` file the scan reads,
        # but one no detect pattern looks at, because the change has none.
        Survey.new(subject: "JSON and JSONB columns",
          sentence: "the JSON and JSONB columns, which are what has to be assigned a Hash",
          read: lambda do |tree, _located|
            tree.flat_map do |path, lines|
              next [] unless path.end_with?("schema.rb")

              lines.each_with_index.filter_map do |line, index|
                next unless line.match?(/\bt\.(json|jsonb)\b/)

                [path, index + 1, line]
              end
            end
          end),

        # "Assigning nil to a serialized attribute now stores NULL rather than passing nil through the
        # coder — `\"null\"` under the JSON coder. A query that compared against the encoded form changes."
        #
        # The declarations name the attributes and the *assignment* is what changed, so the survey joins
        # the two: the attribute names come from the located declaration, and the findings are the lines
        # that assign nil to one of them. No such line is an answer too — it is the one a person wants.
        Survey.new(subject: "serialize",
          sentence: "the lines that assign nil to a serialized attribute, which is what now stores NULL",
          read: lambda do |tree, located|
            names = located.flat_map { |entry| entry["text"].to_s.scan(/serialize\s+:(\w+)/).flatten }.uniq
            next [] if names.empty?

            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next unless names.any? { |name| line.match?(/\b#{Regexp.escape(name)}\s*=\s*nil\b/) }

                [path, index + 1, line]
              end
            end
          end),

        # "Errors are instances of ActiveModel::Error with a changed API, so code that manipulates the
        # errors collection needs a read of its own."
        #
        # There is no detect for this change at all, so the survey reads the tree for the calls the note
        # names — and `errors.add` is deliberately not one of them: adding an error is the same call it
        # always was, while indexing and iterating the collection now yield different objects.
        Survey.new(subject: "ActiveModel::Error",
          sentence: "the lines that read the errors collection, which is what the new class changes",
          read: lambda do |tree, _located|
            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                next unless line.match?(/\berrors\s*(?:\[|\.(?:each|to_hash|messages|details|map|select|first)\b)/)

                [path, index + 1, line]
              end
            end
          end),

        # "New applications default to libvips, and the option names are vips' rather than ImageMagick's:
        # resize becomes resize_to_limit, crop takes an array, monochrome becomes colourspace. Variant URLs
        # encode the transformations, so a cached URL has to be invalidated when the options change."
        #
        # **Which processor the deployment runs is a decision**, so the survey does not rewrite the option
        # names: it names the call sites whose options differ and says whether a processor has been chosen
        # — the same shape as `force_ssl`.
        Survey.new(subject: "Active Storage variant processor",
          sentence: "the `variant` call sites, and whether config.active_storage.variant_processor is set",
          read: lambda do |tree, located|
            mentions = Rewrites.setting_mentions(tree, /\bvariant_processor\b/)
            chosen = mentions.reject { |_path, _line, text| text.start_with?("#") }
            beside =
              if chosen.empty?
                "variant_processor is not set anywhere, so the deployment takes the new default"
              else
                "variant_processor is set in #{chosen.map(&:first).uniq.sort.join(", ")}"
              end
            Rewrites.survey_beside(located, mentions, beside)
          end),

        # **A change whose rule has no call site here is not the same sentence as a change nobody has
        # automated.** `require_dependency` and `request.content_type` both have rules, so a call site
        # would be rewritten — and the 6.0 rung's residue listed both with only the ladder's own note
        # beside them, which reads as work waiting rather than as an observation about this application.
        # A survey with nothing to report is what says which it is; the sentence is what keeps the empty
        # answer from reading as a verdict about the change.
        Survey.new(subject: "require_dependency", sentence: "the lines that still call it",
          read: lambda do |tree, _located|
            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                [path, index + 1, line.strip] if line.match?(/(?:\A|\s)require_dependency\b/)
              end
            end
          end),
        Survey.new(subject: "request.content_type", sentence: "the lines that read it",
          read: lambda do |tree, _located|
            tree.flat_map do |path, lines|
              lines.each_with_index.filter_map do |line, index|
                [path, index + 1, line.strip] if line.match?(/\brequest\.content_type\b/)
              end
            end
          end)
      ].freeze

      Result = Struct.new(:edits, :applied, :left, :scaffolds, :satisfied, keyword_init: true) do
        def to_s
          return "no rule applies" if edits.empty?

          "#{edits.size} edit(s) by this tool's own rules (#{applied.uniq.join(", ")})"
        end
      end

      # **What would close each gap**, by the change's subject. A gap is not a verdict: it is the
      # sentence the residue carries so the next lighthouse — or the next agent — starts from what is
      # missing rather than from scratch. A subject with no entry here still gets a gap (the generic
      # one below), because "nobody has looked at this shape yet" is itself information.
      GENERIC_GAP = "no rule yet: either this shape is not one of the families here (name_moved, " \
                    "option_wrapped, line_removed, call_replaced, finder_moved, option_added, " \
                    "argument_wrapped, argument_dropped, block_value, value_moved, line_replaced, " \
                    "query_materialised, superclass_moved), or the change has no call site to match " \
                    "at all — a config " \
                    "default, a file a generated application has and this one does not. It is carried " \
                    "as a decision either way, and the change's own note is what says which"

      GAPS = {
        # **A survey does not retire the gap, and these three sentences were written before one existed.**
        # A survey reports the call sites; it does not make the edit, so the change is still not
        # automated — but a sentence that says "a rule would need the callers" while a survey is already
        # naming them is a sentence that disagrees with the code beside it.
        #
        # **And a gap sentence is what the residue owes when the survey's lines need no edit at all.**
        # Measured at the 6.1 rung: `ActiveModel::Error`'s survey names two lines in
        # `spec/model/bid_spec.rb` and the generic fallback says "no rule yet: either this shape is not
        # one of the families here, or the change has no call site to match at all" — which reads as an
        # unanswered question when the rung's own suite has already answered it. The sentence below says
        # which of the two it is.
        "ActiveModel::Error" => "the two lines the survey names *read* the collection — " \
                                "`bid.errors[:item].should include …` — and this change is to the object " \
                                "the collection holds: `errors.where`, `errors.details`, and the " \
                                "type/options a caller passes to `add`. A read of the messages is " \
                                "unaffected, and the rung's own suite is what settles that rather than " \
                                "this table: 6.1's post-move suite is green with both lines untouched, " \
                                "so the edit a rule would make is no edit at all",
        "default_scope" => "the survey names the callers that chain a condition on the same column, and " \
                           "the edit is not a rule because the candidate patch (`unscope`, `rewhere`, " \
                           "`unscoped`) is a choice between three intentions",
        "json and hstore columns" => "the rule rewrites `self.<column>[:key]` in the file that declares " \
                                     "the `store_accessor` — the receiver and the declaration together are " \
                                     "what prove the name is the column. A bare `settings[:key]` could be a " \
                                     "local holding any hash, so it is left, and the survey names those lines",
        "alias_attribute" => "the survey names the aliases whose original attribute the file defines " \
                             "itself; whether to define the alias method by hand or to use " \
                             "`alias_method` is a choice about the method's body, which the line does " \
                             "not show",
        "after_commit / after_rollback" => "the change is where an error raised in the callback " \
                                           "*goes*, which the line does not show; `on:` and the " \
                                           "transactional-callbacks default are decisions about the " \
                                           "application's error handling",
        "sanitize / strip_tags" => "the note offers `rails-deprecated_sanitizer` *if the difference " \
                                   "matters*, which is a decision about what the application's HTML " \
                                   "is allowed to contain — declaring it unconditionally would keep " \
                                   "the weaker sanitiser this change exists to replace, so it is a " \
                                   "gap rather than a bridge",
        "serialize" => "the change is what a `nil` assignment *stores* — `NULL` rather than the " \
                       "encoded form — so a rule would need the attribute's queries, not its " \
                       "declaration",
        "config.action_view.raise_on_missing_translations" => "the setting moved rather than " \
                                                              "disappearing — " \
                                                              "`config.i18n.raise_on_missing_translations` " \
                                                              "is where it lives — but the note names " \
                                                              "a *custom I18n exception handler* as the " \
                                                              "alternative, which is a decision about " \
                                                              "how the application reports a missing " \
                                                              "translation",
        # **The gaps that name a mechanism rather than an edit.** The changes with no call site that are
        # not "no rule yet": they need something this tool does not have, and saying which is the point
        # of a gap. (`Spring` used to be here, and what it needed turned out to be a *floor* — a bridge
        # whose work is a version rather than a presence.)
        "@rails npm packages" => "the fix is in `package.json`, which this tool does not read: the " \
                                 "three packages moved under the `@rails` scope and the build fails " \
                                 "loudly without it",
        "tmp/development_secret.txt" => "a file rename, and the file is git-ignored in most " \
                                        "applications — so this is a note rather than a diff. It " \
                                        "matters because a missing one is *generated* rather than " \
                                        "reported, which silently invalidates the sessions and the " \
                                        "signed URLs of every developer",
        "schema.rb column order" => "informational: the dump's order changes and a `schema.rb` diff " \
                                    "is large and meaningless for one rung. `structure.sql` preserves " \
                                    "the exact order if the file has to stay quiet",
        "config.i18n.raise_on_missing_translations" => "the default flips, and a line that sets it " \
                                                       "explicitly is unaffected — while a line that " \
                                                       "does not has nothing for a pattern to point at",
        # **The order is the application's to choose, and the survey is what says where the choice
        # would go.** 4.2 warns until one is picked and 5.0 makes `:random` the default, and the two
        # subjects are the ladder's own spelling at each rung. `:sorted` keeps today's order and
        # `:random` finds the tests that depend on each other — a fact about the suite rather than
        # about the line, which is exactly what a rule cannot read.
        "config.active_support.test_order" => "the survey names the lines that choose an order; " \
                                              "which order the suite wants is a fact about the " \
                                              "tests rather than about the line, so `:sorted` and " \
                                              "`:random` are the application's to choose",
        "test order" => "the survey names the lines that pin the order; 5.0's default is `:random`, " \
                        "and a suite that depends on `:sorted` has to say so — which is a fact about " \
                        "the tests rather than about the line",
        "attr_accessible" => "the list belongs in a controller, and the note's own bridge " \
                             "(`protected_attributes`) keeps it working until 5.0 — which is why this " \
                             "is a gap with the gem named rather than a declaration: a bridge would " \
                             "silence the work rather than do it",
        "force_ssl in a controller" => "the controller method's replacement is application-wide " \
                                       "(`config.force_ssl`), and a controller's own `force_ssl` " \
                                       "scopes to that controller: moving it is a decision about " \
                                       "scope, and `config.ssl_options` is where an exemption goes",
        "format.any" => "the note's fix is to *name the formats the action accepts*, which is a fact " \
                        "about the action rather than about the line",
        "has_many_attached assignment" => "the change is what *assignment* does, and the declaration " \
                                          "the scan locates is not the assignment: `attach` is what " \
                                          "adds without replacing, and which call sites meant to " \
                                          "append is the application's",
        "render :text" => "4.1 deprecates `:text` without removing it, so the choice between " \
                          "`plain:`, `html:` and `body:` is still open here — and it is the 5.1 " \
                          "rung's rule that makes it, because there `:text` is gone and the note " \
                          "answers `render plain:`. A rule at *this* rung would be choosing a " \
                          "content type for a response that still has one",
        "ActiveRecord::Base as a model's superclass" => "the rule covers a model whose superclass is " \
                                                         "written on one line; a model that inherits " \
                                                         "from another model, or whose class line " \
                                                         "spans two, is left — the edit is a rename " \
                                                         "and this is the one place a rename is not " \
                                                         "enough",
        "config.secret_token" => "the note says to *leave it in place and add* `secret_key_base`, " \
                                 "because a Rails 3 cookie is upgraded on the way in and a Rails 4 " \
                                 "cookie cannot be read by Rails 3 — so the two together are what " \
                                 "makes a rollback possible. A rename would be the opposite of the " \
                                 "note, and the new value must not come from the repository",
        "config_for" => "the note's replacement is a call on the *result* " \
                        "(`.with_indifferent_access`), which keeps every call site as it is — so " \
                        "what is missing is a rule that edits the assignment rather than the use",
        "button_to" => "the note's fix is `method: :post` or an explicit path helper, and which one " \
                       "is right depends on whether the button is built from a record — a fact " \
                       "about the view rather than about the line",
        "Active Storage variant processor" => "the note's replacement is an application-wide " \
                                              "setting (`config.active_storage.variant_processor`), " \
                                              "so a rule would be choosing the processor for the " \
                                              "deployment rather than for the line",
        "signed and encrypted cookies" => "the rollback flag is a fact about a *deploy* rather than " \
                                          "about the tree: a walk moves one release at a time, while " \
                                          "`use_authenticated_cookie_encryption = false` exists for the " \
                                          "window where two releases answer the same session cookie — " \
                                          "so it is turned on once every process is on 5.2, and which " \
                                          "of the two a line should say is not readable from the line. " \
                                          "The survey beside this sentence is the other half: it is " \
                                          "what reports that this application sets no rollback flag at " \
                                          "all",
        "cookies and their purpose" => "the same shape at the next rung — 6.0 embeds the purpose in " \
                                       "the cookie value, so a 6.0 cookie is unreadable by 5.2 — and " \
                                       "the three `cookies.` call sites the scan locates are not where " \
                                       "the fix goes: the rollback flag is a deployment decision, and " \
                                       "the survey beside this sentence reports both the flag and the " \
                                       "lines that write a cookie"
      }.freeze

      # **A gap for a subject a rule covers only partly.** `gap_for` answers "does a rule know this
      # change" for the whole subject, and a subject is not always all-or-nothing: `params.slice` is
      # an instance while `params.each` is not, and a residue that said "a rule covers this" while
      # leaving four spellings untouched would be the empty-answer trap with the sign flipped.
      PARTIAL = {
        # One sentence for all eight, because the refusal is the same one: the gem's *home* is the
        # thing this tool will not guess.
        "assigns / assert_template" => "the bridge declares the gem in the block that names its " \
                                       "group, or at the top level when the gem belongs everywhere. " \
                                       "A Gemfile with no such block is left, because a test-only gem " \
                                       "appended to the end of the file is installed in production",
        "ActionCable JavaScript adapters" => "the setting lives in the application's JavaScript " \
                                              "(`ActionCable.WebSocket = ...`), and this tool " \
                                              "scans `.rb`, `.rake`, `.erb`, `.yml` and `.ru` — so " \
                                              "the ladder locates the line only when it appears in " \
                                              "an ERB template, and the edit is in the JavaScript",
        "Spring" => "the bridge rewrites a declaration that asks for no version — `gem \"spring\"` " \
                    "becomes `gem \"spring\", \">= 3.0.0\"`. A Gemfile that already names a version is " \
                    "left as a decision, because replacing somebody's requirement is their call",
        "halted_callback_hook" => "the rule adds the second parameter to `def " \
                                  "halted_callback_hook(x)`. A definition written without parentheses, " \
                                  "or with a splat, does not match and stays a decision",
        "ActiveSupport::Callbacks.set_callback" => "the rule drops the ampersand from a captured block " \
                                                   "on the line the scan located. A lambda written on " \
                                                   "the line *after* `set_callback` is not matched, so " \
                                                   "that call site stays a decision rather than becoming " \
                                                   "a guess",
        "config.secrets.yml" => "the rule empties the initializer's `secret_key_base` line when " \
                                 "`config/secrets.yml` names the *same* environment variable — the " \
                                 "guard is the whole rule, because deleting a key the application has " \
                                 "not carried anywhere else invalidates every session in flight and a " \
                                 "suite does not notice. An initializer holding a literal, or one whose " \
                                 "variable `secrets.yml` does not name, stays a decision",
        "the protected_attributes gem" => "the rule removes the Gemfile line once no model calls " \
                                          "`attr_accessible`/`attr_protected` — the ladder's own " \
                                          "caveat is the condition, and the tree is what answers it. A " \
                                          "model that still calls one leaves the line as a decision, " \
                                          "and the models' conversion is the 4.0 entry's work",
        "assert_tag" => "the rule rewrites the *documented* forms — a tag, an `id` or `class` " \
                        "attribute and a `content`, all quoted literals — into the selector the guide " \
                        "maps them to. A `descendant:`, a `count:`, an attribute that is neither `id` " \
                        "nor `class`, a value held in a variable and a second statement on the line are " \
                        "all refused, because a wrong assertion does not fail: it passes",
        "ActiveStorage::BaseController" => "the rule adds the include to a subclass whose own file " \
                                           "calls `send_blob_stream` — the note's own condition is a " \
                                           "controller *that streams*, and that is a fact about the " \
                                           "file. A controller that streams through a helper defined " \
                                           "elsewhere stays a decision",
        "Rails.application.secrets" => "the rule respells a *literal* key — `secrets[\"smtp\"]` is " \
                                       "`secrets[:smtp]` — and it reads the string because a callable " \
                                       "`replace` is handed the raw region. A key held in a variable is " \
                                       "not matched, and the survey beside the rule names those lines",
        "to_xml" => "the bridge declares the gem; a Gemfile whose group blocks this tool cannot read " \
                    "(a string where the group name is, a block nested in one) is left",
        "content_tag_for / div_for" => "the bridge declares the gem — the behaviour-preserving half " \
                                       "of the note, which also offers rewriting the views; that " \
                                       "rewrite is a decision about how much of the view is being " \
                                       "changed",
        "caches_action / caches_page" => "the bridge declares both gems the change names, and a " \
                                         "Gemfile it cannot read is left. An application that used " \
                                         "only one of the two caches gets a line a reviewer can " \
                                         "delete",
        "ActiveResource" => "the bridge declares the gem, and a Gemfile this tool cannot read is " \
                            "left",
        "Observers and sweepers" => "the bridge declares the gem, and a Gemfile this tool cannot " \
                                    "read is left",
        "respond_with / class-level respond_to" => "the bridge declares the gem, and a Gemfile this " \
                                                   "tool cannot read is left",
        "Active Storage variants" => "the bridge declares `image_processing`; which processor it " \
                                     "drives (`vips`, `mini_magick`) is the application's " \
                                     "configuration and stays a decision",
        "render :text / render :nothing" => "`render :text` is a rule and it writes `plain:` — the " \
                                              "note's own answer and the safe one, because `:text` " \
                                              "sent `text/html` and interpreted markup in the " \
                                              "content. `render html:` is for a response that *is* " \
                                              "markup, which is a fact about the content. A " \
                                              "`:nothing` carrying a status is left too: the status " \
                                              "names the `head` call (`render :nothing => true, " \
                                              "status: :created` is `head :created`)",
        "Rails.logger" => "the rule unwraps `extend(ActiveSupport::Logger.broadcast(x))`; an argument " \
                          "nested deeper than one level is left rather than cut in half, and " \
                          "`Rails.autoloaders.log!` — the other half of the same release's note — is " \
                          "a different edit",
        "bootsnap" => "the bridge is driven by the *tree* rather than by a located line: it declares " \
                      "the gem when `config/boot.rb` requires `bootsnap/setup`, which is what " \
                      "`app:update` writes. An application whose boot file does not mention it is left " \
                      "alone",
        "sprockets-rails" => "the bridge declares the gem when `config/application.rb` requires " \
                             "`sprockets/railtie` — the line a pre-7.0 generated application has. An " \
                             "application that has dropped the pipeline is left alone",
        "match without via:" => "`via: :all` is what preserves the behaviour, and the deprecation " \
                                "exists because a route that answers every verb is usually not what " \
                                "was meant — which verbs this route wants is the application's. A " \
                                "route drawn with a `do` block is left: `via:` goes before the `do`, " \
                                "and that is a different edit",
        "button_to" => "`method: :post` is added to a button built from a record, and on one built " \
                       "from a path helper it is the default it already had — so the edit is right " \
                       "either way. A button whose arguments this tool cannot see the end of is left",
        "config.action_view.raise_on_missing_translations" => "the setting's own line moves to " \
                                                              "`config.i18n`; the note's other half " \
                                                              "— a custom I18n exception handler — is " \
                                                              "a decision about how the application " \
                                                              "reports a missing translation",
        "protect_from_forgery" => "the rule adds `prepend: true` unconditionally, because the line " \
                                  "does not show what runs before it: where a filter is declared " \
                                  "above the callback the option restores the order 5.0 changed, and " \
                                  "where nothing is, it is redundant and can be deleted. Which of " \
                                  "the two this application is, is a fact about its filter order",
        "params as a Hash" => "`params.slice(...)` is a rule (`params.permit(...).to_h`, the note's " \
                              "own shape); `map`, `each`, `each_pair`, `symbolize_keys`, " \
                              "`reverse_merge` and a bare `to_h` are not, because each reads the " \
                              "parameters a different way and the note's fix — permit first — is a " \
                              "decision about what that call site is allowed to read",
        "find_all_by_*" => "the rule makes the call; whether the *caller* wanted the Array the old " \
                           "finder returned is not on the line (`where` returns a relation), which " \
                           "is the note's own warning and the application's suite to catch",
        "find(:all, ...)" => "the rule unwraps `conditions:` — a hash *or* an array — and nothing " \
                             "else, because the note's " \
                             "replacement is the conditions alone: `find(:all, conditions: {…}, " \
                             "order: …)` is left rather than silently losing the other options",
        "scope :name, where(...)" => "the rule wraps a body that starts with a relation call and " \
                                     "runs to the end of the line; a body with a trailing comment, " \
                                     "or one that is not a relation call at all, is left — the " \
                                     "lambda would swallow the comment",
        "return inside an inline callback block" => "the rule takes a block whose body is exactly " \
                                                     "one `return`; a body with a statement after " \
                                                     "it is left, because dropping it would be " \
                                                     "deleting code — the note's other half is to " \
                                                     "move that body to a method and name it",
        "return false from a before callback" => "the rule rewrites the inline block " \
                                                  "(`before_save { return false }`); a `return " \
                                                  "false` in a named method body is not this change " \
                                                  "at all — it is a method's return value, and " \
                                                  "`throw(:abort)` there would be wrong",
        "mutator methods on a Relation" => "the rule matches a receiver whose last call is a query " \
                                           "(`Item.where(...).compact!`), which is what makes `.to_a` " \
                                           "safe — `Array#to_a` returns the array itself, `Hash#to_a` " \
                                           "does not. A local variable is left: nothing on the line " \
                                           "says whether it holds a relation or a hash",
        "config.action_dispatch.show_exceptions" => "the rule maps the two booleans the release no " \
                                                    "longer accepts (`true` to `:all`, `false` to " \
                                                    "`:none`, the note's own mapping); `:rescuable` — " \
                                                    "what a generated application now uses in test — " \
                                                    "is a choice about which exceptions a test " \
                                                    "should see, not a mapping",
        "config.autoload_paths and $LOAD_PATH" => "the rule replaces the one hand-written line that " \
                                                  "put `lib` on the autoload paths, which is the " \
                                                  "shape every generated application had; another " \
                                                  "path list is left, because `autoload_lib`'s " \
                                                  "ignore list is a fact about the directory",
        "belongs_to" => "the rule adds `optional: true` where the model does not already validate " \
                        "the association's presence — which preserves the behaviour the association " \
                        "had before 5.0. It is the *safe* direction and not the only right one: an " \
                        "association the application meant to require should keep the new default " \
                        "instead, and an association whose options run past the line (a lambda " \
                        "scope, a trailing comma) is left alone. A migration's `t.belongs_to :user` " \
                        "is a column definition rather than this change at all, and it is left " \
                        "because the rule is anchored on the association declaration — and a " \
                        "fixture's `belongs_to:` key is not a call at all: measured on the " \
                        "lighthouse, whose 2013 `test/fixtures/items.yml` carries two empty " \
                        "`belongs_to:` keys per fixture, and the rule (before it required the " \
                        "association's name) wrote `belongs_to:, optional: true` into them, so a " \
                        "YAML file the change is not about was edited rather than left",
        "ActiveJob::Base as a job's superclass" => "the rule covers a job whose superclass is written " \
                                                   "on one line; a job that inherits from another job " \
                                                   "is left"
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

      # **The value shapes an option carries and whose end this tool can see**: a string, a symbol, an
      # ivar, a global, or a dotted name. One constant, because `option_wrapped` and `option_renamed`
      # ask the same question and a second copy of it is how the two would start disagreeing about
      # what an option's value is. A call with arguments is deliberately not here: the end of
      # `t(:x, count: 1)` is inside a parenthesis the pattern cannot see, and a rule that guessed it
      # would cut the line in half.
      OPTION_VALUE = /(?<value>"[^"]*"|'[^']*'|:[A-Za-z_]\w*|@@?[a-z_]\w*|\$[a-z_]\w*|[A-Za-z_]\w*(?:\.\w+)*)(?=\s*[,)]|\s*%>|\s*\z)/

      # An option that became a nested one: the value is captured, never guessed, and the lookahead
      # requires it to end where an argument ends — a comma, the call's closing parenthesis, or the
      # line. A first version of this pattern matched the `t` of `confirm: t(:x, count: 1)` and
      # produced `data: { confirm: t }(:x, count: 1)`, which is why the lookahead is here.
      # `already` is the wrapper's own head — what the line looks like *after* this rule has run — and it is
      # passed rather than derived: the wrapper is a replacement string with a backreference in it, and a
      # pattern carved out of one would be a guess about where the value goes. It is asked twice (stop the
      # edit, stop the decision), which is what makes an already-migrated call site an *answer* rather than a
      # refusal.
      #
      # **It has to cover every spelling the input can take, and a guard that misses one mangles a line.**
      # Measured: `:data => { :confirm => "Sure?", :method => :delete }` — a valid Rails call with the
      # hash-rocket spelling — matched the rule and came out as
      # `:data => { data: { confirm: "Sure?" }, :method => :delete }`, which is not a call at all. The first
      # real application's own devise view is one comma away from that shape. The value's lookahead is what
      # saves the two spellings where the value is last (a ` }` after it), and nothing saves the one where a
      # second option follows.
      def self.option_wrapped(subject:, option:, wrapper:, already: nil)
        head = /(?::\s*#{Regexp.escape(option)}\s*=>|\b#{Regexp.escape(option)}:)\s*/
        Rule.new(family: :option_wrapped, subject: subject, already: already,
          pattern: Regexp.new("#{head.source}#{OPTION_VALUE.source}"), replace: wrapper)
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
      #
      # `args` may be a count (that many comma-separated arguments, each without a parenthesis) or a
      # pattern string, for a call whose whole argument list moves as one — `params.slice(:a, :b)`
      # keeps its keys, so the list is captured rather than enumerated. `receiver` names the receiver
      # the call must have, and it is captured rather than looked behind for the same reason
      # `name_moved`'s is: the region is what the write re-matches.
      def self.call_replaced(subject:, from:, to:, args: 1, receiver: nil, already: nil)
        captured =
          if args.is_a?(String)
            "(?<a1>#{args})"
          else
            (1..args).map { |index| "(?<a#{index}>[^,()]+)" }.join("\\s*,\\s*")
          end
        head = receiver ? "(?<receiver>\\b#{Regexp.escape(receiver)})\\." : "\\b"
        Rule.new(family: :call_replaced, subject: subject, already: already,
          pattern: Regexp.new("#{head}#{Regexp.escape(from)}\\s*\\(\\s*#{captured}\\s*\\)"),
          replace: receiver ? "\\k<receiver>.#{to}" : to)
      end

      # **An option the new release requires, added to a call that does not have it.** `belongs_to` is
      # what made this a family: the call's arguments are a flat list, so the option goes on the end.
      # Three refusals keep it honest, and each was measured:
      #
      # * the line already names the option (the first lookahead is what makes the rule idempotent);
      # * the call opens a block — `match "/x" => "y#z" do` came out as
      #   `match "/x" => "y#z" do, via: :all`, which is a route that does not parse. A `do` inside a
      #   string is not seen, because the mask blanks it, which is why the second lookahead can be this
      #   blunt;
      # * an argument runs past the line (a trailing comma, a comment, a nested call) — appending to an
      #   argument list whose end the rule cannot see is how a rule cuts a line in half.
      #
      # The argument runs are *lazy* and they exclude `%` and `<`, and both are what let the ERB close be
      # claimed by the group that names it: greedy, they swallowed ` %>` as an argument and the
      # declaration landed after the tag; with `%` allowed, `<%= button_to "x", item %><% end %>` was
      # read as one call whose argument ran through the second tag. `>` stays allowed, because a route's
      # `=>` is an argument.
      #
      # Positional arguments are allowed, and that is a fix rather than a widening: `button_to "Delete",
      # item` has two arguments and only the second is an option, so a pattern that required every
      # argument to be a `key: value` pair matched none of the buttons the change is about.
      #
      # **Its idempotence is a refusal and deliberately not a declared guard.** `(?!.*\b#{key}:)` stops a
      # second walk adding the option twice, and the tempting tidy is to hand the same predicate to
      # `already:` so an already-optioned line reports `satisfied` the way `:confirm`'s does. That would be
      # a lie: `:confirm`'s guard names the *whole* wrapper it recognises (`data: { confirm: … }`), while
      # this one can only name the option's *key* — `\bmethod:` for `button_to`'s `, method: :post` — and a
      # line carrying `form: { method: :get }` would then be reported as already reading the new way and
      # the option would never be added. `satisfied` is a claim about the line, so it has to be true; a
      # guard too loose to support it leaves the line a decision, which is the honest answer and the one
      # the person can still read.
      # **`argument:` is a required part of the call, for a name too common to recognise on its own.**
      # `belongs_to` is why: the call's own name does not say whether an association is being named, and
      # a *fixture's* `belongs_to:` is a YAML key with no arguments at all. Measured on the lighthouse,
      # whose 2013 `test/fixtures/items.yml` carries two empty `belongs_to:` keys per fixture — the
      # generator's own junk — and the rule wrote `belongs_to:, optional: true` into them: this tool
      # editing a file the change is not about. The pattern the rule then needs is the association's
      # name, and it is the *call* that carries it, so the group still re-emits the whole call.
      def self.option_added(subject:, call:, option:, context: nil, argument: nil, already: nil)
        key = option[/[a-z_]\w*(?=:)/]
        named = argument ? "\\s+#{argument}" : ""
        # **A line that already carries the option is satisfied, not refused.** The pattern's negative
        # lookahead is what stops the rule writing the option twice, and `satisfied` is the same
        # predicate — so a line that asks for it again is *named* rather than handed to a person as work.
        # Measured on the lighthouse: the 5.0 step applied this family to
        # `protect_from_forgery with: :exception, prepend: true`, and every rung after it re-listed that
        # line as a decision whose reason said the call site had been "carried unfixed since 5.0" — the
        # line already read what the rule writes. The predicate is derived from the family's own
        # argument rather than written per instance, because it is the same string the lookahead uses.
        already ||= Regexp.new("#{Regexp.escape(call)}\\b[^\\n]*" \
                               "#{Regexp.escape(option.sub(/\A[,\s]+/, ''))}")
        Rule.new(family: :option_added, subject: subject, context: context, already: already,
          pattern: Regexp.new("#{ERB_OPEN.source}(?!.*\\b#{key}:)(?!.*\\bdo\\b)" \
                              "(?<call>#{Regexp.escape(call)}\\b#{named}[^,()%<]*?(?:\\s*,\\s*[^,()%<]+?)*)#{ERB_CLOSE.source}"),
          replace: "\\k<open>\\k<call>#{option}\\k<close>")
      end

      # **A call's trailing argument list moves under one keyword.** Rails 5.1 removed the positional
      # hash from the test request helpers: `ActionController::TestCase#process` and
      # `ActionDispatch::IntegrationTest#process` now take `params:`, `session:`, `flash:`, `body:`,
      # `xhr:`, `format:` and `as:` as keywords — actionpack-5.1.0's own CHANGELOG, "Remove deprecated
      # support to non-keyword arguments in `ActionController::TestCase#process`" — so
      # `get :index, category_id: @item.category` is `ArgumentError: unknown keyword: category_id` and
      # 17 of the lighthouse's 201 examples fail on it. The whole trailing list *was* the params hash, so
      # it moves under the key unchanged: the edit wraps text, which is why it needs no brace matching.
      #
      # Four refusals, each a line that does not say what the edit would claim:
      #
      # * the call already names the keyword — somebody has moved it, and this is the same predicate
      #   `satisfied` reports, so the line is not left as a decision either;
      # * nothing follows the action — there is no list to move;
      # * the list does not begin with a keyword pair — `post :create, { item: … }` is the *positional*
      #   form, whose first argument is the params hash and whose second may be the session;
      # * a second positional hash follows a comma (`… , { user_id: 1 }`, the same form one argument
      #   further in) — wrapping it would put a bare hash inside the params hash.
      def self.arguments_keyed(subject:, calls:, keyword:, file: nil, rung: nil, wrapper: false)
        names = Array(calls).map { |call| Regexp.escape(call) }.join("|")
        call = "(?:#{names})\\s+:[a-z_]\\w*\\s*,\\s*(?!.*,\\s*\\{)"
        args = "(?<args>[a-z_]\\w*:.*)"
        # **A call inside an inline block on one line, which the anchored shape cannot see.** The
        # lighthouse has 15 of them — `let(:send_request) { get :show, id: @category }` and
        # `lambda { delete :destroy, id: @bid }.should change(Bid, :count).by(-1)` — and they are the same
        # change: the statement is not the line. The arguments end at the *last* `}` on the line, which is
        # the wrapper's close; a hash inside the arguments is never the last one, and the `context` below
        # refuses the one line where that is not true (`expect { … }.to change { … }`).
        pattern = if wrapper == :continues
          # **The wrapper's close is on the *next* line, and both the arguments and the block run past
          # this one.** This application has two of them (`lambda{ post :create, item: { … }, category_id:
          # @category` / `}.should change(Item, :count).by(1)`), and the edit is still within the line: the
          # hash this rule opens closes at the end of the line, and the wrapper's own `}` on the next line
          # closes the block. `wrapper_continues_the_line` is what makes that true — the line's brace depth
          # has to be exactly one, so the arguments it wraps are all the ones it read.
          Regexp.new("\\A(?<lead>.*?\\{\\s*)(?<call>#{call})#{args}(?<tail>\\s*)\\z")
        elsif wrapper
          Regexp.new("\\A(?<lead>.*?\\{\\s*)(?<call>#{call})#{args}(?<tail>\\s*\\}.*)\\z")
        else
          Regexp.new("\\A(?<lead>\\s*)(?<call>#{call})#{args}(?<tail>\\s*)\\z")
        end
        Rule.new(family: :arguments_keyed, subject: subject, file: file, rung: rung,
          already: /\b#{Regexp.escape(keyword)}:/,
          pattern: pattern,
          # **The wrapper's own close has to be the last brace the line has.** The arguments are read to
          # the *last* `}` on the line, which is the wrapper's close — unless the line wraps a second
          # block after it: `expect { get :index, a: 1 }.to change { Item.count }` would put
          # `change { Item.count }` inside the params hash. Measured, this application has no such line;
          # the refusal is what keeps the shape honest rather than lucky.
          context: case wrapper
          when :continues then method(:wrapper_continues_the_line)
          when true then method(:wrapper_closes_the_line)
          end,
          replace: lambda do |match|
            args = match[:args]
            gap = args.match?(/\s\z/) ? " " : ""
            "#{match[:lead]}#{match[:call]}#{keyword}: { #{args.sub(/\s+\z/, "")} }#{gap}#{match[:tail]}"
          end)
      end

      # Whether the inline block this rule found closes at the line's last brace: the `{` the lead
      # stopped at is matched forward, and everything after its close must carry no brace of its own.
      def self.wrapper_closes_the_line(_lines, _found, raw, _tree)
        text = mask(raw.to_s)
        depth = 0
        close = nil
        text.each_char.with_index do |char, index|
          depth += 1 if char == "{"
          next unless char == "}"

          depth -= 1
          if depth.zero?
            close = index
            break
          end
        end
        !close.nil? && !text[(close + 1)..].to_s.include?("{")
      end

      # Whether the inline block this rule found is still open at the line's end, which is the shape where
      # the call's arguments *and* the wrapper's close both run past the line — this application's
      # `lambda{ post :create, item: { … }, category_id: @category` with its `}` and `.should change(…)` on
      # the next line. The wrap adds the hash's close at the end of the line and the wrapper's own `}` on
      # the next line closes the block; the depth has to be exactly one for that to be the same edit, since
      # any deeper means the arguments are not all on this line and the added brace would close the wrong
      # one.
      def self.wrapper_continues_the_line(_lines, _found, raw, _tree)
        depth = 0
        mask(raw.to_s).each_char do |char|
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
        end
        depth == 1
      end

      # **A finder that refuses an object now.** Rails 5.1 added the guard and named the fix in the same
      # sentence — `ArgumentError: You are passing an instance of ActiveRecord::Base to \`find\`. Please
      # pass the id of the object by calling \`.id\`.` — and this application failed 39 of its 201 examples
      # on it: `Item.find(item)`, `Bid.find(@bid)`, `User.find(user_1)` and the rest.
      #
      # Two refusals, and the first is the whole safety: an argument whose *name* says it is already an id
      # (`id`, `@item_id`) is left, because `item_id.id` is not this change — measured in this
      # application's own `app/workers/complete_auction.rb:8`, `Item.find(item_id)`, where the rule would
      # have broken a line that works. And an argument that is not a bare name — `find(params[:id])`,
      # `find(5)`, `find(User.first)` — is left too: the guard refuses an *instance*, and the rule cannot
      # see what a call returns.
      def self.finder_takes_an_id(subject:, file: nil, rung: nil)
        Rule.new(family: :finder_takes_an_id, subject: subject, file: file, rung: rung,
          pattern: /(?<call>\b[A-Z]\w*\.find\()(?<arg>@?[a-z_]\w*)(?<close>\))/,
          replace: lambda do |match|
            next match[0] if match[:arg].match?(/\A@?(?:id|.*_id)\z/)

            "#{match[:call]}#{match[:arg]}.id#{match[:close]}"
          end)
      end

      # **The two ends of an ERB tag.** A rule whose pattern is anchored at `\A` and `\z` is saying "the
      # whole line is this statement", and in a template the statement is wrapped — so a family that
      # anchors has to know the wrapper or it matches nothing in a `.erb` file at all. That is measured
      # rather than imagined: every one of `button_to`'s call sites is in a view, and the rule written
      # for it matched none of them until these two were part of the pattern. The wrapper is captured,
      # not just allowed, because the replacement re-emits the line around the call.
      ERB_OPEN = /(?<open>\A\s*(?:<%[-=]?\s*)?)/
      ERB_CLOSE = /(?<close>(?:\s*-?%>)?\s*\z)/

      # **The extent of an argument this tool will carry across a call**: one level of nesting and no
      # more. `Logger.new("log/x.log")` is one level; a call inside a call inside a call is not, and is
      # left rather than cut in half. One constant, because two families carry an argument across.
      ARGUMENT = /[^()]*(?:\([^()]*\)[^()]*)*/

      # **A call that wraps another, unwrapped.** "`Rails.logger` is an `ActiveSupport::BroadcastLogger`
      # now, and `extend(ActiveSupport::Logger.broadcast(...))` is out" —
      # `Rails.logger.extend(ActiveSupport::Logger.broadcast(other))` is
      # `Rails.logger.broadcast_to(other)`. The target is captured rather than named, because
      # `config.logger` is the same edit, and the argument's extent is the careful half: the inner
      # call's parentheses are why `ARGUMENT` exists.
      def self.call_unwrapped(subject:, wrapper:, unwrap:, method:, context: nil)
        Rule.new(family: :call_unwrapped, subject: subject, context: context,
          pattern: Regexp.new("(?<target>[A-Za-z_]\\w*(?:\\.[A-Za-z_]\\w*)*)\\.#{Regexp.escape(wrapper)}" \
                              "\\(\\s*#{Regexp.escape(unwrap)}\\(\\s*(?<value>#{ARGUMENT.source})\\s*\\)\\s*\\)"),
          replace: "\\k<target>.#{method}(\\k<value>)")
      end

      # **An option that changed its own name, on the call that takes it.** `render :text => x` is
      # `render plain: x` — the value is carried, the key is not — and the pattern is anchored on the
      # *call*, because `text:` appears in other calls' option hashes on the same line
      # (`render partial: "x", locals: { text: y }`) and a rule that matched the first one would
      # rewrite the wrong option. Only the call's own leading option is reached, which is why an
      # option behind another (`render status: 200, text: "x"`) is left.
      def self.option_renamed(subject:, call:, from:, to:)
        Rule.new(family: :option_renamed, subject: subject,
          pattern: Regexp.new("(?<head>\\b#{Regexp.escape(call)}\\s*\\(?\\s*)" \
                              "(?::\\s*#{Regexp.escape(from)}\\s*=>|#{Regexp.escape(from)}:)\\s*" \
                              "#{OPTION_VALUE.source}"),
          replace: "\\k<head>#{to}\\k<value>")
      end

      # **A setting the release deleted, and the line that sets it is the whole edit.** "The identity
      # map was removed from Active Record for its inconsistency with associations, so the setting has
      # no effect — delete the line"; "The setting is deleted in 7.0 — there is no mode to choose.
      # Remove the line rather than setting it to `:zeitwerk`." The pattern is the setting and an
      # assignment, so a line that mentions it in a comment or passes it to something else does not
      # match, and the edit empties the line rather than shifting it away — the same shape
      # `line_removed` writes, because a patch that renumbers a file is a patch nobody can read.
      def self.setting_removed(subject:, setting:, file: nil, rung: nil)
        Rule.new(family: :setting_removed, subject: subject, file: file, rung: rung,
          pattern: /\A(?<indent>\s*)#{Regexp.escape(setting)}\s*=(?!=)\s*.*\z/, replace: "")
      end

      # **A class method that becomes an instance method on its own argument.** "`ActiveSupport::
      # Dependencies.constantize("User")` becomes `"User".constantize`" — the receiver disappears and
      # the argument takes its place, which is a different edit from a rename and the reason this is a
      # family rather than a `call_replaced` with an empty receiver.
      def self.call_inverted(subject:, receiver:, call:, to:, context: nil)
        Rule.new(family: :call_inverted, subject: subject, context: context,
          pattern: /\b#{Regexp.escape(receiver)}\.#{Regexp.escape(call)}\s*\(\s*(?<value>[^(),]*)\s*\)/,
          replace: to)
      end

      # **A call whose own name carries its arguments.** `find_all_by_name(x)` is `where(name: x)`, and
      # the family owns what every instance shares: the attribute list is split out of the method name
      # and each attribute takes the argument in its position. A finder whose arguments do not line up
      # with its attributes — `find_all_by_name(1, 2)`, a call with an options hash — does not match,
      # and that is the conservative half: a wrong pairing writes `where(name: 1, 2)` into a file, and
      # the suite would report it as the application's breakage.
      def self.finder_moved(subject:, from:, to:)
        Rule.new(family: :finder_moved, subject: subject,
          pattern: /(?<!\w)#{Regexp.escape(from)}_(?<names>[a-z_]\w*(?:_and_[a-z_]\w*)*)\((?<args>[^()]*)\)/,
          replace: lambda do |found|
            names = found[:names].split("_and_")
            values = found[:args].split(",").map(&:strip)
            next found[0] unless names.size == values.size

            pairs = names.zip(values).map { |name, value| "#{name}: #{value}" }.join(", ")
            format(FINDER_TARGETS.fetch(to), pairs: pairs)
          end)
      end

      # The destination shapes a dynamic finder becomes. Each is a *shape* rather than a template: the
      # attribute/value pairs are the same list in all four, and what differs is what the call becomes.
      FINDER_TARGETS = {
        where: "where(%<pairs>s)",
        where_last: "where(%<pairs>s).last",
        find_or_create_by: "find_or_create_by(%<pairs>s)",
        find_or_initialize_by: "find_or_initialize_by(%<pairs>s)"
      }.freeze

      # **A finder whose options became a `where` chain.** `find(:all, conditions: {name: 'x'})` is
      # `where(name: 'x')`; the family owns the two parts every instance shares — the scope maps to the
      # method that replaces it, and the conditions are unwrapped rather than rewritten. Anything
      # else in the options (`order:`, `limit:`, a second key) does not match, because the note's
      # replacement is the conditions alone and a rule that dropped the other options would be
      # changing what the query returns.
      #
      # **The conditions may be an array.** The note's own example is the hash form, and the rule knew only
      # that — so it refused the array form, which is the one the lighthouse's failure actually carries:
      # `find(:all, conditions: ["url LIKE ?", "tech%"])` is the same unwrap into
      # `where(["url LIKE ?", "tech%"])`. That call is inside `stringex 1.5.1` rather than in the
      # application, so no rule reaches it; the form is still real, and a rule that knows one of the two
      # spellings of an API refuses half its call sites. The brackets are part of the capture because
      # `where` takes them; the value's *contents* are masked and need not be read, since the whole
      # condition moves as it is.
      def self.find_conditions(subject:, finder: "find")
        Rule.new(family: :find_conditions, subject: subject,
          pattern: /#{Regexp.escape(finder)}\(\s*:(?<scope>all|first|last)\s*,\s*conditions:\s*(?:\{(?<hash>[^{}]*)\}|(?<array>\[[^\[\]]*\]))\s*\)/,
          replace: lambda do |found|
            # The hash's braces are the call's, the array's brackets are the *argument's*: `where(name: 'x')`
            # is what the note writes, and `where(["x = ?", 1])` is the array that takes its own.
            conditions = (found[:hash] || found[:array]).to_s.strip
            format(FIND_SCOPES.fetch(found[:scope].to_sym), conditions: conditions)
          end)
      end

      FIND_SCOPES = {
        all: "where(%<conditions>s)",
        first: "where(%<conditions>s).first",
        last: "where(%<conditions>s).last"
      }.freeze

      # **A call whose trailing argument must become a callable.** `scope :active, where(active: true)`
      # is evaluated when the class loads, which is why 4.0 removed it; the guide's fix is a lambda,
      # and the family is careful about the two things that decide whether wrapping is safe: the
      # argument has to *start* with a relation call (a scope body that is something else is a
      # different edit), and it has to run to the end of the line — a trailing comment would end up
      # inside the braces, which is a line that does not parse.
      def self.argument_wrapped(subject:, call:, starts: RELATION_START, wrapper: '-> { \k<value> }')
        Rule.new(family: :argument_wrapped, subject: subject,
          pattern: Regexp.new("\\A(?<head>\\s*#{Regexp.escape(call)}\\s+:[a-z_]\\w*\\s*,\\s*)" \
                              "(?<value>#{starts.source}.*)\\z"),
          replace: "\\k<head>#{wrapper}")
      end

      # The relation methods a scope body may start with — the ladder's own detect pattern, so the rule
      # and the scan agree about what a scope body is.
      RELATION_START = /(?:where|order|joins|includes|group|having|limit|offset|select|rewhere|unscope)\b/

      # **A block whose body is a bare `return`.** 4.1 makes `before_save { return false }` a
      # `LocalJumpError` and the guide's fix is the value the block meant to return; 5.0 needs the same
      # shape written as `throw(:abort)` instead. Those two changes are the family, and what they share
      # is the safety property: the body is *exactly* one `return <expression>` (with an optional `if`
      # or `unless`), so a `return` in the middle of a block — where dropping it would leave the
      # statements after it unreachable, and a rule that dropped them would be deleting code — does not
      # match. `value` narrows the expression when the change names one (`return false`).
      def self.block_value(subject:, body:, value: nil)
        expression = value ? value.source : "[^;{}]*?"
        Rule.new(family: :block_value, subject: subject,
          pattern: Regexp.new("(?<open>\\{\\s*)return\\b\\s*(?<value>#{expression})" \
                              "(?<modifier>\\s+(?:if|unless)\\s+[^;{}]+)?(?<close>\\s*\\})"),
          replace: lambda do |found|
            written = found[:value].strip
            written = "nil" if written.empty?
            text = format(body, value: written)
            # The modifier keeps its own leading whitespace, so the body's spacing survives the edit:
            # `{ return false if x }` is `{ throw(:abort) if x }` and not `{ throw(:abort)if x }`. And
            # a body with no value and no modifier (`{ return }`) had the whitespace before the brace
            # eaten by the pattern, so it goes back — `{ nil}` is not a line anybody writes.
            modifier = found[:modifier].to_s
            text = "#{text}#{modifier}"
            text = "#{text} " if found[:value].strip.empty? && modifier.empty?
            "#{found[:open]}#{text}#{found[:close]}"
          end)
      end

      # **A setting whose value moved**: the name stays and what it accepts does not. The pattern is
      # the setting and the value the old release took, so a line already naming the new one does not
      # match and is left rather than being rewritten twice.
      def self.value_moved(subject:, setting:, from:, to:)
        Rule.new(family: :value_moved, subject: subject,
          pattern: /(?<head>#{Regexp.escape(setting)}\s*=\s*)#{Regexp.escape(from)}\b/,
          replace: "\\k<head>#{to}")
      end

      # **A statement whose whole text becomes another statement.** The match is the statement's own
      # text exactly, with only the indentation free — so a line that has been edited since the guide
      # was written does not match, and the family cannot half-replace a line it only half-recognises.
      # It is for a change whose replacement is a *different* line rather than a different name.
      def self.line_replaced(subject:, from:, to:)
        Rule.new(family: :line_replaced, subject: subject,
          pattern: /\A(?<indent>\s*)#{Regexp.escape(from)}\s*\z/, replace: "\\k<indent>#{to}")
      end

      # The mutators the query lost, from the change's own detect pattern.
      RELATION_MUTATORS = /(?:map!|collect!|delete_if|keep_if|reject!|select!|compact!|sort!|sort_by!|uniq!)/

      # The methods whose *result* is a query — what makes `.to_a` the right thing to add. Wider than
      # `RELATION_START`, which is the ladder's own list of scope-body openings: `Item.all` is a query
      # and not a scope body, and the two questions are different ones.
      QUERY_METHODS = /(?:all|scoped|#{RELATION_START.source})/

      # A call whose receiver is a query: a constant, then any chain of dotted calls, then one of those
      # methods.
      QUERY_CALL = /\.(?:#{QUERY_METHODS.source})(?:\([^()]*\))?/
      QUERY_RECEIVER = /\b[A-Z]\w*(?:::\w+)*(?:\.\w+(?:\([^()]*\))?)*#{QUERY_CALL.source}/

      # **A mutator the query no longer has.** The note's own edit is `.to_a` first, and the family is
      # careful about which receiver it will do that to: `Array#to_a` returns the array itself, so the
      # edit is a no-op on one, while `Hash#to_a` is a different object — which is why the rule only
      # matches a receiver whose last call is a query (`Item.where(...)`, `Item.all`). A local variable
      # is left: nothing on the line says whether it holds a relation or a hash.
      def self.query_materialised(subject:, methods: RELATION_MUTATORS)
        Rule.new(family: :query_materialised, subject: subject,
          pattern: /(?<receiver>#{QUERY_RECEIVER.source})\.(?<mutator>#{methods.source})(?!\w)/,
          replace: "\\k<receiver>.to_a.\\k<mutator>")
      end

      # **A model's superclass, and the file that has to exist before the rename means anything.**
      # `class Item < ActiveRecord::Base` becomes `class Item < ApplicationRecord`, and the definition
      # itself is the one `ActiveRecord::Base` that stays — so the family refuses to rename the class it
      # is about to write, which is the bug a second walk would otherwise hit: the scan would locate
      # `class ApplicationRecord < ActiveRecord::Base` in the file this rule created and make it
      # inherit from itself.
      def self.superclass_moved(subject:, from:, to:, defines:, scaffold: nil)
        Rule.new(family: :superclass_moved, subject: subject, scaffold: scaffold,
          pattern: /\A(?<indent>\s*class\s+(?!#{Regexp.escape(defines)}\b)[A-Z]\w*(?:::\w+)*\s*<\s*)#{Regexp.escape(from)}\b/,
          replace: "\\k<indent>#{to}")
      end

      # **A definition whose signature gained a parameter.** The one shape where the change is not in a
      # call but in the *method*: 6.1 passes the callback's name as a second argument to
      # `halted_callback_hook`, with no deprecation cycle, so a one-argument override raises
      # `ArgumentError` the moment a callback halts. The parameter is named with a leading underscore
      # because this tool does not know whether the override wants it — and a name the body already uses
      # would be shadowed rather than added.
      #
      # A definition that already takes a second parameter does not match, which is what makes the rule
      # idempotent without an `already` pattern: the argument run excludes commas, so `(message, name)`
      # cannot reach the closing parenthesis.
      def self.parameter_added(subject:, method:, parameter:)
        Rule.new(family: :parameter_added, subject: subject,
          pattern: /(?<head>\bdef\s+(?:self\.)?#{Regexp.escape(method)}\s*\(\s*[^(),]*)(?<close>\s*\))/,
          replace: "\\k<head>, #{parameter}\\k<close>")
      end

      # **The block a callback receives becomes a parameter.** 4.1 passes the block to an `around`
      # callback explicitly, so `->(r, &block)` is `->(r, block)` and the ampersand is the whole edit.
      #
      # The pattern names the *parameter list* rather than the ampersand alone, and the delimiter is part
      # of the match for two measured reasons:
      #
      # * a bare `&(\w+)` would also match a block-pass argument — `set_callback(:x, :around, &block)`
      #   passes the proc as the callback's body, and removing that ampersand passes the proc as an
      #   argument instead. Only `->(` and a block's `|` introduce a parameter list, so those are what
      #   the pattern requires;
      # * a trailing lookahead cannot work here. The write re-matches the *region* (`Rule#after`), so a
      #   pattern that ends in `(?=…)` needs the lookahead to succeed against a string that stops where
      #   the match did — which is why `OPTION_VALUE` carries a `\z` alternative and why the closing
      #   delimiter is a capture here instead.
      def self.block_captured(subject:)
        Rule.new(family: :block_captured, subject: subject,
          pattern: /(?<pre>->\s*\(|\|)(?<args>[^|()]*?)&(?<name>\w+)(?<post>\s*[,|)])/,
          replace: "\\k<pre>\\k<args>\\k<name>\\k<post>")
      end

      # **The rules, by the subject the ladder and the scan both use.** Each is here because its own
      # note sanctions the shape, and `MultiJson` is here because its note forbids a *different* edit
      # than the one written.
      # **The call sites a rule finds for itself**, in a file the scan never sends.
      #
      # A change whose note names a `package.json` line has no detect in the ladder and no Ruby to match,
      # and the scanner reads the languages this tool tells it about. So the client reads the file the
      # rule's `file` names and matches it here — and the entry is shaped exactly like the scan's, because
      # everything downstream is built for that shape: the applier's line re-check, the refusal reasons,
      # the record's own rendering. A second shape would be a second set of bugs.
      #
      # The change's own words travel with the entry (`kind`, `replacement`, `note`, the guide chapter),
      # because a rule that applies a change withdraws its decision and the note is where the caveat a
      # reviewer needs lives — the same reason the service's edits carry them.
      def self.sourced(rules, sources, changes)
        by_subject = Array(changes).to_h { |change| [change["subject"].to_s, change] }
        # **One entry per line per change, not per rule.** A change may have several rules that read the
        # same files — `arguments_keyed` has three, one per shape, and they share a glob — and the first
        # that *matches* the line is the entry. Emitting one per matching rule asked the applier to write
        # the same line twice, so the second was refused as "not the line the scan read" and the record
        # reported refusals that were really one edit: measured at the 5.1 rung, 15 of them, 14 for the
        # seven wrapped call sites whose two sibling rules both matched.
        rules.select(&:file).group_by(&:file).flat_map do |_glob, candidates|
          candidates.group_by(&:subject).flat_map do |subject, group|
            change = by_subject[subject].to_h
            sources.flat_map do |path, lines|
              Array(lines).each_with_index.filter_map do |line, index|
                next unless group.any? { |rule| rule.pattern.match?(line) }

                { "path" => path, "line" => index + 1, "text" => line.chomp, "after" => nil,
                  "subject" => subject, "kind" => change["kind"],
                  "replacement" => change["replacement"], "note" => change["note"],
                  "source" => change["source"], "automatic" => true, "origin" => "rule" }
              end
            end
          end
        end
      end

      # **A file a rule reads for its own call sites is bounded**, and the bound is a file count rather
      # than a size: a glob the walker writes (`app/{assets/javascripts,javascript}/**/*.js`) matches a
      # handful in any application, and one that matched thousands would be a rule reading a tree rather
      # than a file.
      SOURCE_LIMIT = 64

      # **A package name that moved under a scope**, in `package.json`. The file is not Ruby, so the rule
      # matches its raw lines; the closing quote and the colon are part of the match because the write
      # re-matches the region, and a trailing lookahead would have nothing to look at.
      def self.package_scoped(subject:, from:)
        Rule.new(family: :name_moved, subject: subject, file: "package.json",
          pattern: /(?<open>["'])#{Regexp.escape(from)}(?<close>["'])(?<colon>\s*:)/,
          replace: "\\k<open>@rails/#{from}\\k<close>\\k<colon>")
      end

      # **A JavaScript call the release moved or renamed.** The scan does not read JavaScript, so the rule
      # finds its own lines — and it matches the raw line, because there is no Ruby string here whose
      # contents the mask should hide.
      def self.javascript_moved(subject:, file:, from:, to:)
        Rule.new(family: :name_moved, subject: subject, file: file,
          pattern: Regexp.new(from.to_s), replace: to)
      end

      # The value of one key in an `assert_tag` hash, or nil. Both spellings the release accepted are read
      # — `tag: "div"` and `:tag => "div"` — and **only a quoted literal counts**: a variable is not
      # blanked by the mask, so it does not match, and a rule that wrapped one in quotes would be asserting
      # against the variable's *name*.
      def self.assert_tag_value(args, key)
        match = args.match(/(?:\b#{key}:|:#{key}\s*=>)\s*(?<q>["'])(?<value>[^"']*)\k<q>/)
        match && match[:value]
      end

      # The same, for a key inside `attributes: { ... }`. `:refused` when the hash names anything this rule
      # cannot express as a CSS selector, which is how "an attribute that is neither id nor class" leaves
      # the line a decision.
      def self.assert_tag_attribute(args, key)
        hash = args.match(/(?:attributes:|:attributes\s*=>)\s*\{(?<body>[^}]*)\}/)
        return nil if hash.nil?
        return :refused if hash[:body].match?(/\b(?!id\b|class\b)[a-z_]\w*\s*(?::|=>)/)

        assert_tag_value(hash[:body], key)
      end

      RULES = [
        # `link_to 'Delete', path, confirm: 'Sure?'` becomes `data: {confirm: 'Sure?'}`, and the
        # helpers built on link_to go the same way.
        option_wrapped(subject: ":confirm option on link_to", option: "confirm",
          wrapper: 'data: { confirm: \k<value> }',
          already: /(?::data\s*=>|data:)\s*\{\s*:?confirm\s*(?::|=>)/),
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
        call_replaced(subject: "MultiJson", from: "MultiJson.load", to: 'JSON.parse(\k<a1>)'),

        # **The 4.0 dynamic finders, one instance per name shape, all of them the same family.** The
        # ladder documents them as one change (`find_all_by_*`), the note gives each destination
        # (`where`, `.last`, `find_or_create_by`), and the family splits the attribute list out of the
        # method name — which is the part that would otherwise be a rule per finder.
        finder_moved(subject: "find_all_by_*", from: "find_all_by", to: :where),
        finder_moved(subject: "find_all_by_*", from: "find_last_by", to: :where_last),
        finder_moved(subject: "find_all_by_*", from: "find_or_create_by", to: :find_or_create_by),
        finder_moved(subject: "find_all_by_*", from: "find_or_initialize_by", to: :find_or_initialize_by),
        finder_moved(subject: "find_all_by_*", from: "scoped_by", to: :where),
        # The note's own example: `find(:all, conditions: {name: 'x'})` is `where(name: 'x')`.
        find_conditions(subject: "find(:all, ...)"),
        # "A scope body has to be callable … wrap it in a lambda."
        argument_wrapped(subject: "scope :name, where(...)", call: "scope"),

        # **`return` inside an inline block, and its two rungs.** 4.1 wants the value the block meant
        # to return; 5.0 wants the halt written explicitly. The family is the block whose body is
        # exactly one `return`, so the two instances differ only in what the body becomes.
        block_value(subject: "return inside an inline callback block", body: "%<value>s"),
        block_value(subject: "return false from a before callback", body: "throw(:abort)", value: /false/),

        # **`belongs_to`, and the one rule that reads the rest of the file.** Whether an association is
        # required is not a fact about the `belongs_to` line: a model that already says
        # `validates_presence_of :user` is one the new default agrees with, and adding `optional: true`
        # there would be noise in a diff whose whole value is being the list of associations whose
        # behaviour changed. A file the rule could not read answers "nothing validates it", which is the
        # safe direction — the edit is the behaviour-preserving one either way.
        option_added(subject: "belongs_to", call: "belongs_to", option: ", optional: true",
          argument: ":[a-z_]\\w*",
          # **The option itself, spelled out, and only this family may do it.** `option_added`'s own
          # docstring says its key-only guard must not become an `already` — a line carrying
          # `form: { method: :get }` would read as a `button_to` that has `method:` — and that stands for
          # `match` and `button_to`. It does not stand here: the pattern is anchored on
          # `belongs_to :name`, so an `optional: true` on that line *is* the option this rule writes, and
          # the guard is what tells a line this tool already answered at an earlier rung from one it
          # never touched. Measured at the 5.1 rung, whose residue listed the four model lines the 5.0
          # rung had added the option to as decisions still owed. `optional: false` is deliberately not
          # matched: the line says the association is required, which is the *new* default rather than
          # the preserved behaviour, and a person's choice stays a decision.
          already: /^\s*belongs_to\s+:[a-z_]\w*.*\boptional:\s*true\b/,
          context: lambda do |lines, found, _raw, _tree|
            association = found[:call][/:\K[a-z_]\w*/]
            # **`presence`, with no boundary around it**: `validates_presence_of` has no word
            # boundary after the `_`, so `\bpresence\b` matched nothing and the rule added
            # `optional: true` to an association the model already required — measured on the
            # lighthouse, where `Bid` validates `:item` and the rule wrote the option anyway.
            lines.none? do |line|
              line.match?(/\b#{association}(?:_id)?\b/) && line.match?(/presence/)
            end
          end),

        # "The callback is now inserted where it is called rather than prepended, so an
        # authentication filter declared before it runs first. `prepend: true` restores the old
        # order." — the note's own answer, and it is added unconditionally because the line does not
        # show what runs before it: where nothing does, the option is redundant and a reviewer can
        # delete it, which is a diff rather than a decision.
        option_added(subject: "protect_from_forgery", call: "protect_from_forgery",
          option: ", prepend: true"),

        # **The 5.0 superclasses, and the files they depend on.** The note gives both halves: the
        # definition (`self.abstract_class = true`) and the rename, and the family refuses to rename
        # the definition itself.
        superclass_moved(subject: "ActiveRecord::Base as a model's superclass",
          from: "ActiveRecord::Base", to: "ApplicationRecord", defines: "ApplicationRecord",
          scaffold: Scaffold.new(path: "app/models/application_record.rb",
            content: "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n")),
        superclass_moved(subject: "ActiveJob::Base as a job's superclass",
          from: "ActiveJob::Base", to: "ApplicationJob", defines: "ApplicationJob",
          scaffold: Scaffold.new(path: "app/jobs/application_job.rb",
            content: "class ApplicationJob < ActiveJob::Base\nend\n")),

        # **A setting the release deleted, and the line goes.** Three of these are one family, and the
        # notes are the licence: "the setting has no effect — delete the line", "Remove the setting",
        # "Remove the line rather than setting it to `:zeitwerk`".
        setting_removed(subject: "config.active_record.identity_map",
          setting: "config.active_record.identity_map"),
        setting_removed(subject: "config.action_dispatch.best_standards_support",
          setting: "config.action_dispatch.best_standards_support"),
        setting_removed(subject: "config.autoloader", setting: "config.autoloader"),

        # "`ActiveSupport::Dependencies.constantize("User")` becomes `"User".constantize`." The two
        # members of the private API whose edit is that swap; the rest of the change
        # (`mechanism`, `verbose=`, `hook!`, `depend_on`, `require_or_load`) has a different fix each,
        # which is what its gap says.
        #
        # **The context is what keeps it to a string.** `:User.constantize` is not a method — the
        # private API took a name and the public one is on the String — so a symbol argument is left,
        # and the raw line is the only place that can be asked.
        call_inverted(subject: "ActiveSupport::Dependencies private API",
          receiver: "ActiveSupport::Dependencies", call: "constantize", to: "\\k<value>.constantize",
          context: ->(_lines, _found, raw, _tree) { raw.match?(/#{Regexp.escape("constantize")}\(\s*["']/) }),
        call_inverted(subject: "ActiveSupport::Dependencies private API",
          receiver: "ActiveSupport::Dependencies", call: "safe_constantize",
          to: "\\k<value>.safe_constantize",
          context: ->(_lines, _found, raw, _tree) { raw.match?(/safe_constantize\(\s*["']/) }),

        # "`Rails.application.config_for(:app).with_indifferent_access` keeps the call sites as they
        # are." The conversion goes on the call, and the guard is what makes a second walk a no-op —
        # without it the rule appends a second `.with_indifferent_access`.
        call_replaced(subject: "config_for", from: "config_for",
          to: 'config_for(\k<a1>).with_indifferent_access',
          already: /config_for\([^()]*\)\.with_indifferent_access/),

        # **Two options the release now requires, both behaviour-preserving.** A `match` without `via:`
        # is *removed* in 4.0, so the rung requires an edit and `via: :all` is the one that keeps the
        # route answering what it answered — the narrowing is the application's choice, which is what
        # the gap beside it says. And a `button_to` built from a persisted record renders PATCH rather
        # than POST from 7.0; `method: :post` is the note's own answer, and on a button built from a
        # *path* it is the default it already had, so the edit is right either way.
        option_added(subject: "match without via:", call: "match", option: ", via: :all"),
        option_added(subject: "button_to", call: "button_to", option: ", method: :post"),

        # "The private `AbstractController::Translation` setting is gone; use
        # `config.i18n.raise_on_missing_translations`" — the setting moved rather than disappearing,
        # and the name is the whole edit.
        name_moved(subject: "config.action_view.raise_on_missing_translations",
          from: "config.action_view.raise_on_missing_translations",
          to: "config.i18n.raise_on_missing_translations"),

        # "`Rails.logger.extend(ActiveSupport::Logger.broadcast(x))` is out" — the wrapper and the
        # inner call collapse into `broadcast_to`.
        call_unwrapped(subject: "Rails.logger", wrapper: "extend",
          unwrap: "ActiveSupport::Logger.broadcast", method: "broadcast_to"),

        # **The 5.1 rung of the `render :text` story, where the choice has to be made.** 4.1
        # deprecates `:text` without removing it; here the deprecation has run out, and the note's own
        # answer is `plain:` — the safe one, because `:text` sent `text/html` and interpreted markup
        # in the content. `html:` is for a response that *is* markup, which is a fact about the
        # content rather than about the line, and that is what the gap beside this rule says.
        option_renamed(subject: "render :text / render :nothing", call: "render", from: "text",
          to: "plain: "),
        # "`head :ok` is the replacement for a response with no body" — and the statement is the whole
        # edit, so a `:nothing` that carries anything else is left rather than half-rewritten.
        line_replaced(subject: "render :text / render :nothing", from: "render :nothing => true",
          to: "head :ok"),

        # "Permit first and convert: `params.permit([:a, :b]).to_h`" — the key list is captured rather
        # than enumerated, because `slice` takes as many as the call site wants.
        call_replaced(subject: "params as a Hash", from: "slice", receiver: "params",
          args: "[^()]*", to: 'permit(\k<a1>).to_h'),

        # "Relation no longer has the in-place mutators: `Model.where(...).compact!` is
        # `Model.where(...).to_a.compact!`."
        query_materialised(subject: "mutator methods on a Relation"),

        # "`:all` replaces true, `:none` replaces false" — two instances of one family, because the
        # two values the release no longer accepts become two different ones.
        value_moved(subject: "config.action_dispatch.show_exceptions",
          setting: "config.action_dispatch.show_exceptions", from: "true", to: ":all"),
        value_moved(subject: "config.action_dispatch.show_exceptions",
          setting: "config.action_dispatch.show_exceptions", from: "false", to: ":none"),
        # "`config.autoload_lib(ignore: %w(assets tasks))` replaces the hand-written lines that put lib
        # on the autoload paths" — the statement itself, which is why this is `line_replaced`.
        line_replaced(subject: "config.autoload_paths and $LOAD_PATH",
          from: "config.autoload_paths += %W(\#{config.root}/lib)",
          to: "config.autoload_lib(ignore: %w(assets tasks))"),

        # "It now receives the callback name as a second argument. This one has no deprecation cycle — a
        # one-argument override raises `ArgumentError`." The definition is the edit, and the parameter is
        # named `_name` because whether the override wants it is not something this tool can know.
        parameter_added(subject: "halted_callback_hook", method: "halted_callback_hook",
          parameter: "_name"),

        # "The around callback now receives the block as an argument: `->(r, &block) {...}` becomes
        # `->(r, block) {...}`." Both spellings the note's own sentence covers — a lambda and a `do`
        # block — are the same edit, because both are `&block` at the end of a parameter list.
        block_captured(subject: "ActiveSupport::Callbacks.set_callback"),

        # "The streaming concern is no longer included, so a controller inheriting from it that streams
        # has to include it." The subclass's own file is what says whether it streams — the note's own
        # condition — and the concern's method is the marker.
        concern_included(subject: "ActiveStorage::BaseController",
          superclass: "ActiveStorage::BaseController", concern: "ActiveStorage::Streaming",
          marker: /send_blob_stream/),

        # "actioncable, activestorage and rails-ujs are published under the `@rails` scope — a
        # package.json change, and the build fails loudly without it." Three instances of one family,
        # because the note names three packages; the file is not Ruby, so the rules find their own lines.
        package_scoped(subject: "@rails npm packages", from: "actioncable"),
        package_scoped(subject: "@rails npm packages", from: "activestorage"),
        package_scoped(subject: "@rails npm packages", from: "rails-ujs"),

        # "The adapter settings moved under `ActionCable.adapters`, and startDebugging/stopDebugging
        # became `ActionCable.logger.enabled`." Four instances, one per name the note gives — and the
        # file is JavaScript, which the scan does not read at all.
        javascript_moved(subject: "ActionCable JavaScript adapters",
          file: "app/{assets/javascripts,javascript}/**/*.js",
          from: 'ActionCable\.WebSocket\b', to: "ActionCable.adapters.WebSocket"),
        javascript_moved(subject: "ActionCable JavaScript adapters",
          file: "app/{assets/javascripts,javascript}/**/*.js",
          from: 'ActionCable\.logger(?<tail>\s*=)', to: "ActionCable.logger.enabled\\k<tail>"),
        javascript_moved(subject: "ActionCable JavaScript adapters",
          file: "app/{assets/javascripts,javascript}/**/*.js",
          from: 'ActionCable\.startDebugging\(\)', to: "ActionCable.logger.enabled = true"),
        javascript_moved(subject: "ActionCable JavaScript adapters",
          file: "app/{assets/javascripts,javascript}/**/*.js",
          from: 'ActionCable\.stopDebugging\(\)', to: "ActionCable.logger.enabled = false"),

        # "Nested keys in secrets.yml are loaded as symbols now, so `secrets[:smtp]["address"]` raises or
        # returns nil where it used to work."
        #
        # **The rule reads a string's contents, and a callable `replace` is what makes that possible.** The
        # *pattern* matches the quotes — which the mask keeps, and which decide the extent of the match —
        # and the *write* is handed the raw region, so what was between them is readable. Without that this
        # change would be out of reach for the same reason `config.secret_token`'s value is, and
        # `docs/known-limits.md` said exactly that until this rule was written and measured.
        #
        # Only a *literal* key is rewritten: `secrets[:smtp][key]`, with the key in a variable, does not
        # match, and the survey beside this rule is what names those lines.
        key_respelled(subject: "Rails.application.secrets", to: :symbol, all: true),

        # "These columns now map to a string-keyed Hash rather than a HashWithIndifferentAccess, so symbol
        # access stops working — including store_accessors built on them." The mirror of the rule above, and
        # **`self.` plus the declaring file is what makes it safe**: `self.settings` in the class that says
        # `store_accessor :settings` is provably that column, where a bare `settings[:x]` could be a local
        # holding any hash. A bare name is left as a decision, and the survey beside this rule names those
        # lines.
        key_respelled(subject: "json and hstore columns", to: :string,
          file: "app/models/**/*.rb", receiver: /\bself\.\w+/,
          context: lambda do |lines, found, _raw, _tree|
            column = found[:receiver].to_s.split(".").last
            lines.any? { |line| line.match?(/store_accessor\s+:#{Regexp.escape(column)}\b/) }
          end),

        # "A different argument shape, so this is a test to rewrite." `assert_tag` is gone in 4.2, and
        # `assert_select` is not a rename — the note's own mapping is the guide's:
        # `assert_tag tag: "div", attributes: { id: "foo" }` is `assert_select "div#foo"`. So the rule is
        # written for the *documented* forms and refuses the rest, which is the family's whole discipline
        # applied to an assertion: a wrong assertion does not fail, it *passes*, so a form this cannot read
        # exactly is left as a decision rather than guessed at.
        #
        # A callable `replace` is what makes it possible — the values are inside strings the mask blanks —
        # and the same hook is what makes the refusal expressible: returning the region unchanged is what
        # `Rule#after` reads as "no edit". A `descendant:`, a `count:`, a tag held in a variable, an
        # attribute that is neither `id` nor `class`, or a second statement on the line all take that path.
        Rule.new(family: :assertion_rewritten, subject: "assert_tag",
          pattern: /assert_tag\s*\(?\s*(?<args>[^()]*?)\s*\)?\s*\z/,
          replace: lambda do |match|
            args = match[:args].to_s
            # **A refusal returns the whole match, not the arguments it captured.** Returning `args`
            # deleted `assert_tag` and left its arguments behind — `tag: "div", descendant: ...` — which is
            # a line that no longer parses. `Rule#after` reads an unchanged region as "no edit", so the
            # region is what a refusal has to return.
            #
            # **And a second statement on the line is a refusal**, which the same test found: the pattern
            # runs to the end of the line, so `assert_tag tag: "div"; assert_tag tag: "span"` was read as
            # one call whose arguments carried a second assertion — and rewriting the first *deleted* the
            # second. A `;` inside a string would be refused the same way, which is the safe direction.
            next match[0] if args.match?(/\b(descendant|children|ancestor|sibling|parent|count|minimum|maximum)\b/) ||
                             args.include?(";") || args.match?(/\bassert_tag\b/)

            tag = assert_tag_value(args, "tag")
            id = assert_tag_attribute(args, "id")
            klass = assert_tag_attribute(args, "class")
            content = assert_tag_value(args, "content")
            next match[0] if tag.nil? || [id, klass, content].any? { |value| value == :refused }

            selector = "#{tag}#{id && "##{id}"}#{klass && ".#{klass}"}"
            "assert_select #{selector.inspect}#{content ? ", text: #{content.inspect}" : ""}"
          end),

        # "The protected_attributes gem keeps the old list working as a bridge, and Rails 5 removes that
        # bridge." The gem line is the edit, and the ladder's own caveat is the *condition*: removing it is
        # only right once the models have moved, because a model still calling `attr_accessible` fails
        # without the gem. So the rule asks the whole tree — which is what `context`'s fourth argument is
        # for, since a condition about another file is not a fact about this one.
        Rule.new(family: :line_removed, subject: "the protected_attributes gem", file: "Gemfile",
          pattern: /\A\s*gem\s+["']protected_attributes["'][^\n]*\z/,
          replace: "",
          context: lambda do |_lines, _found, _raw, tree|
            tree.none? do |_path, lines|
              lines.any? { |line| line.match?(/\battr_(accessible|protected)\b/) }
            end
          end),

        # "secrets.yml arrives and config/initializers/secret_token.rb is removed. Move the existing
        # secret_key_base into secrets.yml (or an environment variable) before deleting the initializer, or
        # every session in flight is invalidated."
        #
        # **The guard is the whole rule**, because the failure it prevents is silent: deleting a
        # `secret_key_base` the application has not carried anywhere else invalidates every session in flight,
        # and a test suite does not notice. So the line goes only when `config/secrets.yml` names the *same*
        # environment variable — compared on the raw lines, because an environment variable's name is inside
        # the string the mask blanks, which is why this rule needs `context`'s raw line at all.
        #
        # Only that one line goes. A Rails 3 initializer also sets `secret_token`, and the 3.2 rung's note is
        # explicit that it stays: the two together are what makes a rollback possible.
        Rule.new(family: :line_removed, subject: "config.secrets.yml",
          file: "config/initializers/secret_token.rb",
          pattern: /\A\s*\S*\.?config\.secret_key_base\s*=\s*ENV\[\s*["'][^"']*["']\s*\]\s*\z/,
          replace: "",
          context: lambda do |_lines, _found, raw, tree|
            name = raw[/ENV\[\s*["']([^"']+)["']/, 1].to_s
            next false if name.empty?

            tree.any? do |path, lines|
              path.end_with?("config/secrets.yml") &&
                lines.any? { |line| line.match?(/secret_key_base:.*ENV\[\s*["']#{Regexp.escape(name)}["']/) }
            end
          end),

        # **A change the guide does not name, which the rung's own suite finds.** Rails 5.1 removed the
        # positional hash from the test request helpers, and the guide's 5.1 chapter does not mention it —
        # so the ladder cannot carry it: measured, the lighthouse's 5.1 rung died on 17 of 201 examples
        # with `ArgumentError: unknown keyword: category_id` while the residue named nothing about it.
        # The application has 54 call sites, all of one shape, in `spec/` and `test/`.
        #
        # **`rung:` is the gate, and for this rule the gate is the whole safety.** A rule's rung normally
        # comes from the plan — the ladder says when a change belongs — and a rule with no plan entry has
        # nothing to gate it: `get :index, params: { … }` is a call Rails 4 passes as a *parameter* named
        # `params`, so applying this at 4.1 would break the suite it exists to keep green.
        arguments_keyed(subject: "test request helpers take `params:`",
          calls: %w[get post patch put delete head], keyword: "params",
          file: "{spec,test}/**/*.rb", rung: "5.1.0"),
        # The same change inside an inline block: `let(:send_request) { get :show, id: @category }`, which
        # is 15 of this application's 54 call sites.
        arguments_keyed(subject: "test request helpers take `params:`",
          calls: %w[get post patch put delete head], keyword: "params",
          file: "{spec,test}/**/*.rb", rung: "5.1.0", wrapper: true),
        # And the third shape: the arguments *and* the wrapper's close both run past the line — this
        # application's `lambda{ post :create, item: { … }, category_id: @category` with its `}` and
        # `.should change(Item, :count).by(1)` on the next line. Two of the rung's call sites, and its last
        # two failing examples.
        arguments_keyed(subject: "test request helpers take `params:`",
          calls: %w[get post patch put delete head], keyword: "params",
          file: "{spec,test}/**/*.rb", rung: "5.1.0", wrapper: :continues),

        # **A second change the guide does not name, from the same rung's suite.** Rails 5.1's `find`
        # refuses an `ActiveRecord::Base` instance and says so in the message that names the fix; this
        # application passes one in 40 places, 39 examples' worth. Read from `app/` as well as the two
        # test trees, because the guard is the framework's and not the spec's — this application's own
        # `app/workers/complete_auction.rb:8` passes an id (`item_id`), which is why the rule refuses a
        # name that already says it is one.
        finder_takes_an_id(subject: "find with an object argument",
          file: "{spec,test,app}/**/*.rb", rung: "5.1.0"),

        # **A setting the release removed, from the file Rails' own generator wrote it into.** Rails 5.0's
        # `new_framework_defaults.rb` is where an application holds its old defaults one at a time, and 5.2
        # *removed* `ActiveSupport.halt_callback_chains_on_return_false=` — the 5.0 rung's own boot warned
        # "deprecated and will be removed in Rails 5.2", and the 5.2 rung's boot then died with `undefined
        # method 'halt_callback_chains_on_return_false=' for ActiveSupport:Module` at
        # `config/initializers/new_framework_defaults.rb:23`. Deleting the line *is* the change: the setting
        # only ever chose between the old behaviour and the new one, and at 5.2 only the new one exists.
        # The ladder does not carry it (its 5.2 step documents cookies and bootsnap), which is why the rule
        # states its own rung and reads the directory itself — `config/initializers/**/*.rb` is a handful of
        # files, and the line can be in any of them.
        setting_removed(subject: "ActiveSupport.halt_callback_chains_on_return_false",
          setting: "ActiveSupport.halt_callback_chains_on_return_false",
          file: "config/initializers/**/*.rb", rung: "5.2.0")
      ].freeze

      # The edits to hand the applier, the subjects a rule *applied*, the subjects it left, and the
      # files a rule's edit depends on — `left` is a subject whose rule exists but whose line the rule
      # would not touch, and it is carried so that a refusal is visible rather than silent.
      #
      # `files` is what a rule that reads more than its own line gets (`Rule#context`), by path, from
      # the same read the scan used — so a rule and the service are looking at the same bytes.
      # **A rule with a `rung` applies only at or above it.** `Gem::Version` does the comparing because
      # these are Rails releases and `"5.10.0" < "5.2.0"` as strings; an unparseable version is a refusal
      # rather than a default, since the rule is the thing that would be wrong.
      def self.rung_reached?(required, target)
        return true if required.to_s.empty?
        return false if target.to_s.empty?

        Gem::Version.new(target.to_s) >= Gem::Version.new(required.to_s)
      rescue ArgumentError
        false
      end

      def self.apply(manual, rules: RULES, files: {}, sources: {}, changes: [], rung: nil)
        # **A rule with a rung applies only when the caller names a target at or above it.** The plan is
        # what normally gates a rule (the ladder says when a change belongs); a rule the ladder does not
        # document states its own rung, and without it the rule would rewrite lines at every earlier rung
        # too — `get :index, params: { … }` is a call Rails 4 reads as a parameter named `params`.
        rules = rules.select { |rule| rung_reached?(rule.rung, rung) }
        # **A subject may have more than one rule, and the first that matches wins.** `MultiJson` is
        # two edits (`dump` and `load`), and a lookup that kept only the last one silently dropped
        # half of it — measured by this file's own test, which is why the rules are grouped rather
        # than indexed.
        by_subject = rules.group_by(&:subject)
        edits = []
        applied = []
        left = []
        scaffolds = []
        satisfied = []
        (Array(manual) + sourced(rules, sources, changes)).each do |entry|
          subject = entry["subject"].to_s
          candidates = by_subject[subject].to_a
          if candidates.empty?
            left << subject
            next
          end

          text = entry["text"].to_s
          masked = mask(text)
          lines = files[entry["path"].to_s]
          chosen = nil
          written = nil
          # A line a rule's own guard recognises as already-migrated is not a line the rule *refused*.
          done_here = false
          candidates.each do |candidate|
            if candidate.satisfied?(text, masked)
              done_here = true
              next
            end

            # **A rule with a `file` matches the raw line**, because the file it names is not Ruby: in
            # `package.json` the quoted text *is* the data, and the mask exists to stop a pattern
            # matching inside a Ruby string.
            written = candidate.after(text, candidate.file ? text : masked, lines: lines, tree: files)
            next if written.nil?

            chosen = candidate
            break
          end
          if written.nil?
            done_here ? satisfied << subject : left << subject
            next
          end

          edits << edit(entry, written)
          applied << subject
          scaffolds << chosen.scaffold if chosen.scaffold
        end
        Result.new(edits: edits, applied: applied, left: left, scaffolds: scaffolds.uniq,
          satisfied: satisfied.uniq)
      end

      # **The bridges this step should declare**, and the two selectors are the two kinds of evidence.
      #
      # **Three kinds of evidence, and each is a different question.** The rung's own change list is the
      # gate for all of them — a bridge declares a gem for a change *this step* carries, never for one
      # another rung owns:
      #
      # * a call site the scan *located* (`evidence` nil) — a change the application does not use needs
      #   no gem declared for it, and declaring one would be installing a library nothing loads;
      # * the rung itself (`:rung`) — for a change whose fix is a declaration and whose evidence does not
      #   exist yet, because `app:update` is what writes it;
      # * a file in the tree (`Evidence`) — for a change the application's own configuration answers.
      #
      # **The rung is a gate, not a convenience**: a bridge whose subject is not in this step's change
      # list is a gem declared for a change the step is not making. `changes` is required for that reason
      # — a caller with only a located list has not said which rung it is walking.
      def self.bridges(manual, changes:, tree: {}, bridges: BRIDGES)
        located = Array(manual).map { |entry| entry["subject"].to_s }.uniq
        in_rung = Array(changes).map { |change| change["subject"].to_s }.uniq
        bridges.select do |bridge|
          next false unless in_rung.include?(bridge.subject)

          case bridge.evidence
          when :rung then true
          when Evidence then tree[bridge.evidence.path].to_s.match?(bridge.evidence.pattern)
          else located.include?(bridge.subject)
          end
        end
      end

      # **What the surveys found**, by subject, for the changes this rung carries. A survey with nothing
      # to read for a subject is asked nothing, and a subject no survey names has no entry — which is
      # what makes "no survey" and "a survey that found nothing" different things in the residue.
      def self.survey(changes, tree:, located: [], surveys: SURVEYS)
        subjects = Array(changes).map { |change| change["subject"].to_s }
        surveys.select { |survey| subjects.include?(survey.subject) }.to_h do |survey|
          entries = Array(located).select { |entry| entry["subject"].to_s == survey.subject }
          [survey.subject, Found.new(sentence: survey.sentence,
            findings: survey.read.call(tree, entries).uniq)]
        end
      end

      # What a survey's findings read as in a decision's reason: the paths and lines, with the first few
      # lines of code beside them, because a reviewer should not have to open three files to see whether
      # a finding is real. Bounded — a residue is read, not paged.
      SURVEY_SHOWN = 5
      def self.findings_sentence(findings)
        shown = findings.first(SURVEY_SHOWN).map { |path, line, text| "#{path}:#{line} `#{text.strip}`" }
        shown << "and #{findings.size - SURVEY_SHOWN} more" if findings.size > SURVEY_SHOWN
        shown.join(", ")
      end

      # The columns a `where(...)`-shaped condition constrains. Both spellings the ladder's own detect
      # pattern accepts are read — `where(active: true)` and `where(:active => true)` — because a survey
      # that knew one would report half the call sites. A key *inside* a nested hash reads as a column
      # here, and that is a false positive the survey can afford: it reports rather than edits, and the
      # cost of one is a line a person looks at rather than a line a machine rewrites.
      def self.scope_columns(text)
        text.scan(/[({,]\s*:?(\w+)\s*(?::|=>)/).flatten.uniq
      end

      # The rules that name no change in the rung's own plan: a rule that outlives its change is dead
      # weight, and a walker that kept applying it would be editing code for a change the ladder no
      # longer documents. A bridge is the same claim about a gem and a survey the same claim about a
      # reader, so all three are reported the same way. Reported rather than removed, because removing
      # one is a decision about this file rather than about a rung.
      def self.inert(changes, rules: RULES, bridges: BRIDGES, surveys: SURVEYS)
        subjects = Array(changes).map { |change| change["subject"].to_s }
        (rules.map(&:subject) + bridges.map(&:subject) + surveys.map(&:subject)).uniq
          .reject { |subject| subjects.include?(subject) }
      end

      # **What would close this change's gap**, for the residue to carry. A change a rule covers needs
      # nothing — unless the rule covers only *some* of its spellings, which is what `PARTIAL` is for.
      # A subject nobody has looked at yet says so in the generic sentence rather than reading as a
      # verdict.
      def self.gap_for(subject, rules: RULES)
        name = subject.to_s
        return PARTIAL[name] if PARTIAL.key?(name)
        return nil if rules.any? { |rule| rule.subject == name }

        GAPS.fetch(name, GENERIC_GAP)
      end

      # A line with its strings' contents and its trailing comment blanked, every other byte exactly
      # where it was. **A deliberate, narrow mirror of the service's mask**
      # (`Upgrade::Scanner.mask`): a client may not depend on the service's package, and the two have
      # to agree about *offsets* rather than about style, which is why the quotes stay and only their
      # contents go.
      #
      # **`#` followed by `{` is interpolation, not a comment**, and that exception is measured:
      # `config.autoload_paths += %W(#{config.root}/lib)` is the line every generated application has
      # and the line the 7.1 change is about, and a mask that blanked from that `#` onward hid the
      # setting from the rule written for it.
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
          elsif char == "#" && line[index + 1] != "{"
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

      # Where this line's comment starts, or nil. **A rule's second half**, and `mask` alone cannot
      # do it: blanking a comment stops a *word* from matching inside it, but `.` matches a blanked
      # byte, so a family that runs to the end of the line still swallows the comment. `Rule#after`
      # refuses a match that reaches past this offset.
      def self.comment_start(line)
        quote = nil
        index = 0
        while index < line.length
          char = line[index]
          if quote
            quote = nil if char == quote && line[index - 1] != "\\"
          elsif char == "#" && line[index + 1] != "{"
            return index
          elsif char == '"' || char == "'"
            quote = char
          end
          index += 1
        end
        nil
      end

      # The scan's own entry, plus what the applier needs to accept it: `automatic` is what the applier
      # checks, and this edit *is* a rewrite — the walker's rather than the service's — so `origin` is
      # what tells the two apart in the record and the patch. `note` is the ladder's own sentence about
      # the change, and it travels into the record with the edit: a rule that applied a change
      # withdraws its decision, and the note is where the caveat a reviewer needs lives.
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
