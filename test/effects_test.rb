# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "agents_fyi/upgrader"

# **An accepted decision's effects, applied to somebody's tree.**
#
# The cases here are the four ways this can go wrong, and each is a sentence an operator will read in
# the run rather than a silent no-op: a question nobody accepted is not a decision; a condition this
# build does not understand must not be read as "always"; a `find` that is absent and one that occurs
# twice are different mistakes; and a path outside the working copy is refused by the same guard the
# ladder's own edits go through.
class EffectsTest < Minitest::Test
  def with_tree(files)
    Dir.mktmpdir do |dir|
      files.each do |path, body|
        full = File.join(dir, path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      yield dir
    end
  end

  def decision(id: "d1", accepted_by: "operator:9f2c1ab8", answer: "remove the link",
    question: "Should the row keep a Show link?", effects: [])
    { "id" => id, "question" => question, "answer" => answer, "accepted_by" => accepted_by,
      "effects" => effects }
  end

  def patch(path:, find:, replace:, applies_when: nil)
    effect = { "kind" => "patch", "payload" => { "path" => path, "find" => find, "replace" => replace } }
    effect["applies_when"] = applies_when if applies_when
    effect
  end

  def test_a_patch_is_written_once_at_the_line_it_located
    with_tree("app/views/bids/index.html.erb" => "<% @bids.each do |bid| %>\n  <%= link_to 'Show', bid %>\n<% end %>\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [patch(path: "app/views/bids/index.html.erb",
          find: "  <%= link_to 'Show', bid %>\n", replace: "")])
      ])

      assert_empty result.refused
      assert_equal 1, result.applied.length
      edit = result.applied.first
      assert_equal "app/views/bids/index.html.erb", edit.path
      assert_equal 2, edit.line
      assert_equal "decision:d1", edit.origin
      assert_equal "remove the link", edit.note
      refute_includes File.read(File.join(dir, "app/views/bids/index.html.erb")), "Show"
    end
  end

  # **Config first, then the patch — and the order is load-bearing.** A patch whose `find` only
  # matches after the config change applies here; applied the other way round it would refuse.
  def test_a_config_effect_is_applied_before_a_patch_that_depends_on_it
    with_tree("config/application.rb" => "config.load_defaults 5.2\n",
      "app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [
          patch(path: "app/models/item.rb", find: "ITEM = 1", replace: "ITEM = 2"),
          { "kind" => "config", "payload" => { "path" => "config/application.rb",
                                               "find" => "config.load_defaults 5.2",
                                               "replace" => "config.load_defaults 6.0" } }
        ])
      ])

      assert_empty result.refused
      assert_equal %w[config patch], result.applied.map { |edit| edit.origin == "decision:d1" ? edit.path : nil }
        .compact.map { |path| path.start_with?("config/") ? "config" : "patch" }
      assert_includes File.read(File.join(dir, "config/application.rb")), "6.0"
      assert_includes File.read(File.join(dir, "app/models/item.rb")), "ITEM = 2"
    end
  end

  # A condition scoped to a rung applies there and nowhere before it. This is what lets an answer
  # given at 6.0 govern 6.0 and every later rung without being a note about one.
  def test_an_effect_applies_only_inside_the_window_its_condition_names
    with_tree("app/views/layouts/application.html.erb" => "<%= yield %>\n") do |dir|
      effects = AgentsFyi::Upgrader::Effects
      decision = decision(effects: [patch(path: "app/views/layouts/application.html.erb",
        find: "<%= yield %>", replace: "<%= yield %>\n<footer></footer>",
        applies_when: { "rung_gte" => "6.0.0" })])

      before = effects.new(root: dir, rung: "5.2.0").apply([decision])
      assert_empty before.applied, "the effect ran before the rung it was decided for"
      assert_empty before.refused

      after = effects.new(root: dir, rung: "6.0.0").apply([decision])
      assert_equal 1, after.applied.length
      assert_includes File.read(File.join(dir, "app/views/layouts/application.html.erb")), "footer"
    end
  end

  # **A condition nobody understands must not be read as "always".** The tempting fallback applies an
  # effect the operator scoped to one rung to every rung after it.
  def test_an_unknown_condition_refuses_rather_than_applying
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [patch(path: "app/models/item.rb", find: "ITEM = 1", replace: "ITEM = 2",
          applies_when: { "after_the_release" => "6.0.0" })])
      ])

      assert_empty result.applied
      assert_equal 1, result.refused.length
      assert_includes result.refused.first.reason, "does not know"
      assert_includes File.read(File.join(dir, "app/models/item.rb")), "ITEM = 1"
    end
  end

  # Absent and twice are different mistakes: one is an application that moved on, the other is a patch
  # that would have edited a site it was not written for.
  def test_a_find_that_is_absent_or_occurs_twice_is_refused_with_which
    with_tree("app/models/item.rb" => "ITEM = 1\nITEM = 1\n") do |dir|
      twice = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [patch(path: "app/models/item.rb", find: "ITEM = 1", replace: "ITEM = 2")])
      ])
      assert_includes twice.refused.first.reason, "more than once"

      absent = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [patch(path: "app/models/item.rb", find: "ITEM = 9", replace: "x")])
      ])
      assert_includes absent.refused.first.reason, "does not contain"

      assert_equal "ITEM = 1\nITEM = 1\n", File.read(File.join(dir, "app/models/item.rb"))
    end
  end

  # **A proposal is not a decision.** A declaration is a file and a file can carry anything, so the
  # authority rule is checked at the write as well as in the service.
  def test_a_decision_nobody_accepted_is_refused_rather_than_applied
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(accepted_by: "", effects: [patch(path: "app/models/item.rb", find: "ITEM = 1",
          replace: "ITEM = 2")])
      ])

      assert_empty result.applied
      assert_includes result.refused.first.reason, "proposal rather than a decision"
      assert_includes File.read(File.join(dir, "app/models/item.rb")), "ITEM = 1"
    end
  end

  # A path is checked by the same guard the ladder's own edits go through — a decision is not a reason
  # to write outside the working copy.
  def test_a_path_outside_the_working_copy_is_refused
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [patch(path: "../outside.rb", find: "x", replace: "y")])
      ])

      assert_empty result.applied
      assert_includes result.refused.first.reason, "outside the working copy"
    end
  end

  # The service's rule shape: the outer payload names the change and the mechanism, and the
  # mechanism's own fields are nested under `payload`. `Decision::RuleEffect` is the one place
  # that shape is decided, and the client reads the same bytes the declaration carries.
  def rule(kind:, change_key: "ruby|actionpack|before_filter", guard: nil, **payload)
    outer = { "change_key" => change_key, "kind" => kind,
              "payload" => payload.transform_keys(&:to_s) }
    outer["guard"] = guard unless guard.nil?
    { "kind" => "rule", "payload" => outer }
  end

  # **A skip is the walk's own behaviour, and it fires without touching the tree.** The step reads
  # the fired rule and removes the change from the scan's findings; the record still says which
  # decision did it, because the run body sends the decision id.
  def test_a_skip_rule_fires_and_names_the_decision_that_asked_for_it
    with_tree("app/models/item.rb" => "before_filter :x\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "skip")])
      ])

      assert_empty result.applied
      assert_empty result.refused
      assert_equal 1, result.rules.length
      assert_equal "skip", result.rules.first["kind"]
      assert_equal "d1", result.rules.first["decision_id"]
      assert_equal "ruby|actionpack|before_filter", result.rules.first["change_key"]
      assert_includes result.to_s, "1 rule(s) fired"
    end
  end

  # An expect rule is a rule the run may meet; it fires here, and the step decides from the run's
  # own output whether the failure it names is the one that happened.
  def test_an_expect_rule_fires_with_the_failure_it_accepts
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "expect", failure: "undefined method `x'")])
      ])

      assert_equal "expect", result.rules.first["kind"]
      assert_equal "undefined method `x'", result.rules.first.dig("payload", "failure")
    end
  end

  # **A rewrite is a whole-token rename through the line-checked applier.** It must not rename the
  # word inside a string or a comment — the mask is what makes "literal whole token" true — and the
  # edit carries the decision's origin so the run can say which rule made it.
  def test_a_rewrite_rule_renames_the_token_and_not_the_prose
    body = <<~RUBY
      before_filter :authenticate
      # before_filter is documented here
      logger.info("before_filter was renamed")
      before_filter :other
    RUBY
    with_tree("app/controllers/items_controller.rb" => body) do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "rewrite", old: "before_filter", new: "before_action")])
      ])

      assert_empty result.refused
      assert_equal 2, result.applied.length
      assert_equal ["decision:d1", "decision:d1"], result.applied.map(&:origin)
      assert_equal 1, result.rules.length
      written = File.read(File.join(dir, "app/controllers/items_controller.rb"))
      assert_equal 2, written.scan("before_action").length
      assert_includes written, "# before_filter is documented here"
      assert_includes written, %("before_filter was renamed")
      refute_includes written, "before_action :authenticate\nbefore_action :other\nbefore_action :authenticate"
    end
  end

  # An insertion is a replacement of its anchor line with itself plus the new text, so the applier's
  # line check still applies. An anchor that is absent or appears twice is refused with the count.
  def test_an_insert_rule_adds_a_line_after_its_anchor_and_refuses_an_ambiguous_one
    with_tree("config/application.rb" => "module Store\n  class Application\n  end\nend\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "insert", path: "config/application.rb",
          after: "class Application", text: "    config.load_defaults 6.0")])
      ])

      assert_empty result.refused
      assert_equal 1, result.applied.length
      assert_equal 1, result.rules.length
      assert_includes File.read(File.join(dir, "config/application.rb")),
        "class Application\n    config.load_defaults 6.0"

      ambiguous = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(id: "d2", effects: [rule(kind: "insert", path: "config/application.rb",
          after: "end", text: "    # twice")])
      ])
      assert_includes ambiguous.refused.first.reason, "more than once"
    end
  end

  # A rule config names a setting, and the client turns it into the existing config effect's
  # line-checked edit: the same exactly-once `find`, the same applied line and the same record, so
  # a rule cannot become a second, looser config writer. The line's own `=`/space and comment stay.
  def test_a_config_rule_uses_the_existing_config_edit
    with_tree("config/application.rb" => "  config.load_defaults 5.2 # keep this for now\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "config", key: "config.load_defaults",
          file: "config/application.rb", value: "6.0")])
      ])

      assert_empty result.refused
      assert_equal 1, result.applied.length
      assert_equal "config", result.rules.first["kind"]
      assert_includes File.read(File.join(dir, "config/application.rb")),
        "  config.load_defaults 6.0 # keep this for now"
    end
  end

  # A setting that is absent or occurs twice is refused with which, for the reason every config
  # edit is: the line is the only thing that says which site the value belongs to.
  def test_a_config_rule_refuses_a_setting_it_cannot_locate_once
    with_tree("config/application.rb" => "config.load_defaults 5.2\nconfig.load_defaults 5.2\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "config", key: "config.load_defaults",
          file: "config/application.rb", value: "6.0")])
      ])

      assert_empty result.applied
      assert_includes result.refused.first.reason, "more than once"
    end
  end

  # A rule that cannot say which of the five it is has no vocabulary to apply, and the refusal names
  # the five rather than treating it as a tree edit.
  def test_a_rule_of_an_unknown_kind_is_refused_with_the_vocabulary
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [{ "kind" => "rule",
          "payload" => { "change_key" => "ruby|actionpack|x", "action" => "skip_change" } }])
      ])

      assert_empty result.applied
      assert_includes result.refused.first.reason, "known: rewrite, insert, config, skip, expect"
    end
  end

  # **A guard this build cannot read refuses rather than applying everywhere.** `applies_when` is
  # the condition the walk understands; a guard silently dropped would apply a rule outside the
  # window its author scoped it to.
  def test_a_rule_guard_this_build_does_not_read_refuses
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "rewrite", old: "ITEM", new: "THING",
          guard: { "file" => "app/models/item.rb" })])
      ])

      assert_empty result.applied
      assert_includes result.refused.first.reason, "no guard vocabulary"
    end
  end

  # The key is what joins a rule to its change and retires it, so a rule without one is refused
  # rather than applied to whatever the walk happens to be doing.
  def test_a_rule_without_a_change_key_is_refused
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [{ "kind" => "rule", "payload" => { "kind" => "skip" } }])
      ])

      assert_includes result.refused.first.reason, "no `change_key`"
    end
  end

  # A rule's own payload is read by its kind, so a key the kind does not know is refused with that
  # kind's vocabulary rather than silently ignored.
  def test_a_rule_payload_key_the_kind_does_not_read_is_refused
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [rule(kind: "skip", subject: "before_filter")])
      ])

      assert_includes result.refused.first.reason, "subject"
      assert_includes result.refused.first.reason, "known: change_key"
    end
  end

  # A payload key nobody reads is refused beside the write rather than at load, so one typo refuses one
  # rung's effect instead of stopping a walk: the sentence names the field and the vocabulary.
  def test_a_payload_key_the_walker_does_not_read_is_refused
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [{ "kind" => "patch", "payload" => { "path" => "app/models/item.rb",
                                                               "fnd" => "ITEM = 1" } }])
      ])

      assert_includes result.refused.first.reason, "fnd"
      assert_includes result.refused.first.reason, "known: path, find, replace"
    end
  end

  def test_an_effect_of_a_kind_the_schema_does_not_declare_is_refused
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [{ "kind" => "sed", "payload" => {} }])
      ])

      assert_includes result.refused.first.reason, "known: patch, config, gem, file, delete, chmod, rule"
    end
  end

  # **A dependency decision is an operation, not a `find`/`replace`.** Add, update and remove each
  # rewrite the declaration by name, and the result names the Gemfile line.
  def test_a_gem_effect_adds_updates_and_removes_a_declaration
    with_tree("Gemfile" => "source \"https://rubygems.org\"\ngem \"rails\", \"6.0.0\"\ngem \"puma\", \"~> 5.0\"\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "7.0.0").apply([
        decision(effects: [
          { "kind" => "gem", "payload" => { "name" => "sidekiq", "requirement" => "~> 7.0" } },
          { "kind" => "gem", "payload" => { "name" => "rails", "action" => "update",
                                             "requirement" => "7.0.0" } },
          { "kind" => "gem", "payload" => { "name" => "puma", "action" => "remove" } }
        ])
      ])

      assert_empty result.refused
      body = File.read(File.join(dir, "Gemfile"))
      assert_includes body, "gem \"sidekiq\", \"~> 7.0\""
      assert_includes body, "gem \"rails\", \"7.0.0\""
      refute_includes body, "gem \"puma\""
      assert_equal %w[Gemfile Gemfile Gemfile], result.applied.map(&:path)
    end
  end

  # **A file, a delete and a mode are their own kinds.** None has a `find`, and rendering one as an
  # empty patch was the failure this covers.
  # A typed effect is still a write into somebody's tree, so every kind goes through the same
  # boundary as a patch.
  def test_typed_effects_outside_the_working_copy_are_refused
    with_tree("Gemfile" => "gem \"rails\"\n", "app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "7.0.0").apply([
        decision(effects: [
          { "kind" => "file", "payload" => { "path" => "../outside.rb", "content" => "x" } },
          { "kind" => "delete", "payload" => { "path" => "../outside.rb" } },
          { "kind" => "chmod", "payload" => { "path" => "../outside.rb", "mode" => "0755" } },
          { "kind" => "gem", "payload" => { "name" => "x", "path" => "../Gemfile" } }
        ])
      ])

      assert_empty result.applied
      assert_equal 4, result.refused.length
      result.refused.each { |refusal| assert_includes refusal.reason, "outside" }
    end
  end

  def test_file_delete_and_chmod_effects_change_the_tree_without_a_find
    with_tree("bin/run" => "#!/bin/sh\nexit 0\n", "script.sh" => "#!/bin/sh\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "7.0.0").apply([
        decision(effects: [
          { "kind" => "file", "payload" => { "path" => "config/initializers/new.rb",
                                             "content" => "NEW = true\n" } },
          { "kind" => "delete", "payload" => { "path" => "bin/run" } },
          { "kind" => "chmod", "payload" => { "path" => "script.sh", "mode" => "0755" } }
        ])
      ])

      assert_empty result.refused
      assert_equal "NEW = true\n", File.read(File.join(dir, "config/initializers/new.rb"))
      refute File.exist?(File.join(dir, "bin/run"))
      assert_equal 0o755, File.stat(File.join(dir, "script.sh")).mode & 0o777
    end
  end
end
