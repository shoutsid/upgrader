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
        globs: [],
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
        rules: []
      )

      ENTRIES = [RSPEC_RAILS_THREE, SHOULDA_MATCHERS].freeze

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
