# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # **A gem's own upgrade can require an edit to the application's code, and the Gemfile is not
    # where that fact lives.**
    #
    # The digest moves a Gemfile line and the routing says which line to move it to; both are claims
    # about an index, and both are answered by rewriting one declaration. Some moves do not stop
    # there: the gem's own upgrade changes what the application's files must say, and no Rails release
    # documents it because the reason is the gem's. Measured on the lighthouse at the 5.0 rung:
    # moving `rspec-rails` to the 3.x line, which Rails 5 forces because 2.14.2's
    # `controller_example_group.rb` calls `named_routes.helpers`, takes the suite from 47 failures to
    # **133** — every controller spec loses `sign_in` and every routing spec loses `route_to`, because
    # rspec-rails 3 stopped inferring an example group's `type` from the class it describes and from
    # the directory a spec is in, and this application includes `Devise::TestHelpers` for
    # `type: :controller` only. Adding `config.infer_spec_type_from_file_location!` takes it to **3**,
    # and the three `expect { }.not_to change { }.by(N)` call sites (which rspec 3 refuses outright)
    # take it to **0**. A walk that moved the Gemfile line and stopped would call that rung failed and
    # hand a person four sentences with no mechanism behind any of them.
    #
    # So a companion is *the rule of a gem's own upgrade*, keyed to the move that makes it necessary
    # rather than to a ladder change — there is no ladder change, because the failure is in the gem's
    # code and not Rails'. Its edits are the same applier edits every other repair is (line-checked,
    # recorded, in the patch), and they are applied at the **gems** stage: after the baseline, so a
    # suite that is still on the old Rails is measured against the old gem, and before the pin, so the
    # suite the pin leaves behind already carries them.
    #
    # Two shapes, because these two changes are two shapes:
    #
    # * a `Rewrites::Rule`, for a line the application already has (`not_to change(...).by(1)`);
    # * an `Insert`, for a line it does not (`config.infer_spec_type_from_file_location!`). A rule
    #   cannot express that one: its idempotence guard reads the line it matched, and this edit's
    #   evidence is on the *next* line, which a rule never sees.
    module Companions
      # One edit, in the applier's own vocabulary.
      Edit = Struct.new(:path, :line, :text, :after, :subject, :note, keyword_init: true) do
        def to_h
          {
            "path" => path, "line" => line, "text" => text, "after" => after,
            "automatic" => true, "origin" => "companion", "subject" => subject, "note" => note
          }
        end
      end

      # A line the file does not have yet, anchored on a line it does. Absent anchor or a file that
      # already carries the line is `nil` rather than an edit: the first is an application that does
      # not keep its rspec configuration there, and the second is a move a person already finished.
      #
      # **`marker` is the evidence, and for a one-line insert it is the line itself.** A *block* is
      # several lines and its evidence is one of them: a check that looked for the whole block among
      # the file's lines would never find it — the file stores lines, not blocks — so a second pass
      # over a tree the first pass had already fixed would insert it again. The field defaults to
      # `line` (nil means "the line is its own evidence"), which is why the one-line inserts below
      # never mention it.
      #
      # **`types` is the third shape: content the application's own tree decides.** A line whose text
      # depends on which directories an application has cannot be data, so an insert that names a
      # `types` table is computed at edit time — one call per directory that is actually there — and
      # each call is guarded by itself, because a person who fixed one of them has fixed that one.
      Insert = Struct.new(:path, :anchor, :line, :note, :marker, :types, keyword_init: true)

      # The move that needs the edits, and the edits themselves.
      Entry = Struct.new(:gem, :requirement, :subject, :note, :globs, :inserts, :rules,
        keyword_init: true)

      # The one gem move the walk has needed so far. `requirement` is the digest's own line, and a test
      # holds the two together: a digest that moves the line without moving this is an application that
      # gets the Gemfile rewritten and its suite left broken.
      RSPEC_RAILS_THREE = Entry.new(
        gem: "rspec-rails",
        requirement: "~> 3.5.0",
        subject: "rspec-rails 3",
        note: "rspec-rails 3 no longer infers an example group's type from the class it describes or " \
              "from the directory a spec is in, and rspec 3 refuses `expect { }.not_to change { " \
              "}.by(N)`; measured at the 5.0 rung, the move alone took the suite from 47 failures " \
              "to 133 (`sign_in` and `route_to`), the inference call to 3, and the three call sites " \
              "below to 0",
        globs: %w[spec/**/*_spec.rb],
        inserts: [
          Insert.new(
            path: "spec/spec_helper.rb",
            anchor: "RSpec.configure do |config|",
            line: "  config.infer_spec_type_from_file_location!",
            note: "rspec-rails 3 does not infer an example group's type from its class or its " \
                  "directory unless this is asked for; without it this application's " \
                  "`spec/support/devise.rb` — which includes `Devise::TestHelpers` for " \
                  "`:type => :controller` — stops applying and every controller spec raises " \
                  "`undefined method `sign_in'`"
          ),
          # The other place a generated rspec-rails 3 application puts the block. An absent file is no
          # edit, so naming both costs a file read and covers the application that moved its
          # configuration when it upgraded — and an application that keeps the block in *both* gets the
          # call in both, which is harmless because the setting is idempotent.
          Insert.new(
            path: "spec/rails_helper.rb",
            anchor: "RSpec.configure do |config|",
            line: "  config.infer_spec_type_from_file_location!",
            note: "rspec-rails 3 does not infer an example group's type unless this is asked for; " \
                  "an application on `rails_helper.rb` asks for it there"
          )
        ],
        rules: [
          Rewrites::Rule.new(
            family: :argument_dropped,
            subject: "rspec-rails 3",
            # `not_to change(...).by(N)` is not "the count did not move by N" in rspec 3, it is an
            # error: a negated change matcher with a delta cannot be evaluated. The examples mean "no
            # record was written", which is exactly the matcher without the delta. **Both spellings of
            # the negation, and both forms of the matcher**: this application writes
            # `lambda { … }.should_not change(Item, :count).by(1)`, and an application that has moved to
            # rspec 3's own syntax writes `expect { … }.not_to change { Item.count }.by(1)` — a rule
            # that knew only the first would leave the second failing with the same NotImplementedError.
            # `all: true` because a one-line example can carry two of them, and a rule that rewrote the
            # first and reported the line applied would leave the second failing.
            pattern: /(?<call>\.(?:should_not|not_to)\s+change(?:\([^)]*\)|\s*\{[^{}]*\}))\s*\.by\(\s*-?\d+\s*\)/,
            replace: '\k<call>',
            all: true
          )
        ]
      )

      # **The spec directories rspec-rails does not infer a `type` from, and the type each one means.**
      # `infer_spec_type_from_file_location!` matches the *plural* names a generated application has —
      # measured in rspec-rails 3.5.2, the pattern is `Regexp.compile(%w[spec models].join('[\\/]') +
      # '[\\/]')`, so `spec/model/` is not it. An application of this era wrote the singular, and its
      # example groups then carry **no type at all**, which is invisible until a gem starts filtering by
      # one: rspec-rails' own example-group modules and every shoulda-matchers library are included with
      # `type:`, so a group with no type loses its model helpers and every matcher with them. Measured
      # at the 7.0 rung: this application's `spec/model/*_spec.rb` is **all 26** of its baseline's
      # failures. `routing` is absent on purpose — rspec-rails spells it the same way in both places, so
      # that directory *is* inferred from.
      SINGULAR_SPEC_DIRECTORIES = {
        "model" => "model", "controller" => "controller", "mailer" => "mailer",
        "helper" => "helper", "job" => "job", "view" => "view", "feature" => "feature",
        "request" => "request"
      }.freeze

      # The block shoulda-matchers 3.0 onward tells an application to add to its test helper, in the
      # gem's own words: its `MissingTestFramework#validate!` prints exactly this, and its README
      # carries it. Nothing here is a choice — the gem will not include a single matcher until it is
      # told which test framework and which library to integrate with.
      SHOULDA_CONFIGURATION = <<~RUBY.chomp
        Shoulda::Matchers.configure do |config|
          config.integrate do |with|
            with.test_framework :rspec
            with.library :rails
          end
        end
      RUBY

      # **A gem that stopped including its own matchers, so the suite is red before the rung's move
      # is even measured.** Measured at the 7.0 rung, which is the first to run on the 2.7 era: the
      # era forces this gem's line off 2.8.0 (2.8.0 calls `BigDecimal.new`, removed in Ruby 2.7, in a
      # class body it loads at boot — the digest's `~> 4.1` entry), and **shoulda-matchers 3.0 stopped
      # including its matchers automatically**. From 3.0 the suite has to configure it, and this 2013
      # application never had to, because 2.x did it for you. Without the block the matcher methods are
      # simply absent from the example group: 16 of the rung's 17 baseline failures are
      # `NoMethodError: undefined method `validate_presence_of'` and `undefined method
      # `validate_uniqueness_of'` from `spec/model/*`, and one more is `expected #<User:…> to respond to
      # `has_many?'`. A rung cannot be verified on a red baseline — "the suite was not green before this
      # step, so what it says afterwards cannot be attributed to the move" — so this is the difference
      # between the walk reaching 7.0 and stopping at 6.1.
      #
      # **The anchor is the require that loads the test framework, and that is causal rather than
      # convenient.** `Shoulda::Matchers.configure` resolves `:rspec` through the gem's own registry,
      # so the framework has to be loaded before the block runs; the line that loads it is the one line
      # every rspec helper has. An application that spells it another way gets no edit rather than a
      # block in the wrong place, and `placed?` is what lets the caller say so.
      SHOULDA_MATCHERS = Entry.new(
        gem: "shoulda-matchers",
        requirement: "~> 4.1",
        subject: "shoulda-matchers 3",
        note: "shoulda-matchers 3.0 stopped including its matchers automatically, so the suite has " \
              "to carry a `Shoulda::Matchers.configure` block **and give its example groups a " \
              "`type`** — every library is included with one, and rspec-rails infers a type only from " \
              "the plural directory names; measured at the 7.0 rung, its absence is all 26 baseline " \
              "failures on the 2.7 era",
        globs: %w[app/models/**/*.rb spec/model/**/*_spec.rb config/initializers/devise.rb],
        inserts: [
          Insert.new(
            path: "spec/spec_helper.rb",
            anchor: "require 'rspec/rails'",
            line: SHOULDA_CONFIGURATION,
            marker: "Shoulda::Matchers.configure do |config|",
            note: "shoulda-matchers 3.0 includes no matcher until the suite says which test " \
                  "framework and which library to integrate with; this application's " \
                  "`spec/spec_helper.rb` requires `rspec/rails` and never configured the gem, " \
                  "because 2.8.0 did it for you"
          ),
          # The other place a generated rspec suite keeps its helper. An absent file is no edit, so
          # naming both costs a file read and covers the application that moved its configuration
          # when it upgraded — and an application that carries the block in *both* is configured
          # twice, which is idempotent because the second call replaces the first's integration.
          Insert.new(
            path: "spec/rails_helper.rb",
            anchor: "require 'rspec/rails'",
            line: SHOULDA_CONFIGURATION,
            marker: "Shoulda::Matchers.configure do |config|",
            note: "shoulda-matchers 3.0 includes no matcher until the suite configures it; an " \
                  "application on `rails_helper.rb` configures it there"
          ),
          # **The second half of the same move, and the half the gem's own documentation does not
          # mention.** Configuring the gem is necessary and not sufficient: every shoulda-matchers
          # library is included with a `type:`, so an example group with no type has no matchers
          # whatever the configuration says. Measured at the 7.0 rung, where the block alone left the
          # baseline red with the *same* 26 failures, all of them `spec/model/*`.
          Insert.new(
            path: "spec/spec_helper.rb",
            anchor: "RSpec.configure do |config|",
            line: nil,
            types: SINGULAR_SPEC_DIRECTORIES,
            note: "shoulda-matchers' libraries are included with `type:`, and rspec-rails infers a " \
                  "type only from the plural directory names (`spec/models`, `spec/controllers`), so " \
                  "this application's `spec/model` specs have no type and no matchers — the gem's own " \
                  "configuration block is not enough on its own"
          ),
          Insert.new(
            path: "spec/rails_helper.rb",
            anchor: "RSpec.configure do |config|",
            line: nil,
            types: SINGULAR_SPEC_DIRECTORIES,
            note: "shoulda-matchers' libraries are included with `type:`, so a suite whose spec " \
                  "directories are named in the singular derives them here"
          )
        ],
        rules: [
          # **The association has to say it too.** `RequiredMatcher` does not accept a
          # `validates_presence_of` as proof: it asks for the error Rails' own `required:` produces
          # (the `:required` key, where a presence validation adds `:blank`), so `Bid#item` and
          # `Item#user` have to declare what their presence validations already mean. That is the same
          # fact in the association's own vocabulary, and it is the Rails 5.0 default
          # (`belongs_to_required_by_default`, a `default_changed` change this ladder carries) that this
          # application never adopted — its models were written the 4.2 way, with the validation beside
          # the association. Measured: with `required: true` here, `.required(true)` in the spec passes.
          Rewrites::Rule.new(
            family: :option_added,
            subject: "shoulda-matchers 3",
            pattern: /(?<call>belongs_to\s+:(?<assoc>\w+)(?<rest>[^\n]*))$/,
            replace: '\k<call>, required: true',
            already: /required:\s*(?:true|false)/,
            context: ->(lines, found, _line, _tree) {
              Companions.presence_validated?(lines, found[:assoc])
            }
          ),
          # **The model's own proc has to stop raising, and this is the one edit no spec can make.**
          # 3.0's `belong_to` asks whether the record is valid with the association unset — it *nulls*
          # it — and this application's `greater_than_or_equal_to: Proc.new { |bid|
          # bid.item.min_bid_amount.to_f }` then calls a method on nil. Measured, that is the failure
          # for **both** `belong_to` examples, and no `subject` can avoid it, because the matcher is
          # what removes the item. Guarding the *validation* with `if: :item` was measured first and is
          # wrong: it skips the check that `validate_numericality_of(:amount)` asserts, turning a
          # passing example into a failing one. So the proc itself answers for the absent association,
          # with the floor that means "no minimum to meet" — the missing item is already reported by
          # `validates_presence_of :item`, so this branch decides nothing else.
          Rewrites::Rule.new(
            family: :block_value,
            subject: "shoulda-matchers 3",
            pattern: /(?<proc>Proc\.new \{ \|(?<var>\w+)\| \k<var>\.(?<assoc>\w+)\.(?<rest>[^}]*)\})/,
            replace: ->(match) {
              "Proc.new { |#{match[:var]}| #{match[:var]}.#{match[:assoc]} ? " \
              "#{match[:var]}.#{match[:assoc]}.#{match[:rest].strip} : 0 }"
            },
            already: /Proc\.new \{ \|\w+\| \w+\.\w+ \? /
          ),
          # **The three edits 3.0 makes necessary in the application's own files, each measured on
          # the rung's baseline and each derived from the application rather than assumed.** With the
          # block above in place the baseline is down to three failures, and every one of them is a
          # fact this application states somewhere else.
          #
          # The first is what 3.0 changed about *every* matcher that validates a record: it uses the
          # example group's `subject`, and this application's is RSpec's implicit `Bid.new` — which is
          # **invalid** (no item, no amount). 2.x's matchers never validated the record, so that was
          # invisible; 3.0's ask the record whether it is valid with an association unset, and an
          # invalid one answers nothing. **The fix is the application's own definition of a valid
          # record — its factory** — which repairs `belong_to(:user)` without touching the model.
          Rewrites::Rule.new(
            family: :option_added,
            subject: "shoulda-matchers 3",
            pattern: /^(?<describe>describe (?<model>[A-Z]\w*) do)$/,
            replace: ->(match) {
              "#{match[:describe]}\n  subject { FactoryGirl.build(:#{Companions.underscore(match[:model])}) }"
            },
            context: ->(lines, _found, _line, _tree) {
              !Array(lines).any? { |each| each.match?(/^\s*subject\s*[{(]/) }
            }
          ),
          # `belong_to` in 3.0 compares the matcher's `required:` with what the *record does* — and its
          # default comes from `RailsShim.belongs_to_required_by_default?`, which is nil for an
          # application that never ran `load_defaults`, so the matcher asks that the record be *valid*
          # with the association unset. This application's `Bid` fails validation for `:item` and not
          # for `:user`, and its own files say so: `validates_presence_of :item` beside
          # `belongs_to :item`, and `belongs_to :user, optional: true`. The rule asks the model the spec
          # describes, which is the only place that fact is written down.
          Rewrites::Rule.new(
            family: :option_added,
            subject: "shoulda-matchers 3",
            pattern: /(?<call>belong_to\(:(?<assoc>\w+)\))(?!\.)/,
            replace: '\k<call>.required(true)',
            context: ->(lines, found, _line, tree) {
              Companions.association_is_required?(lines, found[:assoc], tree)
            }
          ),
          # And `validate_uniqueness_of` compares its own case-sensitivity with the validation's — in
          # 4.x the option is spelled **`case_insensitive`**, which the first run measured by asking
          # for `case_sensitive(false)` and being told so. This application's email uniqueness is
          # **devise's**, not its own — `User` declares `validates_uniqueness_of(:username)` and nothing
          # for email, which `devise :validatable` validates case-insensitively (devise's default
          # `case_insensitive_keys` is `[:email]`, and an application that configured it says so in its
          # initializer). Without the option the matcher asserts something the model does not do, which
          # is what the failure says: it expected the case-swapped address to be valid, and the record
          # rejected it.
          Rewrites::Rule.new(
            family: :option_added,
            subject: "shoulda-matchers 3",
            pattern: /(?<call>validate_uniqueness_of\(:(?<attr>\w+)\))(?!\.)/,
            replace: '\k<call>.case_insensitive',
            context: ->(lines, found, _line, tree) {
              Companions.devise_validates_case_insensitively?(lines, found[:attr], tree)
            }
          )
        ]
      )

      # **The names a factory body's DSL answers to, so that everything else is an attribute.** Measured
      # in factory_bot 4.11.1's `DefinitionProxy`: the methods it defines (`add_attribute`, `ignore`,
      # `transient`, `sequence`, `association`, `to_create`, `skip_create`, `factory`, `trait`,
      # `initialize_with`), the three it delegates to the definition (`before`, `after`, `callback`), and
      # the handful it deliberately leaves unproxied so they reach the real object (`send`, `method`,
      # `raise`, `extend`, `instance_eval`, `caller`, `object_id`). The proxy undefines every other
      # inherited method, so a name that is not here goes to `method_missing` — and `method_missing` with
      # an argument and no block is `add_attribute`, which is the static-attribute path.
      FACTORY_PROXY_METHODS = %w[
        add_attribute ignore transient sequence association to_create skip_create factory trait
        initialize_with before after callback send method raise extend instance_eval caller object_id
      ].freeze

      # **A gem the framework deprecated by name, whose successor is the same code under a new one — and
      # the code has to be renamed with it.** Measured at the 7.2 rung: `app:update` dies inside
      # `Bundler.require` with `factory_girl-4.9.0/lib/factory_girl.rb:158: private method `warn' called
      # for ActiveSupport::Deprecation:Class`, which Rails 7.2 made private. `factory_girl_rails`'s last
      # release is 4.9.0 and `factory_bot_rails` is the same gem renamed; the application has **93**
      # `FactoryGirl` call sites — the factories, the specs, and `spec_helper`'s
      # `config.include FactoryGirl::Syntax::Methods` — so the line and the code move together.
      #
      # **A whole-word rename, and nothing cleverer.** The two names differ by one word, so a rule that
      # rewrote `FactoryGirl` wherever it appears as a constant is the whole change; `FactoryBot` inside a
      # string or a symbol is not this gem's business and a word-boundary pattern leaves it alone.
      #
      # **And the gem's own deprecation is the second half, which no rename reaches.** Measured: every
      # *resolvable* 4.x release calls `ActiveSupport::Deprecation.warn` — 4.8.2, 4.10.0, 4.11.0 and 4.11.1
      # have three call sites each, and 4.9.0, the only release with none, is yanked and cannot be resolved
      # — and the one this application reaches is 4.11.1's `warn_static_attribute_deprecation`: `app:update`
      # dies at `spec/factories/api/admin_factory.rb:5`, whose `password 'password'` is a static attribute. The
      # gem's own message is the edit — "Static attributes will be removed in FactoryBot 5.0. Please use
      # dynamic attributes instead by wrapping the attribute value in a block" — so this is not a workaround
      # for the warning, it is the change the release asks for and the one 5.0 will otherwise break.
      FACTORY_BOT = Entry.new(
        gem: "factory_girl_rails",
        requirement: "~> 4.9",
        subject: "factory_bot",
        note: "factory_girl was renamed factory_bot, and the application's 93 `FactoryGirl` call sites " \
              "have to move with the line; measured at the 7.2 rung, the gem's own static-attribute " \
              "deprecation then reaches Rails 7.2's private `ActiveSupport::Deprecation.warn` from " \
              "`spec/factories/api/admin_factory.rb:5`, so the static attributes become dynamic ones — the " \
              "change the deprecation asks for, and the one FactoryBot 5.0 requires",
        globs: %w[app/**/*.rb config/**/*.rb lib/**/*.rb spec/**/*.rb test/**/*.rb],
        inserts: [],
        rules: [
          Rewrites::Rule.new(
            family: :name_moved,
            subject: "factory_bot",
            pattern: /\bFactoryGirl\b/,
            replace: "FactoryBot",
            all: true
          ),
          # **And the gem's *name* moves too, which the constant rule cannot see.** Measured at the 7.2
          # rung, once the suite got past its first failure: `Failure/Error: require 'factory_girl_rails'`
          # → `LoadError: cannot load such file -- factory_girl_rails` from `spec/spec_helper.rb:12`. The
          # rename is a fact about the gem, so the application's own `require` has to move with the line —
          # and the *load path* is what makes it a real failure rather than a stale one: the baseline runs
          # with the lock that still holds the old gem, and the suite runs with the lock the pin wrote.
          #
          # **A string's contents are not visible to a pattern, so the pattern asks the shape and the
          # callable asks the name.** The mask blanks what is inside the quotes and keeps the quotes, so
          # the pattern can match a `require "…"` line but cannot tell which gem it names; the callable
          # receives the *raw* region (that is what makes a respelling rule possible at all), and a
          # replacement that changes nothing leaves the line alone rather than writing it back. The
          # condition is the third reader: it sees the raw line, which is the only place the old name is.
          Rewrites::Rule.new(
            family: :name_moved,
            subject: "factory_bot",
            pattern: /\A(?<indent>[ \t]*)(?<call>require\s+(?<quote>["'])[^"']*\k<quote>)/,
            replace: ->(found) { "#{found[:indent]}#{found[:call].sub("factory_girl", "factory_bot")}" },
            context: ->(_lines, _found, line, _tree) { line.to_s.match?(/require\s+["']factory_girl/) }
          ),
          # **A static attribute becomes a dynamic one, which is the deprecation's own prescription.**
          # The gem decides this from the *call*, not from the line: `method_missing` with an argument and
          # no block is `add_attribute`, and `add_attribute` warns when it has a value and no block. So the
          # rule is "a name that is not the DSL, given a complete single-line value, and not already
          # wrapped in a block" — and every exclusion below is one of the gem's own branches rather than a
          # guess about style.
          Rewrites::Rule.new(
            family: :block_value,
            subject: "factory_bot",
            pattern: /\A(?<indent>[ \t]*)(?<name>[a-z_]\w*)[ \t]+(?<value>\S.*?)[ \t]*\z/,
            replace: ->(found) { "#{found[:indent]}#{found[:name]} { #{found[:value]} }" },
            already: /\A[ \t]*[a-z_]\w*[ \t]+\{/,
            context: ->(lines, found, _line, _tree) {
              Companions.factory_file?(lines) &&
                Companions.static_attribute?(found[:name], found[:value])
            }
          )
        ]
      )

      # **The require has to be before `require "rails"`, not merely in the bundle.** Rails 7.0's
      # `active_support` names `Logger` while it loads, and the application's own `Bundler.require`
      # comes after `require "rails"` — so a `gem "logger"` line alone is in the bundle but not
      # required yet. Concurrent-ruby stopped requiring it, and Rails 7.1.5 added the require
      # upstream; this companion carries that line into the application's own file.
      LOGGER = Entry.new(
        gem: "logger",
        requirement: "~> 1.4",
        subject: "logger",
        note: "Rails 7.0's activesupport names Logger while it loads; concurrent-ruby 1.3.4 stopped " \
              "requiring it, and the application's Bundler.require runs after `require \"rails\"`, " \
              "so the require has to be written before it",
        globs: %w[config/application.rb],
        inserts: [
          Insert.new(
            path: "config/application.rb",
            anchor: 'require_relative "boot"',
            line: 'require "logger"',
            note: "loads the logger gem before `require \"rails\"` reaches activesupport, where " \
                  "`Logger` is named before the application's own Bundler.require has run"
          )
        ],
        rules: []
      )

      # **devise-two-factor 6 moved its OTP secret onto Active Record Encryption.** The gem used to
      # bring `attr_encrypted`; from 6 it calls `ActiveRecord::Encryption` directly, whose credentials
      # are absent in a test environment and whose missing-key error is raised on the first `User#save!`
      # — measured at the 7.1 rung as three 2FA controller failures and fifteen `Person.search`
      # failures, all from a user save rather than from the search. The keys below are deterministic
      # test material; production still supplies its own, which is why this is a test-environment
      # insert rather than a change to the application's credentials.
      DEVISE_TWO_FACTOR_SIX = Entry.new(
        gem: "devise-two-factor",
        requirement: "~> 6.3.1",
        subject: "devise-two-factor 6",
        note: "devise-two-factor 6 encrypts the OTP secret with Active Record Encryption, so a " \
              "test environment needs the three keys; the failure is a user save, not a search",
        globs: %w[config/environments/test.rb],
        inserts: [
          Insert.new(
            path: "config/environments/test.rb",
            anchor: "Rails.application.configure do",
            line: "  # devise-two-factor 6 encrypts otp_secret with Active Record Encryption.\n  " \
                  "# These are deterministic test keys; production supplies its own credentials.\n  " \
                  "config.active_record.encryption.primary_key = " \
                  "\"0123456789abcdef0123456789abcdef\"\n  " \
                  "config.active_record.encryption.deterministic_key = " \
                  "\"fedcba9876543210fedcba9876543210\"\n  " \
                  "config.active_record.encryption.key_derivation_salt = " \
                  "\"00112233445566778899aabbccddeeff\"",
            marker: "config.active_record.encryption.primary_key = " \
                    "\"0123456789abcdef0123456789abcdef\"",
            note: "devise-two-factor 6 stores the OTP secret with Active Record Encryption; without " \
                  "the keys every User#save! raises, and the failure surfaces in unrelated specs"
          )
        ],
        rules: []
      )

      ENTRIES = [RSPEC_RAILS_THREE, SHOULDA_MATCHERS, FACTORY_BOT, LOGGER, DEVISE_TWO_FACTOR_SIX].freeze

      class << self
        # The companion for a move, or nil. The requirement is matched exactly: the digest's line *is*
        # the one this was measured against, and a test says so.
        def for(gem, requirement)
          ENTRIES.find do |entry|
            entry.gem == gem.to_s && entry.requirement == requirement.to_s
          end
        end

        # The edits this move needs, already guarded against a tree that has them.
        def edits(entry, root:)
          files = read(entry.globs, root: root)
          Array(entry.inserts).filter_map { |insert| insertion(insert, entry: entry, root: root) } +
            rule_edits(entry, files)
        end

        # **Whether the application already carries what the companion asks for, so a caller can
        # tell "nothing to do" from "nothing could be done".** `edits` returns an empty list both
        # when the file already has the insert and when no file here carries its anchor, and those
        # are opposite facts: the first is a move a person finished, and the second is a suite that
        # will stay red with nothing in the record saying why. Measured at the 7.0 rung, where the
        # whole point of the companion is a *baseline* that runs before any of the rung's own work.
        def placed?(entry, root:)
          Array(entry.inserts).any? do |insert|
            path = File.join(root, insert.path)
            next false unless File.file?(path)

            carries?(File.read(path, encoding: "utf-8").lines.map(&:chomp), insert, root: root)
          end
        end

        # The model file a spec file describes: the first `describe <Constant> do` in it, underscored —
        # `Item` is `app/models/item.rb`. `underscore` is ActiveSupport's rule written out, because this
        # directory is stdlib only.
        def model_source(lines, tree)
          described = Array(lines).filter_map { |line| line[/^\s*describe\s+([A-Z]\w*)\s+do\s*$/, 1] }.first
          return nil if described.nil?

          tree["app/models/#{underscore(described)}.rb"]
        end

        def underscore(name)
          name.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
        end

        # Whether the model's own file validates the presence of this association. That is the
        # application saying the association may not be absent — the same fact as `required: true`, in
        # the vocabulary 4.2 used, which is why the rule above can move it to the other one.
        def presence_validated?(lines, name)
          Array(lines).any? { |line| line.match?(/validates_presence_of[^\n]*:#{Regexp.escape(name)}\b/) }
        end

        # Whether the model's own files say the record *fails validation* with this association unset.
        # That is what 3.0's `belong_to` compares against, and in this application's idiom it is a
        # `validates_presence_of` for the association — `belongs_to :item` alone is not enough, because
        # an application that never ran `load_defaults` does not make a `belongs_to` required.
        # `optional: true` is the application saying the opposite, and it wins.
        def association_is_required?(lines, name, tree)
          source = model_source(lines, tree)
          return false if source.nil?

          joined = Array(source).join("\n")
          return false if joined.match?(/^\s*belongs_to\s+:#{Regexp.escape(name)}\b[^\n]*optional:\s*true/)

          joined.match?(/validates_presence_of[^\n]*:#{Regexp.escape(name)}\b/)
        end

        # Whether devise is what validates this attribute, and whether it does so case-insensitively.
        # `devise :validatable` is the line that makes the model validate it at all; which attributes
        # it treats case-insensitively is devise's own setting, `[:email]` by default and whatever the
        # application's initializer says when it says anything.
        def devise_validates_case_insensitively?(lines, attribute, tree)
          source = model_source(lines, tree)
          return false if source.nil?

          # **The `devise` call is several lines in this application** — `:validatable` is on its
          # second — so the question is asked of the joined source, not of one line. Measured: a
          # single-line pattern missed it and the rule silently did nothing.
          return false unless Array(source).join("\n").match?(/^\s*devise\b[^)]*:validatable/)

          configured = Array(tree["config/initializers/devise.rb"]).find do |line|
            line.match?(/^\s*config\.case_insensitive_keys\s*=/)
          end
          keys = configured ? configured.scan(/:(\w+)/).flatten : ["email"]
          keys.include?(attribute.to_s)
        end

        # **A file whose body is a factory definition, because the shape this rule rewrites is ordinary
        # Ruby everywhere else.** `name value` → `name { value }` is what a static attribute needs, and
        # `return foo` and `raise "x"` are the same shape: the rule has to know it is inside a factory
        # rather than guess from the line, and the file's own `FactoryBot.define` is the fact that says so.
        def factory_file?(lines)
          Array(lines).any? { |line| line.match?(/^\s*(?:FactoryGirl|FactoryBot)\.define\b/) }
        end

        # **Whether this line is an attribute the gem will call static, by the gem's own rule.** See
        # `FACTORY_PROXY_METHODS` for the names that are the DSL rather than an attribute. The rest is the
        # shape of a complete single-line value: a value that opens a block, a call or an array is not this
        # shape, `factory:` is the gem's own association branch, and a value that ends in an operator, a
        # comma or `do` is a continuation — `description "a" +` must not become `description { "a" + }`.
        def static_attribute?(name, value)
          return false if FACTORY_PROXY_METHODS.include?(name.to_s)

          text = value.to_s.strip
          return false if text.empty? || text.start_with?("{", "(", "[", "|")
          return false if text.match?(/\bfactory:/) || text.match?(/\bdo\s*\z/)
          return false if text.end_with?(",", "+", "-", "*", "/", "%", "|", "&", "=", ":", "\\", ".", "(")

          true
        end

        private

        def read(globs, root:)
          Array(globs).flat_map { |glob| Dir.glob(glob, base: root).sort.first(Rewrites::SOURCE_LIMIT) }
            .uniq
            .filter_map do |path|
              full = File.join(root, path)
              [path, File.file?(full) ? File.read(full, encoding: "utf-8").lines.map(&:chomp) : nil]
            end.to_h
        end

        def insertion(insert, entry:, root:)
          path = File.join(root, insert.path)
          return nil unless File.file?(path)

          lines = File.read(path, encoding: "utf-8").lines.map(&:chomp)
          return nil if carries?(lines, insert, root: root)

          index = lines.index { |line| line.strip == insert.anchor.strip }
          return nil if index.nil?

          body = insert.line || derived_types(insert, root: root, lines: lines).join("\n")
          return nil if body.to_s.strip.empty?

          Edit.new(path: insert.path, line: index + 1, text: lines[index],
            after: "#{lines[index]}\n#{body}", subject: entry.subject,
            note: insert.note)
        end

        # Whether a file already carries an insert — the marker where the insert names one, the line
        # itself where it does not, and *every* derived call where the content is the application's
        # own. An empty `lines` asks the question of the derived calls themselves rather than of the
        # file, which is how `placed?` reads it. **An insert with nothing to derive is not "placed"**:
        # an application with no singular spec directory owes this companion nothing *here*, and a
        # vacuously-true answer would let `placed?` report the whole companion done while the gem's own
        # configuration block was still missing.
        def carries?(lines, insert, root:)
          if insert.types
            derived = derived_types(insert, root: root, lines: [])
            return !derived.empty? &&
              derived.all? { |line| lines.any? { |each| each.strip == line.strip } }
          end

          marker = (insert.marker || insert.line).to_s.strip
          lines.any? { |line| line.strip == marker }
        end

        # **The `define_derived_metadata` call for each of the application's own spec directories that
        # rspec-rails does not infer a type from.** One call per directory that is actually there, and
        # only for the ones the file does not already carry, because each call is a fact about one
        # directory: a person who derived `:model` by hand has fixed that one and not the others.
        def derived_types(insert, root:, lines:)
          table = insert.types || {}
          Dir.glob("spec/*", base: root).sort.filter_map do |path|
            type = table[File.basename(path)]
            next if type.nil? || !File.directory?(File.join(root, path))

            line = "  config.define_derived_metadata(file_path: %r{/#{Regexp.escape(path)}/}) " \
                   "{ |metadata| metadata[:type] = :#{type} }"
            next if lines.any? { |each| each.strip == line.strip }

            line
          end
        end

        # **The located line carries the companion's subject, so the rule that rewrites it is the one
        # that answers.** `Rewrites.apply` groups by subject; a manual entry naming any other subject
        # would find no rule and be reported as a change needing a person. The rules are re-labelled
        # here rather than trusted to agree: a companion whose rule kept its own subject would apply
        # nothing, silently, which is the failure mode this module must not have.
        def rule_edits(entry, files)
          rules = Array(entry.rules).map do |rule|
            next rule if rule.subject == entry.subject

            rule.dup.tap { |copy| copy.subject = entry.subject }
          end
          manual = files.flat_map do |path, lines|
            Array(lines).each_with_index.filter_map do |line, index|
              masked = Rewrites.mask(line)
              next unless rules.any? { |rule| rule.pattern.match?(masked) }

              { "path" => path, "line" => index + 1, "text" => line, "subject" => entry.subject }
            end
          end
          return [] if manual.empty?

          Rewrites.apply(manual, rules: rules, files: files, changes: []).edits.map do |edit|
            Edit.new(path: edit["path"], line: edit["line"], text: edit["text"],
              after: edit["after"], subject: entry.subject, note: entry.note)
          end
        end
      end
    end
  end
end
