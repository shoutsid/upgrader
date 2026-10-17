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
    assert_includes Rewrites.gap_for("alias_attribute"), "the attribute's own definition"
    assert_includes Rewrites.gap_for("assigns / assert_template"),
      "installed in production"
    assert_includes Rewrites.gap_for("config.secret_token"), "leave it in place and add"
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

    assert_includes inert, ":confirm option on link_to"
    refute_includes inert, "request.content_type"
    named = (Rewrites::RULES.map(&:subject) + Rewrites::BRIDGES.map(&:subject)).map { |s| { "subject" => s } }
    assert_empty Rewrites.inert(named), "a rule or bridge that names no change is reported"
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
    bridges = Rewrites.bridges(located)

    assert_equal ["assigns / assert_template"], bridges.map(&:subject)
    assert_equal ["rails-controller-testing"], bridges.first.gems
    assert_equal :test, bridges.first.group,
      "a controller-testing helper declared at the top level is installed in production"
    assert_empty Rewrites.bridges([entry(subject: "MultiJson", text: "  x = MultiJson.dump(a)")])
    assert_includes Rewrites.inert([{ "subject" => "MultiJson" }]), "assigns / assert_template"
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
