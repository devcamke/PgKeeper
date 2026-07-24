# frozen_string_literal: true

module PgKeeper
  # Schedule editing by the same targeted text surgery as {append_database}:
  # set, replace, or remove a `schedule:` key — on one database entry or the
  # top level — without re-serializing the document, so a hand-authored file
  # keeps its comments and its `<%= ENV[...] %>` interpolations intact.
  module ConfigWriter
    module_function

    # Set, replace, or (with a nil +expression+) remove the `schedule:` key of
    # the database entry named +name+. Raises {ConfigError} when no entry
    # named +name+ exists.
    def set_database_schedule(text, name, expression)
      lines = text.lines
      range = database_entry_range(lines, name)
      idx = range.find { |i| lines[i].match?(/\A\s*schedule:/) }
      if expression.nil?
        lines.delete_at(idx) if idx
      elsif idx
        lines[idx] = "#{lines[idx][/\A */]}schedule: #{scalar(expression)}\n"
      else
        indent = " " * (lines[range.begin][/\A */].length + 2)
        lines.insert(last_content_line(lines, range) + 1, "#{indent}schedule: #{scalar(expression)}\n")
      end
      lines.join
    end

    # Set, replace, or (with a nil +expression+) remove the file's top-level
    # `schedule:`. A key the file doesn't have yet is inserted just above
    # `databases:` (or appended), where a reader expects to find it.
    def set_global_schedule(text, expression)
      lines = text.lines
      idx = lines.index { |line| line.match?(/\Aschedule:/) }
      if idx
        expression.nil? ? lines.delete_at(idx) : lines[idx] = "schedule: #{scalar(expression)}\n"
      elsif expression
        at = lines.index { |line| line.match?(/\A\s*databases:\s*(#.*)?\z/) } || lines.length
        lines.insert(at, "schedule: #{scalar(expression)}\n")
      end
      lines.join
    end

    # The inclusive line range of the entry named +name+ under `databases:`.
    # An entry runs from its `- ` line to the line before the next item (or,
    # for the last item, to the last line indented as entry content). Comment
    # and blank lines never terminate an entry.
    def database_entry_range(lines, name)
      db_idx = lines.index { |line| line.match?(/\A\s*databases:\s*(#.*)?\z/) }
      raise ConfigError, "could not find a `databases:` list in the config" if db_idx.nil?

      starts = item_starts(lines, db_idx, list_indent(lines, db_idx))
      starts.each_with_index do |start, i|
        stop = (starts[i + 1] || block_end(lines, start, list_indent(lines, db_idx))) - 1
        return start..stop if entry_named?(lines, start..stop, name)
      end
      raise ConfigError, "no database named #{name.inspect} in the config"
    end

    # Line indices where `databases:` list items begin. Stops at the first
    # non-blank, non-comment line dedented past the items (the next section).
    def item_starts(lines, db_idx, indent)
      starts = []
      ((db_idx + 1)...lines.length).each do |i|
        stripped = lines[i].strip
        next if stripped.empty? || stripped.start_with?("#")

        if lines[i].match?(/\A {#{indent}}- /)
          starts << i
        elsif lines[i][/\A */].length < indent
          break
        end
      end
      starts
    end

    # First line at or past which +start+'s entry is over: non-blank,
    # non-comment, and dedented below the entry's field indentation.
    def block_end(lines, start, indent)
      ((start + 1)...lines.length).each do |i|
        stripped = lines[i].strip
        next if stripped.empty? || stripped.start_with?("#")
        return i if lines[i][/\A */].length < indent + 2
      end
      lines.length
    end

    # Whether the entry spanning +range+ has `name:` equal to +name+
    # (surrounding quotes and a trailing comment tolerated).
    def entry_named?(lines, range, name)
      range.any? do |i|
        m = lines[i].match(/\A\s*(?:- )?name:\s*(.+?)\s*\z/)
        m && m[1].sub(/\s+#.*\z/, "").gsub(/\A(['"])(.*)\1\z/, '\2') == name
      end
    end

    # Index of the last non-blank, non-comment line in +range+ — where a new
    # field is appended so it lands inside the entry, not after trailing
    # comments that belong to the next section.
    def last_content_line(lines, range)
      range.to_a.reverse_each do |i|
        stripped = lines[i].strip
        return i unless stripped.empty? || stripped.start_with?("#")
      end
      range.begin
    end
  end
end
