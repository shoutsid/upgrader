#!/usr/bin/env ruby
# frozen_string_literal: true

# What a `database.yml` says, in lines a shell script can read.
#
# **Read by the container's own Ruby, which is the era's**, so this file is written for Ruby
# 2.1: no `filter_map`, no `&.`, no `YAML.unsafe_load` (2.1's `YAML.load` is already the
# unsafe one, and the file being read is the application's own). It is a file rather than a
# heredoc inside `services.sh` for one reason: which roles a database needs, and with what
# password, is a *rule*, and a rule inside a shell heredoc is a rule no test can run.
# `test/dbconfig_test.rb` drives this file directly, one fixture per shape, and
# `services.sh` reads its lines.
#
# The shapes it has to survive are the ones real applications have: **no username at all**
# (libpq's own default), a username and a password, `host: localhost` (which resolves to
# either loopback family, so the server must listen on both), a `url:` in place of the keys,
# YAML anchors and aliases, ERB reading `ENV[...]`, a `test:` section named with
# `TEST_ENV_NUMBER`, and adapters that are not PostgreSQL at all.
#
# It never guesses. An adapter it does not recognise is printed as itself and the shell
# script decides; a file it cannot parse prints `unreadable:1` so the caller falls back to
# its own plain-text scan rather than reading silence as "this application has no database".
#
# The output, one fact per line, all optional:
#
#     unreadable:1                    the YAML could not be read (the fallback lines follow)
#     adapter:postgresql              the *test* environment's adapter (or the URL's scheme)
#     host:localhost                  the test environment's host, when it names one
#     database:bidding-test           the test environment's database, when it names one
#     user:james                      every username any environment names
#     credential:james:password       that username's password, when the file names one

require "yaml"
require "uri"

begin
  require "erb"
rescue LoadError
  nil
end

def emit(key, value)
  text = value.to_s
  puts "#{key}:#{text}" unless text.strip.empty?
end

path = ARGV[0].to_s
# A file that is not there is *silence*: `services.sh` only calls this when it exists, and a
# reader that answered `unreadable` for a missing file would be telling the script to fall
# back to a text scan of nothing.
exit 0 unless File.file?(path)

text = begin
  File.read(path)
rescue StandardError
  ""
end

config = nil
begin
  source = defined?(ERB) ? ERB.new(text).result : text
  # **The loader is chosen by what the interpreter has, and the difference is aliases.**
  # Ruby 2.1 — the era images' own interpreter — has no `unsafe_load`, and its `YAML.load` is
  # already the unsafe one (aliases, anchors, arbitrary tags). Ruby 3.1+ made `YAML.load` a
  # *safe* load that refuses an alias (`Psych::AliasesNotEnabled`), and a 2013 application's
  # `database.yml` is full of them: three environments sharing one `&default` anchor is the
  # shape Rails generated. So the reader asks for the unsafe loader where it exists and takes
  # 2.1's `load` where it does not — the file being read is the application's own, which is
  # the same file Rails itself loads.
  config = if YAML.respond_to?(:unsafe_load)
    YAML.unsafe_load(source)
  else
    YAML.load(source)
  end
rescue StandardError
  config = nil
end

unless config.is_a?(Hash)
  # The plain-text fallback is deliberately crude and deliberately *not* silent: an
  # application whose `database.yml` uses a construct this reader cannot follow still has an
  # adapter and possibly users, and the shell script has to know whether to start a server.
  puts "unreadable:1"
  emit("adapter", text[/adapter:\s*["']?([A-Za-z0-9_]+)/, 1])
  text.scan(/username:\s*["']?([A-Za-z0-9_.-]+)/).each { |name| emit("user", name.first) }
  exit 0
end

environments = {}
config.each do |name, value|
  environments[name.to_s] = value if value.is_a?(Hash)
end

seen_users = {}

environments.each do |_name, environment|
  # **A Rails 7.1 multi-database file names its connections one level down.** The test
  # environment can be `test: { ollama: { adapter: …, <<: *default } }`, and a reader that
  # only looks at `test['adapter']` starts no server for an application that has one. Read
  # the connection hashes as well as the environment itself; a standard one-level file still
  # arrives as `[environment]`.
  connections = environment.values.grep(Hash)
  connections = [environment] if connections.empty? || !environment["adapter"].to_s.strip.empty?

  connections.each do |connection|
    user = connection["username"]
    password = connection["password"]
    seen_users[user.to_s] = password.to_s if user && !user.to_s.strip.empty?

    url = connection["url"].to_s
    next if url.strip.empty?

    begin
      parsed = URI.parse(url)
      # `match?` is Ruby 2.4+ and `delete_prefix` is 2.5+; this file runs on the era's Ruby
      # 2.1 (`test/dbconfig_test.rb` holds the whole file to that vocabulary, one method name
      # at a time, because the failure is a container that starts a database with no roles in
      # it rather than a test that goes red here).
      if parsed.scheme.to_s =~ /\A(postgres|postgresql|mysql2?|sqlite3)\z/ # rubocop:disable Performance/RegexpMatch
        emit("adapter", parsed.scheme == "postgres" ? "postgresql" : parsed.scheme)
      end
      emit("host", parsed.host)
      emit("database", parsed.path.to_s.sub(%r{\A/}, "")) # rubocop:disable Performance/DeletePrefix
      seen_users[parsed.user.to_s] = parsed.password.to_s if parsed.user
    rescue StandardError
      nil
    end
  end
end

test = environments["test"] || {}
# The first named connection that carries its own adapter is the one whose server this
# script has to start. A `test:` with no nested connection stays itself.
test = test.values.find { |value| value.is_a?(Hash) && !value["adapter"].to_s.strip.empty? } || test
adapter = test["adapter"].to_s
if adapter.strip.empty? && !test["url"].to_s.strip.empty?
  adapter = begin
    scheme = URI.parse(test["url"].to_s).scheme.to_s
    scheme == "postgres" ? "postgresql" : scheme
  rescue StandardError
    ""
  end
end

emit("adapter", adapter)
emit("host", test["host"])
emit("database", test["database"])
seen_users.each do |user, password|
  emit("user", user)
  # A password the line protocol cannot carry (one with a newline in it) is left out rather
  # than printed as two lines: the role is still created, and the server this script starts
  # authenticates over `trust` anyway — a credential is only set so that a deployment which
  # ever moves to password authentication finds the role it was told about.
  next if password.to_s.strip.empty? || password.to_s.include?("\n")

  emit("credential", "#{user}:#{password}")
end
