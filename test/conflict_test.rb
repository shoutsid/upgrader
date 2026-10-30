# frozen_string_literal: true

require "minitest/autorun"
require "agents/upgrader"

# **The derivation, not the message.** Bundler's conflict output nests one branch per requirer;
# these drive the shapes that matter — a nested path, a sibling branch, every block rather than
# the first, and the ordinary failure that names only one requirement.
class ConflictTest < Minitest::Test
  C = Agents::Upgrader::Conflict

  MESSAGE = <<~OUTPUT
    Bundler could not find compatible versions for gem "rack":
      In Gemfile:
        rails (= 4.2.11) was resolved to 4.2.11, which depends on
          actionpack (= 4.2.11) was resolved to 4.2.11, which depends on
            rack (< 2.0)

        sinatra was resolved to 1.4.8, which depends on
          rack (~> 1.6)
  OUTPUT

  def test_two_branches_become_one_set_with_each_requirer_path
    conflict = C.derive(MESSAGE).first

    assert_equal "rack", conflict["gem"]
    requirements = conflict["requirements"]
    assert_equal ["< 2.0", "~> 1.6"], requirements.map { |row| row["requirement"] }
    assert_equal ["rails 4.2.11", "actionpack 4.2.11"], requirements.first["via"]
    assert_equal ["sinatra 1.4.8"], requirements.last["via"]
    assert_includes conflict["summary"], "rack is required as < 2.0"
  end

  def test_a_single_requirement_is_a_missing_release_rather_than_a_conflict
    message = <<~OUTPUT
      Bundler could not find compatible versions for gem "webrick":
        In Gemfile:
          rails was resolved to 7.0.0, which depends on
            webrick (>= 1.7)
    OUTPUT

    assert_empty C.derive(message)
  end

  def test_every_conflict_block_is_kept_rather_than_only_the_first
    message = <<~OUTPUT
      Bundler could not find compatible versions for gem "rack":
        In Gemfile:
          rails was resolved to 4.2.11, which depends on
            rack (< 2.0)
          sinatra was resolved to 1.4.8, which depends on
            rack (~> 1.6)

      Bundler could not find compatible versions for gem "json":
        In Gemfile:
          rails was resolved to 4.2.11, which depends on
            json (~> 1.8)
          another was resolved to 2.0.0, which depends on
            json (~> 2.0)
    OUTPUT

    conflicts = C.derive(message)

    assert_equal %w[rack json], conflicts.map { |row| row["gem"] }
  end

  # **The digest-declaration shape, which Bundler writes as an instruction.** A requirement the
  # Gemfile added against a release the lock already holds names both constraints without a
  # "compatible versions" header; the minimal set is the requested range and the locked version.
  def test_a_requested_version_against_the_lock_is_a_conflict
    message = <<~OUTPUT
      You have requested:
        responders ~> 2.0

      The bundle currently has responders locked at 1.1.2.
      Try running `bundle update responders`
    OUTPUT

    conflict = C.derive(message).first

    assert_equal "responders", conflict["gem"]
    assert_equal ["~> 2.0", "= 1.1.2"],
      conflict["requirements"].map { |row| row["requirement"] }
    assert_equal ["the Gemfile"], conflict["requirements"].first["via"]
    assert_equal ["Gemfile.lock"], conflict["requirements"].last["via"]
  end

  def test_a_requirement_less_dependency_is_not_a_constraint
    message = <<~OUTPUT
      Bundler could not find compatible versions for gem "rack":
        In Gemfile:
          rails was resolved to 4.2.11, which depends on
            rack
          sinatra was resolved to 1.4.8, which depends on
            rack (~> 1.6)
    OUTPUT

    assert_empty C.derive(message)
  end

  # **A set is minimal because a smaller one cannot hold, not because it is short.** The two
  # branches here exclude each other at the same version, so the derivation says so and the
  # summary is the sentence a maintainer can act on.
  def test_two_excluding_branches_are_a_proven_minimal_set
    message = <<~OUTPUT
      Bundler could not find compatible versions for gem "rails":
        In Gemfile:
          rails (= 4.2.11)
          another was resolved to 5.0.0, which depends on
            rails (= 5.0.0)
    OUTPUT

    conflict = C.derive(message).first

    assert_equal true, conflict["proven"]
    assert_equal ["= 4.2.11", "= 5.0.0"],
      conflict["minimal"].map { |row| row["requirement"] }
    assert_includes conflict["summary"], "the smallest set that cannot hold together"
  end

  # **Requirements that hold together are not a conflict.** `< 2.0` and `~> 1.6` are both
  # satisfied by 1.6.x, so naming them as the cause sends a maintainer after a release problem
  # that does not exist; the derivation keeps both rows and says the resolver could not place one.
  def test_satisfiable_requirements_are_not_claimed_as_a_conflict
    conflict = C.derive(MESSAGE).first

    assert_equal false, conflict["proven"]
    assert_empty conflict["minimal"]
    assert_equal ["< 2.0", "~> 1.6"],
      conflict["requirements"].map { |row| row["requirement"] }
    assert_includes conflict["summary"], "the resolver could not place a release against them"
  end

  # The branch that agrees with one side of the contradiction is not part of the cause, so the
  # smallest set is the two that exclude each other rather than everything Bundler printed.
  def test_a_requirement_that_agrees_with_one_side_is_dropped_from_the_minimal_set
    message = <<~OUTPUT
      Bundler could not find compatible versions for gem "json":
        In Gemfile:
          alpha was resolved to 1.0.0, which depends on
            json (< 2.0)
          beta was resolved to 2.0.0, which depends on
            json (>= 2.0)
          gamma was resolved to 3.0.0, which depends on
            json (>= 1.0)
    OUTPUT

    conflict = C.derive(message).first

    assert_equal ["< 2.0", ">= 2.0"], conflict["minimal"].map { |row| row["requirement"] }
    assert_equal 3, conflict["requirements"].length, "every named branch is still the evidence"
  end

  # **A clause RubyGems cannot read makes the question undecidable rather than answered.** Saying
  # "not minimal" here is the honest answer; a partial parse that guessed would be a second
  # resolver whose disagreement with Bundler nobody could see.
  def test_an_unreadable_requirement_keeps_the_full_set
    message = <<~OUTPUT
      Bundler could not find compatible versions for gem "rack":
        In Gemfile:
          rails was resolved to 4.2.11, which depends on
            rack (~> 1.6)
          sinatra was resolved to 1.4.8, which depends on
            rack (^ 1.0)
    OUTPUT

    conflict = C.derive(message).first

    assert_equal false, conflict["proven"]
    assert_empty conflict["minimal"]
    assert_equal ["~> 1.6", "^ 1.0"],
      conflict["requirements"].map { |row| row["requirement"] }
  end
end
