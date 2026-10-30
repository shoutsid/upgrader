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
end
