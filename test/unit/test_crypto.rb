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

    # --- key rotation (keyring) -------------------------------------------

    # After rotating the passphrase, a backup written under the OLD passphrase
    # must still decrypt as long as the old passphrase is kept in the keyring via
    # `previous_passphrase_envs`.
    def test_rotated_key_still_decrypts_old_backups
      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        payload = "written under the old key " * 500
        File.binwrite(source, payload)

        old = Crypto.build(PASS_CONFIG, env: { "PGKEEPER_TEST_PASS" => "old-secret" })
        enc = File.join(dir, "old.enc")
        old.encrypt(source, enc)

        rotated = Crypto.build(
          PASS_CONFIG.merge("previous_passphrase_envs" => ["OLD_PASS"]),
          env: { "PGKEEPER_TEST_PASS" => "new-secret", "OLD_PASS" => "old-secret" }
        )
        restored = File.join(dir, "restored.dump")
        rotated.decrypt(enc, restored)

        assert_equal payload, File.binread(restored)
      end
    end

    def test_new_backups_use_the_primary_key_only
      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        File.binwrite(source, "fresh payload")

        rotated = Crypto.build(
          PASS_CONFIG.merge("previous_passphrase_envs" => ["OLD_PASS"]),
          env: { "PGKEEPER_TEST_PASS" => "new-secret", "OLD_PASS" => "old-secret" }
        )
        enc = File.join(dir, "new.enc")
        rotated.encrypt(source, enc)

        # Only the retired key: cannot decrypt a backup written with the new key.
        only_old = Crypto.build(PASS_CONFIG, env: { "PGKEEPER_TEST_PASS" => "old-secret" })
        assert_raises(Error) { only_old.decrypt(enc, File.join(dir, "nope.dump")) }

        # The new (primary) key decrypts it.
        only_new = Crypto.build(PASS_CONFIG, env: { "PGKEEPER_TEST_PASS" => "new-secret" })
        only_new.decrypt(enc, File.join(dir, "ok.dump"))

        assert_equal "fresh payload", File.binread(File.join(dir, "ok.dump"))
      end
    end

    def test_wrong_key_with_no_previous_raises_and_leaves_no_output
      in_tmpdir do |dir|
        source = File.join(dir, "plain.dump")
        File.binwrite(source, "secret")
        enc = File.join(dir, "x.enc")
        Crypto.build(PASS_CONFIG, env: { "PGKEEPER_TEST_PASS" => "right" }).encrypt(source, enc)

        wrong = Crypto.build(PASS_CONFIG, env: { "PGKEEPER_TEST_PASS" => "wrong" })
        out = File.join(dir, "out.dump")
        assert_raises(Error) { wrong.decrypt(enc, out) }
        refute_path_exists out, "a failed decrypt must not leave a partial file"
      end
    end

    def test_missing_previous_passphrase_env_raises
      cfg = PASS_CONFIG.merge("previous_passphrase_envs" => ["NOT_SET"])
      assert_raises(ConfigError) do
        Crypto.build(cfg, env: { "PGKEEPER_TEST_PASS" => "p" })
      end
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
