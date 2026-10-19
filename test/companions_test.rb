# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The edits a gem's own upgrade requires, driven against real files.
#
# The point of this file is the half no ladder change covers: a rung can fail in the *gem's* code,
# and then the Gemfile line is only the first of the changes the move needs. Measured on the
# lighthouse at the 5.0 rung: the rspec-rails 3 move alone took the suite from 47 failures to 133,
# the inference call to 3, and the three negated change matchers to 0.
class CompanionsTest < Minitest::Test
  Companions = AgentsFyi::Upgrader::Companions
  Rewrites = AgentsFyi::Upgrader::Rewrites
  Applier = AgentsFyi::Upgrader::Applier
  ROOT = File.expand_path("../../..", __dir__)
  DIGEST = File.join(ROOT, "data", "gem_migrations.json")

  def tree(files)
    dir = Dir.mktmpdir
    files.each do |path, text|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
    (@dirs ||= []) << dir
    dir
  end

  def teardown
    @dirs&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def entry = Companions::RSPEC_RAILS_THREE

  # **The insert is anchored, not guessed at.** The line belongs inside `RSpec.configure`; a file
  # that keeps its rspec configuration some other way has no anchor and gets no edit, which is the
  # honest answer rather than appending a line to the end of somebody's file.
  def test_an_insert_lands_the_line_after_its_anchor
    root = tree("spec/spec_helper.rb" => "ENV['RAILS_ENV'] ||= 'test'\nRSpec.configure do |config|\nend\n")

    edits = Companions.edits(entry, root: root)

    insert = edits.find { |edit| edit.path == "spec/spec_helper.rb" }
    refute_nil insert, "no insert was produced for a file that carries the anchor"
    assert_equal 2, insert.line, "the anchor is the second line"
    assert_equal "RSpec.configure do |config|\n  config.infer_spec_type_from_file_location!",
      insert.after
  end

  # A second walk over a tree a person already fixed is not a repair, and re-running the walker
  # must not append the line twice.
  def test_an_insert_already_in_the_file_is_no_edit
    root = tree("spec/spec_helper.rb" =>
      "RSpec.configure do |config|\n  config.infer_spec_type_from_file_location!\nend\n")

    assert_empty Companions.edits(entry, root: root)
  end

  def test_an_insert_without_its_anchor_is_no_edit
    root = tree("spec/spec_helper.rb" => "RSpec.configure { |config| }\n")

    assert_empty Companions.edits(entry, root: root)
  end

  # rspec 3 refuses `expect { }.not_to change { }.by(N)` — a negative matcher with a delta cannot be
  # evaluated — and the examples mean "no record was written", which is the matcher without the
  # delta. Both signs are dropped: `should_not change(X, :count).by(-1)` is the same refusal.
  def test_a_negated_change_matcher_loses_its_delta
    root = tree("spec/items_spec.rb" => <<~RUBY)
      describe 'items' do
        it 'adds' do
          lambda { post :create }.should_not change(Item, :count).by(1)
        end

        it 'destroys' do
          lambda { delete :destroy }.should_not change(Item, :count).by(-1)
        end
      end
    RUBY

    edits = Companions.edits(entry, root: root)

    assert_equal 2, edits.size, "both call sites are the change: #{edits.map(&:after).inspect}"
    edits.each do |edit|
      refute_match(/\.by\(/, edit.after.to_s, "a negated change matcher kept its delta: #{edit.after}")
      assert_includes edit.after, ".should_not change(Item, :count)"
    end
  end

  # A *positive* matcher is valid in rspec 3 and is the application's own statement about what the
  # request did. Rewriting it would change what the example proves.
  def test_a_positive_change_matcher_is_left_alone
    root = tree("spec/items_spec.rb" => "lambda { post :create }.should change(Item, :count).by(1)\n")

    assert_empty Companions.edits(entry, root: root)
  end

  # **The mechanism is the reusable half: a second companion is data and adds no branch.** This drives
  # an entry for a gem that does not exist against a synthetic tree, with a rule whose own subject
  # deliberately disagrees with the entry's — the shape a hurried second instance would have, and one
  # that would otherwise apply nothing because `Rewrites.apply` groups by subject.
  def test_a_second_companion_is_data_and_needs_no_new_branch
    second = Companions::Entry.new(
      gem: "some-gem", requirement: "~> 2.0", subject: "some-gem 2",
      note: "a second gem whose own upgrade needs an edit",
      globs: %w[spec/**/*_spec.rb],
      inserts: [
        Companions::Insert.new(path: "config/initializers/some.rb", anchor: "# boot",
          line: "SomeGem.configure", note: "a second insert")
      ],
      rules: [
        Rewrites::Rule.new(family: :argument_dropped, subject: "a different subject",
          pattern: /(?<call>\.should_not\s+change\([^)]*\))\s*\.by\(\s*-?\d+\s*\)/,
          replace: '\k<call>')
      ]
    )
    root = tree("config/initializers/some.rb" => "# boot\n",
      "spec/x_spec.rb" => "lambda { 1 }.should_not change(X, :count).by(1)\n")

    edits = Companions.edits(second, root: root)

    assert_equal 2, edits.size, "the second companion's edits are #{edits.map(&:path).inspect}"
    assert(edits.all? { |edit| edit.subject == "some-gem 2" },
      "every edit is recorded under the entry's subject, not the rule's")
    assert_equal "SomeGem.configure",
      edits.find { |edit| edit.path == "config/initializers/some.rb" }.after.split("\n").last
    refute_match(/\.by\(/, edits.find { |edit| edit.path == "spec/x_spec.rb" }.after.to_s,
      "a rule whose subject disagreed with its entry applied nothing")
  end

  # **The other spelling of the same refusal.** This application writes `lambda { … }.should_not
  # change(X, :count).by(N)`; an application already on rspec 3's syntax writes `expect { … }.not_to
  # change { X.count }.by(N)`. Both raise the same NotImplementedError and both mean "no record was
  # written", so the rule reads both — a rule that knew only the first would leave the second failing.
  def test_the_not_to_spelling_and_the_block_form_are_the_same_change
    root = tree("spec/x_spec.rb" => <<~RUBY)
      expect { post :create }.not_to change(Item, :count).by(1)
      expect { delete :destroy }.not_to change { Item.count }.by(-1)
    RUBY

    edits = Companions.edits(entry, root: root)

    assert_equal 2, edits.size, "the not_to spellings were not read: #{edits.map(&:after).inspect}"
    edits.each { |edit| refute_match(/\.by\(/, edit.after.to_s) }
  end

  # A one-line example can carry two, and a rule that rewrote only the first would report the line
  # applied while the second still raised.
  def test_two_matchers_on_one_line_are_both_rewritten
    root = tree("spec/x_spec.rb" =>
      "expect { a }.not_to change(X, :count).by(1); expect { b }.not_to change(Y, :count).by(1)\n")

    edits = Companions.edits(entry, root: root)

    assert_equal 1, edits.size
    refute_match(/\.by\(/, edits.first.after.to_s, "the second matcher kept its delta")
  end

  # **A multi-line edit carries the file's own terminator, line by line.** A CRLF checkout must not
  # gain bare LF lines: the applier's terminator ends only the *last* line it writes, so an insert's
  # own newline had to be translated — measured writing `RSpec.configure do |config|\n  config.infer…`
  # into a `\r\n` file.
  def test_an_insert_into_a_crlf_file_writes_crlf_lines
    root = tree("spec/spec_helper.rb" => "RSpec.configure do |config|\r\nend\r\n")

    edits = Companions.edits(entry, root: root)
    Applier.new(root).apply(edits.map(&:to_h))

    bytes = File.binread(File.join(root, "spec/spec_helper.rb"))
    refute_match(/(?<!\r)\n/, bytes, "a bare LF was written into a CRLF file: #{bytes.inspect}")
    assert_includes bytes, "config.infer_spec_type_from_file_location!\r\n"
  end

  # The trigger is the move's own line: a companion for `~> 2.14.0` would be the edits for a move the
  # application is not making.
  def test_the_companion_is_keyed_by_the_line_the_move_declares
    assert_equal entry, Companions.for("rspec-rails", "~> 3.5.0")
    assert_nil Companions.for("rspec-rails", "~> 2.14.0")
    assert_nil Companions.for("json", "~> 1.8")
  end

  # **The digest and the companion have to agree about the line, or the application gets the Gemfile
  # rewritten and the suite left broken.** A digest edited to move rspec-rails to a different line
  # fails here, which is the only place the two can be compared.
  def test_the_companion_is_the_line_the_digest_declares
    digest = JSON.parse(File.read(DIGEST)).fetch("migrations")
    rung = digest.select { |migration| migration["gem"] == "rspec-rails" }
      .find { |migration| migration.dig("when", "rails_at_least") == "5.0" }

    refute_nil rung, "the digest has no rspec-rails rule for the 5.0 rung"
    assert_equal entry.requirement, rung["requirement"],
      "the digest moves rspec-rails to #{rung["requirement"].inspect} and the companion's edits " \
      "are keyed to #{entry.requirement.inspect}"
    assert_equal false, rung["mechanical"],
      "the move cannot be a preflight repair: rspec-rails 3 stops providing assigns, and the gem " \
      "that restores it requires actionpack ~> 5.x"
  end

  # **A block is several lines, and its evidence is one of them.** The insert has to land after the
  # require that loads the test framework — `Shoulda::Matchers.configure` resolves `:rspec` through
  # the gem's own registry, so the framework has to be loaded before the block runs — and a second
  # pass over a tree the first pass fixed must not insert it again. That is what `marker` is for: a
  # check that looked for the whole block among the file's lines would never find it.
  def test_a_block_insert_lands_whole_and_is_recognised_by_its_marker
    shoulda = Companions::SHOULDA_MATCHERS
    helper = "ENV['RAILS_ENV'] ||= 'test'\nrequire 'rspec/rails'\n\nRSpec.configure do |config|\nend\n"
    root = tree("spec/spec_helper.rb" => helper)

    edits = Companions.edits(shoulda, root: root)

    assert_equal 1, edits.size, "the companion's edits are #{edits.map(&:path).inspect}"
    insert = edits.first
    assert_equal 2, insert.line, "the anchor is the `require 'rspec/rails'` line"
    assert_equal "require 'rspec/rails'\n#{Companions::SHOULDA_CONFIGURATION}", insert.after
    assert_includes insert.after, "with.test_framework :rspec"
    assert_includes insert.after, "with.library :rails"

    Applier.new(root).apply(edits.map(&:to_h))
    assert_empty Companions.edits(shoulda, root: root),
      "a second pass over a configured helper is not a second insert"
    assert(Companions.placed?(shoulda, root: root), "the marker is what says the block is there")
  end

  # **An application that spells the require another way gets no edit, and the caller has to be able
  # to say so.** `edits` returns an empty list both when the block is already there and when nothing
  # carries the anchor; `placed?` is the difference, and at the 7.0 rung it is the difference between
  # a green baseline and a rung that stops with nothing in the record saying why.
  def test_a_helper_without_the_anchor_is_not_placed_rather_than_configured
    root = tree("spec/spec_helper.rb" => "ENV['RAILS_ENV'] ||= 'test'\n")

    assert_empty Companions.edits(Companions::SHOULDA_MATCHERS, root: root)
    refute Companions.placed?(Companions::SHOULDA_MATCHERS, root: root),
      "no file carries the marker, so the companion is not placed"
  end

  # **The digest and the companion have to agree about the line here too, and this one is
  # interpreter-scoped.** The entry that moves shoulda-matchers off 2.8.0 is scoped by `ruby_at_least
  # 2.7` — the interpreter that removed `BigDecimal.new`, which 2.8.0 calls in a class body at boot —
  # and the companion's edits are keyed to that same requirement.
  def test_the_shoulda_companion_is_the_line_the_digest_declares
    digest = JSON.parse(File.read(DIGEST)).fetch("migrations")
    rung = digest.select { |migration| migration["gem"] == "shoulda-matchers" }
      .find { |migration| migration.dig("when", "ruby_at_least") == "2.7" }

    refute_nil rung, "the digest has no shoulda-matchers rule for the 2.7 era"
    assert_equal Companions::SHOULDA_MATCHERS.requirement, rung["requirement"],
      "the digest moves shoulda-matchers to #{rung["requirement"].inspect} and the companion's " \
      "edits are keyed to #{Companions::SHOULDA_MATCHERS.requirement.inspect}"
    assert_equal true, rung["mechanical"],
      "the line move is a preflight repair, which is what lets its companion be applied there"
  end

  # **The second half of the same move: the matchers are included with a `type`, and rspec-rails
  # infers one only from the plural directory names.** Measured at the 7.0 rung, the gem's own
  # configuration block alone left the baseline red with the *same* 26 failures — this application's
  # model specs live in `spec/model`, so their example groups carry no type at all and every matcher
  # with them. The insert is computed from the tree, and each call is guarded by itself, because a
  # person who derived one directory has fixed that one and not the others.
  def test_a_singular_spec_directory_has_its_type_derived
    shoulda = Companions::SHOULDA_MATCHERS
    root = tree(
      "spec/model/user_spec.rb" => "describe User do\nend\n",
      "spec/spec_helper.rb" => "require 'rspec/rails'\nRSpec.configure do |config|\nend\n"
    )

    edits = Companions.edits(shoulda, root: root)
    derive = edits.find { |edit| edit.after.to_s.include?("define_derived_metadata") }

    refute_nil derive, "no type was derived: #{edits.map(&:after).inspect}"
    assert_equal "spec/spec_helper.rb", derive.path
    assert_includes derive.after,
      "  config.define_derived_metadata(file_path: %r{/spec/model/}) { |metadata| " \
      "metadata[:type] = :model }"
    assert_includes derive.after, "RSpec.configure do |config|", "the call goes inside the block"

    Applier.new(root).apply(edits.map(&:to_h))
    assert_empty Companions.edits(shoulda, root: root),
      "a second pass is not a second derivation"
  end

  # A directory rspec-rails *does* infer a type from gets nothing: `spec/models` is already `:model`,
  # and `spec/routing` is spelled the same way in the mapping, so neither is in the table.
  def test_a_plural_spec_directory_needs_no_derivation
    root = tree(
      "spec/models/user_spec.rb" => "describe User do\nend\n",
      "spec/spec_helper.rb" => "require 'rspec/rails'\nRSpec.configure do |config|\nend\n"
    )

    edits = Companions.edits(Companions::SHOULDA_MATCHERS, root: root)

    refute(edits.any? { |edit| edit.after.to_s.include?("define_derived_metadata") },
      "a plural directory was derived: #{edits.map(&:after).inspect}")
  end

  # **The four edits 3.0 makes necessary in the application's own files, and each is a fact that file
  # already states.** Measured on the 7.0 rung's baseline: with the configuration block and the type
  # derivation in place it was still 26 failures → 3 → 2, and closing the rest meant asking the
  # application what it means rather than assuming it.
  def test_a_model_spec_gets_the_applications_own_definition_of_a_valid_record
    shoulda = Companions::SHOULDA_MATCHERS
    root = tree("spec/model/bid_spec.rb" => "describe Bid do\n  it { should belong_to(:item) }\nend\n")

    edits = Companions.edits(shoulda, root: root)
    subject = edits.find { |edit| edit.after.to_s.include?("subject {") }

    refute_nil subject, "no subject was derived: #{edits.map(&:after).inspect}"
    assert_includes subject.after, "describe Bid do\n  subject { FactoryGirl.build(:bid) }"

    Applier.new(root).apply(edits.map(&:to_h))
    assert_empty Companions.edits(shoulda, root: root), "a second pass is not a second subject"
  end

  # **The association says what its presence validation already means.** `RequiredMatcher` does not
  # accept `validates_presence_of` as proof — it asks for the `:required` error Rails' own `required:`
  # produces — so the model has to declare it. `optional: true` is the application saying the opposite
  # and it wins.
  def test_an_association_the_model_validates_the_presence_of_is_declared_required
    root = tree(
      "app/models/bid.rb" => <<~RUBY
        class Bid < ApplicationRecord
          belongs_to :item, counter_cache: true
          belongs_to :user, optional: true
          validates_presence_of :item, :amount
        end
      RUBY
    )

    edits = Companions.edits(Companions::SHOULDA_MATCHERS, root: root)

    assert_equal 1, edits.size, "the required association is the one edit: #{edits.map(&:after).inspect}"
    assert_includes edits.first.after, "belongs_to :item, counter_cache: true, required: true"
    refute(edits.any? { |edit| edit.after.to_s.include?("belongs_to :user") },
      "an association the model calls optional was made required")
  end

  # **An option proc that dereferences an association raises when the association is absent**, and
  # 3.0's matchers null it to ask their question. Guarding the *validation* with `if: :item` was
  # measured first and is wrong — it skips the check `validate_numericality_of(:amount)` asserts — so
  # the proc itself answers for the absent association.
  def test_an_option_proc_that_dereferences_an_association_is_made_nil_safe
    root = tree(
      "app/models/bid.rb" => <<~RUBY
        class Bid < ApplicationRecord
          validates_numericality_of :amount,
            greater_than_or_equal_to: Proc.new { |bid| bid.item.min_bid_amount.to_f }
        end
      RUBY
    )

    edits = Companions.edits(Companions::SHOULDA_MATCHERS, root: root)
    guarded = edits.find { |edit| edit.after.to_s.include?("Proc.new") }

    refute_nil guarded, "the proc was not guarded: #{edits.map(&:after).inspect}"
    assert_includes guarded.after, "Proc.new { |bid| bid.item ? bid.item.min_bid_amount.to_f : 0 }"
  end

  # **Devise is what validates the email, and it does so case-insensitively** — and the `devise` call
  # is several lines in this application, which a single-line pattern missed (measured: the rule
  # silently did nothing). A `validate_uniqueness_of(:username)` the model declares itself is left
  # alone: telling it to be case-insensitive would assert something the model does not do.
  def test_devises_case_insensitive_email_gets_the_matching_matcher_option
    root = tree(
      "app/models/user.rb" => <<~RUBY,
        class User < ApplicationRecord
          devise :database_authenticatable,
                 :validatable
          validates_uniqueness_of(:username)
        end
      RUBY
      "spec/model/user_spec.rb" => <<~RUBY
        describe User do
          it { should validate_uniqueness_of(:email) }
          it { should validate_uniqueness_of(:username) }
        end
      RUBY
    )

    edits = Companions.edits(Companions::SHOULDA_MATCHERS, root: root)
    email = edits.find { |edit| edit.after.to_s.include?(":email") }

    refute_nil email, "the email matcher was not told: #{edits.map(&:after).inspect}"
    assert_includes email.after, "validate_uniqueness_of(:email).case_insensitive"
    refute(edits.any? { |edit| edit.after.to_s.include?(":username).case_insensitive") },
      "a case-sensitive uniqueness assertion was told to be case-insensitive")
  end

  # **A gem renamed by its own maintainers, and the code has to be renamed with it.** Measured at the
  # 7.2 rung: `factory_girl-4.9.0/lib/factory_girl.rb:158: private method `warn' called for
  # ActiveSupport::Deprecation:Class` — Rails 7.2 made that private — and `factory_bot` 4.9.0, the same
  # release renamed, does not call it at all. The application has 93 `FactoryGirl` call sites.
  def test_the_gem_that_was_renamed_takes_its_constant_with_it
    factory = Companions::FACTORY_BOT
    root = tree(
      "spec/factories/user_factory.rb" => "FactoryGirl.define do\n  factory :user do\n  end\nend\n",
      "spec/model/user_spec.rb" => "user = FactoryGirl.create(:user)\nFactoryGirl.build(:user)\n"
    )

    edits = Companions.edits(factory, root: root)

    assert_equal 3, edits.size, "every call site is the change: #{edits.map(&:after).inspect}"
    edits.each { |edit| assert_includes edit.after, "FactoryBot" }
    refute_match(/FactoryGirl/, edits.map(&:after).join)
  end

  # **The rename is a word, not a string.** `FactoryGirl` inside a string is somebody's data, and a
  # pattern without a word boundary would rewrite it.
  def test_the_rename_leaves_a_string_that_merely_names_it
    root = tree("spec/x_spec.rb" => %(puts "FactoryGirl is the old name"\n))

    assert_empty Companions.edits(Companions::FACTORY_BOT, root: root)
  end

  # **The gem's *name* moves too, and a pattern cannot see it.** Measured at the 7.2 rung, once the
  # suite got past its first failure: `Failure/Error: require 'factory_girl_rails'` →
  # `LoadError: cannot load such file -- factory_girl_rails` from `spec/spec_helper.rb:12`. The mask
  # blanks what is inside the quotes and keeps the quotes, so the pattern asks the *shape* of a require,
  # the callable receives the raw region and rewrites the name, and the condition reads the raw line —
  # the only place the old name is. A line that already names the new gem is left, which is what makes a
  # second walk a no-op.
  def test_the_gems_own_name_moves_in_a_require
    root = tree(
      "spec/spec_helper.rb" => "require 'rspec/rails'\nrequire 'factory_girl_rails'\n",
      "spec/rails_helper.rb" => %(require "factory_bot_rails"\n)
    )

    edits = Companions.edits(Companions::FACTORY_BOT, root: root)

    assert_equal ["require 'factory_bot_rails'"], edits.map(&:after),
      "the require did not move, or a line that did not need to did: #{edits.map(&:after).inspect}"
  end

  # **The gem's own deprecation, which the rename does not reach.** Measured at the 7.2 rung: with the
  # line and the 93 call sites already moved, `app:update` dies at `spec/factories/admin_factory.rb:5`
  # with `private method `warn' called for ActiveSupport::Deprecation:Class` — factory_bot 4.11.1's
  # `warn_static_attribute_deprecation` calls the class-level method Rails 7.2 made private, and a static
  # attribute is what reaches it. The gem's own message is the edit: "Static attributes will be removed in
  # FactoryBot 5.0. Please use dynamic attributes instead by wrapping the attribute value in a block."
  def test_a_static_attribute_becomes_dynamic_where_the_gem_asks_for_it
    root = tree("spec/factories/item_factory.rb" => <<~RUBY)
      FactoryGirl.define do
        factory :item do
          name { generate(:item_name) }
          description 'foo'
          starting_price 100
          closing_time Time.now + 1.day
          closed false
        end
      end
    RUBY

    edits = Companions.edits(Companions::FACTORY_BOT, root: root)
    statics = edits.reject { |edit| edit.after.include?("FactoryBot.define") }

    assert_equal [
      "    description { 'foo' }",
      "    starting_price { 100 }",
      "    closing_time { Time.now + 1.day }",
      "    closed { false }"
    ], statics.map(&:after)
    assert(edits.any? { |edit| edit.after.include?("FactoryBot.define") },
      "the rename did not happen beside it: #{edits.map(&:after).inspect}")
  end

  # **Everything else in a factory body is not a static attribute, and each exclusion is one of the
  # gem's own branches.** factory_bot 4.11.1's `DefinitionProxy#method_missing` sends a name with an
  # argument and no block to `add_attribute` — the static path — while its own methods and the three it
  # delegates (`before`, `after`, `callback`) are the DSL, a bare name is an implicit attribute, and a
  # value already wrapped in a block is dynamic. `factory:` is the gem's own association branch.
  def test_a_factorys_own_dsl_and_bare_names_are_not_static_attributes
    root = tree("spec/factories/user_factory.rb" => <<~RUBY)
      FactoryGirl.define do
        sequence(:email) { |n| "foo\#{n}@example.com" }

        factory :user do
          email { generate(:email) }
          item
          association :account, factory: :account
          after(:create) { |user| user.touch }
        end
      end
    RUBY

    edits = Companions.edits(Companions::FACTORY_BOT, root: root)

    assert_equal ["FactoryBot.define do"], edits.map(&:after),
      "something that is not a static attribute was rewritten: #{edits.map(&:after).inspect}"
  end

  # **The shape is ordinary Ruby outside a factory, so the rule is scoped to the files that are
  # factories.** `return false unless sold` and `raise "no time" if closed` are `name value` too, and a
  # rule that rewrote every line of that shape would turn ordinary code into blocks. `Rewrites.apply`
  # matches the *line*, so the file's own `FactoryBot.define` is the only thing that can tell them apart
  # — which is what the rule's condition asks.
  def test_the_static_attribute_rule_stays_out_of_ordinary_ruby
    root = tree(
      "app/models/item.rb" => <<~RUBY,
        class Item < ActiveRecord::Base
          def closing_time
            return false unless sold
            raise "no time" if closed
            closing_time
          end
        end
      RUBY
      "spec/factories/item_factory.rb" => "FactoryGirl.define do\n  factory :item do\n    sold false\n  end\nend\n"
    )

    edits = Companions.edits(Companions::FACTORY_BOT, root: root)

    assert_equal 2, edits.size, "ordinary Ruby was rewritten: #{edits.map { |edit| [edit.path, edit.after] }.inspect}"
    assert_equal ["    sold { false }"], edits.reject { |edit| edit.after.include?("FactoryBot.define") }.map(&:after)
  end
end
