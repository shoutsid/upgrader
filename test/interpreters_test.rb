# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "tmpdir"
require "agents_fyi/upgrader"

# The interpreter matrix and the two decisions over it.
#
# The selection itself — which era a step ends up executing on — is a pipeline decision and
# is driven in `step_machine_test.rb` with a machine per era. This file is about the rules
# underneath: what a floor excludes, where the walk starts, and what the shipped matrix says
# about each era's image. A matrix read wrongly is a step that runs on an interpreter nobody
# chose, so each of these asserts the *reason* a candidate is or is not in the list.
class InterpretersTest < Minitest::Test
  Interpreters = AgentsFyi::Upgrader::Interpreters

  # A matrix row as the file carries one. The base is a well-formed pin because the shipped
  # matrix's pins are asserted below; this is a row a test can vary one field of.
  def row(name:, ruby:, image: "era-#{name}", base: "ruby:#{ruby}@sha256:#{"a" * 64}",
          bundler: "1.17.3")
    { "name" => name, "ruby" => ruby, "image" => image, "base" => base,
      "bundler" => bundler }
  end

  def write_matrix(rows)
    dir = Dir.mktmpdir
    path = File.join(dir, "interpreters.json")
    File.write(path, JSON.generate("interpreters" => rows))
    (@dirs ||= []) << dir
    path
  end

  def teardown
    @dirs&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def three
    write_matrix([
      row(name: "2.5", ruby: "2.5.9"),
      row(name: "2.1", ruby: "2.1.10"),
      row(name: "2.2", ruby: "2.2.10")
    ])
  end

  def names(path, **kwargs)
    Interpreters.candidates(path: path, **kwargs).map(&:name)
  end

  # Ascending by version, whatever the file's order: the candidate order *is* the selection
  # rule, so a file that lists 2.5 before 2.1 must not make 2.5 the first thing tried.
  def test_the_matrix_is_ascending_whatever_order_the_file_uses
    assert_equal %w[2.1 2.2 2.5], names(three)
  end

  def test_a_step_s_floor_excludes_every_era_below_it
    assert_equal %w[2.5], names(three, requires_ruby: "2.5.0")
  end

  # The comparison is by *version* and not by the era's name, and the difference is the case
  # that matters: the 2.2 era is 2.2.10, which meets Rails 5.0's 2.2.2 floor — an era named
  # "2.2" compared as the string "2.2" would have excluded the interpreter the floor was
  # written for.
  def test_the_floor_is_compared_against_the_interpreter_s_version_not_its_era_name
    assert_equal %w[2.2 2.5], names(three, requires_ruby: "2.2.2")
  end

  # A floor this reader cannot place is not an absent floor and not a met one: the shipped
  # matrix is the place a bad floor is caught, and refusing to filter on it would silently
  # drop every candidate. So the rule is "not a floor" — and `Step` records the step's
  # `requires_ruby` verbatim either way, which is what a reader would need to see the bug.
  def test_a_floor_that_is_not_a_version_does_not_filter_anything
    assert_equal %w[2.1 2.2 2.5], names(three, requires_ruby: "banana")
  end

  def test_no_floor_means_every_era
    assert_equal %w[2.1 2.2 2.5], names(three, requires_ruby: nil)
  end

  # **A declaration's `eras` is a constraint, not a hint.** A project whose CI runs 3.2 must not
  # spend a bundle resolve on 2.7 because that is the oldest era its rung allows.
  def test_a_declaration_s_eras_are_the_only_ones_tried
    assert_equal %w[2.2], names(three, only: %w[2.2])
  end

  def test_a_declaration_s_era_order_is_the_order_tried
    assert_equal %w[2.5 2.2], names(three, only: %w[2.5 2.2])
  end

  def test_a_declared_era_below_the_floor_is_not_tried
    assert_equal %w[2.5], names(three, requires_ruby: "2.5.0", only: %w[2.1 2.5])
  end

  # Where the walk starts is what the application itself says: a lockfile resolved under
  # 2.5 does not need 2.1 probed first, and a step on a modern application must not spend a
  # bundle resolve on a 2013 interpreter to find out it cannot install Rails 8.
  #
  # The start is a *rotation* and not a cut, and the difference is the failure the other
  # choice has: a hint that is wrong — a lockfile resolved under an interpreter the gems do
  # not actually install on — must cost probes, not a dead end, so the candidates below the
  # hint follow it around rather than being dropped.
  def test_the_application_s_own_ruby_decides_where_the_walk_starts
    assert_equal "2.5", names(three, locked: "2.5.9").first
    assert_equal "2.2", names(three, declared: "2.2.0").first
    # And nothing is lost when the hint is wrong: every era that meets the floor is still in
    # the list, behind the ones at or above the hint.
    assert_equal %w[2.5 2.1 2.2], names(three, locked: "2.5.9")
  end

  def test_a_declared_ruby_wins_over_the_lockfile_s
    assert_equal "2.2", names(three, declared: "2.2.0", locked: "2.1.0").first
  end

  # **A Gemfile's `ruby` line is a requirement, and reading it as a version made it no hint at
  # all.** `ruby '~> 2.2.0'` is the shape applications write; `Gem::Version` cannot place it, so the
  # walk started at the oldest era and spent a bundle resolve on every one below the declaration.
  # Measured on `rails_modular_monolith`, whose `~> 3.2.0` cost five bundle installs and five apt
  # installs before the era it names was tried.
  def test_a_declared_ruby_requirement_starts_at_the_first_era_it_accepts
    assert_equal "2.2", names(three, declared: "~> 2.2.0").first
    assert_equal "2.5", names(three, declared: ">= 2.5").first
  end

  # A bare version is a *floor*, not an equality: `ruby "2.2.0"` is what a developer had installed,
  # and the matrix's 2.2 entry is 2.2.10 — so reading it as `= 2.2.0` would answer "nothing here is
  # enough" for the era that is.
  def test_a_declared_ruby_with_no_operator_is_a_floor_and_not_an_equality
    assert_equal "2.2", names(three, declared: "2.2.0").first
    assert_equal %w[2.2 2.5 2.1], names(three, declared: "2.2.0")
  end

  # A requirement no era satisfies still starts at the newest, for the reason a version above the
  # whole matrix does: "nothing here is known to be enough" is answered by the closest thing the
  # machine has rather than by a 2013 interpreter.
  def test_a_requirement_the_matrix_cannot_satisfy_starts_at_the_newest_era
    assert_equal "2.5", names(three, declared: "~> 4.0").first
  end

  # `.ruby-version` is the weakest of the three declarations — what a developer happened to install —
  # so it is read only when the Gemfile and the lockfile say nothing, and it is never a floor.
  def test_the_dot_ruby_version_is_a_hint_only_when_nothing_else_declares_one
    assert_equal "2.5", names(three, dot: "2.5.4").first
    assert_equal "2.2", names(three, declared: "2.2.0", dot: "2.5.4").first
    assert_equal "2.1", names(three, locked: "2.1.0", dot: "2.5.4").first
  end

  # Above the matrix is "nothing here is known to be enough", and the newest era is the
  # closest thing to an answer: an application declaring Ruby 3.3 starts at the newest era
  # rather than at the oldest, because the alternative is three bundle resolves spent
  # proving that ages do not satisfy a floor the newest era also cannot.
  def test_a_version_above_the_whole_matrix_starts_at_the_newest_era
    assert_equal "2.5", names(three, locked: "3.3.12").first
  end

  # The era that worked for this move before is tried first. Without it, an application whose
  # floor admits 2.1 but whose bundle only installs on 2.2 would re-probe 2.1 on every cycle.
  def test_the_era_a_previous_attempt_used_is_tried_first
    assert_equal "2.2", names(three, preferred: "2.2").first
    assert_equal %w[2.2 2.5 2.1], names(three, preferred: "2.2")
  end

  def test_a_preferred_era_below_the_step_s_floor_is_not_tried_at_all
    assert_equal %w[2.5], names(three, requires_ruby: "2.5.0", preferred: "2.1")
  end

  def test_a_preferred_era_the_matrix_no_longer_carries_changes_nothing
    assert_equal %w[2.1 2.2 2.5], names(three, preferred: "1.9")
  end

  # A deployment pins digests without a code change; an override is the whole matrix entry's
  # image, so the entry's other facts (its ruby version, its floor arithmetic) stay the
  # matrix's.
  def test_an_image_override_replaces_the_reference_the_matrix_carries
    kept = names(three, images: { "2.2" => "era-2.2@sha256:beef" })
    assert_equal %w[2.1 2.2 2.5], kept
    entry = Interpreters.candidates(path: three, images: { "2.2" => "era-2.2@sha256:beef" })
                        .find { |candidate| candidate.name == "2.2" }
    assert_equal "era-2.2@sha256:beef", entry.image
  end

  def test_the_override_environment_is_one_comma_separated_list_of_pairs
    overrides = Interpreters.overrides_from("UPGRADER_INTERPRETER_IMAGES" => "2.1=one, 2.2=two")
    assert_equal({ "2.1" => "one", "2.2" => "two" }, overrides)
    assert_empty Interpreters.overrides_from({})
  end

  # A digest is the pin an operator naturally writes, and a bare one has to inherit the
  # repository from the matrix. Passing it through unchanged produced an image reference that
  # began with `sha256:` and named no image, which the daemon could only refuse.
  def test_a_bare_digest_override_inherits_the_matrix_image
    entry = Interpreters.candidates(path: three, images: { "2.2" => "sha256:beef" })
      .find { |candidate| candidate.name == "2.2" }

    assert_equal "era-2.2@sha256:beef", entry.image
  end

  def test_two_entries_under_one_name_are_refused
    path = write_matrix([row(name: "2.2", ruby: "2.2.10"), row(name: "2.2", ruby: "2.2.11")])
    error = assert_raises(Interpreters::Invalid) { Interpreters.matrix(path: path) }
    assert_includes error.message, "name"
  end

  def test_an_entry_whose_version_is_not_a_version_is_refused
    path = write_matrix([row(name: "2.2", ruby: "latest")])
    assert_raises(Interpreters::Invalid) { Interpreters.matrix(path: path) }
  end

  def test_a_file_that_is_not_a_matrix_is_refused
    dir = Dir.mktmpdir
    (@dirs ||= []) << dir
    path = File.join(dir, "interpreters.json")
    File.write(path, "{ this is not json")
    assert_raises(Interpreters::Invalid) { Interpreters.matrix(path: path) }
  end

  # **The shipped matrix, held to the two things its arithmetic rests on.** Every base pinned
  # by digest — a tag that moves is an interpreter nobody verified, and the floor comparison
  # would be made against a version string that describes a different image. And a candidate
  # for every floor the ladder's steps carry: `data/rails_ladder.json` needs 1.9.3, 2.2.2,
  # 2.5.0, 2.7.0, 3.1.0 and 3.2.0, and a matrix that cannot serve one of them is a step that
  # can only ever be refused on the one deployment that exists to walk old applications.
  def test_the_shipped_matrix_pins_every_base_and_covers_every_floor
    matrix = Interpreters.matrix
    refute_empty matrix, "the shipped matrix is empty"
    matrix.each do |entry|
      assert_match(/@sha256:[0-9a-f]{64}\z/, entry.base,
        "#{entry.name}'s base is not pinned by digest: #{entry.base}")
    end

    %w[1.9.3 2.2.2 2.5.0 2.7.0 3.1.0 3.2.0].each do |floor|
      found = Interpreters.candidates(requires_ruby: floor)
      refute_empty found, "no era in the shipped matrix meets the ladder's #{floor} floor"
      assert(found.any? { |entry| Interpreters.meets?(entry.ruby, floor) },
        "the candidates for #{floor} do not include an interpreter that meets it")
    end
  end

  # The build facts the images depend on, read out of the files that carry them.
  #
  # Each of these is invisible until an image is built and a step runs on it: an era whose
  # Debian release is not told to use the archive fails its build with 404s, a Bundler that
  # does not match the Ruby it installs into fails with "Bundler requires Ruby version", and
  # a `services.sh` the image does not copy is a step whose PostgreSQL was never started.
  # The suite cannot build six images, so it reads the recipe and the script — the same shape
  # as `artifact_test.rb` beside it.
  # **The host setup script is the other half of `UPGRADER_RUNTIME=rvm`, and it has to agree with
  # the matrix and with the walker.** Three facts, each of which has been wrong in some version of
  # a setup script: the interpreter comes from the matrix rather than from a second list, the gemset
  # is the walker's own variable (a walk must not install its gems into the gemset a developer uses
  # for their own work), and it installs no system packages — rvm's `autolibs` is respected rather
  # than overridden, because a script that ran `sudo apt-get` on somebody's machine because they
  # asked for a Ruby is a script that changes that machine in ways nobody read.
  def test_the_host_setup_script_reads_the_matrix_and_changes_no_system_packages
    root = File.expand_path("..", __dir__)
    script = File.read(File.join(root, "scripts", "upgrader-rubies.sh"), encoding: "utf-8")

    assert_includes script, "interpreters.json", "the script keeps its own copy of the eras"
    assert_includes script, 'rvm install "$ruby"', "the era's interpreter is not installed"
    assert_includes script, 'gem install bundler --version "$bundler"',
      "the era's bundler is not installed, and a Rails 4-era lockfile requires bundler < 2"
    assert_includes script, "UPGRADER_RVM_GEMSET", "the gemset is not the walker's own variable"
    assert_includes script, "UPGRADER_RVM_ROOT", "the rvm root is not the walker's own variable"
    assert_includes script, "missing_packages", "missing system packages are not reported"
    refute_match(/^\s*(sudo|apt-get)\b/m, script,
      "the script changes the host's system packages instead of reporting them")
  end

  def test_the_era_images_and_the_matrix_agree
    root = File.expand_path("..", __dir__)
    dockerfile = File.read(File.join(root, "images", "Dockerfile"), encoding: "utf-8")
    script = File.read(File.join(root, "images", "services.sh"), encoding: "utf-8")
    builder = File.read(File.join(root, "scripts", "upgrader-images.sh"), encoding: "utf-8")

    %w[BASE_IMAGE BUNDLER].each do |argument|
      assert_includes dockerfile, "ARG #{argument}", "the Dockerfile takes no #{argument}"
      assert_includes builder, "build-arg \"#{argument}=", "the builder never passes #{argument}"
    end
    # **The distribution is read, not passed.** Two of the six eras were wrong about theirs
    # (2.5 is buster, 2.7 is bullseye), and apt pointed at the wrong release answers a
    # package-list error; so the Dockerfile asks the image and the builder has no column
    # for it. A test rather than a comment because the failure is a build, not a test run.
    assert_includes dockerfile, "VERSION_CODENAME",
      "the Dockerfile no longer reads the distribution out of the image"
    refute_includes builder, "APT_SUITE", "the builder passes a distribution again"
    refute_includes builder, "APT_ARCHIVE", "the builder decides how to reach packages again"
    assert_includes builder, "data/interpreters.json",
      "the builder does not read the matrix, so the two would drift"
    # **The start script does the two things a build cannot**, and a real application found
    # both. It names the walker's uid — `initdb` refuses an unnamed uid, and every failure of
    # that kind reads as a broken database rather than as a missing passwd entry. And it hands
    # the gem home over: Rails 4.0.0.rc1 declares a *runtime dependency on bundler*, so a
    # 2013 application's `bundle install` installs bundler into its own bundle and writes the
    # binstub into a root-owned `bin/` — the last line of an otherwise clean install, reported
    # as "an error occurred while installing bundler" with no permission anywhere in the
    # sentence. The uid is the host's, so the image cannot know it and the chown cannot be a
    # build step.
    start = File.read(File.join(root, "images", "start.sh"), encoding: "utf-8")
    assert_includes start, "getent passwd", "nothing names the walker's uid"
    assert_includes start, "/var/run/postgresql", "the socket directory is not prepared"
    assert_match(/chown -R .*\/usr\/local\/bundle/, start,
      "the gem home is not handed to the walker, so a Rails 4.0.0.rc1 bundle cannot install")

    # **The database reader is a file the image ships and the script calls**, because which
    # roles a database needs — and with what password — is a rule a test has to be able to
    # run. `services.sh` must call it by that path, and the Dockerfile must copy it there;
    # the two are asserted together because a mismatch is a container that starts a database
    # with no roles in it.
    services = File.read(File.join(root, "images", "services.sh"), encoding: "utf-8")
    assert_includes services, "/usr/local/bin/agents-fyi-dbconfig",
      "the services script does not call the reader"
    assert_includes dockerfile, "COPY dbconfig.rb /usr/local/bin/agents-fyi-dbconfig",
      "the reader is never shipped into the image"
    assert_includes services, "listen_addresses=localhost",
      "the server does not listen on both loopback families, so `host: localhost` may not reach it"
    assert_includes services, "ALTER ROLE", "the passwords the file names are never set"

    # **A rebuild cleans up the image it supersedes, and `prune` cleans up the cache.** A
    # `docker build -t` untags the image the tag pointed at rather than deleting it, and this
    # script rebuilds six images at a time: five rebuilds in one session left 8.5 GB of build
    # cache here and a stack of untagged layers. `build` therefore removes exactly the id it
    # replaced (`docker image prune` would take every other project's dangling images on the
    # same daemon with it) and says what is left; `prune` reclaims the cache explicitly.
    assert_includes builder, 'docker image rm "$previous"',
      "a rebuild no longer removes the image it superseded"
    assert_match(/^prune\(\) \{/m, builder, "the script has no prune subcommand")
    assert_includes builder, "docker builder prune -f",
      "prune does not reclaim the build cache, which is where a rebuild's cost actually lands"
    assert_includes builder, "prune)", "prune is not reachable from the command line"

    assert_includes dockerfile, "COPY services.sh /usr/local/bin/agents-fyi-services",
      "the image does not install the services script"
    assert_includes script, "initdb", "the services script starts no PostgreSQL"
    assert_includes script, "redis-server", "the services script starts no Redis"
  end
end
