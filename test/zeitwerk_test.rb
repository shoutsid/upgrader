# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "agents_fyi/upgrader"

# The spelling Zeitwerk cannot guess, driven against real files.
#
# Measured at the 7.0 rung, which is the first to run without classic mode: its suite is green except
# for one routing example, and the failure is `Zeitwerk::NameError: expected file /app/lib/sse.rb to
# define constant Sse, but didn't`. The file defines `module SSE` — what this 2013 application calls it
# — and taking `lib` off `config.autoload_paths` does not repair it. Zeitwerk's own answer for an
# acronym is an inflector, and measured, it takes the rung's suite to 201 examples, 0 failures.
class ZeitwerkTest < Minitest::Test
  Zeitwerk = AgentsFyi::Upgrader::Zeitwerk
  Rewrites = AgentsFyi::Upgrader::Rewrites

  def tree(files)
    dir = Dir.mktmpdir
    files.each do |path, text|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
    (@dirs ||= []) << dir
    dir
  end

  def teardown
    @dirs&.each { |dir| FileUtils.remove_entry(dir) if File.directory?(dir) }
  end

  # **An acronym is a spelling, and the loader is taught it rather than the file renamed.** `SSE` and
  # `Sse` are the same word; the application's spelling is the one that stays.
  def test_a_constant_that_differs_only_in_capitalisation_is_taught_to_zeitwerk
    root = tree("lib/sse.rb" => "module SSE\n  class Client\n  end\nend\n")

    scaffolds = Zeitwerk.spellings(root: root)

    assert_equal 1, scaffolds.size, "no spelling was derived"
    assert_equal "config/initializers/zeitwerk.rb", scaffolds.first.path
    assert_equal %(Rails.autoloaders.main.inflector.inflect("sse" => "SSE")\n), scaffolds.first.content
  end

  # A file whose constant already matches needs nothing, and so does a file this cannot read a constant
  # from — the honest answer for both is silence rather than an inflection.
  def test_a_file_that_already_matches_needs_no_spelling
    root = tree(
      "lib/report.rb" => "class Report\nend\n",
      "lib/plain.rb" => "# nothing to see\n"
    )

    assert_empty Zeitwerk.spellings(root: root)
  end

  # **A different word is not an acronym.** `lib/sse.rb` defining `module Mailer` is a misnamed file,
  # which is a decision about the application's code: inflecting it would teach Zeitwerk a spelling
  # nobody uses and leave the real one broken.
  def test_a_constant_that_is_a_different_word_gets_no_spelling
    root = tree("lib/sse.rb" => "module Mailer\nend\n")

    assert_empty Zeitwerk.spellings(root: root)
  end

  # The scan reads the application's `lib` and nothing else, so an application without one gets no file
  # written into it.
  def test_an_application_with_no_lib_gets_no_file
    root = tree("app/models/user.rb" => "class User\nend\n")

    assert_empty Zeitwerk.spellings(root: root)
  end
end
