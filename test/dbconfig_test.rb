# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "tmpdir"

# The `database.yml` reader the era images ship.
#
# It is a file rather than a heredoc inside `services.sh` so that this suite can exist: which
# roles a database needs, and with what password, is a rule, and the shapes it has to survive
# are the ones real applications have — no username at all, a username and a password, `host:
# localhost` (either loopback family), a `url:`, YAML anchors, ERB reading `ENV[...]`, a
# `test:` section named with `TEST_ENV_NUMBER`, and adapters that are not PostgreSQL.
#
# The file is executed by the *container's* Ruby, which is the era's, so it is written for
# Ruby 2.1 — and that is asserted here by running it on this host's Ruby and by the era
# images being built and started with it. What this suite drives is the output contract: the
# lines `services.sh` parses, one per fact, and never a line a caller could read as "no
# database" for a file the reader could not follow.
class DbconfigTest < Minitest::Test
  READER = File.expand_path("../images/dbconfig.rb", __dir__)

  def setup
    @dirs = []
  end

  def teardown
    @dirs.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  def read(yaml, name: "database.yml", env: {})
    dir = Dir.mktmpdir
    @dirs << dir
    path = File.join(dir, name)
    File.write(path, yaml)
    out, _status = Open3.capture2e(env, "ruby", READER, path)
    out
  end

  def lines(yaml, **kwargs)
    read(yaml, **kwargs).split("\n")
  end

  # The application this was written for: an ERB-named test database, a username and a
  # password, no host (so libpq's socket), and a production section that must not confuse the
  # answer about the test one.
  def test_a_password_and_a_user_are_both_reported
    lines = lines(<<~YAML)
      development:
        adapter: postgresql
        database: bidding-development
        username: james
        password: 'password'

      test: &test
        adapter: postgresql
        database: bidding-test<%= ENV['TEST_ENV_NUMBER'] %>
        username: james
        password: 'password'

      production:
        adapter: postgresql
        database: bidding-production
        username: james
        password: 'password'
    YAML

    assert_includes lines, "adapter:postgresql"
    assert_includes lines, "database:bidding-test"
    assert_includes lines, "user:james"
    assert_includes lines, "credential:james:password"
    refute(lines.any? { |line| line.include?("production") },
      "the test environment's answer must not be about another environment's database")
  end

  # No username at all is a *shape*, not a gap: libpq's default is used, and the script
  # creates no role for it.
  def test_a_file_with_no_username_reports_no_user
    lines = lines(<<~YAML)
      test:
        adapter: sqlite3
        database: db/test.sqlite3
    YAML

    assert_includes lines, "adapter:sqlite3"
    assert_includes lines, "database:db/test.sqlite3"
    refute(lines.any? { |line| line.start_with?("user:") })
  end

  # `host: localhost` is the shape that decides the server's listen addresses, and a remote
  # host is a fact the record has to carry: the suite will connect there, not here.
  def test_a_host_is_reported_whether_it_is_local_or_not
    assert_includes lines("test:\n  adapter: postgresql\n  host: localhost\n"), "host:localhost"
    assert_includes lines("test:\n  adapter: postgresql\n  host: db.internal.example\n"),
      "host:db.internal.example"
  end

  def test_an_environment_number_in_the_database_name_renders_empty_when_it_is_unset
    lines = lines("test:\n  adapter: postgresql\n  database: app-test<%= ENV['TEST_ENV_NUMBER'] %>\n")

    assert_includes lines, "database:app-test"
  end

  def test_an_environment_number_in_the_database_name_renders_when_it_is_set
    lines = lines("test:\n  adapter: postgresql\n  database: app-test<%= ENV['TEST_ENV_NUMBER'] %>\n",
      env: { "TEST_ENV_NUMBER" => "2" })

    assert_includes lines, "database:app-test2"
  end

  # A `url:` in place of the keys is the shape Rails 4.1's own generated files use, and the
  # credential is inside the URL rather than beside it.
  def test_a_url_carries_the_adapter_the_host_the_database_and_the_credential
    lines = lines("test:\n  url: postgresql://james:password@localhost:5432/bidding-test\n")

    assert_includes lines, "adapter:postgresql"
    assert_includes lines, "host:localhost"
    assert_includes lines, "database:bidding-test"
    assert_includes lines, "user:james"
    assert_includes lines, "credential:james:password"
  end

  # YAML anchors and aliases, which a 2013 application uses to keep its three environments in
  # step — and which a reader that only grepped the text would mis-read.
  def test_yaml_anchors_are_resolved_rather_than_read_as_text
    lines = lines(<<~YAML)
      default: &default
        adapter: postgresql
        encoding: unicode
        pool: 5

      test:
        <<: *default
        database: app-test
        username: app
        password: hunter2
    YAML

    assert_includes lines, "adapter:postgresql"
    assert_includes lines, "database:app-test"
    assert_includes lines, "credential:app:hunter2"
  end

  # **Rails 7.1 can name its only test connection one level down.** The reader used to look
  # only at `test['adapter']`, so `test: { ollama: { <<: *default } }` started no server —
  # measured on rails_modular_monolith, whose whole schema is the vector-backed ollama DB.
  def test_a_named_test_connection_is_read_as_the_test_connection
    lines = lines(<<~YAML)
      default: &default
        adapter: postgresql
        username: app
        password: hunter2

      test:
        ollama:
          <<: *default
          database: ollama_test
    YAML

    assert_includes lines, "adapter:postgresql"
    assert_includes lines, "database:ollama_test"
    assert_includes lines, "credential:app:hunter2"
  end

  # A password with a colon in it is the case a shell `sed` split gets wrong, which is why the
  # reader emits `credential:<user>:<rest>` and the script splits on the *first* colon.
  def test_a_password_may_contain_a_colon
    lines = lines("test:\n  adapter: postgresql\n  username: app\n  password: pa:ss:word\n")

    assert_includes lines, "credential:app:pa:ss:word"
  end

  def test_a_password_with_a_newline_is_left_out_rather_than_printed_as_two_lines
    lines = lines("test:\n  adapter: postgresql\n  username: app\n  password: \"two\\nlines\"\n")

    assert_includes lines, "user:app"
    refute(lines.any? { |line| line.start_with?("credential:") },
      "a credential the line protocol cannot carry must not be printed at all")
  end

  # **A file the reader cannot follow is not silence.** The caller decides what to start from
  # the adapter, and a YAML it could not parse must say so rather than print nothing — which
  # a script would read as "this application has no database".
  def test_an_unreadable_file_says_so_and_still_reports_what_can_be_scanned
    lines = lines("test:\n  adapter: postgresql\n\tusername: broken-indent\n")

    assert_includes lines, "unreadable:1"
    assert_includes lines, "adapter:postgresql"
  end

  # **The reader runs on the era's Ruby, and this is the only file in this repository that
  # does.** Ruby 2.1 has no `match?` (2.4), no `delete_prefix`/`delete_suffix` (2.5), no
  # `filter_map` (2.7), no safe navigation (2.3), no `transform_values`/`Hash#slice` (2.5),
  # no `dig` (2.3) and no `sum` (2.4) — and every one of them is an idiom a modern Ruby
  # programmer reaches for without thinking. The failure they cause is not a red test here:
  # it is a container that starts a database with no roles in it, which reads as an
  # application whose suite cannot connect. Comments are dropped first, because the file
  # *names* these methods in the paragraph that says not to use them.
  def test_the_reader_only_uses_methods_ruby_2_1_has
    code = File.read(READER, encoding: "utf-8").lines
               .reject { |line| line.lstrip.start_with?("#") }
               .join
    forbidden = {
      "match?" => /\bmatch\?/, "delete_prefix" => /delete_prefix/, "delete_suffix" => /delete_suffix/,
      "filter_map" => /filter_map/, "transform_values" => /transform_values/,
      "transform_keys" => /transform_keys/, "dig" => /\.dig\b/, "sum" => /\.sum\b/,
      "then" => /\.then\b/, "yield_self" => /yield_self/, "positive?" => /\bpositive\?/,
      "negative?" => /\bnegative\?/, "clamp" => /\bclamp\b/, "safe navigation" => /&\./,
      "tally" => /\btally\b/, "slice" => /\.slice\b/, "intersection" => /\bintersection\b/
    }

    used = forbidden.select { |_name, pattern| code.match?(pattern) }.keys
    assert_empty used, "the reader uses methods Ruby 2.1 does not have: #{used.join(", ")}"
  end

  def test_a_missing_file_is_an_empty_reading_rather_than_a_crash
    out, status = Open3.capture2e("ruby", READER, "/nonexistent/database.yml")

    assert_predicate status, :success?
    assert_equal "", out.strip
  end
end
