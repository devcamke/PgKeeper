# frozen_string_literal: true

module PgKeeper
  # A tiny line-oriented prompt helper for the interactive commands (the
  # onboarding {Wizard}). Input and output are injected so the flow can be
  # driven deterministically in tests with StringIO, and so an exhausted stream
  # (a closed pipe, a non-interactive `cron` invocation) surfaces as a clean
  # {Aborted} rather than blocking forever on a read that never returns.
  class Prompt
    # Raised when input runs out (EOF) mid-question — typically the command was
    # run non-interactively with nothing piped to answer the prompts.
    class Aborted < Error; end

    def initialize(input: $stdin, output: $stdout, color: nil)
      @input = input
      @output = output
      # Colorize only when writing to a terminal, unless told otherwise.
      @color = color.nil? ? tty? : color
    end

    # True when the input stream is an interactive terminal.
    def interactive?
      @input.respond_to?(:tty?) && @input.tty?
    end

    # Print a line as-is.
    def say(message = "")
      @output.puts(message)
    end

    # Print a section heading with a blank line above it.
    def heading(message)
      @output.puts
      @output.puts(bold(message))
    end

    # Ask a free-text question. Returns the trimmed answer, or +default+ when the
    # user just presses enter. When +required+ and there is no default, re-asks
    # until a non-empty answer is given.
    def ask(label, default: nil, required: false)
      loop do
        write_label(label, default)
        answer = read_line.strip
        return answer unless answer.empty?
        return default unless default.nil?
        return "" unless required

        say("  (a value is required)")
      end
    end

    # Ask for a secret. Echo is suppressed when the input is a real terminal;
    # otherwise (tests, pipes) it falls back to a normal read.
    def ask_secret(label)
      write_label(label, nil)
      value = read_secret
      say("") # terminate the (silent) line the terminal never echoed
      value.strip
    end

    # Ask a yes/no question, returning true or false. Enter accepts +default+.
    def yes?(label, default: true)
      suffix = default ? "[Y/n]" : "[y/N]"
      loop do
        @output.print("#{label} #{suffix} ")
        flush
        answer = read_line.strip.downcase
        return default if answer.empty?
        return true if %w[y yes].include?(answer)
        return false if %w[n no].include?(answer)

        say(%(  please answer "y" or "n"))
      end
    end

    private

    def write_label(label, default)
      hint = default.nil? || default.to_s.empty? ? "" : " (#{default})"
      @output.print("#{label}#{hint}: ")
      flush
    end

    def read_line
      line = @input.gets
      raise Aborted, "input ended unexpectedly (nothing left to read)" if line.nil?

      line
    end

    def read_secret
      if interactive? && @input.respond_to?(:noecho)
        begin
          require "io/console"
          return @input.noecho { @input.gets }.to_s
        rescue StandardError
          # No usable no-echo terminal; fall back to an ordinary (echoed) read.
        end
      end
      read_line
    end

    def flush
      @output.flush if @output.respond_to?(:flush)
    end

    def tty?
      @output.respond_to?(:tty?) && @output.tty?
    end

    def bold(text) = @color ? "\e[1m#{text}\e[0m" : text
  end
end
