# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The changes this walker makes that the service will not.
#
# `/api/rails/scan` locates a call site and stops: its contract is a statement about the ladder. A rule
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

    # **And the ERB spelling, which is the one the call sites actually have.** The value's lookahead accepted
    # `,`, `)` or the end of the line — so a view's `<%= link_to … confirm: 'x' %>` was refused, and every
    # `:confirm` call site in the first real application is in a view. The rule applied nothing there for a
    # whole session of walks, and the residue said the change was refused rather than unreadable.
    view = Rewrites.apply([
      entry(subject: ":confirm option on link_to", path: "app/views/x.html.erb",
        text: %(<%= link_to 'Delete', post, confirm: 'Sure?' %>)),
      entry(subject: ":confirm option on link_to", path: "app/views/x.html.erb",
        text: %(<%= link_to 'Delete', post, :confirm => "Sure?" %>))
    ])

    assert_equal [
      %(<%= link_to 'Delete', post, data: { confirm: 'Sure?' } %>),
      %(<%= link_to 'Delete', post, data: { confirm: "Sure?" } %>)
    ], view.edits.map { |edit| edit["after"] }
    assert_equal 2, view.applied.size

    # And a line that already carries the wrapper is *satisfied* rather than refused: the rule's own guard is
    # the reader that can tell "this application already reads the new way" from "nobody can read this line".
    # **Every spelling of the wrapper, because a guard that misses one mangles a line**: the hash-rocket form
    # with a second option after it came out as `:data => { data: { confirm: … }, :method => :delete }`, and
    # the first real application's own devise view is one comma away from that shape.
    [
      %(<%= link_to 'Delete', post, data: { confirm: 'Sure?' } %>),
      %(<%= link_to 'Delete', post, data: { confirm: 'Sure?', class: 'btn' } %>),
      %(<%= button_to 'Cancel', path, :data => { :confirm => "Sure?" } %>),
      %(<%= button_to 'Cancel', path, :data => { :confirm => "Sure?", :method => :delete } %>)
    ].each do |text|
      done = Rewrites.apply([entry(subject: ":confirm option on link_to", path: "app/views/x.html.erb",
        text: text)])
      assert_empty done.edits, "no edit for #{text}"
      assert_empty done.left, "and not a refusal either: #{text}"
      assert_equal [":confirm option on link_to"], done.satisfied
    end

    # **And the guard reads what the pattern reads.** A guard matched against the *raw* line was measured
    # dropping a change silently: a comment mentioning the wrapper made a line that needs the edit report as
    # `satisfied`, so the residue said nothing and the line stayed unmigrated. A comment is not evidence of
    # anything — that is the whole reason the mask exists.
    commented = Rewrites.apply([entry(subject: ":confirm option on link_to", path: "app/views/x.html.erb",
      text: %(<%= link_to 'Delete', post, confirm: 'Sure?' # data: { confirm: x } %>))])
    assert_equal [%(<%= link_to 'Delete', post, data: { confirm: 'Sure?' } # data: { confirm: x } %>)],
      commented.edits.map { |edit| edit["after"] },
      "a mention of the wrapper in a comment is not the wrapper"
    assert_empty commented.satisfied
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

  # **A rename is every occurrence on the line, not the first.** The uploads path writes
  # `request.content_type.to_s == "" ? … : request.content_type.to_s`, and replacing one branch
  # left the old call behind — a rename half-applied while the record said it had been made.
  def test_the_content_type_rule_rewrites_every_occurrence_on_the_line
    line = %(  type = request.content_type.to_s == "" ? "x" : request.content_type.to_s)
    result = Rewrites.apply([entry(subject: "request.content_type", text: line)])

    assert_equal [%(  type = request.media_type.to_s == "" ? "x" : request.media_type.to_s)],
      result.edits.map { |edit| edit["after"] }
  end

  # **Rails 7.1 stops `alias_attribute` from overriding a method inherited from an included
  # module.** The application's relayables alias `parent` to an association, while
  # `Diaspora::Relayable` declares a `parent` that raises; without this rule every comment and poll
  # save raises NotImplementedError. The alias line stays for its setter; the getter is explicit.
  def test_alias_attribute_parent_is_written_by_hand_at_seven_one
    sources = {
      "app/models/comment.rb" => ["class Comment", "  alias_attribute :parent, :commentable", "end"]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "7.1.0")

    assert_equal [
      "  alias_attribute :parent, :commentable\n  def parent\n    commentable\n  end"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal ["alias_attribute parent"], result.applied
  end

  # The rule must not add a second method on a later rung: the alias line is still there, so the
  # file's own `def parent` is the evidence that the edit has been made.
  def test_alias_attribute_parent_is_left_alone_once_the_method_exists
    sources = {
      "app/models/comment.rb" => ["class Comment", "  alias_attribute :parent, :commentable",
                                  "  def parent", "    commentable", "  end"]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "7.1.0")

    assert_empty result.edits
  end

  # **Rails 7.2 refuses an `alias_attribute` whose target is not an attribute.** The parent rule
  # above is the 7.1 half; this is the 7.2 half, and it must move the setter as well as the getter
  # because the alias had generated both.
  def test_alias_attribute_with_a_non_attribute_target_becomes_alias_method_at_seven_two
    sources = {
      "app/models/comment.rb" => [
        "class Comment",
        "  alias_attribute :post, :commentable",
        "  alias_attribute :parent, :commentable",
        "  def parent",
        "    commentable",
        "  end",
        "end"
      ]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "7.2.0")

    assert_equal [
      "  alias_method :post, :commentable\n  alias_method :post=, :commentable=",
      "  alias_method :parent, :commentable\n  alias_method :parent=, :commentable="
    ], result.edits.map { |edit| edit["after"] }
  end

  # **Rails 7.1 removed the `ActiveRecord::NullRelation` constant.** The app's search guard used it;
  # the relation's own `null_relation?` predicate is the same question and survives the release.
  def test_the_null_relation_check_uses_the_predicate_at_seven_one
    sources = {
      "app/models/person.rb" => ["return query if query.is_a?(ActiveRecord::NullRelation)"]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "7.1.0")

    assert_equal ["return query if query.null_relation?"],
      result.edits.map { |edit| edit["after"] }
    assert_equal ["ActiveRecord::NullRelation"], result.applied
  end

  # **Rails 7.2 removed the positional `serialize` argument.** A class becomes `type:` and a coder
  # becomes `coder:`; the 7.1 deprecation named both forms, and the first one is a boot failure.
  def test_serialize_positional_arguments_become_keywords_at_seven_two
    result = Rewrites.apply([
      entry(subject: "serialize", text: "  serialize :hidden_shareables, Hash"),
      entry(subject: "serialize", text: "  serialize :scopes, JSON")
    ], rung: "7.2.0")

    assert_equal ["  serialize :hidden_shareables, type: Hash",
                  "  serialize :scopes, coder: JSON"],
      result.edits.map { |edit| edit["after"] }
  end

  # **Rails 8.0 removes the keyword form of `enum`.** The 7.2 run warns about it; the positional
  # form is the same list with the name first, and the symbol block stays where it is.
  def test_enum_keyword_arguments_become_positional_at_eight
    sources = {
      "app/models/pod.rb" => ["  enum status: %i(", "    unchecked", "    unknown_error", "  )"]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "8.0.0")

    assert_equal ["  enum :status, %i("], result.edits.map { |edit| edit["after"] }
  end

  # **A modular monolith keeps its models in components, not only in `app/models`.** The rule's
  # first glob missed `components/ollama/app/models/ollama/consumed_message.rb`, so the scan
  # located the enum, the rule edited nothing, and the 8.0 boot failed on the keyword form. The
  # component path is the regression's own fixture.
  def test_enum_keyword_arguments_cover_component_models_at_eight
    sources = {
      "components/ollama/app/models/ollama/consumed_message.rb" => [
        "    enum status: {",
        "      processing: 0,",
        "      succeeded: 1,",
        "      failed: 2",
        "    }"
      ]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "8.0.0")

    assert_equal ["    enum :status, {"], result.edits.map { |edit| edit["after"] }
  end

  # **Rails 7.2 gives a string `form_for` a false object**, and `objects.compact` does not drop it.
  # The helper asks which objects have errors; `false` does not.
  def test_error_messages_ignores_a_false_form_object_at_seven_two
    sources = {
      "app/helpers/error_messages_helper.rb" => [
        "    messages = objects.compact.map { |o| o.errors.full_messages }.flatten"
      ]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "7.2.0")

    assert_equal [
      "    messages = objects.compact.select { |o| o.respond_to?(:errors) }" \
        ".map { |o| o.errors.full_messages }.flatten"
    ], result.edits.map { |edit| edit["after"] }
  end

  # **Rails 8.0 reworded `ParameterMissing`.** The message is the rung's, and the spec's exact
  # assertion moves with it.
  def test_parameter_missing_wording_moves_at_eight
    sources = {
      "spec/integration/api/search_controller_spec.rb" => [
        'confirm_api_error(response, 422, "param is missing or the value is empty: tag")',
        'confirm_api_error(response, 422, "param is missing or the value is empty: query")'
      ]
    }
    result = Rewrites.apply([], sources: sources, files: sources, rung: "8.0.0")

    assert_equal [
      'confirm_api_error(response, 422, "param is missing or the value is empty or invalid: tag")',
      'confirm_api_error(response, 422, "param is missing or the value is empty or invalid: query")'
    ], result.edits.map { |edit| edit["after"] }
  end

  # **The scan's budget is not the rule's, and the rule's scope is the project's.** The serialize
  # rule used to name two files from one application (`app/models/user.rb` and
  # `lib/diaspora/signature.rb`); the scope is now every source root the project declares, and the
  # filter keeps the read to files that can contain the line. A second application with its models
  # in a component and its declaration in `lib` is the same rule.
  def test_the_serialize_rule_reads_every_declared_source_root_and_filters_the_files
    Dir.mktmpdir do |root|
      files = {
        "app/models/user.rb" => "  serialize :preferences, Hash\n",
        "lib/diaspora/signature.rb" => "  serialize :data, JSON\n",
        "components/ollama/app/models/thing.rb" => "  serialize :payload, Array\n",
        "app/models/plain.rb" => "class Plain\nend\n"
      }
      files.each do |path, text|
        FileUtils.mkdir_p(File.dirname(File.join(root, path)))
        File.write(File.join(root, path), text)
      end

      found, truncated = Rewrites.source_files(root: root,
        source_roots: %w[app lib components], rules: [Rewrites.serialize_options])

      assert_equal %w[app/models/user.rb components/ollama/app/models/thing.rb
        lib/diaspora/signature.rb].sort, found.keys.sort
      assert_empty truncated
      refute_includes found.keys, "app/models/plain.rb",
        "the filter read a file that cannot contain a serialize declaration"
    end
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

  # **And a change whose surveyed lines need no edit at all still owes a sentence.** Measured at the
  # 6.1 rung: `ActiveModel::Error`'s survey names two lines in `spec/model/bid_spec.rb`, and the generic
  # fallback — "no rule yet: either this shape is not one of the families here, or the change has no call
  # site to match at all" — reads as an unanswered question when the rung's own suite has already
  # answered it. The rung passed with both lines untouched, so the sentence has to say which of the two
  # it is rather than leave a reader to work it out from a green suite.
  def test_a_change_whose_surveyed_lines_need_no_edit_carries_its_own_sentence
    sentence = Rewrites.gap_for("ActiveModel::Error")

    refute_equal Rewrites::GENERIC_GAP, sentence,
      "the subject falls back to the generic gap, which asks a question the suite has answered"
    assert_includes sentence, "read"
    assert_includes sentence, "no edit at all"
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
    assert_includes Rewrites.gap_for("config.active_support.test_order"),
      "`:sorted` and `:random` are the application's to choose"
    assert_includes Rewrites.gap_for("test order"), "5.0's default is `:random`"
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

  # **A default the application already loads is not a change to make.** The scan's window starts at
  # the ladder's earliest so it can find work a rung missed, which also offers a 6.1 application the
  # 5.0 `belongs_to` change. Its own `config.load_defaults` line is the fact that says the default is
  # already in force; without this guard the rule made 30 associations optional and the application's
  # own presence specs failed.
  def test_the_belongs_to_rule_leaves_an_application_that_already_loads_the_default
    files = {
      "config/application.rb" => ["module Diaspora", "  class Application < Rails::Application",
                                  "    config.load_defaults 6.1"],
      "app/models/contact.rb" => ["class Contact", "  belongs_to :user"]
    }
    result = Rewrites.apply(
      [entry(subject: "belongs_to", text: "  belongs_to :user", path: "app/models/contact.rb")],
      files: files
    )

    assert_empty result.edits
    assert_includes result.satisfied, "belongs_to"
    assert_empty result.left
  end

  # The other half of the guard: an application that has not loaded the 5.0 defaults still needs the
  # option, because the new default is the change it has not adopted.
  def test_the_belongs_to_rule_still_applies_below_the_default
    files = {
      "config/application.rb" => ["  config.load_defaults 4.2"],
      "app/models/contact.rb" => ["class Contact", "  belongs_to :user"]
    }
    result = Rewrites.apply(
      [entry(subject: "belongs_to", text: "  belongs_to :user", path: "app/models/contact.rb")],
      files: files
    )

    assert_equal ["  belongs_to :user, optional: true"], result.edits.map { |edit| edit["after"] }
  end

  # **A `belongs_to` that names no association is not a call this change is about.** The lighthouse's
  # 2013 fixture file carries two empty `belongs_to:` keys per fixture — the generator's own junk — and
  # the rule, recognising the call by its name alone, wrote `belongs_to:, optional: true` into them:
  # measured in the 5.0 rung's own commit, where `test/fixtures/items.yml` is edited by that line and
  # nothing else. A YAML key is not an association declaration, and the association's name is what
  # says which is which.
  def test_belongs_to_with_no_association_named_is_left_alone
    files = { "test/fixtures/items.yml" => ["one:", "  name: MyString", "  belongs_to: ", "  belongs_to: "] }

    result = Rewrites.apply(
      [entry(subject: "belongs_to", text: "  belongs_to: ", path: "test/fixtures/items.yml")],
      files: files
    )

    assert_empty result.edits,
      "the rule rewrote a fixture: #{result.edits.map { |edit| edit["after"] }.inspect}"
  end

  # **A change whose rule has no call site here is not the same sentence as a change nobody has
  # automated.** `require_dependency` and `request.content_type` both have rules — a call site would be
  # rewritten — and the 6.0 rung's residue listed both with only the ladder's own note beside them, which
  # reads as work waiting rather than as an observation about this application. The survey is what says
  # which it is, and the sentence is what keeps an empty answer from reading as a verdict on the change.
  def test_a_survey_says_whether_a_change_with_a_rule_has_a_call_site_here
    changes = [{ "subject" => "require_dependency" }, { "subject" => "request.content_type" }]
    tree = { "app/controllers/items_controller.rb" => ["    Item.find(params[:id])\n"] }

    empty = Rewrites.survey(changes, tree: tree)

    assert_equal ["request.content_type", "require_dependency"], empty.keys.sort
    assert_empty empty["require_dependency"].findings, "no call site is an observation, not a verdict"
    assert_includes empty["require_dependency"].sentence, "the lines that still call it"
    assert_includes empty["request.content_type"].sentence, "the lines that read it"

    found = Rewrites.survey(changes,
      tree: { "app/models/item.rb" => [%(require_dependency "vendor/lib"\n)] })

    assert_equal [["app/models/item.rb", 1, %(require_dependency "vendor/lib")]],
      found["require_dependency"].findings
  end

  # **A survey's fact still travels when the change has no call site here.** `force_ssl in a controller`
  # promised two things — the controllers that ask for it, and whether `config.force_ssl` is set — and
  # reported only the first: measured at the 6.0 rung, its residue read "none found" while the setting is
  # mentioned in `config/environments/production.rb` (commented out), and a commented default is not a
  # setting. The mention is the finding when there is no call site, and nothing mentioned plus nothing
  # located is what "none found" is for.
  def test_a_survey_reports_its_application_wide_fact_when_there_is_no_call_site
    changes = [{ "subject" => "force_ssl in a controller" }]
    commented = { "config/environments/production.rb" => ["  # config.force_ssl = true\n"] }

    found = Rewrites.survey(changes, tree: commented)["force_ssl in a controller"]

    assert_equal 1, found.findings.size, "the mention is the finding when there is no call site"
    assert_equal ["config/environments/production.rb", 1], found.findings.first[0, 2]
    assert_includes found.findings.first[2], "config.force_ssl is not set anywhere",
      "a commented default is not a setting"

    set = Rewrites.survey(changes,
      tree: { "config/environments/production.rb" => ["  config.force_ssl = true\n"] })

    assert_includes set["force_ssl in a controller"].findings.first[2], "is set in config/environments/production.rb"

    empty = Rewrites.survey(changes, tree: { "app/controllers/items_controller.rb" => ["    Item.find(1)\n"] })

    assert_empty empty["force_ssl in a controller"].findings,
      "nothing located and nothing mentioned is what `none found` is for"
  end

  # **A setting the rung removed, deleted from the file Rails' generator wrote it into.** Rails 5.0's
  # `new_framework_defaults.rb` holds an application's old defaults one at a time; 5.2 removed
  # `halt_callback_chains_on_return_false` (the 5.0 rung's own boot said "deprecated and will be removed in
  # Rails 5.2") and the 5.2 boot then died with `undefined method … for ActiveSupport:Module` at line 23.
  # Deleting the line *is* the change, and a commented spelling is not the setting.
  def test_a_setting_the_rung_removed_is_deleted_from_the_initializer
    entry = entry(subject: "ActiveSupport.halt_callback_chains_on_return_false",
      text: "ActiveSupport.halt_callback_chains_on_return_false = true",
      path: "config/initializers/new_framework_defaults.rb")
    commented = entry.merge("text" => "# ActiveSupport.halt_callback_chains_on_return_false = true")

    result = Rewrites.apply([entry, commented], rung: "5.2.0")

    assert_equal [""], result.edits.map { |edit| edit["after"] },
      "the setting's line goes and the commented one stays"
    assert_equal 1, result.left.size
    assert_empty Rewrites.apply([entry], rung: "5.1.0").edits,
      "the setting exists at 5.1, so the rule must not run there"
  end

  # **A request helper's whole trailing list was the params hash, and 5.1 moves it under `params:`.**
  # Shape and refusals both: measured on the lighthouse, 48 call sites in `spec/` and `test/` are of this
  # shape, and 17 of its 201 examples fail on `ArgumentError: unknown keyword: category_id` without it.
  def test_a_request_helpers_arguments_move_under_params
    lines = [
      "      get :index, category_id: @category",
      "        post :create, item_id: @item, bid: { amount: 200 }, category_id: @category",
      "      get :index",
      "      get :index, params: { category_id: 1 }",
      "      post :create, { item: 1 }, { user_id: 1 }"
    ]
    entries = lines.each_with_index.map do |text, index|
      entry(subject: "test request helpers take `params:`", text: text,
        path: "spec/controllers/x_spec.rb", line: index + 1)
    end

    result = Rewrites.apply(entries, rung: "5.1.0")

    assert_equal [
      "      get :index, params: { category_id: @category }",
      "        post :create, params: { item_id: @item, bid: { amount: 200 }, category_id: @category }"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal 3, result.left.size + result.satisfied.size,
      "the no-argument call, the moved one and the positional pair are not this edit"
  end

  # **A rule the ladder does not document states its own rung, and the gate is the safety.** The ladder
  # is the service's documented half and its recordings are frozen, so a change the guide's chapter omits
  # has no rung for the plan to gate — and Rails 4 reads `get :index, params: { … }` as a parameter named
  # `params`, so applying this below 5.1 would break the suite it exists to keep green.
  def test_a_rule_with_a_rung_does_not_apply_below_it
    entry = entry(subject: "test request helpers take `params:`",
      text: "      get :index, category_id: @category", path: "spec/controllers/x_spec.rb")

    below = Rewrites.apply([entry], rung: "5.0.0")
    at = Rewrites.apply([entry], rung: "5.1.0")

    assert_empty below.edits, "the rule applied at 5.0: #{below.edits.inspect}"
    assert_equal 1, at.edits.size
  end

  # **The option's own guard, and only this family may declare it.** A `belongs_to :user, optional: true`
  # line is one this rule has already answered — the 5.0 rung added the option, and the 5.1 rung's
  # residue listed those lines as work still owed. `option_added`'s docstring says its key-only guard
  # must not become an `already`, because `form: { method: :get }` on a `button_to` line would read as
  # the option — which is why the guard here names the option itself, on a line anchored on the call.
  def test_the_belongs_to_rule_recognises_the_option_it_writes
    rule = Rewrites::RULES.find { |candidate| candidate.subject == "belongs_to" }

    assert rule.satisfied?("  belongs_to :user, optional: true",
      Rewrites.mask("  belongs_to :user, optional: true"))
    refute rule.satisfied?("  belongs_to :user", Rewrites.mask("  belongs_to :user"))
    refute rule.satisfied?("  belongs_to :user, optional: false",
      Rewrites.mask("  belongs_to :user, optional: false"))
    refute rule.satisfied?("    t.belongs_to :user, optional: true",
      Rewrites.mask("    t.belongs_to :user, optional: true"))
  end

  # **The same change inside an inline block on one line.** The lighthouse has 15 of these — a `let` or a
  # `lambda` wrapping the request — and the anchored shape sees none of them: the statement is not the
  # line. Measured over the whole application, the two shapes together are 63 call sites.
  def test_a_request_helper_inside_an_inline_block_moves_its_arguments_too
    wrapped = "      lambda { delete :destroy, item_id: @item, id: @bid, category_id: @category }.should change(Bid, :count).by(-1)"
    nested = "      lambda { post :create, category: { name: 'Techbology' } }.should change(Category, :count).by(1)"
    entry = entry(subject: "test request helpers take `params:`",
      text: wrapped, path: "spec/controllers/bids_controller_spec.rb")

    result = Rewrites.apply([entry, entry.merge("text" => nested)], rung: "5.1.0")

    assert_equal [
      "      lambda { delete :destroy, params: { item_id: @item, id: @bid, category_id: @category } }.should change(Bid, :count).by(-1)",
      "      lambda { post :create, params: { category: { name: 'Techbology' } } }.should change(Category, :count).by(1)"
    ], result.edits.map { |edit| edit["after"] }
  end

  # **And a third shape: the arguments and the wrapper's close both run past the line.** This
  # application's `lambda{ post :create, item: { … }, category_id: @category`, with its `}` and
  # `.should change(Item, :count).by(1)` on the next line — the rung's last two failing examples. The wrap
  # closes the hash at the end of the line and the next line's `}` closes the block, which is why the rule
  # requires the line's brace depth to be exactly one: any deeper and the arguments are not all here.
  def test_a_wrapper_whose_arguments_run_past_the_line_wraps_what_the_line_holds
    line = "      lambda{ post :create, item: { name: 'foo', min_accept_bid: 600 }, category_id: @category"
    deeper = "      lambda{ post :create, item: { name: 'foo',"
    entry = entry(subject: "test request helpers take `params:`", text: line,
      path: "spec/controllers/items_controller_spec.rb")

    result = Rewrites.apply([entry, entry.merge("text" => deeper)], rung: "5.1.0")

    assert_equal [
      "      lambda{ post :create, params: { item: { name: 'foo', min_accept_bid: 600 }, category_id: @category }"
    ], result.edits.map { |edit| edit["after"] }
    assert_equal 1, result.left.size, "a line whose arguments are not all on it is left"
  end

  # **A wrapper whose close is not the last brace on the line is refused**, not read as the end of the
  # arguments: `expect { get :index, a: 1 }.to change { Item.count }` would put the second block inside
  # the params hash. The application has no such line, which is why the shape is a refusal rather than a
  # second pattern.
  def test_a_wrapper_whose_close_is_not_the_last_brace_is_refused
    line = "      expect { get :index, category_id: @category }.to change { Item.count }"
    entry = entry(subject: "test request helpers take `params:`", text: line, path: "spec/x_spec.rb")

    assert_empty Rewrites.apply([entry], rung: "5.1.0").edits
  end

  # **Rails 5.1's `find` refuses an object, and the message names the fix.** Two refusals make the rule
  # safe: an argument whose name says it is already an id, and an argument that is not a bare name.
  # Measured over the application: 39 rewrites, and exactly one refusal — its own
  # `app/workers/complete_auction.rb:8`, `Item.find(item_id)`.
  def test_a_find_with_an_object_argument_takes_its_id
    lines = [
      "        Item.find(item).closed.should eql(false)",
      "          Bid.find(@bid).amount.should eql(5000.to_d)",
      "    item = Item.find(item_id)",
      "      Item.find(params[:id])",
      "      Item.find(User.first)",
      "      Item.find(item.id)",
      "      TRUSTED_OEMBED_PROVIDERS.find(url)"
    ]
    entries = lines.each_with_index.map do |text, index|
      entry(subject: "find with an object argument", text: text, path: "spec/model/item_spec.rb", line: index + 1)
    end
    models = {
      "app/models/item.rb" => "class Item < ApplicationRecord\nend",
      "app/models/bid.rb" => "class Bid < ApplicationRecord\nend"
    }

    result = Rewrites.apply(entries, rung: "5.1.0", files: models)

    assert_equal [
      "        Item.find(item.id).closed.should eql(false)",
      "          Bid.find(@bid.id).amount.should eql(5000.to_d)"
    ], result.edits.map { |edit| edit["after"] }
    assert_includes result.left, "find with an object argument",
      "a constant that is not one of the application's models was rewritten"
  end

  # The rule degrades to the unconditional one when it cannot read the file, because the edit it makes
  # is the behaviour-preserving one either way — and refusing everything it could not read would leave
  # an association to fail validation silently, which is the note's own warning.
  def test_the_belongs_to_rule_still_edits_a_file_it_could_not_read
    result = Rewrites.apply([entry(subject: "belongs_to", text: "  belongs_to :user")])

    assert_equal ["  belongs_to :user, optional: true"], result.edits.map { |edit| edit["after"] }
  end

  # A setting whose *value* moved: the two booleans the release no longer accepts become the two
  # symbols the note names. **A line already naming one is the rule's own answer about the
  # application**, not a line the rule refused, which is what stops a second walk reporting a fixed
  # line as a decision owed. Measured at the 7.2 rung: the 7.1 step applied this rule to
  # `config/environments/test.rb:24` and wrote `:none`, and the 7.2 residue still carried the change as
  # "carried unfixed since", because `value_moved` had no `already` guard for `satisfied?` to read.
  def test_the_show_exceptions_booleans_map_to_the_symbols_and_a_mapped_line_is_satisfied
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
    assert_equal ["config.action_dispatch.show_exceptions"], result.satisfied,
      "the line that already reads the new way is the rule's answer, not a refusal"
    assert_empty result.left, "a fixed line was reported as work the rule would not do"
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
  # before it, and the residue's gap says which of the two cases this application is.
  #
  # **A line that already names the option is satisfied rather than left**, which is what makes a second
  # walk a no-op *and* keeps the record from calling the site unfixed: measured on the lighthouse, where
  # the 5.0 step applied the option and every rung from 5.1 on re-listed `protect_from_forgery with:
  # :exception, prepend: true` as a decision whose reason said it had been "carried unfixed since 5.0".
  # The predicate is the family's own — the same string the pattern's negative lookahead refuses — so it
  # is derived from `option` rather than written per instance.
  def test_the_forgery_callback_has_its_order_restored_and_a_restored_line_is_satisfied
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
    assert_equal ["protect_from_forgery"], result.satisfied,
      "the option is already there, so the line is named rather than handed over as work"
    assert_empty result.left
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
    # **And the three outcomes are three, which is the point of the guard having a second reader.** The line
    # that already carries the appendage is *satisfied* — the rule read it and there is nothing to do, which
    # is an answer about the application — while the two-argument call is *left*, because the note's
    # replacement names the one-argument form and the arguments are part of what the call means. Only the
    # second should leave a decision behind.
    assert_equal ["config_for"], result.left
    assert_equal ["config_for"], result.satisfied
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
    assert_equal 2, views.left.size,
      "a button built from a path and a line with two tags"
    assert_equal ["button_to"], views.satisfied,
      "a button that already names the method is named, not left as work"
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

  # **A rule that finds its own call sites**, for a change whose file the scan never sends. `package.json`
  # is not Ruby, the ladder has no detect for it, and the scanner reads the languages this tool tells it
  # about — so the client reads the file the rule's `file` names and matches it here. Two things are
  # different about such a rule and both are measured: it matches the **raw** line (in JSON the quoted text
  # *is* the data, which is exactly what the mask blanks), and its edit travels in the scan's own shape so
  # the applier's line re-check and the record's rendering are the ones every other edit gets.
  def test_a_rule_that_names_its_own_file_finds_its_call_sites_there
    sources = {
      "package.json" => ["{", "  \"dependencies\": {", "    \"actioncable\": \"^5.2.0\",",
                         "    \"rails-ujs\": \"^5.2.0\",", "    \"jquery\": \"^3.4.0\"", "  }", "}"],
      "app/assets/javascripts/application.js" => [
        "ActionCable.WebSocket = MySocket", "ActionCable.logger = site admin",
        "ActionCable.startDebugging()", "ActionCable.logger.enabled = true"
      ]
    }
    changes = [{ "subject" => "@rails npm packages", "kind" => "renamed", "note" => "the packages moved" },
      { "subject" => "ActionCable JavaScript adapters", "kind" => "renamed", "note" => "the adapters moved" }]

    result = Rewrites.apply([], sources: sources, changes: changes)

    assert_equal ["    \"@rails/actioncable\": \"^5.2.0\",", "    \"@rails/rails-ujs\": \"^5.2.0\","],
      result.edits.select { |edit| edit["path"] == "package.json" }.map { |edit| edit["after"] }
    assert_equal ["ActionCable.adapters.WebSocket = MySocket", "ActionCable.logger.enabled = site admin",
      "ActionCable.logger.enabled = true"],
      result.edits.select { |edit| edit["path"].end_with?(".js") }.map { |edit| edit["after"] },
      "the line that already reads `logger.enabled` is not renamed twice"
    assert_equal ["the adapters moved", "the packages moved"], result.edits.map { |edit| edit["note"] }.uniq.sort,
      "the change's own note travels with the edit, because a rule that applied it withdraws its decision"
    assert_empty result.left

    # A rule with no `file` is applied to what the scan located and never to a file it did not name —
    # which is the whole safety of the mechanism: the file is what says the pattern belongs to it.
    assert_empty Rewrites.sourced(Rewrites::RULES.reject(&:file), sources, changes)
  end

  # **One entry per line per change, not per rule.** `arguments_keyed` has three rules for one subject and
  # one glob, and a wrapped call matches two of them — so `sourced` emitted two entries for one line, the
  # applier wrote the first and refused the second ("not the line the scan read"), and the record reported
  # a refusal that was really one edit: measured at the 5.1 rung, 14 of its 15 refusals were the seven
  # wrapped call sites whose second sibling rule had matched.
  def test_sourced_emits_one_entry_for_a_line_several_rules_of_one_change_match
    rules = Rewrites::RULES.select { |rule| rule.rung == "5.1.0" && rule.file == "{spec,test}/**/*.rb" }
    line = "      lambda { delete :destroy, id: @bid, category_id: @category }.should change(Bid, :count).by(-1)"
    sources = { "spec/controllers/bids_controller_spec.rb" => [line] }
    changes = [{ "subject" => "test request helpers take `params:`", "kind" => "moved", "note" => "n" }]

    assert_operator rules.count { |rule| rule.pattern.match?(line) }, :>=, 2,
      "the fixture stopped matching more than one rule, so this proves nothing"
    assert_equal 1, Rewrites.sourced(rules, sources, changes).size
  end

  # **A rule can read a string's contents, and that is what a callable `replace` is for.** The *pattern*
  # matches the quotes — which the mask keeps, and which decide the extent of the match — and the *write*
  # is handed the raw region, so what was between them is readable. This is the rule that proved it: the
  # known-limits doc said a string's contents were out of reach until this was written and measured.
  def test_a_respelling_rule_reads_the_string_the_mask_blanks_and_rewrites_every_key_on_the_line
    assert_equal ["  Rails.application.secrets[:smtp][:address]"],
      secrets_after(%q{  Rails.application.secrets["smtp"]["address"]}),
      "both keys on the line, because a half-fixed line is a nil where the change says a nil or a raise"
    assert_equal ["  address: Rails.application.secrets[:smtp][:address],"],
      secrets_after(%q{  address: Rails.application.secrets[:smtp]["address"],})
    assert_equal [%q{  Rails.application.secrets[:"smtp-2"]}],
      secrets_after(%q{  Rails.application.secrets["smtp-2"]}),
      "a key that is not an identifier still has a symbol spelling"
    assert_empty secrets_after(%q{  Rails.application.secrets[:smtp][:address]}), "already a symbol"
    assert_empty secrets_after(%q{  x = Rails.application.secrets[:smtp][key]}),
      "a key in a variable is not matched, and the survey names those lines"
  end

  def secrets_after(text)
    Rewrites.apply([entry(subject: "Rails.application.secrets", text: text)])
      .edits.map { |edit| edit["after"] }
  end

  # **`all` is opt-in**, because it is wrong for the families that append: a rule that added its option to
  # every match would add it twice to a line with two calls. This drives the distinction directly.
  def test_rewriting_every_match_is_opt_in_because_appending_twice_is_wrong
    twice = entry(subject: "probe", text: %(  x = alpha(a) + alpha(b)))
    rule = Rewrites::Rule.new(family: :probe, subject: "probe", pattern: /alpha\((\w)\)/, replace: "beta(\\1)")
    everything = Rewrites::Rule.new(family: :probe, subject: "probe", pattern: /alpha\((\w)\)/,
      replace: "beta(\\1)", all: true)

    assert_equal ["  x = beta(a) + alpha(b)"], Rewrites.apply([twice], rules: [rule]).edits.map { |e| e["after"] }
    assert_equal ["  x = beta(a) + beta(b)"],
      Rewrites.apply([twice], rules: [everything]).edits.map { |e| e["after"] }
  end

  # **An assertion rewrite, where a wrong answer does not fail — it passes.** `assert_tag` is gone in 4.2
  # and `assert_select` is not a rename: the note's own mapping is the guide's, so the rule is written for
  # the *documented* forms and refuses the rest. The refusals are the half that matters, and the first
  # version of this rule got them wrong in a way worth recording: it returned the arguments it had captured
  # instead of the whole match, so a refusal *deleted* `assert_tag` and left `tag: "div", descendant: …`
  # behind — a line that no longer parses. A refusal returns the region, because an unchanged region is
  # what `Rule#after` reads as "no edit".
  def test_an_assertion_rule_rewrites_the_documented_forms_and_refuses_the_rest
    assert_equal [%q(    assert_select "div#post")],
      assert_after(%q(    assert_tag tag: "div", attributes: { id: "post" }))
    assert_equal [%q(    assert_select "span", text: "Hello")],
      assert_after(%q(    assert_tag :tag => "span", :content => "Hello"))
    assert_equal [%q(    assert_select "a.button", text: "Home")],
      assert_after(%q(    assert_tag tag: "a", attributes: { class: "button" }, content: "Home"))
    assert_equal [%q(    assert_select "h1")], assert_after(%q(    assert_tag(tag: "h1")))

    # Every one of these is a form this cannot read exactly, and each stays a decision.
    [%q(    assert_tag tag: "div", descendant: { tag: "span" }),
      %q(    assert_tag tag: "div", attributes: { href: "/x" }),
      %q(    assert_tag tag: tag_name),
      %q(    assert_tag tag: "div", attributes: { id: "a" }, count: 2),
      %q(    assert_tag tag: "div"; assert_tag tag: "span")].each do |text|
      assert_empty assert_after(text), "this form is not one the rule can express: #{text.strip}"
    end
  end

  def assert_after(text)
    Rewrites.apply([entry(subject: "assert_tag", path: "spec/x_spec.rb", text: text)])
      .edits.map { |edit| edit["after"] }
  end

  # **A rule whose condition is about another file**, which is what `context`'s fourth argument is for.
  # The protected_attributes gem is the case: Rails 5 removes the bridge it provided, so the Gemfile line
  # goes — but the ladder's own caveat is the condition, because a model still calling `attr_accessible`
  # fails without the gem. The tree is what answers it, and the Gemfile is not the file that knows.
  def test_a_rule_may_ask_the_whole_tree_before_it_touches_a_line
    sources = { "Gemfile" => ["source \"https://rubygems.org\"", "gem \"rails\", \"4.2.11\"",
                              "gem \"protected_attributes\""] }
    changes = [{ "subject" => "the protected_attributes gem", "kind" => "removed",
                 "note" => "Rails 5 removes the bridge" }]

    converted = { "app/models/user.rb" => ["class User < ApplicationRecord", "end"] }
    result = Rewrites.apply([], sources: sources, changes: changes,
      files: converted.merge(sources))
    assert_equal [["Gemfile", 3, ""]], result.edits.map { |edit| [edit["path"], edit["line"], edit["after"]] },
      "the line goes once nothing calls what the gem provided"
    assert_empty result.left

    still_using = { "app/models/user.rb" => ["class User < ApplicationRecord",
      "  attr_accessible :name", "end"] }
    result = Rewrites.apply([], sources: sources, changes: changes,
      files: still_using.merge(sources))
    assert_empty result.edits, "a model that still calls it leaves the line alone"
    assert_equal ["the protected_attributes gem"], result.left
    assert_includes Rewrites.gap_for("the protected_attributes gem"), "leaves the line as a decision"
  end

  # **The conditions may be an array.** The note's own example is the hash form, and a rule that knew only
  # that refused half the API's spellings — the array form is what the lighthouse's failure carries, in a
  # `stringex` call no rule can reach. The hash's braces are the call's and the array's brackets are the
  # *argument's*; that distinction is the whole of the rule, so both are driven here.
  def test_a_finder_whose_conditions_are_an_array_unwraps_the_same_way
    assert_equal [%(    @categories = Category.where(["url LIKE ?", "tech-1%"]))],
      finder_after(%(    @categories = Category.find(:all, conditions: ["url LIKE ?", "tech-1%"])))
    assert_equal [%(    @last = User.where(["x = ?", 1]).last)],
      finder_after(%(    @last = User.find(:last, conditions: ["x = ?", 1])))
    assert_equal [%(    @items = Item.where(sold: false))],
      finder_after(%(    @items = Item.find(:all, conditions: {sold: false})))

    # A second option is still a refusal, because the note's replacement is the conditions alone.
    assert_empty finder_after(%(    @first = User.find(:first, conditions: {name: "a"}, order: "name")))
  end

  def finder_after(text)
    Rewrites.apply([entry(subject: "find(:all, ...)", path: "app/models/category.rb", text: text)])
      .edits.map { |edit| edit["after"] }
  end

  # **A rule whose guard is the whole of it, because the failure it prevents is silent.** Deleting a
  # `secret_key_base` the application has not carried anywhere else invalidates every session in flight, and a
  # test suite does not notice — so the line goes only when `config/secrets.yml` names the *same* environment
  # variable, compared on the raw lines because a variable's name is inside the string the mask blanks. And
  # only that line goes: a Rails 3 initializer's `secret_token` stays, which is the rollback the 3.2 rung's
  # note asks for.
  def test_the_secrets_rule_removes_the_line_only_when_the_same_variable_is_carried_elsewhere
    initializer = { "config/initializers/secret_token.rb" => [
      "# Be sure to restart your server when you modify this file.",
      %(Myapp::Application.config.secret_token = ENV["SECRET_TOKEN"]),
      %(Myapp::Application.config.secret_key_base = ENV["SECRET_KEY_BASE"])
    ] }
    changes = [{ "subject" => "config.secrets.yml", "kind" => "moved", "note" => "secrets.yml arrives" }]

    carried = initializer.merge("config/secrets.yml" => [
      "production:", %(  secret_key_base: <%= ENV["SECRET_KEY_BASE"] %>)
    ])
    result = Rewrites.apply([], sources: initializer, changes: changes, files: carried)
    assert_equal [["config/initializers/secret_token.rb", 3, ""]],
      result.edits.map { |edit| [edit["path"], edit["line"], edit["after"]] },
      "the key base line goes and the secret_token line above it stays"
    assert_empty result.left

    # A different variable, or no `secrets.yml` at all, is a refusal — and it is the same refusal.
    [
      ["a different variable", initializer.merge("config/secrets.yml" =>
        ["production:", %(  secret_key_base: <%= ENV["OTHER"] %>)])],
      ["no secrets.yml", initializer]
    ].each do |label, tree|
      refused = Rewrites.apply([], sources: initializer, changes: changes, files: tree)
      assert_empty refused.edits, label
      assert_equal ["config.secrets.yml"], refused.left, label
    end
  end

  # **The mirror of `key_respelled`, where the *receiver* is the doubt.** The 4.1 json/hstore change makes a
  # column string-keyed, so `settings[:theme]` stops finding anything — but a bare name could be a local
  # holding any hash, and rewriting that would change a lookup silently. `self.settings` in the class that
  # declares `store_accessor :settings` is *provably* the column, so that is what the rule takes; a bare name
  # is left, and the survey beside it names those lines.
  def test_the_json_column_rule_takes_the_accessor_it_can_prove_and_leaves_a_bare_name
    declaring = ["class Profile < ApplicationRecord", "  store_accessor :settings, :theme",
      "  def dark?", %(    self.settings[:theme] == "dark"), "  end", "end"]
    changes = [{ "subject" => "json and hstore columns", "kind" => "default_changed",
                 "note" => "the column is string-keyed now" }]

    proved = Rewrites.apply([], sources: { "app/models/profile.rb" => declaring }, changes: changes,
      files: { "app/models/profile.rb" => declaring })
    assert_equal [%(    self.settings["theme"] == "dark")], proved.edits.map { |edit| edit["after"] }

    # The same line in a file that does not declare the accessor is a refusal — the rule will not guess that
    # `settings` is the column.
    plain = ["class Profile < ApplicationRecord", "  def dark?", %(    self.settings[:theme] == "dark"),
      "  end", "end"]
    refused = Rewrites.apply([], sources: { "app/models/profile.rb" => plain }, changes: changes,
      files: { "app/models/profile.rb" => plain })
    assert_empty refused.edits
    assert_equal ["json and hstore columns"], refused.left

    # And a bare name is not matched at all: `settings[:x]` could be anything, so the rule does not claim it
    # and the survey is what reports it.
    bare = ["class Profile < ApplicationRecord", "  store_accessor :settings, :theme",
      %(    settings[:theme])]
    assert_empty Rewrites.apply([], sources: { "app/models/profile.rb" => bare }, changes: changes,
      files: { "app/models/profile.rb" => bare }).edits
  end

  # **Every rule applied to a recorded call site is idempotent**, and the lines come from the frozen recording
  # rather than from a fixture of my own — the same rule the `button_to` family learned the hard way ("a test
  # fixture that tidies a name tests a spelling no row carries").
  #
  # What it does **not** do is catch the mangle, and saying so is the point of writing it down: this test was
  # added to catch `:data => { :confirm => "x", :method => :delete }` becoming
  # `:data => { data: { confirm: "x" }, :method => :delete }`, and reverting the guard's spelling coverage
  # leaves it *green*. The mangled output satisfies both the rule's own lookahead and the broken guard, so no
  # property read off the rule's output can see it — the check that catches it is the spelling coverage itself,
  # in the `:confirm` test beside this one, which does fail on the reverted guard. Idempotence is a real
  # property and a cheap regression guard; it is not a proof that a rewrite is well-formed, and a docstring
  # claiming otherwise is the kind of thing this repository keeps paying for.
  #
  # The count is asserted because a recording that stopped carrying located lines would make this pass
  # vacuously, and a check that cannot fail is not a check.
  def test_every_rule_applied_to_a_recorded_call_site_is_idempotent
    recording = JSON.parse(File.read(File.join(__dir__, "..", "..", "..",
      "test", "agents_fyi", "fixtures", "rails_scan_golden.json")))
    located = recording["requests"].flat_map { |request| request.dig("scan", "manual") || [] }

    checked = 0
    located.each do |entry|
      subject = entry["subject"].to_s
      next if Rewrites::RULES.none? { |rule| rule.subject == subject }

      checked += 1
      text = entry["text"].to_s
      path = entry["path"].to_s
      first = Rewrites.apply([entry], files: { path => [text] })
      next if first.edits.empty?

      after = first.edits.first["after"].to_s
      second = Rewrites.apply([{ "path" => path, "line" => entry["line"], "text" => after,
                                 "subject" => subject }], files: { path => [after] })
      # The message is a proc, so it is built only when the assertion fails: a message that reads
      # `second.edits.first` eagerly raises on the pass, which is how this test first arrived.
      assert_empty second.edits, lambda {
        "#{subject} rewrote its own output again:\n  #{text}\n=> #{after}\n" \
          "=> #{second.edits.first["after"]}"
      }
    end

    assert_operator checked, :>=, 2, "the recording stopped carrying call sites a rule covers"
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
    assert_includes found.sentence, "the assertions the rule could not express as a selector"
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
