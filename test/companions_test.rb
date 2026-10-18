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
end
