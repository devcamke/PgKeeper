# frozen_string_literal: true

require "test_helper"

module PgKeeper
  class TestCrypto < Minitest::Test
    include TestHelpers

    PASS_CONFIG = { "enabled" => true, "type" => "aes256gcm", "passphrase_env" => "PGKEEPER_TEST_PASS" }.freeze

    def aes(passphrase: "correct horse battery staple")
      Crypto.build(PASS_CONFIG, env: { "PGKEEPER_TEST_PASS" => passphrase })
    end

    def test_aes_round_trips
      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        payload = "sensitive backup contents " * 1000
        File.binwrite(source, payload)

        enc = File.join(dir, "plain.dump.enc")
        aes.encrypt(source, enc)

        assert_path_exists enc
        refute_equal payload, File.binread(enc), "ciphertext must differ from plaintext"

        restored = File.join(dir, "restored.dump")
        aes.decrypt(enc, restored)

        assert_equal payload, File.binread(restored)
      end
    end

    def test_aes_round_trips_large_multichunk
      in_tmpdir do |dir|
        source = File.join(dir, "big.dump")
        payload = OpenSSL::Random.random_bytes(3 * 1024 * 1024)
        File.binwrite(source, payload)

        enc = File.join(dir, "big.enc")
        aes.encrypt(source, enc)
        restored = File.join(dir, "big.out")
        aes.decrypt(enc, restored)

        assert_equal payload, File.binread(restored)
      end
    end

    def test_aes_wrong_passphrase_fails
      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        File.binwrite(source, "secret")
        enc = File.join(dir, "plain.enc")
        aes(passphrase: "right").encrypt(source, enc)

        restored = File.join(dir, "out.dump")
        err = assert_raises(Error) { aes(passphrase: "wrong").decrypt(enc, restored) }
        assert_match(/wrong key or corrupted/, err.message)
        refute_path_exists restored, "failed decryption must not leave a partial file"
      end
    end

    def test_aes_tamper_detection
      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        File.binwrite(source, "important data " * 100)
        enc = File.join(dir, "plain.enc")
        aes.encrypt(source, enc)

        # Flip a byte in the ciphertext body.
        bytes = File.binread(enc).bytes
        bytes[Crypto::Aes256Gcm::HEADER_LEN + 4] ^= 0xFF
        File.binwrite(enc, bytes.pack("C*"))

        assert_raises(Error) { aes.decrypt(enc, File.join(dir, "out")) }
      end
    end

    def test_aes_keyfile_round_trips
      in_tmpdir do |dir|
        keyfile = File.join(dir, "key.bin")
        File.binwrite(keyfile, OpenSSL::Random.random_bytes(32))
        cfg = { "enabled" => true, "type" => "aes256gcm", "keyfile" => keyfile }
        enc = Crypto.build(cfg)

        source = File.join(dir, "plain.dump")
        File.binwrite(source, "keyfile-protected")
        cipher_path = File.join(dir, "plain.enc")
        enc.encrypt(source, cipher_path)

        restored = File.join(dir, "out.dump")
        Crypto.build(cfg).decrypt(cipher_path, restored)

        assert_equal "keyfile-protected", File.binread(restored)
      end
    end

    def test_build_returns_nil_when_disabled
      assert_nil Crypto.build({ "enabled" => false })
      assert_nil Crypto.build(nil)
    end

    def test_missing_passphrase_env_raises
      cfg = { "enabled" => true, "type" => "aes256gcm", "passphrase_env" => "NOT_SET_ANYWHERE" }
      assert_raises(ConfigError) { Crypto.build(cfg, env: {}) }
    end

    def test_unknown_type_raises
      cfg = { "enabled" => true, "type" => "rot13", "passphrase_env" => "X" }
      assert_raises(ConfigError) { Crypto.build(cfg, env: { "X" => "p" }) }
    end

    def test_gpg_symmetric_round_trips_or_skips
      gpg = Crypto.build(
        { "enabled" => true, "type" => "gpg", "passphrase_env" => "GPGPASS" },
        env: { "GPGPASS" => "hunter2" }
      )
      skip "gpg binary not installed" unless gpg.available?

      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        File.binwrite(source, "gpg-protected payload")
        enc = File.join(dir, "plain.gpg")
        gpg.encrypt(source, enc)

        refute_equal File.binread(source), File.binread(enc)

        restored = File.join(dir, "out.dump")
        gpg.decrypt(enc, restored)

        assert_equal "gpg-protected payload", File.binread(restored)
      end
    end
  end
end
