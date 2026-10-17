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

  # **A removal rule, and its whole-line safety.** The note says "every use of it can be deleted",
  # and the edit is the whole line — so only a line that is nothing but the call is touched. A line
  # with code after it, or one that merely mentions the name, is left: removing the line would take
  # whatever else was on it.
  def test_the_removal_rule_takes_a_whole_line_and_leaves_every_other_shape_alone
    result = Rewrites.apply([
      entry(subject: "require_dependency", text: %(require_dependency "app/models/post")),
      entry(subject: "require_dependency", text: %(require_dependency "x"; Post.new)),
      entry(subject: "require_dependency", text: %(  # require_dependency "x" was here))
    ])

    assert_equal 1, result.edits.size
    assert_equal "", result.edits.first["after"], "the line should be emptied, not shifted away"
    assert_equal ["require_dependency", "require_dependency"], result.left,
      "the line with code after it and the comment are both left"
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

  # **A note that forbids a swap is read as what it forbids, not as a verdict.** `MultiJson`'s note
  # says "do not swap it mechanically for JSON.dump/JSON.load — those serialise arbitrary Ruby
  # objects and are not the same thing", and it is right about the *names*. The ladder's own
  # replacement is `obj.to_json`, which is the same operation for a call that takes one argument —
  # so the edit is mechanical there, and a call carrying options is a decision.
  def test_the_multi_json_note_forbids_the_names_and_not_the_edit
    result = Rewrites.apply([
      entry(subject: "MultiJson", text: "  body = MultiJson.dump(payload)"),
      entry(subject: "MultiJson", text: "  data = MultiJson.load(response.body)"),
      entry(subject: "MultiJson", text: "  body = MultiJson.dump(payload, pretty: true)")
    ])

    assert_equal ["  body = payload.to_json", "  data = JSON.parse(response.body)"],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["MultiJson"], result.left, "a call with options is not the same operation"
  end

  # **A family is the reusable half, and this is the proof**: a name that moved, in a library nobody
  # has walked yet, is an instance of the same family the Rails rules use.
  def test_a_family_builds_the_same_rule_for_another_lighthouse
    rule = Rewrites.name_moved(subject: "SomeGem::Old", from: "Old", to: "New")
    result = Rewrites.apply([entry(subject: "SomeGem::Old", text: "  x = Old.new")], rules: [rule])

    assert_equal :name_moved, rule.family
    assert_equal ["  x = New.new"], result.edits.map { |edit| edit["after"] }
  end

  # **Nothing is "never".** A change with no rule is a *gap*, and the gap says what would close it —
  # which is what makes the residue a queue with reasons rather than a list a person re-derives every
  # rung. A subject nobody has looked at says so in the generic sentence rather than reading as a
  # verdict, and a change a rule covers needs no gap at all.
  def test_a_gap_says_what_would_close_it_and_what_nobody_has_looked_at_says_so
    assert_nil Rewrites.gap_for("MultiJson"), "a covered change needs no gap"
    assert_includes Rewrites.gap_for("default_scope"), "callers that chain conditions onto the scope"
    assert_includes Rewrites.gap_for("belongs_to"), "whether absence is legal"
    assert_equal Rewrites::GENERIC_GAP, Rewrites.gap_for("a change nobody has looked at yet")
    assert_includes Rewrites::GENERIC_GAP, "carried as a located decision until one is written"
  end

  # The gap for a change whose migration belongs to a *later* rung says so, which is the difference
  # between "not automated yet" and "not this rung's business".
  def test_the_render_text_gap_names_the_spelling_and_the_rung_the_choice_belongs_to
    gap = Rewrites.gap_for("render :text")

    assert_includes gap, "`render :text => x` becomes `render text: x`"
    assert_includes gap, "belongs to the 5.0 rung"
  end

  # **A rule whose change has left the ladder is inert and said to be.** Applying it would be
  # editing code for a change nobody documents any more.
  def test_a_rule_that_names_no_change_in_this_rung_is_reported_rather_than_used
    inert = Rewrites.inert([{ "subject" => "request.content_type" }])

    assert_equal [":confirm option on link_to", "HashWithIndifferentAccess", "require_dependency",
                  "MultiJson"], inert
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
