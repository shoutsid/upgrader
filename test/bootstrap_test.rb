# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents/upgrader"

# **A fresh clone is configured from the repository's own examples, and only where the repository
# says so.** Each of these is one of the two questions the rule asks: does git ignore the target,
# and does the repository ship a tracked example beside it. A copy made anywhere else is a file
# the walker invented, which is why the refusals are as load-bearing as the seed.
class BootstrapTest < Minitest::Test
  Bootstrap = Agents::Upgrader::Bootstrap

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def repo(files, ignore: nil)
    dir = Dir.mktmpdir
    @dirs << dir
    File.write(File.join(dir, ".gitignore"), ignore) if ignore
    files.each do |path, text|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
    system("git", "init", "--quiet", dir, out: File::NULL, err: File::NULL)
    commit(dir)
    dir
  end

  def commit(dir, message = "fixture")
    system("git", "-C", dir, "add", "--all", out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "-c", "user.email=t@example.com", "-c", "user.name=t",
      "commit", "--quiet", "-m", message, out: File::NULL, err: File::NULL)
  end

  # The measured case, both halves: `config/database.yml` decides whether the services stage
  # starts a database, and a fork's own `config/diaspora.toml` decides whether `bin/rails` boots
  # at all. Both are ignored, both ship an example, and both are missing from a clone.
  def test_a_git_ignored_file_with_a_tracked_example_is_seeded
    dir = repo({
      "config/database.yml.example" => "adapter: postgresql\n",
      "config/diaspora.toml.example" => "[configuration]\n"
    }, ignore: "config/database.yml\nconfig/diaspora.toml\n")

    seeds, failures = Bootstrap.seed(dir)

    assert_empty failures
    assert_equal %w[config/database.yml config/diaspora.toml], seeds.map(&:path).sort
    assert_equal "adapter: postgresql\n", File.read(File.join(dir, "config", "database.yml"))
    assert_equal "[configuration]\n", File.read(File.join(dir, "config", "diaspora.toml"))
    assert_includes seeds.first.sentence, "config/database.yml.example"
  end

  # **An existing file is the application's operator's, or an earlier step's.** Overwriting it
  # with the example would take a working configuration away from the walk measuring it.
  def test_an_existing_target_is_never_overwritten
    dir = repo({
      "config/database.yml" => "adapter: postgresql\n",
      "config/database.yml.example" => "adapter: mysql2\n"
    }, ignore: "config/database.yml\n")

    seeds, failures = Bootstrap.seed(dir)

    assert_empty seeds
    assert_empty failures
    assert_equal "adapter: postgresql\n", File.read(File.join(dir, "config", "database.yml"))
  end

  # A tracked target cannot be missing from a clone. One that is missing anyway — a worktree
  # somebody deleted a file from — is a different problem from local configuration, and copying
  # the example would hide it behind a plausible file.
  def test_an_example_whose_target_git_tracks_is_left_alone
    dir = repo({
      "config/application.yml" => "secret: real\n",
      "config/application.yml.example" => "secret: example\n"
    })

    seeds, _failures = Bootstrap.seed(dir)
    FileUtils.rm(File.join(dir, "config", "application.yml"))
    seeds_after_delete, _ = Bootstrap.seed(dir)

    assert_empty seeds
    assert_empty seeds_after_delete
  end

  # The example is the repository's statement. A file a previous step left in the tree is not:
  # it was never committed, so no person cloning this application would receive it.
  def test_an_untracked_example_is_not_the_repositorys_statement
    dir = repo({ "config/database.yml.example" => "adapter: postgresql\n" },
      ignore: "config/database.yml\nconfig/local.yml\n")
    # Written after the commit, so the working tree has an example the repository does not:
    # exactly the shape a previous step leaves behind.
    File.write(File.join(dir, "config", "local.yml.example"), "local\n")

    seeds, _failures = Bootstrap.seed(dir)

    assert_equal ["config/database.yml"], seeds.map(&:path)
  end

  # **The example may sit before the extension rather than after it.** Figaro applications ship
  # `config/application.example.yml` and ignore `config/application.yml`; measured on `ohana-api`,
  # the rule saw the tracked example and the ignored target and copied neither, so `bin/rails`
  # died on `Figaro::MissingKeys` in every stage after the install.
  def test_an_example_before_the_extension_seeds_the_target
    dir = repo({ "config/application.example.yml" => "API_PATH: api\n" },
      ignore: "config/application.yml\n")

    seeds, failures = Bootstrap.seed(dir)

    assert_empty failures
    assert_equal ["config/application.yml"], seeds.map(&:path)
    assert_equal "API_PATH: api\n", File.read(File.join(dir, "config", "application.yml"))
  end

  # `.sample` is the same promise under the other spelling, and a repository that uses it is
  # configured by the same rule.
  def test_a_sample_is_an_example_under_a_different_name
    dir = repo({ ".env.sample" => "RAILS_SECRET_TOKEN=\n" }, ignore: ".env\n")

    seeds, _failures = Bootstrap.seed(dir)

    assert_equal [".env"], seeds.map(&:path)
    assert File.file?(File.join(dir, ".env"))
  end

  # **A database example can name its adapter after the filename.** Rails 3/4 applications ship
  # `database.yml.example.pg` rather than `database.yml.example`; the trailing segment is the
  # variant, not the target's extension. Measured on `19wu`, whose three examples all promise
  # `config/database.yml` — the old reading computed `database.yml.pg` and seeded nothing.
  def test_an_adapter_suffixed_database_example_seeds_the_database_file
    dir = repo({ "config/database.yml.example.pg" => "adapter: postgresql\n" },
      ignore: "config/database.yml\n")

    seeds, failures = Bootstrap.seed(dir)

    assert_empty failures
    assert_equal ["config/database.yml"], seeds.map(&:path)
    assert_equal "adapter: postgresql\n", File.read(File.join(dir, "config", "database.yml"))
    assert_includes seeds.first.source, "database.yml.example.pg"
  end

  # **One target, several variants, and the walk serves PostgreSQL.** `19wu` ships `.pg`,
  # `.mysql2` and `.sqlite3` examples for the same file; filename order would configure MySQL,
  # which the era images do not start, and the measurement would fail for the walker's reason
  # rather than the application's.
  def test_the_postgres_adapter_variant_wins_when_several_examples_promise_one_target
    dir = repo({
      "config/database.yml.example.mysql2" => "adapter: mysql2\n",
      "config/database.yml.example.pg" => "adapter: postgresql\n",
      "config/database.yml.example.sqlite3" => "adapter: sqlite3\n"
    }, ignore: "config/database.yml\n")

    seeds, failures = Bootstrap.seed(dir)

    assert_empty failures
    assert_equal ["config/database.yml"], seeds.map(&:path)
    assert_equal "adapter: postgresql\n", File.read(File.join(dir, "config", "database.yml"))
  end

  # Two targets the repository says are both local config is an ambiguity the rule will not
  # guess at. The example is still tracked, but neither candidate is uniquely ignored.
  def test_two_ignored_targets_for_one_example_are_left_alone
    dir = repo({ "config/settings.example.yml" => "key: value\n" },
      ignore: "config/settings\nconfig/settings.yml\n")

    seeds, _failures = Bootstrap.seed(dir)

    assert_empty seeds
  end

  # A vendored dependency's test fixture named `something.example` is not this application's
  # configuration, and the prune is what keeps the rule from walking a gem tree.
  def test_a_vendored_example_is_not_local_configuration
    dir = repo({
      "vendor/bundle/gems/thing/test/fixture.yml.example" => "fixture\n"
    }, ignore: "vendor/bundle/gems/thing/test/fixture.yml\n")

    seeds, _failures = Bootstrap.seed(dir)

    assert_empty seeds
  end

  # Nothing to do is not a stage. The step records one only when a file was copied or a copy
  # failed; a tree that arrived configured reads as one that arrived configured.
  def test_a_tree_with_nothing_to_seed_answers_nothing
    dir = repo({ "README.md" => "hello\n" })

    assert_equal [[], []], Bootstrap.seed(dir)
  end
end
