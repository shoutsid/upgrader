# frozen_string_literal: true

module AgentsFyi
  module Upgrader
    # The one place a line of somebody's source is rewritten.
    #
    # Everything else in this directory reads: `plan` prints, and the step pipeline
    # works on a scratch copy of the application precisely so that nothing it does
    # reaches a caller's repository. This class is the exception, and it is written as
    # if it were the only one, because it is: a codemod that writes the wrong line
    # writes it into the tree somebody is about to open a pull request from.
    #
    # Two rules carry that weight, and both are's:
    #
    # * **The line is re-checked before it is written.** `/api/rails/scan` read the file and
    #   returned the text it saw. Between that read and this write the file can have
    #   changed — an editor, a formatter, another edit of ours — and an applier that
    #   trusts a line number edits whatever is there now. So the line is compared
    #   against the text the service sent, and a mismatch *refuses* the edit rather
    #   than shifting, guessing or applying it best-effort. `RailsEditOut#text` is
    #   documented as "the line as sent" for exactly this reason.
    # * **The manual half is never applied.** `after` is null on an edit that needs a
    #   decision — an argument that moved, a default to turn off — and a whole-word
    #   rename is the only thing this class will write.
    #
    # Stdlib only, like the rest of this directory: rewriting a line is
    # `File.binread`, one comparison and `File.binwrite`.
    class Applier
      # One edit that was written, with the line before and the line after, so a
      # record can show both without re-reading the file it changed.
      #
      # `origin` is who asked for it: nil for the service's own edit (it called the change
      # mechanical), `"rule"` for one of this tool's own rewrites (`Rewrites`), which the service
      # deliberately does not make. A reader of the patch can tell the two apart, and the guard
      # below is why the distinction has to be explicit rather than inferred.
      #
      # `note` is the change's own sentence from the ladder, and it is carried here because a rule
      # that *applied* a change withdraws its decision — correctly, it is no longer one — and the note
      # is where the caveat a reviewer needs lives (`find_all_by_*`'s "`where` returns a relation, not
      # an array"). A preflight repair carries the digest's reason in the same field, so the record's
      # `applied` list answers "why" for both kinds of edit.
      Applied = Struct.new(:path, :line, :text, :after, :subject, :origin, :note, keyword_init: true)

      # One edit that was not written, and what was actually found. `found` is the
      # line that is there when there is one: "refused" on its own sends a reader to
      # open the file and compare it by hand, which is the work this field exists to
      # save.
      #
      # `subject` is carried for the same reason `Applied` carries it, and it was
      # missing here first: a refusal is what the coverage figure is measured from, and
      # a figure that counted refusals without being able to name *which* documented
      # change each one was could say how much of a step was mechanical and not which
      # part of it is left to write. A path and a line cannot answer that across two
      # repositories; the subject can.
      #
      # `kind`, `replacement`, `source` and `note` are the *service's* words for the
      # change that was refused, copied off the edit rather than invented here. The
      # service stores a refusal under exactly these names — `kind` is "the kind of
      # change, as the ladder names it", `source` is the guide chapter
      # (`Upgrade::Refusal`) — so a client that filled them with its own vocabulary
      # would be answering a different question in the same field. They are nil for a
      # refusal that is not about a change at all (an unsafe path, a file that could not
      # be read), which is honest rather than empty.
      Refused = Struct.new(:path, :line, :text, :found, :reason, :subject,
        :kind, :replacement, :source, :note, keyword_init: true)

      # `files_written` is the number of files whose bytes changed, and it is the
      # number an operator wants first, because it is the one that can be wrong.
      Result = Struct.new(:applied, :refused, :files_written, keyword_init: true)

      def initialize(root)
        @root = File.expand_path(root)
        # Comparisons happen in *real* path space, so none of the checks below can be
        # walked around by a symlink in the middle of a path: `app/models ->
        # /tmp/elsewhere` is inside the copy by its spelling and outside it by its
        # bytes, and a copy of a repository is exactly where that turns up.
        @root_real =
          begin
            File.realpath(@root)
          rescue SystemCallError
            @root
          end
      end

      def apply(edits)
        applied = []
        refused = []
        lines_by_file = {}
        unreadable = {}
        dirty = {}

        Array(edits).each do |edit|
          path = edit["path"].to_s
          full, unsafe = sealed(path)
          if full.nil?
            refused << refuse(edit, path, nil, unsafe)
            next
          end

          unless lines_by_file.key?(full)
            begin
              lines_by_file[full] = File.binread(full).split("\n", -1)
            rescue SystemCallError => e
              lines_by_file[full] = nil
              unreadable[full] = "could not be read (#{e.class}: #{e.message})"
            end
          end

          lines = lines_by_file[full]
          if lines.nil?
            # A change whose fix is a file to create arrives as a documented change
            # with `findable: false`, never as an edit, so a missing file here is a
            # refusal and not a file to write.
            refused << refuse(edit, path, nil, "#{path} #{unreadable[full]}")
            next
          end

          index = edit["line"].to_i - 1
          if index.negative? || index >= lines.size
            refused << refuse(
              edit, path, nil,
              "#{path} has #{lines.size} line(s), so line #{edit["line"]} is not in it"
            )
            next
          end

          found = lines[index]
          unless edit["automatic"] == true && !edit["after"].nil?
            refused << refuse(
              edit, path, found,
              "`#{edit["subject"]}` is carried as #{edit["kind"]} rather than as a " \
              "whole-word rename, so it needs a decision and this tool will not make it"
            )
            next
          end

          # Compared as *bytes*. `==` between a binary string and a UTF-8 one is false
          # even when every byte agrees, and the file was read as binary while the text
          # arrived as JSON — so a line with any non-ASCII character in it would be
          # refused for ever: safe, and useless.
          if strip_cr(found).b != strip_cr(edit["text"].to_s).b
            refused << refuse(
              edit, path, found,
              "#{path}:#{edit["line"]} is not the line the scan read, so it was not written"
            )
            next
          end

          # The terminator is the file's, not the scan's: a CRLF file read by a service
          # that splits on `\n` comes back with the `\r` or without it depending on
          # which side of the wire it was on, and a comparison that insisted on either
          # would refuse every edit in that file — or rewrite it as LF, which is a
          # whole-file change nobody asked for. So the `\r` is ignored for the
          # comparison and put back on the way out.
          # **And on the way out it belongs to every line the edit writes.** The terminator below ends
          # the *last* line only, so a multi-line replacement — a line a companion inserts — put bare
          # LF lines into a CRLF file and dropped the `\r` from the line it replaced. Measured with a
          # `Companions::Insert` against a CRLF `spec_helper.rb`: `RSpec.configure do |config|\n
          # config.infer…\r\n`. A `\r\n` the replacement already carries is left alone.
          written = edit["after"].to_s
          written = written.gsub(/(?<!\r)\n/, "\r\n") if found.end_with?("\r")
          lines[index] = "#{written}#{found.end_with?("\r") ? "\r" : ""}".b
          dirty[full] = true
          applied << Applied.new(
            path: path, line: edit["line"], text: edit["text"], after: edit["after"],
            subject: edit["subject"], origin: edit["origin"], note: edit["note"]
          )
        end

        # **One read and one write per file**, at the end rather than per edit. Writing
        # inside the loop would mean two edits in one file each rewriting the file from
        # a snapshot, so the second would put the first back; reading once also keeps a
        # refusal from being decided against a file an earlier edit had already
        # changed. A file no edit was accepted for is not opened for writing at all.
        dirty.each_key { |full| File.binwrite(full, lines_by_file[full].join("\n")) }

        Result.new(applied: applied, refused: refused, files_written: dirty.size)
      end

      private

      def refuse(edit, path, found, reason)
        Refused.new(
          path: path, line: edit["line"], text: edit["text"], found: found, reason: reason,
          subject: edit["subject"], kind: edit["kind"], replacement: edit["replacement"],
          source: edit["source"], note: edit["note"]
        )
      end

      def strip_cr(line)
        line.end_with?("\r") ? line[0..-2] : line
      end

      # The full path when it is a file this applier may write, or `nil` and the reason it may not.
      # The rule is `Sealed`'s, because the decision effects write to the same tree and a second copy
      # of it is a second answer to "is this path inside the copy".
      def sealed(path)
        Sealed.path(@root, path, root_real: @root_real)
      end
    end
  end
end
