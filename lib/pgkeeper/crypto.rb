# frozen_string_literal: true

require "digest"
require "pgkeeper/crypto/aes256_gcm"
require "pgkeeper/crypto/gpg"

module PgKeeper
  # Optional encryption-at-rest for backup artifacts — worth having *before*
  # anything is shipped to a third-party cloud.
  #
  # Every encryptor implements a symmetric pair:
  #
  #   encryptor.encrypt(source_path, dest_path) # => dest_path
  #   encryptor.decrypt(source_path, dest_path)
  #   encryptor.extension                        # "enc" (AES) or "gpg"
  #   encryptor.name
  #
  # {build} turns the +encryption:+ config block into an encryptor, or +nil+
  # when encryption is disabled.
  module Crypto
    TYPES = %w[aes256gcm gpg].freeze

    module_function

    # Build an encryptor from the validated +encryption+ config hash, or return
    # nil when encryption is disabled. +env+ supplies passphrases by variable
    # name so secrets never live in the config file.
    def build(config, env: ENV)
      return nil unless config.is_a?(Hash) && config["enabled"]

      type = (config["type"] || "aes256gcm").to_s
      case type
      when "aes256gcm" then Aes256Gcm.new(keys: resolve_keys(config, env))
      when "gpg" then build_gpg(config, env)
      else
        raise ConfigError, "unknown encryption type: #{type.inspect} (expected one of #{TYPES.join(', ')})"
      end
    end

    # The full AES keyring: the primary key first (used for encryption), then any
    # previous keys retired by a rotation (used only to decrypt older backups).
    # See +previous_passphrase_envs+ / +previous_keyfiles+ in the config.
    def resolve_keys(config, env)
      keys = [resolve_key(config, env)]

      Array(config["previous_passphrase_envs"]).each do |var|
        secret = env[var]
        raise ConfigError, "encryption previous passphrase env #{var} is not set" if secret.nil? || secret.empty?

        keys << KeyMaterial.from_passphrase(secret)
      end
      Array(config["previous_keyfiles"]).each { |path| keys << KeyMaterial.from_keyfile(path) }
      keys
    end

    # Derive raw 32-byte key material for AES from either a passphrase env var or
    # a keyfile. The salt for passphrase derivation is generated per-artifact and
    # stored in the encrypted file header, so it isn't needed here.
    def resolve_key(config, env)
      if config["keyfile"]
        KeyMaterial.from_keyfile(config["keyfile"])
      elsif config["passphrase_env"]
        passphrase = env[config["passphrase_env"]]
        if passphrase.nil? || passphrase.empty?
          raise ConfigError, "encryption passphrase env #{config['passphrase_env']} is not set"
        end

        KeyMaterial.from_passphrase(passphrase)
      else
        raise ConfigError, "encryption requires either `passphrase_env` or `keyfile`"
      end
    end

    def build_gpg(config, env)
      passphrase = config["passphrase_env"] && env[config["passphrase_env"]]
      Gpg.new(recipient: config["recipient"], passphrase: passphrase)
    end

    # How AES key material is obtained. A passphrase is stretched with PBKDF2 at
    # encrypt time (salt lives in the file); a keyfile provides key bytes
    # directly (hashed to 32 bytes if it isn't already exactly that long).
    module KeyMaterial
      PBKDF2_ITERATIONS = 210_000

      module_function

      def from_passphrase(passphrase)
        { kind: :passphrase, passphrase: passphrase }
      end

      def from_keyfile(path)
        raise ConfigError, "keyfile not found: #{path}" unless File.file?(path)

        bytes = File.binread(path)
        key = bytes.bytesize == 32 ? bytes : Digest::SHA256.digest(bytes)
        { kind: :raw, key: key }
      end
    end
  end
end
