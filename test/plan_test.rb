# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "agents_fyi/upgrader"

# The rendering, driven by payloads shaped like the service's own answers. What is
# asserted here is what a reader has to be able to tell apart: how much of a step a
# machine can do, why an executed half is empty, and which facts came from Rails'
# guide rather than from an execution.
class PlanTest < Minitest::Test
  NEXT_STEP = "4 step(s) from 4.2.0 to 6.0.0, one minor release at a time: " \
              "9 documented change(s) to work through, 3 of which raise by the release you named."

  def payload(observed: [], unclassified: 0)
    {
      "from_version" => "4.2.11",
      "to_version" => "6.0.0",
      "documented" => 9,
      "observed" => observed.size,
      "unplaced" => 0,
      "truncated" => false,
      "guide" => "https://guides.rubyonrails.org/upgrading_ruby_on_rails.html",
      "next_step" => NEXT_STEP,
      "steps" => [
        step(
          to_version: "5.0.0", name: "Rails 5.0", requires_ruby: "2.2.2",
          changes: [
            change(subject: "before_filter", kind: "renamed", replacement: "before_action",
              automatic: true, source: "5.0, controller filters (deprecated; removed in 5.1)"),
            change(subject: "after_filter", kind: "renamed", replacement: "after_action",
              automatic: true, source: "5.0, controller filters (deprecated; removed in 5.1)"),
            change(subject: "ActiveRecord::Base as a model's superclass", kind: "moved",
              replacement: "ApplicationRecord", automatic: false,
              source: "4.2 → 5.0, Active Record Models Now Inherit from ApplicationRecord")
          ],
          observed: observed, unclassified: unclassified
        ),
        step(to_version: "5.1.0", name: "Rails 5.1", requires_ruby: "2.2.2"),
        step(to_version: "5.2.0", name: "Rails 5.2", requires_ruby: "2.2.2"),
        # The most demanding step of the walk, and not the first: the floor a move
        # needs is the highest one in it.
        step(to_version: "6.0.0", name: "Rails 6.0", requires_ruby: "2.5.0")
      ]
    }
  end

  def step(to_version:, name:, requires_ruby:, changes: [], observed: [], unclassified: 0)
    {
      "from_version" => "4.2.0",
      "to_version" => to_version,
      "name" => name,
      "requires_ruby" => requires_ruby,
      "guidance" => "Change the Rails version to #{to_version} in the Gemfile and run `bundle update rails`.",
      "note" => "",
      "counts" => { "documented" => changes.size },
      "observed" => observed,
      "observed_unclassified" => unclassified,
      "changes" => changes
    }
  end

  def change(subject:, kind:, replacement:, automatic:, source:)
    {
      "subject" => subject,
      "kind" => kind,
      "replacement" => replacement,
      "removed_in" => "5.1.0",
      "automatic" => automatic,
      "findable" => true,
      "enforced_in_your_move" => false,
      "note" => "",
      "source" => source
    }
  end

  def render(payload)
    AgentsFyi::Upgrader::Plan.new(
      payload: payload,
      repository: "acme/storefront",
      commit: "9f2c1ab8",
      lockfile: StubLockfile.new
    ).to_s
  end

  # Stands in for a lockfile, so a rendering test is not also a parsing test.
  class StubLockfile
    Pinned = Struct.new(:gem, :version)

    def rails
      Pinned.new("rails", "4.2.11")
    end

    def locked_ruby
      "2.7.8"
    end

    def declared_ruby
      nil
    end

    def dot_ruby_version
      nil
    end
  end

  def test_a_step_says_how_much_of_it_a_machine_can_do_and_how_much_it_cannot
    out = render(payload)

    assert_includes out, "3 documented change(s): 2 a machine can apply, 1 need a decision"
    assert_includes out, "apply:  before_filter -> before_action (renamed; 5.0, controller filters"
    assert_includes out, "decide: ActiveRecord::Base as a model's superclass -> ApplicationRecord"
  end

  def test_every_documented_change_carries_the_chapter_it_came_from
    out = render(payload)

    assert_includes out, "4.2 → 5.0, Active Record Models Now Inherit from ApplicationRecord"
  end

  def test_the_floor_is_the_most_demanding_step_and_not_the_first
    out = render(payload)

    assert_includes out, "Ruby floor this move needs: 2.5.0 (Rails 6.0.0 requires it"
  end

  # The empty half, which is the one that has to explain itself. Nothing executed in
  # a window and reports that are not recorded as changes are two different
  # emptinesses, and only the first means the guide is all there is.
  def test_a_window_the_corpus_never_executed_says_the_list_is_the_guide
    out = render(payload)

    assert_includes out, "nothing this corpus executed falls inside this step's window"
  end

  def test_reports_that_are_not_recorded_as_changes_are_counted_rather_than_read_as_silence
    out = render(payload(unclassified: 2))

    assert_includes out, "2 report(s) in this window are not recorded as changes either"
  end

  def test_a_window_that_was_executed_lists_what_was_found
    observed = [
      {
        "title" => "actionpack 5.0.1 removed ActionController::Live::Buffer",
        "subject" => "Live::Buffer",
        "broken_in" => "5.0.1",
        "from_version" => "4.2.11",
        "status" => "resolved_verified",
        "trust" => 0.8
      }
    ]
    out = render(payload(observed: observed, unclassified: 1))

    assert_includes out, "executed here: 1 change(s)"
    assert_includes out, "Live::Buffer: broke in 5.0.1, still worked in 4.2.11"
    assert_includes out, "1 report(s) in this window are not recorded as changes"
  end

  # The service's own sentence is the last thing a reader gets, after the steps it
  # describes — a summary printed above the detail is a summary nobody has read yet.
  def test_the_services_own_sentence_comes_after_the_steps_it_describes
    out = render(payload)

    assert_includes out, "next: #{NEXT_STEP}"
    assert_operator out.index(NEXT_STEP), :>, out.index("== Rails 5.0")
  end

  def test_a_plan_says_what_it_did_not_do
    out = render(payload)

    assert_includes out, "nothing was written to acme/storefront"
  end
end
