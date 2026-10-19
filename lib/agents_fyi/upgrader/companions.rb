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
      Insert = Struct.new(:path, :anchor, :line, :note, keyword_init: true)

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

      ENTRIES = [RSPEC_RAILS_THREE].freeze

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
          return nil if lines.any? { |line| line.strip == insert.line.strip }

          index = lines.index { |line| line.strip == insert.anchor.strip }
          return nil if index.nil?

          Edit.new(path: insert.path, line: index + 1, text: lines[index],
            after: "#{lines[index]}\n#{insert.line}", subject: entry.subject,
            note: insert.note)
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
