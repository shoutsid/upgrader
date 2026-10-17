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
    # `argument_wrapped`, `block_value`, `value_moved`, `line_replaced`, `query_materialised`,
    # `superclass_moved`), and the next lighthouse — a gem's own upgrade, a framework nobody has
    # walked yet — writes an instance of a family that already exists rather than a new mechanism.
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
      Rule = Struct.new(:family, :subject, :pattern, :replace, :context, :scaffold, :already,
        keyword_init: true) do
        # The line with this rule applied, or nil when it does not match or changes nothing.
        #
        # The match runs against the *masked* line (strings and comments blanked) and the write
        # against the raw one, at the same offsets — the shape the service's own scanner uses, and
        # the reason the mask preserves every byte's position: a pattern that matched inside a string
        # would rewrite a log message.
        def after(line, masked, lines: nil)
          return nil if already && already.match?(line)

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
          return nil if context && !context.call(Array(lines), found, line)

          region = line[found.begin(0)...found.end(0)]
          written =
            if replace.respond_to?(:call)
              # The region's own match, because the write is against the *raw* line: a capture the
              # masked line matched inside a string is a different one here, and a family that
              # re-matched for itself could see a different extent than the one being replaced.
              own = pattern.match(region)
              own ? replace.call(own) : region
            else
              region.sub(pattern, replace)
            end
          text = "#{line[0, found.begin(0)]}#{written}#{line[found.end(0)..]}"
          text == line ? nil : text
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
      Bridge = Struct.new(:subject, :gems, :group, :why, keyword_init: true)

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
          why: "image_processing is what the macros are built on now; which processor it uses behind that is the application's configuration")
      ].freeze

      Result = Struct.new(:edits, :applied, :left, :scaffolds, keyword_init: true) do
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
                    "argument_wrapped, block_value, value_moved, line_replaced, query_materialised, " \
                    "superclass_moved), or the change has no call site to match at all — a config " \
                    "default, a file a generated application has and this one does not. It is carried " \
                    "as a decision either way, and the change's own note is what says which"

      GAPS = {
        "default_scope" => "a rule would need the callers that chain conditions onto the scope, and " \
                           "whether the merge changes what they read — the candidate patch " \
                           "(`unscope`, `rewhere`, `unscoped`) depends on them",
        "json and hstore columns" => "a rule would need the column's usages to tell a symbol key " \
                                     "from a string one; the patch is per call site",
        "alias_attribute" => "a rule would need the attribute's own definition to write the " \
                             "explicit method the new release wants",
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
        # **The gaps that name a mechanism rather than an edit.** Four of the twenty changes with no
        # call site are not "no rule yet": they need something this tool does not have, and saying which
        # is the point of a gap.
        "bootsnap" => "`app:update` rewrites `config/boot.rb` to require it, so the gem has to be " \
                      "declared — and no call site points at it. This is the bridge the tool does not " \
                      "have yet: one driven by the *plan* rather than by the scan, with a condition " \
                      "over the tree (does `config/boot.rb` require it) instead of a located line",
        "Spring" => "the gem has to *move* (3.0.0 or newer), and a pin that must move is the " \
                    "routing's answer rather than an edit — `POST /releases/route` is what says " \
                    "whether a recorded release fits. An older Spring raises " \
                    "`undefined method 'mechanism='` before the application boots, which reads as an " \
                    "application error",
        "@rails npm packages" => "the fix is in `package.json`, which this tool does not read: the " \
                                 "three packages moved under the `@rails` scope and the build fails " \
                                 "loudly without it",
        "tmp/development_secret.txt" => "a file rename, and the file is git-ignored in most " \
                                        "applications — so this is a note rather than a diff. It " \
                                        "matters because a missing one is *generated* rather than " \
                                        "reported, which silently invalidates the sessions and the " \
                                        "signed URLs of every developer",
        "config.secrets.yml" => "`app:update` writes the file; the initializer's secret has to move " \
                                "*before* `config/initializers/secret_token.rb` goes, or every session " \
                                "in flight is invalidated. The ordering is the decision, which is why " \
                                "this is a gap and not a scaffold",
        "sprockets-rails" => "an application still using the asset pipeline has to add the gem, and " \
                             "*whether this one does* is a fact about the application rather than " \
                             "about a line — the same shape as a bridge, with a condition no scan " \
                             "can answer",
        "schema.rb column order" => "informational: the dump's order changes and a `schema.rb` diff " \
                                    "is large and meaningless for one rung. `structure.sql` preserves " \
                                    "the exact order if the file has to stay quiet",
        "config.i18n.raise_on_missing_translations" => "the default flips, and a line that sets it " \
                                                       "explicitly is unaffected — while a line that " \
                                                       "does not has nothing for a pattern to point at",
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
        "assert_tag" => "the note says the argument shape differs, so a rename would break the " \
                        "assertion rather than move it: a rule would need to rewrite each " \
                        "assertion's arguments, which is reading the test rather than the line",
        "halted_callback_hook" => "the note says a one-argument override raises `ArgumentError` with " \
                                  "no deprecation cycle, so a rule would need the override's own " \
                                  "signature — the line the scan located is the definition, and its " \
                                  "arity is on the next one",
        "config_for" => "the note's replacement is a call on the *result* " \
                        "(`.with_indifferent_access`), which keeps every call site as it is — so " \
                        "what is missing is a rule that edits the assignment rather than the use",
        "the protected_attributes gem" => "the change is the *absence* of a bridge, so the edit is a " \
                                          "Gemfile line to remove — and removing it is only right " \
                                          "once the models have moved to strong parameters, which " \
                                          "is the 4.0 entry's work",
        "button_to" => "the note's fix is `method: :post` or an explicit path helper, and which one " \
                       "is right depends on whether the button is built from a record — a fact " \
                       "about the view rather than about the line",
        "Active Storage variant processor" => "the note's replacement is an application-wide " \
                                              "setting (`config.active_storage.variant_processor`), " \
                                              "so a rule would be choosing the processor for the " \
                                              "deployment rather than for the line"
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
        "Rails.application.secrets" => "the fix is to read a nested *string* key as a symbol " \
                                        "(`secrets[:smtp][\"address\"]` is `secrets[:smtp][:address]`), " \
                                        "and a rule cannot see a string's contents: the mask blanks " \
                                        "them, which is the same property that stops a rule " \
                                        "rewriting a log message",
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
        "find(:all, ...)" => "the rule unwraps `conditions:` and nothing else, because the note's " \
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
                        "because the rule is anchored on the association declaration",
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
      OPTION_VALUE = /(?<value>"[^"]*"|'[^']*'|:[A-Za-z_]\w*|@@?[a-z_]\w*|\$[a-z_]\w*|[A-Za-z_]\w*(?:\.\w+)*)(?=\s*[,)]|\s*\z)/

      # An option that became a nested one: the value is captured, never guessed, and the lookahead
      # requires it to end where an argument ends — a comma, the call's closing parenthesis, or the
      # line. A first version of this pattern matched the `t` of `confirm: t(:x, count: 1)` and
      # produced `data: { confirm: t }(:x, count: 1)`, which is why the lookahead is here.
      def self.option_wrapped(subject:, option:, wrapper:)
        head = /(?::\s*#{Regexp.escape(option)}\s*=>|\b#{Regexp.escape(option)}:)\s*/
        Rule.new(family: :option_wrapped, subject: subject,
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
      def self.option_added(subject:, call:, option:, context: nil)
        key = option[/[a-z_]\w*(?=:)/]
        Rule.new(family: :option_added, subject: subject, context: context,
          pattern: Regexp.new("#{ERB_OPEN.source}(?!.*\\b#{key}:)(?!.*\\bdo\\b)" \
                              "(?<call>#{Regexp.escape(call)}\\b[^,()%<]*?(?:\\s*,\\s*[^,()%<]+?)*)#{ERB_CLOSE.source}"),
          replace: "\\k<open>\\k<call>#{option}\\k<close>")
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
      def self.setting_removed(subject:, setting:)
        Rule.new(family: :setting_removed, subject: subject,
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
      # method that replaces it, and the conditions hash is unwrapped rather than rewritten. Anything
      # else in the options (`order:`, `limit:`, a second key) does not match, because the note's
      # replacement is the conditions alone and a rule that dropped the other options would be
      # changing what the query returns.
      def self.find_conditions(subject:, finder: "find")
        Rule.new(family: :find_conditions, subject: subject,
          pattern: /#{Regexp.escape(finder)}\(\s*:(?<scope>all|first|last)\s*,\s*conditions:\s*\{(?<conditions>[^{}]*)\}\s*\)/,
          replace: lambda do |found|
            format(FIND_SCOPES.fetch(found[:scope].to_sym), conditions: found[:conditions].strip)
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
          context: lambda do |lines, found, _raw|
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
          context: ->(_lines, _found, raw) { raw.match?(/#{Regexp.escape("constantize")}\(\s*["']/) }),
        call_inverted(subject: "ActiveSupport::Dependencies private API",
          receiver: "ActiveSupport::Dependencies", call: "safe_constantize",
          to: "\\k<value>.safe_constantize",
          context: ->(_lines, _found, raw) { raw.match?(/safe_constantize\(\s*["']/) }),

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
          to: "config.autoload_lib(ignore: %w(assets tasks))")
      ].freeze

      # The edits to hand the applier, the subjects a rule *applied*, the subjects it left, and the
      # files a rule's edit depends on — `left` is a subject whose rule exists but whose line the rule
      # would not touch, and it is carried so that a refusal is visible rather than silent.
      #
      # `files` is what a rule that reads more than its own line gets (`Rule#context`), by path, from
      # the same read the scan used — so a rule and the service are looking at the same bytes.
      def self.apply(manual, rules: RULES, files: {})
        # **A subject may have more than one rule, and the first that matches wins.** `MultiJson` is
        # two edits (`dump` and `load`), and a lookup that kept only the last one silently dropped
        # half of it — measured by this file's own test, which is why the rules are grouped rather
        # than indexed.
        by_subject = rules.group_by(&:subject)
        edits = []
        applied = []
        left = []
        scaffolds = []
        Array(manual).each do |entry|
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
          candidates.each do |candidate|
            written = candidate.after(text, masked, lines: lines)
            next if written.nil?

            chosen = candidate
            break
          end
          if written.nil?
            left << subject
            next
          end

          edits << edit(entry, written)
          applied << subject
          scaffolds << chosen.scaffold if chosen.scaffold
        end
        Result.new(edits: edits, applied: applied, left: left, scaffolds: scaffolds.uniq)
      end

      # **The bridges for the changes the scan located.** Driven by what the scan found rather than by
      # the rung's whole change list, because a bridge is about call sites: a change this application
      # does not use needs no gem declared for it, and declaring one would be installing a library
      # nothing loads.
      def self.bridges(manual, bridges: BRIDGES)
        subjects = Array(manual).map { |entry| entry["subject"].to_s }.uniq
        bridges.select { |bridge| subjects.include?(bridge.subject) }
      end

      # The rules that name no change in the rung's own plan: a rule that outlives its change is dead
      # weight, and a walker that kept applying it would be editing code for a change the ladder no
      # longer documents. A bridge is the same claim about a gem, so it is reported the same way.
      # Reported rather than removed, because removing one is a decision about this file rather than
      # about a rung.
      def self.inert(changes, rules: RULES, bridges: BRIDGES)
        subjects = Array(changes).map { |change| change["subject"].to_s }
        (rules.map(&:subject) + bridges.map(&:subject)).uniq.reject { |subject| subjects.include?(subject) }
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
