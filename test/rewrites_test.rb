# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The changes this walker makes that the service will not.
#
# `/rails/scan` locates a call site and stops: its contract is a statement about the ladder. A rule
# here is this tool's own knowledge of how to make one of those edits, and what is asserted is the
# three things that keep a rule honest — it names the change it belongs to, it carries that change's
# provenance, and it refuses to touch a line whose value it cannot see the end of.
class RewritesTest < Minitest::Test
  Rewrites = AgentsFyi::Upgrader::Rewrites
  Applier = AgentsFyi::Upgrader::Applier

  def entry(subject:, text:, path: "app/views/x.html.erb", line: 3)
    {
      "path" => path, "line" => line, "text" => text, "after" => nil,
      "subject" => subject, "kind" => "renamed", "replacement" => "whatever",
      "automatic" => false, "note" => "the change's own note", "source" => "4.0 → 4.1, the chapter"
    }
  end

  # The note's own example, in both spellings: the value is *captured*, never guessed.
  def test_the_confirm_option_becomes_a_data_attribute_in_both_spellings
    result = Rewrites.apply([
      entry(subject: ":confirm option on link_to", text: %(link_to 'Delete', path, confirm: 'Sure?')),
      entry(subject: ":confirm option on link_to", text: %(link_to 'Delete', path, :confirm => "Sure?"))
    ])

    assert_equal [
      %(link_to 'Delete', path, data: { confirm: 'Sure?' }),
      %(link_to 'Delete', path, data: { confirm: "Sure?" })
    ], result.edits.map { |edit| edit["after"] }
    assert_equal 2, result.applied.size
  end

  # **A value whose end the rule cannot see is not touched.** `confirm: t(:x, count: 1)` has an
  # argument list inside it; a rule that guessed where the value stopped would cut the line in half,
  # so the line stays a decision — a located one, which is the honest answer.
  def test_an_option_value_the_rule_cannot_see_the_end_of_stays_a_decision
    result = Rewrites.apply([
      entry(subject: ":confirm option on link_to", text: %(link_to 'x', path, confirm: t(:sure, count: 1)))
    ])

    assert_empty result.edits
    assert_empty result.applied
    assert_equal [":confirm option on link_to"], result.left
  end

  # The constant is soft-deprecated and still works, so this is the step to move the references.
  # One that is already qualified is not touched — `(?<!::)` is the whole of that rule.
  def test_the_constant_is_qualified_once_and_never_twice
    result = Rewrites.apply([
      entry(subject: "HashWithIndifferentAccess", text: "  attrs = HashWithIndifferentAccess.new"),
      entry(subject: "HashWithIndifferentAccess", text: "  attrs = ActiveSupport::HashWithIndifferentAccess.new")
    ])

    assert_equal 1, result.edits.size
    assert_equal "  attrs = ActiveSupport::HashWithIndifferentAccess.new",
      result.edits.first["after"]
  end

  # The pattern names the receiver, because `response.content_type` is a different method that did
  # not change.
  def test_the_content_type_rule_names_the_receiver
    result = Rewrites.apply([
      entry(subject: "request.content_type", text: "  type = request.content_type"),
      entry(subject: "request.content_type", text: "  type = response.content_type")
    ])

    assert_equal ["  type = request.media_type"], result.edits.map { |edit| edit["after"] }
  end

  # **A match inside a string or a comment is not a call site.** The service masks a line before it
  # matches; this mirrors that, preserving every byte's position, so the write can be spliced into
  # the raw line at the match's offsets.
  def test_a_match_inside_a_string_or_a_comment_is_not_rewritten
    result = Rewrites.apply([
      entry(subject: "HashWithIndifferentAccess", text: %(  log "HashWithIndifferentAccess is gone")),
      entry(subject: "HashWithIndifferentAccess", text: "  # HashWithIndifferentAccess is gone")
    ])

    assert_empty result.edits, "a string and a comment are not references"
    assert_equal 2, result.left.size
  end

  # An edit that would change nothing is not an edit: a rule that fired on an already-correct line
  # would fill the patch with no-ops a reviewer has to read.
  def test_a_line_the_rule_would_not_change_is_not_an_edit
    result = Rewrites.apply([
      entry(subject: "request.content_type", text: "  type = request.media_type")
    ])

    assert_empty result.edits
  end

  # The shape the applier consumes, and the two fields that make the walker's own edit legible: it
  # *is* a rewrite (`automatic`), and it is not the service's (`origin`).
  def test_an_edit_carries_the_change_s_provenance_and_the_rule_s_origin
    result = Rewrites.apply([entry(subject: "request.content_type", text: "  x = request.content_type")])
    edit = result.edits.first

    assert_equal true, edit["automatic"]
    assert_equal "rule", edit["origin"]
    assert_equal "  x = request.content_type", edit["text"]
    assert_equal "4.0 → 4.1, the chapter", edit["source"]
    assert_equal "the change's own note", edit["note"]
  end

  # **A rule whose change has left the ladder is inert and said to be.** Applying it would be
  # editing code for a change nobody documents any more.
  def test_a_rule_that_names_no_change_in_this_rung_is_reported_rather_than_used
    inert = Rewrites.inert([{ "subject" => "request.content_type" }])

    assert_equal [":confirm option on link_to", "HashWithIndifferentAccess"], inert
    assert_empty Rewrites.inert(Rewrites::RULES.map { |rule| { "subject" => rule.subject } })
  end

  # End to end through the applier: the write is the applier's, so the line re-check, the sealed
  # path and the refusal reasons are the ones the service's own edits get.
  def test_the_rule_s_edit_is_written_by_the_applier_with_the_line_re_checked
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app", "models"))
      path = File.join(root, "app", "models", "thing.rb")
      File.write(path, "class Thing\n  x = HashWithIndifferentAccess.new\nend\n")

      result = Rewrites.apply([entry(subject: "HashWithIndifferentAccess",
        text: "  x = HashWithIndifferentAccess.new", path: "app/models/thing.rb", line: 2)])
      applied = Applier.new(root).apply(result.edits)

      assert_equal 1, applied.applied.size
      assert_equal "rule", applied.applied.first.origin
      assert_includes File.read(path), "x = ActiveSupport::HashWithIndifferentAccess.new"

      # And the same edit against a line that has moved is refused, not half-written.
      stale = result.edits.first.merge("text" => "  x = SomethingElse.new")
      refused = Applier.new(root).apply([stale])

      assert_equal 1, refused.refused.size
      assert_includes refused.refused.first.reason, "is not the line the scan read"
    end
  end
end
