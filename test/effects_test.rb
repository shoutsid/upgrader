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

  # `rule` is the walk's own behaviour rather than the tree's, and this build applies none: refused by
  # name, because an effect that vanishes is a decision nobody can see was ignored.
  def test_a_rule_effect_is_refused_by_name
    with_tree("app/models/item.rb" => "ITEM = 1\n") do |dir|
      result = AgentsFyi::Upgrader::Effects.new(root: dir, rung: "6.0.0").apply([
        decision(effects: [{ "kind" => "rule",
                             "payload" => { "action" => "skip_change", "subject" => "before_filter" } }])
      ])

      assert_empty result.applied
      assert_includes result.refused.first.reason, "applies no rules"
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
