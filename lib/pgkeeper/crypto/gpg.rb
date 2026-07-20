# frozen_string_literal: true

require "open3"

module PgKeeper
  module Crypto
    # Encryption by shelling out to +gpg+. Two modes:
    #
    # * recipient-based (asymmetric): +recipient:+ set — encrypts to a public
    #   key; decryption needs the corresponding secret key in the keyring.
    # * symmetric: +passphrase:+ set — encrypts with a passphrase, AES-256.
    #
    # This is an alternative to the built-in {Aes256Gcm} for shops already
    # standardized on GPG key management.
    class Gpg
      def initialize(recipient: nil, passphrase: nil)
        @recipient = recipient
        @passphrase = passphrase
        validate!
      end

      def name = "gpg"
      def extension = "gpg"

      def available?
        !which("gpg").nil?
      end

      def encrypt(source, dest)
        ensure_available!
        args = ["--batch", "--yes", "--output", dest]
        args += if @recipient
                  ["--encrypt", "--recipient", @recipient]
                else
                  ["--symmetric", "--cipher-algo", "AES256", "--passphrase-fd", "0"]
                end
        args << source
        run!(args, stdin: symmetric? ? @passphrase : nil)
        dest
      end

      def decrypt(source, dest)
        ensure_available!
        args = ["--batch", "--yes", "--output", dest]
        args += ["--passphrase-fd", "0"] if symmetric?
        args += ["--decrypt", source]
        run!(args, stdin: symmetric? ? @passphrase : nil)
        dest
      end

      private

      def symmetric? = @recipient.nil?

      def validate!
        return if @recipient || @passphrase

        raise ConfigError, "gpg encryption requires either `recipient` or a passphrase (`passphrase_env`)"
      end

      def ensure_available!
        return if available?

        raise EnvironmentError, "gpg binary not found on PATH; install gnupg or choose a different encryption type"
      end

      def run!(args, stdin: nil)
        out, err, status = Open3.capture3("gpg", *args, stdin_data: stdin.to_s)
        return out if status.success?

        raise Error, "gpg failed (#{status.exitstatus}): #{err.strip}"
      end

      def which(tool)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).find do |dir|
          path = File.join(dir, tool)
          File.executable?(path) && File.file?(path)
        end
      end
    end
  end
end
