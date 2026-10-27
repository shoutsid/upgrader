#!/usr/bin/env ruby
# frozen_string_literal: true

# **`install` cannot set permissions on a large file on Docker Desktop's bind mounts, and a native
# gem's build is the first thing to notice.**
#
# Measured on the lighthouse's 6.0 rung, while `make install` built `sassc` out of `sass-rails 6`:
#
#     /usr/bin/install: setting permissions for './.gem.…/sassc/libsass.so': Operation not permitted
#     make: *** [Makefile:188: install-so] Error 1
#
# The trigger is the file, not the destination: in the same directory `install -c -m 0755` succeeded
# for a three-byte text file and failed for a 3 MB file of random bytes and for the 3.2 MB
# `libsass.so`, while `cp` plus `chmod 755` on those same two files succeeded. The command is the one
# mkmf writes into a gem's Makefile out of `RbConfig` (`INSTALL_PROG = /usr/bin/install -c`), so the
# walker cannot configure it away from its side — and a rung whose bundle cannot be installed is
# reported `unverified` rather than walked.
#
# So every era image keeps the real binary as `/usr/bin/install.coreutils` and puts this file at
# `/usr/bin/install`. **It is the real `install` whenever the real `install` works** — which is every
# case on a local filesystem — and the same operation done with `cp` and `chmod` when it does not.
# A flag this file does not understand is refused rather than guessed at, so what a caller sees is
# the real binary's own failure and never a wrong success.
#
# `test/install_test.rb` drives this file as a program with `AGENTS_INSTALL_REAL` pointed at a
# double, because on a host where the real thing works the fallback is unreachable otherwise.
require "fileutils"

REAL = ENV["AGENTS_INSTALL_REAL"] || "/usr/bin/install.coreutils"

# The real `install`, quoted output and all: the failure this file exists for is one of the few the
# tool needs to *not* show, because the fallback below is what answers it.
def real(argv)
  system(REAL, *argv, out: File::NULL, err: File::NULL) ? 0 : 1
rescue SystemCallError
  1
end

# The flags a gem's Makefile uses, and only those — `-c -m MODE SOURCE… DESTINATION`, which is what
# mkmf and the RubyGems extension builder hand it. Anything else is the real `install`'s business.
def fallback(argv)
  mode = nil
  operands = []
  arguments = argv.dup
  until arguments.empty?
    argument = arguments.shift
    case argument
    when "-m" then mode = arguments.shift
    when "-o", "-g", "-S", "-t" then arguments.shift
    when "-c", "-p", "-s", "-v" then next
    when /\A-/ then return nil
    else operands << argument
    end
  end
  return nil unless operands.size >= 2 && !mode.to_s.empty?

  destination = operands.last
  operands[0..-2].each do |source|
    target = File.directory?(destination) ? File.join(destination, File.basename(source)) : destination
    FileUtils.cp(source, target)
    File.chmod(mode.to_i(8), target)
  end
  0
end

status = real(ARGV)
status = fallback(ARGV) if status != 0
exit(status.nil? ? 1 : status)
