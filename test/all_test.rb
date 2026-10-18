# frozen_string_literal: true

# The whole suite: `cd upgrader && ruby -Ilib -Itest test/all_test.rb`.
#
# No Gemfile and no rake, because the tool has no dependencies — a suite that needs a
# `bundle install` before it can check a program that needs nothing would be the
# wrong shape for this directory, and it would make the tests the only part of the
# tool that cannot run in a bare `ruby` image.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |path| require path }

# **A test that never runs is not a test.** A `def test_…` written *outside* a `Minitest::Test` subclass is a
# private method on `Object`: minitest never collects it, the suite stays green, and the only evidence is a
# count nobody takes. That happened in this directory — twice, from appending to a file by stripping its last
# `end` — and the second time it was a test written to prove a fix, which then proved nothing. So the count
# is taken: every `def test_` in these files has to belong to a runnable.
declared = Dir[File.join(__dir__, "*_test.rb")].sum { |path| File.read(path).scan(/^\s*def test_/).size }
# `instance_methods(false)` rather than minitest's own `runnable_methods`, which shuffles and needs the
# seed minitest has not set yet. Every test class here is a direct `Minitest::Test`, so the two agree.
loaded = Minitest::Runnable.runnables.sum { |runnable| runnable.instance_methods(false).grep(/\Atest_/).size }
abort("all_test: #{declared} test(s) are declared and #{loaded} are runnable — a `def test_` outside its " \
      "class is invisible to minitest") if declared != loaded
