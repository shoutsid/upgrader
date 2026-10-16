# frozen_string_literal: true

# The whole suite: `cd upgrader && ruby -Ilib -Itest test/all_test.rb`.
#
# No Gemfile and no rake, because the tool has no dependencies — a suite that needs a
# `bundle install` before it can check a program that needs nothing would be the
# wrong shape for this directory, and it would make the tests the only part of the
# tool that cannot run in a bare `ruby` image.
Dir[File.join(__dir__, "*_test.rb")].sort.each { |path| require path }
