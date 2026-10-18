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
    assert_includes Rewrites.gap_for("default_scope"), "the survey names the callers"
    assert_includes Rewrites.gap_for("alias_attribute"), "the survey names the aliases"
    assert_includes Rewrites.gap_for("assigns / assert_template"),
      "installed in production"
    assert_includes Rewrites.gap_for("config.secret_token"), "leave it in place and add"
    assert_equal Rewrites::GENERIC_GAP, Rewrites.gap_for("a change nobody has looked at yet")
    assert_includes Rewrites::GENERIC_GAP, "no call site to match at all",
      "the generic sentence has to be honest for a change no pattern can find"
  end

  # The gap for a change whose migration belongs to a *later* rung says so, which is the difference
  # between "not automated yet" and "not this rung's business".
  def test_the_render_text_gap_names_the_rung_whose_rule_makes_the_choice
    gap = Rewrites.gap_for("render :text")

    assert_includes gap, "4.1 deprecates `:text` without removing it"
    assert_includes gap, "it is the 5.1 rung's rule that makes it"
  end

  # **A rule whose change has left the ladder is inert and said to be.** Applying it would be
  # editing code for a change nobody documents any more.
  def test_a_rule_that_names_no_change_in_this_rung_is_reported_rather_than_used
    inert = Rewrites.inert([{ "subject" => "request.content_type" }])

    assert_includes inert, ":confirm option on link_to"
    refute_includes inert, "request.content_type"
    named = (Rewrites::RULES.map(&:subject) + Rewrites::BRIDGES.map(&:subject) +
             Rewrites::SURVEYS.map(&:subject)).map { |s| { "subject" => s } }
    assert_empty Rewrites.inert(named), "a rule, bridge or survey that names no change is reported"
  end

  # **A dynamic finder's own name carries its arguments, and the family splits them out.** The note
  # gives each destination; the part a rule per finder would repeat — the attribute list out of the
  # method name — is the family's. The finder Rails *kept* (`find_by_*`) and one whose arguments do
  # not line up with its attributes are both left, because a wrong pairing writes `where(name: 1, 2)`
  # into a file.
  def test_the_dynamic_finders_become_where_and_the_kept_finder_is_left_alone
    result = Rewrites.apply([
      entry(subject: "find_all_by_*", text: "  @items = Item.find_all_by_name(name)"),
      entry(subject: "find_all_by_*", text: "  x = Item.find_all_by_name_and_closed(name, true)"),
      entry(subject: "find_all_by_*", text: "  x = Item.find_last_by_name(name)"),
      entry(subject: "find_all_by_*", text: "  x = Item.find_or_create_by_name(name)"),
      entry(subject: "find_all_by_*", text: "  x = Item.find_or_initialize_by_name(name)"),
      entry(subject: "find_all_by_*", text: "  x = Item.scoped_by_name(name)"),
      entry(subject: "find_all_by_*", text: "  x = Item.find_by_name(name)"),
      entry(subject: "find_all_by_*", text: "  x = Item.find_all_by_name(name, 2)")
    ])

    assert_equal [
      "  @items = Item.where(name: name)",
      "  x = Item.where(name: name, closed: true)",
      "  x = Item.where(name: name).last",
      "  x = Item.find_or_create_by(name: name)",
      "  x = Item.find_or_initialize_by(name: name)",
      "  x = Item.where(name: name)"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal ["find_all_by_*", "find_all_by_*"], result.left,
      "the finder Rails kept, and one whose arguments do not line up with its attributes"
  end

  # The old hash-based finder: the scope decides what replaces it, and the conditions are unwrapped
  # rather than rewritten. Anything else in the options is left, because the note's replacement is the
  # conditions alone and dropping the rest would change what the query returns.
  def test_the_hash_based_finder_becomes_a_where_chain_and_keeps_its_other_options_out
    result = Rewrites.apply([
      entry(subject: "find(:all, ...)", text: "  @items = Item.find(:all, conditions: {name: 'x'})"),
      entry(subject: "find(:all, ...)", text: "  @one = Item.find(:first, conditions: {name: 'x'})"),
      entry(subject: "find(:all, ...)", text: "  @last = Item.find(:last, conditions: {name: 'x'})"),
      entry(subject: "find(:all, ...)",
        text: "  @items = Item.find(:all, conditions: {name: 'x'}, order: 'y')")
    ])

    assert_equal [
      "  @items = Item.where(name: 'x')",
      "  @one = Item.where(name: 'x').first",
      "  @last = Item.where(name: 'x').last"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal ["find(:all, ...)"], result.left
  end

  # **A scope body has to be callable.** The wrap is the edit; the two refusals are the rule. A body
  # that is already a lambda needs nothing, and a body with a trailing comment *cannot* be wrapped:
  # the closing brace would land inside the comment, which is a line that does not parse — the failure
  # that made `Rule#after` refuse a match reaching into a comment at all.
  def test_a_scope_body_is_wrapped_and_a_comment_or_an_existing_lambda_is_left
    result = Rewrites.apply([
      entry(subject: "scope :name, where(...)", text: "  scope :active, where(active: true)"),
      entry(subject: "scope :name, where(...)",
        text: "  scope :recent, order(created_at: :desc).limit(5)"),
      entry(subject: "scope :name, where(...)",
        text: "  scope :active, where(active: true) # the actives"),
      entry(subject: "scope :name, where(...)", text: "  scope :active, -> { where(active: true) }")
    ])

    assert_equal [
      "  scope :active, -> { where(active: true) }",
      "  scope :recent, -> { order(created_at: :desc).limit(5) }"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal ["scope :name, where(...)", "scope :name, where(...)"], result.left
  end

  # **The block whose body is a bare `return`, and the two rungs that need it.** 4.1 wants the value
  # the block meant to return; 5.0 wants the halt written explicitly — so the two instances differ
  # only in what the body becomes, which is what makes this one family. A body with a statement after
  # the `return` is left, because dropping it would be deleting code; 5.0's rule takes only `false`,
  # because a `return true` is a method's value rather than a halt.
  def test_the_inline_block_return_is_rewritten_at_both_rungs_and_left_when_it_is_more_than_one_statement
    four_one = Rewrites.apply([
      entry(subject: "return inside an inline callback block", text: "  before_save { return false }"),
      entry(subject: "return inside an inline callback block",
        text: "  before_save { return false if x }"),
      entry(subject: "return inside an inline callback block", text: "  before_save { return }"),
      entry(subject: "return inside an inline callback block",
        text: "  before_save { return false; other }")
    ])
    five_oh = Rewrites.apply([
      entry(subject: "return false from a before callback", text: "  before_save { return false }"),
      entry(subject: "return false from a before callback",
        text: "  before_save { return false if x }"),
      entry(subject: "return false from a before callback", text: "  before_save { return true }")
    ])

    assert_equal ["  before_save { false }", "  before_save { false if x }", "  before_save { nil }"],
      four_one.edits.map { |edit| edit["after"] }
    assert_equal ["return inside an inline callback block"], four_one.left
    assert_equal ["  before_save { throw(:abort) }", "  before_save { throw(:abort) if x }"],
      five_oh.edits.map { |edit| edit["after"] }
    assert_equal ["return false from a before callback"], five_oh.left
  end

  # **The one rule that reads the rest of the file.** Whether an association is required is not a fact
  # about the `belongs_to` line: a model that already validates the presence is one the new default
  # agrees with, and the diff's whole value is being the list of associations whose behaviour changed.
  # A migration's `t.belongs_to` is a column definition rather than this change at all.
  def test_the_belongs_to_rule_reads_the_model_and_leaves_the_ones_it_already_requires
    files = {
      "app/models/bid.rb" => ["class Bid", "  belongs_to :user", "  belongs_to :item",
                              "  validates_presence_of :item, :amount"],
      "app/models/item.rb" => ["class Item", "  belongs_to :category", "  belongs_to :user",
                               "  validates :user, presence: true"],
      "db/migrate/1_create_items.rb" => ["    t.belongs_to :user"]
    }
    result = Rewrites.apply([
      entry(subject: "belongs_to", text: "  belongs_to :user", path: "app/models/bid.rb"),
      entry(subject: "belongs_to", text: "  belongs_to :item", path: "app/models/bid.rb"),
      entry(subject: "belongs_to", text: "  belongs_to :category", path: "app/models/item.rb"),
      entry(subject: "belongs_to", text: "  belongs_to :user", path: "app/models/item.rb"),
      entry(subject: "belongs_to", text: "    t.belongs_to :user", path: "db/migrate/1_create_items.rb")
    ], files: files)

    assert_equal ["  belongs_to :user, optional: true", "  belongs_to :category, optional: true"],
      result.edits.map { |edit| edit["after"] }
    assert_equal 3, result.left.size,
      "the two associations the models already require, and the migration's column"
  end

  # The rule degrades to the unconditional one when it cannot read the file, because the edit it makes
  # is the behaviour-preserving one either way — and refusing everything it could not read would leave
  # an association to fail validation silently, which is the note's own warning.
  def test_the_belongs_to_rule_still_edits_a_file_it_could_not_read
    result = Rewrites.apply([entry(subject: "belongs_to", text: "  belongs_to :user")])

    assert_equal ["  belongs_to :user, optional: true"], result.edits.map { |edit| edit["after"] }
  end

  # A setting whose *value* moved: the two booleans the release no longer accepts become the two
  # symbols the note names. A line already naming one is left, which is what makes the rule
  # idempotent across two walks.
  def test_the_show_exceptions_booleans_map_to_the_symbols_and_a_mapped_line_is_left
    result = Rewrites.apply([
      entry(subject: "config.action_dispatch.show_exceptions",
        text: "  config.action_dispatch.show_exceptions = false"),
      entry(subject: "config.action_dispatch.show_exceptions",
        text: "  config.action_dispatch.show_exceptions = true"),
      entry(subject: "config.action_dispatch.show_exceptions",
        text: "  config.action_dispatch.show_exceptions = :none")
    ])

    assert_equal [
      "  config.action_dispatch.show_exceptions = :none",
      "  config.action_dispatch.show_exceptions = :all"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal ["config.action_dispatch.show_exceptions"], result.left
  end

  # A statement whose whole text becomes another statement: the match is exact, so a line edited since
  # the guide was written is left rather than half-replaced. And `#{…}` is interpolation rather than a
  # comment, which is the mask's other measured exception — the setting lives inside `%W(#{…})`.
  def test_a_whole_statement_is_replaced_exactly_and_a_changed_one_is_left
    result = Rewrites.apply([
      entry(subject: "config.autoload_paths and $LOAD_PATH",
        text: "    config.autoload_paths += %W(\#{config.root}/lib)"),
      entry(subject: "config.autoload_paths and $LOAD_PATH",
        text: "    config.autoload_paths += %W(\#{config.root}/lib \#{config.root}/app/services)")
    ])

    assert_equal ["    config.autoload_lib(ignore: %w(assets tasks))"],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["config.autoload_paths and $LOAD_PATH"], result.left
  end

  # **A mutator the query no longer has, and the receiver that makes `.to_a` safe.** `Array#to_a`
  # returns the array itself, so the edit is a no-op on one; `Hash#to_a` does not, which is why a
  # local variable is left — nothing on the line says whether it holds a relation or a hash.
  def test_the_relation_mutators_are_materialised_and_a_local_variable_is_left
    result = Rewrites.apply([
      entry(subject: "mutator methods on a Relation", text: "  Item.where(closed: false).compact!"),
      entry(subject: "mutator methods on a Relation", text: "  Item.all.uniq!"),
      entry(subject: "mutator methods on a Relation", text: "  bids.compact!"),
      entry(subject: "mutator methods on a Relation",
        text: "  Item.where(closed: false).to_a.compact!")
    ])

    assert_equal ["  Item.where(closed: false).to_a.compact!", "  Item.all.to_a.uniq!"],
      result.edits.map { |edit| edit["after"] }
    assert_equal 2, result.left.size
  end

  # **A model's superclass, and the file the rename depends on.** The definition itself is the one
  # `ActiveRecord::Base` that stays, so the rule refuses to rename the class it is about to write —
  # which is the bug a second walk would otherwise hit: the scan would locate the file this rule
  # created and make the class inherit from itself.
  def test_the_superclass_moves_and_the_definition_it_names_is_never_renamed
    result = Rewrites.apply([
      entry(subject: "ActiveRecord::Base as a model's superclass",
        text: "class Item < ActiveRecord::Base"),
      entry(subject: "ActiveRecord::Base as a model's superclass",
        text: "class ApplicationRecord < ActiveRecord::Base")
    ])

    assert_equal ["class Item < ApplicationRecord"], result.edits.map { |edit| edit["after"] }
    assert_equal ["app/models/application_record.rb"], result.scaffolds.map(&:path)
    assert_includes result.scaffolds.first.content, "self.abstract_class = true"
    assert_equal ["ActiveRecord::Base as a model's superclass"], result.left
  end

  # **A partial coverage still has a gap.** `params.slice` is an instance while `params.each` is not,
  # and a residue that said "a rule covers this" while leaving four spellings untouched would be the
  # empty-answer trap with the sign flipped. The receiver is captured and put back, because the
  # pattern matched the dot outside it.
  def test_a_subject_a_rule_covers_partly_still_carries_a_gap
    result = Rewrites.apply([
      entry(subject: "params as a Hash", text: "  attrs = params.slice(:a, :b)"),
      entry(subject: "params as a Hash", text: "  attrs = params.each { |k, v| }")
    ])

    assert_equal ["  attrs = params.permit(:a, :b).to_h"], result.edits.map { |edit| edit["after"] }
    assert_equal ["params as a Hash"], result.left
    assert_includes Rewrites.gap_for("params as a Hash"), "`params.slice(...)` is a rule"
    assert_includes Rewrites.gap_for("find_all_by_*"), "whether the *caller* wanted the Array"
  end

  # **A rule may not match into a comment.** `.` matches a blanked comment byte, so a family that runs
  # to the end of the line would wrap the comment too — the line would not parse, and the failure
  # would be reported as the application's breakage. A match that *ends* before the comment is fine.
  def test_a_rule_refuses_a_match_that_reaches_into_a_comment
    result = Rewrites.apply([
      entry(subject: "HashWithIndifferentAccess", text: "  x = HashWithIndifferentAccess.new # a note"),
      entry(subject: "scope :name, where(...)", text: "  scope :a, where(x: 1) # a note")
    ])

    assert_equal ["  x = ActiveSupport::HashWithIndifferentAccess.new # a note"],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["scope :name, where(...)"], result.left
  end

  # **The order restored explicitly.** 5.0 inserts the callback where it is called rather than
  # prepending it, so an authentication filter declared above it runs first — and the note's own
  # answer is `prepend: true`. It goes on unconditionally, because the line does not show what runs
  # before it, and the residue's gap says which of the two cases this application is. A line that
  # already names the option is left, which is what makes a second walk a no-op.
  def test_the_forgery_callback_has_its_order_restored_and_a_restored_line_is_left
    result = Rewrites.apply([
      entry(subject: "protect_from_forgery", text: "  protect_from_forgery with: :exception"),
      entry(subject: "protect_from_forgery", text: "  protect_from_forgery"),
      entry(subject: "protect_from_forgery",
        text: "  protect_from_forgery with: :exception, prepend: true")
    ])

    assert_equal [
      "  protect_from_forgery with: :exception, prepend: true",
      "  protect_from_forgery, prepend: true"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal ["protect_from_forgery"], result.left
    assert_includes Rewrites.gap_for("protect_from_forgery"), "unconditionally"
  end

  # **A bridge is not a rule.** There is no pattern to match and no line to rewrite — the call sites
  # keep working once the gem is declared — so it is selected by what the scan *located* rather than by
  # the rung's whole change list: a change this application does not use needs no library installed.
  # And it counts against the change the way a rule does, which is why `inert` reports a bridge whose
  # change has left the ladder too.
  def test_a_bridge_is_selected_by_what_the_scan_located_and_counts_as_coverage
    located = [entry(subject: "assigns / assert_template", text: "  expect(assigns(:post))")]
    rung = [{ "subject" => "assigns / assert_template" }, { "subject" => "bootsnap" }]
    bridges = Rewrites.bridges(located, changes: rung)

    assert_equal ["assigns / assert_template", "bootsnap"], bridges.map(&:subject),
      "the located change and the one whose evidence is the rung itself — two questions, two answers"
    assert_equal ["rails-controller-testing"], bridges.first.gems
    assert_equal :test, bridges.first.group,
      "a controller-testing helper declared at the top level is installed in production"

    # **The rung is a gate**: a located change this rung does not carry is nobody's bridge — and a
    # bridge whose evidence is the rung needs no located line at all, which is the whole point of it.
    assert_equal ["bootsnap"],
      Rewrites.bridges([entry(subject: "MultiJson", text: "  x = MultiJson.dump(a)")],
        changes: rung).map(&:subject),
      "MultiJson has no bridge, and bootsnap is selected by the rung alone"
    assert_empty Rewrites.bridges(located, changes: []), "no plan, no bridge"
    assert_includes Rewrites.inert([{ "subject" => "MultiJson" }]), "assigns / assert_template"
  end

  # **A setting the release deleted, and the line goes.** The notes are the licence — "the setting has
  # no effect — delete the line", "Remove the line rather than setting it to `:zeitwerk`" — and the
  # pattern is the setting *and* an assignment, so a line that mentions it in a comment, or sets it
  # inside something else, is left. The edit empties the line rather than shifting it away, which is
  # the shape `line_removed` writes for the same reason: a patch that renumbers a file is a patch
  # nobody can read.
  def test_a_deleted_setting_loses_its_line_and_a_mention_of_it_is_left
    result = Rewrites.apply([
      entry(subject: "config.active_record.identity_map",
        text: "  config.active_record.identity_map = true", path: "config/application.rb"),
      entry(subject: "config.active_record.identity_map",
        text: "  # config.active_record.identity_map = true", path: "config/application.rb"),
      entry(subject: "config.active_record.identity_map",
        text: "  x = config.active_record.identity_map = true", path: "config/application.rb"),
      entry(subject: "config.autoloader", text: "  config.autoloader = :zeitwerk",
        path: "config/application.rb")
    ])

    assert_equal ["", ""], result.edits.map { |edit| edit["after"] },
      "each deleted setting's whole line is emptied"
    assert_equal 2, result.left.size, "the comment and the line that sets it inside something else"
  end

  # **A class method that becomes an instance method on its own argument.** The receiver disappears and
  # the argument takes its place — and the *context* is what keeps it to a string, because
  # `:User.constantize` is not a method: the private API took a name and the public one is on the
  # String. The raw line is the only place that can be asked, since the mask blanks a string's
  # contents. The other members of the private API have a different fix each, and are left.
  def test_the_private_dependency_api_becomes_a_call_on_its_argument_and_a_symbol_is_left
    result = Rewrites.apply([
      entry(subject: "ActiveSupport::Dependencies private API",
        text: %(  name = ActiveSupport::Dependencies.constantize("User")), path: "lib/x.rb"),
      entry(subject: "ActiveSupport::Dependencies private API",
        text: %(  name = ActiveSupport::Dependencies.safe_constantize("User")), path: "lib/x.rb"),
      entry(subject: "ActiveSupport::Dependencies private API",
        text: "  name = ActiveSupport::Dependencies.constantize(:User)", path: "lib/x.rb"),
      entry(subject: "ActiveSupport::Dependencies private API",
        text: "  ActiveSupport::Dependencies.mechanism = :load", path: "lib/x.rb")
    ])

    assert_equal [%(  name = "User".constantize), %(  name = "User".safe_constantize)],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["ActiveSupport::Dependencies private API"] * 2, result.left
  end

  # **The guard is what makes an appending rule safe across two walks.** Without it the rule appends a
  # second `.with_indifferent_access` on the next rung, and the failure is a line that parses and does
  # something else. A two-argument call is left, because the note's replacement names the one-argument
  # form and the arguments are part of what the call means.
  def test_a_conversion_is_appended_to_the_call_and_never_twice
    result = Rewrites.apply([
      entry(subject: "config_for", text: "  smtp = Rails.application.config_for(:smtp)"),
      entry(subject: "config_for",
        text: "  smtp = Rails.application.config_for(:smtp).with_indifferent_access"),
      entry(subject: "config_for",
        text: %(  smtp = Rails.application.config_for(:smtp, env: "production")))
    ])

    assert_equal ["  smtp = Rails.application.config_for(:smtp).with_indifferent_access"],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["config_for"] * 2, result.left
  end

  # **The 5.1 rung of the `render :text` story, where the choice has to be made.** 4.1 deprecates
  # `:text` without removing it; here the deprecation has run out and the note's own answer is
  # `plain:` — the safe one, because `:text` sent `text/html` and interpreted markup in the content.
  # The pattern is anchored on the *call*, because `text:` appears in other calls' option hashes on the
  # same line and a rule that matched the first one would rewrite the wrong option. A `:nothing` with a
  # status is left, because the status names the `head` call and that is a different statement.
  def test_render_text_becomes_plain_and_the_option_is_anchored_on_the_call
    result = Rewrites.apply([
      entry(subject: "render :text / render :nothing", text: %(    render :text => "hello"),
        path: "app/controllers/posts_controller.rb"),
      entry(subject: "render :text / render :nothing", text: "    render text: @body",
        path: "app/controllers/posts_controller.rb"),
      entry(subject: "render :text / render :nothing", text: %(    render(:text => "hello")),
        path: "app/controllers/posts_controller.rb"),
      entry(subject: "render :text / render :nothing", text: %(    render partial: "x", locals: { text: "y" }),
        path: "app/views/posts/index.html.erb"),
      entry(subject: "render :text / render :nothing", text: "    render plain: @body",
        path: "app/controllers/posts_controller.rb"),
      entry(subject: "render :text / render :nothing", text: "    render :nothing => true",
        path: "app/controllers/posts_controller.rb"),
      entry(subject: "render :text / render :nothing", text: "    render :nothing => true, status: :created",
        path: "app/controllers/posts_controller.rb")
    ])

    assert_equal [
      %(    render plain: "hello"),
      "    render plain: @body",
      %(    render(plain: "hello")),
      "    head :ok"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal 3, result.left.size,
      "the option in another call's hash, the line already saying plain:, and a :nothing with a status"
    assert_includes Rewrites.gap_for("render :text / render :nothing"), "is for a response that *is* markup"
  end

  # **Two options the release now requires, both behaviour-preserving.** A `match` without `via:` is
  # *removed* in 4.0, so the rung requires an edit and `via: :all` is the one that keeps the route
  # answering what it answered — the narrowing is the application's, which is what the gap says. And a
  # `button_to` built from a persisted record renders PATCH rather than POST from 7.0, where
  # `method: :post` is the note's own answer and, on a button built from a path, the default it already
  # had.
  def test_a_route_names_its_verbs_and_a_button_names_its_method
    routes = Rewrites.apply([
      entry(subject: "match without via:", text: %(  match "/legacy" => "legacy#index"),
        path: "config/routes.rb"),
      entry(subject: "match without via:", text: %(  match "/a" => "b#c", as: :legacy),
        path: "config/routes.rb"),
      entry(subject: "match without via:", text: %(  match "/legacy" => "legacy#index", via: :get),
        path: "config/routes.rb"),
      entry(subject: "match without via:", text: %(  match "/legacy" => "legacy#index" do),
        path: "config/routes.rb")
    ])
    views = Rewrites.apply([
      entry(subject: "button_to", text: %(  <%= button_to "Delete", item %>),
        path: "app/views/items/index.html.erb"),
      entry(subject: "button_to", text: %(  <%= button_to "Delete", item, class: "btn" %>),
        path: "app/views/items/index.html.erb"),
      entry(subject: "button_to", text: %(  <%= button_to "Delete", item, method: :post %>),
        path: "app/views/items/index.html.erb"),
      entry(subject: "button_to", text: %(  <%= button_to "Delete", item_path(item) %>),
        path: "app/views/items/index.html.erb"),
      entry(subject: "button_to", text: %(  <%= button_to "Delete", item %><% end %>),
        path: "app/views/items/index.html.erb")
    ])

    assert_equal [%(  match "/legacy" => "legacy#index", via: :all),
      %(  match "/a" => "b#c", as: :legacy, via: :all)], routes.edits.map { |edit| edit["after"] }
    assert_equal ["match without via:"] * 2, routes.left
    assert_equal [%(  <%= button_to "Delete", item, method: :post %>),
      %(  <%= button_to "Delete", item, class: "btn", method: :post %>)],
      views.edits.map { |edit| edit["after"] },
      "the declaration goes inside the ERB tag, not after it"
    assert_equal 3, views.left.size,
      "a button that already names the method, one built from a path, and a line with two tags"
    assert_includes Rewrites.gap_for("match without via:"), "which verbs this route wants"
    assert_includes Rewrites.gap_for("button_to"), "the default it already had"
  end

  # The setting moved rather than disappearing, and the name is the whole edit.
  def test_the_translation_setting_moves_to_the_i18n_namespace
    result = Rewrites.apply([
      entry(subject: "config.action_view.raise_on_missing_translations",
        text: "  config.action_view.raise_on_missing_translations = true",
        path: "config/environments/development.rb")
    ])

    assert_equal ["  config.i18n.raise_on_missing_translations = true"],
      result.edits.map { |edit| edit["after"] }
    assert_includes Rewrites.gap_for("config.action_view.raise_on_missing_translations"),
      "a custom I18n exception handler"
  end

  # **A call that wraps another, unwrapped.** The target is captured rather than named, because
  # `config.logger` is the same edit, and the argument's extent is the family's careful half: an
  # argument nested deeper than one level is left rather than cut in half.
  def test_the_broadcast_logger_wrapper_is_unwrapped_and_a_deep_argument_is_left
    result = Rewrites.apply([
      entry(subject: "Rails.logger",
        text: %(  Rails.logger.extend(ActiveSupport::Logger.broadcast(Logger.new("log/x.log")))),
        path: "config/environments/production.rb"),
      entry(subject: "Rails.logger",
        text: %(  config.logger.extend(ActiveSupport::Logger.broadcast(other)) if ENV["X"]),
        path: "config/environments/production.rb"),
      entry(subject: "Rails.logger",
        text: "  Rails.logger.extend(ActiveSupport::Logger.broadcast(a.b(c.d(e))))",
        path: "config/environments/production.rb")
    ])

    assert_equal [%(  Rails.logger.broadcast_to(Logger.new("log/x.log"))),
      %(  config.logger.broadcast_to(other) if ENV["X"])],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["Rails.logger"], result.left
    assert_includes Rewrites.gap_for("Rails.logger"), "nested deeper than one level"
  end

  # **The definition is the edit.** 6.1 passes the callback's name to `halted_callback_hook` as a second
  # argument with no deprecation cycle, so a one-argument override raises `ArgumentError` the moment a
  # callback halts — and the arity is on the line the scan located, which the gap beside this rule had
  # assumed was not true.
  def test_a_definition_that_gained_a_parameter_gets_one_named_for_being_unused
    result = Rewrites.apply([
      entry(subject: "halted_callback_hook", text: "      def halted_callback_hook(message)"),
      entry(subject: "halted_callback_hook", text: "      def self.halted_callback_hook(message)")
    ])

    assert_equal ["      def halted_callback_hook(message, _name)",
      "      def self.halted_callback_hook(message, _name)"], result.edits.map { |edit| edit["after"] }

    # A definition that already takes the second parameter does not match, which is what makes the rule
    # idempotent without an `already` pattern: the argument run excludes commas.
    already = Rewrites.apply([entry(subject: "halted_callback_hook",
      text: "      def halted_callback_hook(message, name)")])
    assert_empty already.edits
    assert_includes Rewrites.gap_for("halted_callback_hook"), "without parentheses"
  end

  # "The around callback now receives the block as an argument" — both spellings the note's sentence
  # covers, and the ampersand is the whole edit.
  def test_the_block_a_callback_receives_becomes_a_parameter
    result = Rewrites.apply([
      entry(subject: "ActiveSupport::Callbacks.set_callback",
        text: "    set_callback :save, :around, ->(record, &block) { block.call(record) }"),
      entry(subject: "ActiveSupport::Callbacks.set_callback",
        text: "    set_callback :save, :around do |record, &block|")
    ])

    assert_equal [
      "    set_callback :save, :around, ->(record, block) { block.call(record) }",
      "    set_callback :save, :around do |record, block|"
    ], result.edits.map { |edit| edit["after"] }

    # A line with no captured block is not a line this rule can help, and it stays a decision.
    assert_empty Rewrites.apply([entry(subject: "ActiveSupport::Callbacks.set_callback",
      text: "    set_callback :save, :before, :check")]).edits

    # **A block-pass is not a parameter list**, and this is the difference the pattern is built on:
    # `&block` as an argument passes the proc as the callback's body, so removing the ampersand would
    # pass the proc as an argument instead — a different call, silently.
    assert_empty Rewrites.apply([entry(subject: "ActiveSupport::Callbacks.set_callback",
      text: "    set_callback :save, :around, &handler")]).edits
  end

  # **A survey reports rather than edits**, and that is what makes it the honest place for a change whose
  # fix is a judgement. `default_scope` is the case: 4.1 merges the scope with the conditions a caller
  # chains, and which of `unscope`, `rewhere` and `unscoped` an application meant is not something a
  # pattern can know — but *which callers read differently* is a fact about the tree, and naming them is
  # the difference between "needs a person" and "needs a person, and these are the lines".
  def test_the_default_scope_survey_names_the_callers_that_read_differently
    tree = {
      "app/models/item.rb" => [
        "class Item < ApplicationRecord\n",
        "  default_scope { where(active: true) }\n",
        "  scope :cheap, -> { where(price: 0..10) }\n",
        "  scope :archived, -> { where(active: false) }\n"
      ],
      "app/controllers/items_controller.rb" => [
        "class ItemsController\n",
        "  def index\n",
        "    @items = Item.where(active: false).order(:name)\n",
        "    @other = Item.where(price: 0).count\n",
        "  end\n"
      ]
    }
    located = [entry(subject: "default_scope", path: "app/models/item.rb", line: 2,
      text: "  default_scope { where(active: true) }")]

    found = Rewrites.survey([{ "subject" => "default_scope" }], tree: tree, located: located)
      .fetch("default_scope")

    assert_equal ["app/models/item.rb:4", "app/controllers/items_controller.rb:3"],
      found.findings.map { |path, line, _| "#{path}:#{line}" },
      "the scope's own line is not a caller of itself, and a condition on another column is not this " \
      "change's — the two halves have to meet"
    assert_includes Rewrites.findings_sentence(found.findings), "Item.where(active: false)"
  end

  # A change the rung does not carry is asked nothing, and a subject no survey names has no entry at
  # all — so the residue can tell "the analysis found nothing" from "nobody has written the analysis".
  def test_a_survey_runs_only_for_the_changes_the_rung_carries
    tree = { "app/models/item.rb" => ["class Item\n", "  default_scope { where(active: true) }\n"] }
    located = [entry(subject: "default_scope", path: "app/models/item.rb", line: 2,
      text: "  default_scope { where(active: true) }")]

    assert_empty Rewrites.survey([{ "subject" => "a change with no reader" }], tree: tree, located: located),
      "a subject no survey names has no entry — which is what tells \"no survey\" from \"none found\""

    found = Rewrites.survey([{ "subject" => "default_scope" }], tree: tree, located: located)
    assert_predicate found.fetch("default_scope").findings, :empty?,
      "the declaration alone is not a caller that reads differently"
  end

  # The other two surveys, and each is one question about the tree: does anything *assign* to the
  # collection, and does the file define the method the alias names?
  def test_the_assignment_and_alias_surveys_read_the_tree_rather_than_a_line
    tree = {
      "app/models/post.rb" => [
        "class Post < ApplicationRecord\n",
        "  has_many_attached :photos\n",
        "  alias_attribute :headline, :title\n",
        "  def title\n",
        "    super.upcase\n",
        "  end\n"
      ],
      "app/controllers/posts_controller.rb" => [
        "class PostsController\n",
        "  def update\n",
        "    @post.photos = params[:photos]\n",
        "    @post.photos.attach(params[:one])\n",
        "  end\n"
      ]
    }

    assignments = Rewrites.survey([{ "subject" => "has_many_attached assignment" }], tree: tree,
      located: [entry(subject: "has_many_attached assignment", path: "app/models/post.rb", line: 2,
        text: "  has_many_attached :photos")]).fetch("has_many_attached assignment")
    assert_equal ["app/controllers/posts_controller.rb:3"],
      assignments.findings.map { |path, line, _| "#{path}:#{line}" },
      "`attach` adds without replacing, so the call that already uses it is not a call site that " \
      "changes behaviour"

    aliases = Rewrites.survey([{ "subject" => "alias_attribute" }], tree: tree,
      located: [entry(subject: "alias_attribute", path: "app/models/post.rb", line: 3,
        text: "  alias_attribute :headline, :title")]).fetch("alias_attribute")
    assert_equal ["app/models/post.rb:4"], aliases.findings.map { |path, line, _| "#{path}:#{line}" },
      "the alias whose original the file defines itself is exactly the deprecation warning's list"
  end

  # The stored column's symbol access, which is what stops working: the accessors `store_accessor`
  # defines are methods and are unaffected, so a survey that reported *those* would report every method
  # call in the application instead of the one thing that changed.
  def test_the_json_and_hstore_survey_reports_symbol_indexing_into_the_column
    tree = {
      "app/models/profile.rb" => [
        "class Profile < ApplicationRecord\n",
        "  store_accessor :settings, :theme\n",
        "  def dark?\n",
        "    theme == \"dark\"\n",
        "  end\n"
      ],
      "app/controllers/profiles_controller.rb" => [
        "class ProfilesController\n",
        "  def show\n",
        "    @theme = @profile.settings[:theme]\n",
        "    @keys = @profile.settings.keys\n",
        "  end\n"
      ]
    }
    located = [entry(subject: "json and hstore columns", path: "app/models/profile.rb", line: 2,
      text: "  store_accessor :settings, :theme")]

    found = Rewrites.survey([{ "subject" => "json and hstore columns" }], tree: tree,
      located: located).fetch("json and hstore columns")

    assert_equal ["app/controllers/profiles_controller.rb:3"],
      found.findings.map { |path, line, _| "#{path}:#{line}" },
      "the accessor call is a method and keeps working; the symbol index into the column does not"
  end

  # **A survey for a change whose answer is the opposite of a rename.** The note says to *leave*
  # `secret_token` in place and add `secret_key_base` beside it — a Rails 3 cookie is upgraded on the way
  # in, and a Rails 4 cookie cannot be read by Rails 3, so the two together are what makes a rollback
  # possible. The value is one only the application has, so the edit is not this tool's; what it can add
  # is the fact the note turns on, which is whether the key base is set yet.
  def test_the_secret_token_survey_says_whether_the_key_base_is_set_beside_it
    tree = {
      "config/initializers/secret_token.rb" => [
        "# Be sure to restart your server when you modify this file.\n",
        "Myapp::Application.config.secret_token = ENV[\"SECRET_TOKEN\"]\n"
      ]
    }
    located = [entry(subject: "config.secret_token", path: "config/initializers/secret_token.rb",
      line: 2, text: "Myapp::Application.config.secret_token = ENV[\"SECRET_TOKEN\"]")]

    found = Rewrites.survey([{ "subject" => "config.secret_token" }], tree: tree,
      located: located).fetch("config.secret_token")
    assert_includes Rewrites.findings_sentence(found.findings), "secret_key_base is not set anywhere"

    with_key = tree.merge("config/secrets.yml" => ["production:\n", "  secret_key_base: <%= ENV[\"X\"] %>\n"])
    found = Rewrites.survey([{ "subject" => "config.secret_token" }], tree: with_key,
      located: located).fetch("config.secret_token")
    assert_includes Rewrites.findings_sentence(found.findings), "secret_key_base is set elsewhere"
  end

  # **The call sites themselves are the evidence** for a change whose work is a review: a decision names
  # one line, so a change with three call sites has two the residue never shows. This is the family that
  # fixes that, and the assertion that matters is that *all* of them come back.
  def test_a_survey_of_call_sites_returns_all_of_them_and_not_only_the_first
    located = [entry(subject: "assert_tag", path: "test/controllers/posts_controller_test.rb", line: 12,
      text: "    assert_tag tag: \"div\", attributes: { id: \"post\" }"),
      entry(subject: "assert_tag", path: "test/controllers/posts_controller_test.rb", line: 18,
        text: "    assert_tag tag: \"span\""),
      entry(subject: "assert_tag", path: "test/views/posts_test.rb", line: 4,
        text: "    assert_tag tag: \"h1\"")]

    found = Rewrites.survey([{ "subject" => "assert_tag" }], tree: {}, located: located)
      .fetch("assert_tag")

    assert_equal ["test/controllers/posts_controller_test.rb:12",
      "test/controllers/posts_controller_test.rb:18", "test/views/posts_test.rb:4"],
      found.findings.map { |path, line, _| "#{path}:#{line}" }
    assert_includes Rewrites.findings_sentence(found.findings), "test/views/posts_test.rb:4"
    assert_includes found.sentence, "the assertions to rewrite"
  end

  # **A setting's own value is the fact**, and for `force_ssl` there are two: which controllers ask for it
  # and whether the application-wide setting is on. Moving one to the other changes what it covers — a
  # controller's `force_ssl` is its actions, `config.force_ssl` is everything — so the survey says both
  # rather than making the move.
  def test_the_force_ssl_survey_names_the_controllers_and_the_application_wide_setting
    tree = {
      "app/controllers/checkouts_controller.rb" => [
        "class CheckoutsController < ApplicationController\n",
        "  force_ssl only: [:create]\n"
      ],
      "config/environments/production.rb" => [
        "Rails.application.configure do\n",
        "  config.force_ssl = true\n"
      ]
    }
    located = [entry(subject: "force_ssl in a controller", path: "app/controllers/checkouts_controller.rb",
      line: 2, text: "  force_ssl only: [:create]")]

    found = Rewrites.survey([{ "subject" => "force_ssl in a controller" }], tree: tree, located: located)
      .fetch("force_ssl in a controller")
    assert_includes Rewrites.findings_sentence(found.findings),
      "config.force_ssl is set in config/environments/production.rb"

    without = Rewrites.survey([{ "subject" => "force_ssl in a controller" }],
      tree: tree.except("config/environments/production.rb"), located: located)
      .fetch("force_ssl in a controller")
    assert_includes Rewrites.findings_sentence(without.findings),
      "config.force_ssl is not set anywhere"
  end

  # `:test` is the one adapter this change does not touch, and the survey is what tells the two apart —
  # the difference between a test environment that behaves the same and one that quietly does not.
  def test_the_queue_adapter_survey_reads_the_value_rather_than_the_line
    tree = {
      "config/environments/test.rb" => [
        "Rails.application.configure do\n",
        "  config.active_job.queue_adapter = :test\n",
        "  config.active_job.queue_adapter = :sidekiq # the suite drives the real one\n"
      ]
    }
    located = [
      entry(subject: "config.active_job.queue_adapter in tests", path: "config/environments/test.rb",
        line: 2, text: "  config.active_job.queue_adapter = :test"),
      entry(subject: "config.active_job.queue_adapter in tests", path: "config/environments/test.rb",
        line: 3, text: "  config.active_job.queue_adapter = :sidekiq # the suite drives the real one")
    ]

    found = Rewrites.survey([{ "subject" => "config.active_job.queue_adapter in tests" }],
      tree: tree, located: located).fetch("config.active_job.queue_adapter in tests")
    sentence = Rewrites.findings_sentence(found.findings)

    assert_includes sentence, "the test adapter, which this change does not touch"
    assert_includes sentence, ":sidekiq — every test now runs on it"
  end

  # **The indexing is what breaks, and the string key is what marks it** — and those are lines the scan
  # did not stop on, because the change's own detect finds the assignment. So this survey reads the tree
  # rather than the located entries, which is the other half of what a survey is for.
  def test_the_secrets_survey_finds_the_string_key_indexing_the_scan_did_not_stop_on
    tree = {
      "config/initializers/smtp.rb" => [
        "Rails.application.config.action_mailer.smtp_settings = {\n",
        "  address: Rails.application.secrets[:smtp][\"address\"],\n",
        "  user_name: Rails.application.secrets[:smtp][:user_name]\n",
        "}\n"
      ]
    }
    located = [entry(subject: "Rails.application.secrets", path: "config/initializers/smtp.rb", line: 1,
      text: "Rails.application.config.action_mailer.smtp_settings = {")]

    found = Rewrites.survey([{ "subject" => "Rails.application.secrets" }], tree: tree, located: located)
      .fetch("Rails.application.secrets")

    assert_equal ["config/initializers/smtp.rb:2"],
      found.findings.map { |path, line, _| "#{path}:#{line}" },
      "the symbol key is the shape the release wants, so it is not a finding"
  end

  # **A concern the release stopped including**, where the note's own condition ("a controller that
  # streams") is a fact about the *file* rather than about the class line — so the rule asks the file.
  # The write is two lines, because the applier replaces a line and this edit is the line plus the one
  # under it.
  def test_a_concern_the_release_stopped_including_goes_under_the_class_that_needs_it
    tree = {
      "app/controllers/blobs_controller.rb" => [
        "class BlobsController < ActiveStorage::BaseController\n",
        "  def show\n",
        "    send_blob_stream(blob)\n",
        "  end\n",
        "end\n"
      ]
    }
    located = [entry(subject: "ActiveStorage::BaseController",
      path: "app/controllers/blobs_controller.rb", line: 1,
      text: "class BlobsController < ActiveStorage::BaseController")]
    result = Rewrites.apply(located, files: tree)

    assert_equal ["class BlobsController < ActiveStorage::BaseController\n  include ActiveStorage::Streaming"],
      result.edits.map { |edit| edit["after"] }

    # A subclass whose own file does not stream is not one the note is about, and it stays a decision.
    plain = tree.merge("app/controllers/blobs_controller.rb" => [
      "class BlobsController < ActiveStorage::BaseController\n", "end\n"
    ])
    assert_empty Rewrites.apply(located, files: plain).edits

    # And one that already includes it is left, which is the `already` guard.
    included = tree.merge("app/controllers/blobs_controller.rb" => [
      "class BlobsController < ActiveStorage::BaseController\n",
      "  include ActiveStorage::Streaming\n",
      "  def show\n",
      "    send_blob_stream(blob)\n",
      "  end\n",
      "end\n"
    ])
    assert_empty Rewrites.apply(located, files: included).edits
    assert_includes Rewrites.gap_for("ActiveStorage::BaseController"), "stays a decision"
  end

  # **A setting is the evidence for a change that has no call site.** The same setting is spelled
  # differently in each place it can live, so the match is on its last segment as a whole word — and the
  # question is only whether the application mentions it.
  def test_a_setting_survey_reads_the_application_for_the_setting_it_names
    tree = {
      "config/environments/test.rb" => [
        "Rails.application.configure do\n",
        "  config.active_support.test_order = :sorted\n"
      ],
      "config/application.rb" => [
        "module Myapp\n",
        "  class Application < Rails::Application\n"
      ]
    }

    found = Rewrites.survey([{ "subject" => "config.active_support.test_order" }], tree: tree,
      located: []).fetch("config.active_support.test_order")
    assert_equal ["config/environments/test.rb:2"],
      found.findings.map { |path, line, _| "#{path}:#{line}" }

    # A change the rung carries whose setting the application never mentions says so, which is the
    # difference between "already chosen" and "left at the new default".
    assert_predicate Rewrites.survey([{ "subject" => "cookies_serializer" }], tree: tree, located: [])
      .fetch("cookies_serializer").findings, :empty?
  end

  # `db/schema.rb` is a `.rb` file the scan reads and no detect pattern looks at, which is exactly why
  # the columns a JSON change is about are a survey's job rather than a rule's.
  def test_the_json_column_survey_reads_the_schema_and_not_the_application
    tree = {
      "db/schema.rb" => [
        "ActiveRecord::Schema.define(version: 2020_01_01) do\n",
        "  create_table \"events\" do |t|\n",
        "    t.jsonb \"payload\", default: {}\n",
        "    t.string \"name\"\n"
      ],
      "app/models/event.rb" => ["class Event < ApplicationRecord\n", "  # a jsonb payload\n"]
    }

    found = Rewrites.survey([{ "subject" => "JSON and JSONB columns" }], tree: tree, located: [])
      .fetch("JSON and JSONB columns")
    assert_equal ["db/schema.rb:3"], found.findings.map { |path, line, _| "#{path}:#{line}" }
  end

  # **Two surveys that join a declaration to the lines it affects.** `serialize`'s declarations name the
  # attributes and the *assignment* is what changed, so the survey joins the two; `ActiveModel::Error`
  # has no detect at all, so the survey reads the tree for the calls the note names — and `errors.add` is
  # deliberately not one of them, because adding an error is the same call it always was.
  def test_the_serialize_and_errors_surveys_join_a_declaration_to_the_lines_it_affects
    tree = {
      "app/models/report.rb" => [
        "class Report < ApplicationRecord\n",
        "  serialize :payload, JSON\n",
        "  def clear!\n",
        "    self.payload = nil\n",
        "  end\n",
        "end\n"
      ],
      "app/models/thing.rb" => [
        "class Thing < ApplicationRecord\n",
        "  validate :sane\n",
        "  def sane\n",
        "    errors.add(:name, :blank) if name.blank?\n",
        "    errors[:name].any? && errors.each { |e| e.message }\n",
        "  end\n",
        "end\n"
      ]
    }
    located = [entry(subject: "serialize", path: "app/models/report.rb", line: 2,
      text: "  serialize :payload, JSON")]

    serialized = Rewrites.survey([{ "subject" => "serialize" }], tree: tree, located: located)
      .fetch("serialize")
    assert_equal ["app/models/report.rb:4"],
      serialized.findings.map { |path, line, _| "#{path}:#{line}" }

    errors = Rewrites.survey([{ "subject" => "ActiveModel::Error" }], tree: tree, located: [])
      .fetch("ActiveModel::Error")
    assert_equal ["app/models/thing.rb:5"], errors.findings.map { |path, line, _| "#{path}:#{line}" },
      "`errors.add` is the call it always was, and the collection reads are what changed"
  end

  # **A processor is a deployment's choice**, so the survey names the call sites whose options differ and
  # says whether a processor has been chosen — the same shape as `force_ssl`, and the reason neither is a
  # rule: rewriting the option names is only right once the processor is known.
  def test_the_variant_survey_names_the_call_sites_and_the_processor_setting
    tree = { "config/application.rb" => [
      "module Myapp\n", "  class Application < Rails::Application\n",
      "    config.active_storage.variant_processor = :mini_magick\n"
    ] }
    located = [entry(subject: "Active Storage variant processor", path: "app/views/posts/show.html.erb",
      line: 3, text: "  <%= image_tag post.photo.variant(resize: \"300x300\") %>")]

    found = Rewrites.survey([{ "subject" => "Active Storage variant processor" }], tree: tree,
      located: located).fetch("Active Storage variant processor")
    assert_includes Rewrites.findings_sentence(found.findings),
      "variant_processor is set in config/application.rb"

    without = Rewrites.survey([{ "subject" => "Active Storage variant processor" }], tree: {}, located: located)
      .fetch("Active Storage variant processor")
    assert_includes Rewrites.findings_sentence(without.findings), "takes the new default"
  end

  def test_a_finding_list_is_bounded_and_says_how_many_it_left_out
    findings = (1..9).map { |n| ["app/models/item.rb", n, "  where(active: #{n})\n"] }
    sentence = Rewrites.findings_sentence(findings)

    assert_includes sentence, "app/models/item.rb:1"
    assert_includes sentence, "app/models/item.rb:5"
    assert_includes sentence, "and 4 more"
    refute_includes sentence, "app/models/item.rb:6"
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
