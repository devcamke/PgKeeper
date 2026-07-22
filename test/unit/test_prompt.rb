# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestPrompt < Minitest::Test
    include TestHelpers

    def build(script)
      out = StringIO.new
      prompt = Prompt.new(input: StringIO.new(script), output: out, color: false)
      [prompt, out]
    end

    def test_ask_returns_trimmed_answer
      prompt, = build("  hello  \n")

      assert_equal "hello", prompt.ask("Name")
    end

    def test_ask_uses_default_on_blank
      prompt, = build("\n")

      assert_equal "localhost", prompt.ask("Host", default: "localhost")
    end

    def test_ask_answer_overrides_default
      prompt, = build("db.internal\n")

      assert_equal "db.internal", prompt.ask("Host", default: "localhost")
    end

    def test_ask_required_reasks_until_nonblank
      prompt, out = build("\n\nfinally\n")

      assert_equal "finally", prompt.ask("Name", required: true)
      assert_includes out.string, "required"
    end

    def test_ask_without_default_allows_empty
      prompt, = build("\n")

      assert_equal "", prompt.ask("Optional")
    end

    def test_ask_secret_reads_a_line_when_not_a_tty
      prompt, = build("s3cr3t\n")

      assert_equal "s3cr3t", prompt.ask_secret("Password")
    end

    def test_yes_accepts_default_on_blank
      prompt, = build("\n")

      assert prompt.yes?("Proceed?", default: true)

      prompt2, = build("\n")

      refute prompt2.yes?("Proceed?", default: false)
    end

    def test_yes_parses_variants
      %w[y Y yes YES].each do |answer|
        prompt, = build("#{answer}\n")

        assert prompt.yes?("?", default: false), "#{answer.inspect} should be true"
      end
      %w[n N no NO].each do |answer|
        prompt, = build("#{answer}\n")

        refute prompt.yes?("?", default: true), "#{answer.inspect} should be false"
      end
    end

    def test_yes_reasks_on_garbage
      prompt, out = build("maybe\nyes\n")

      assert prompt.yes?("?", default: false)
      assert_includes out.string, %(please answer "y" or "n")
    end

    def test_eof_raises_aborted
      prompt, = build("")
      assert_raises(Prompt::Aborted) { prompt.ask("Name", required: true) }
    end
  end
end
