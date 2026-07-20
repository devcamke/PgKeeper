# frozen_string_literal: true

require "openssl"
require "digest"
require "fileutils"

module PgKeeper
  module Crypto
    # Authenticated encryption with AES-256-GCM, using only the Ruby stdlib
    # (+openssl+). GCM gives us both confidentiality and integrity: if a single
    # byte of the ciphertext is altered, decryption fails loudly rather than
    # returning garbage.
    #
    # On-disk format (all fixed-width fields big-endian byte strings):
    #
    #   magic    "PGKAES1"   7 bytes
    #   version  0x01        1 byte
    #   kdf      0x01 pbkdf2 / 0x00 raw-key   1 byte
    #   salt     16 bytes    (random; meaningful only for pbkdf2)
    #   iv       12 bytes    (random per artifact)
    #   ...ciphertext...     (streamed)
    #   tag      16 bytes    (GCM auth tag, at end of file)
    #
    # The tag lives at the end because it isn't known until the whole plaintext
    # has been processed; decryption reads it first, then streams the ciphertext.
    class Aes256Gcm
      MAGIC = "PGKAES1"
      VERSION = 1
      KDF_RAW = 0
      KDF_PBKDF2 = 1
      SALT_LEN = 16
      IV_LEN = 12
      TAG_LEN = 16
      HEADER_LEN = MAGIC.bytesize + 1 + 1 + SALT_LEN + IV_LEN # 37
      CHUNK = 1 << 20 # 1 MiB
      CIPHER = "aes-256-gcm"

      # +key+ is the descriptor produced by {Crypto::KeyMaterial}: either a raw
      # 32-byte key or a passphrase to stretch with PBKDF2.
      def initialize(key:)
        @key_material = key
      end

      def name = "aes256gcm"
      def extension = "enc"

      def encrypt(source, dest)
        salt = OpenSSL::Random.random_bytes(SALT_LEN)
        kdf, key = derive_key(salt)

        cipher = OpenSSL::Cipher.new(CIPHER)
        cipher.encrypt
        cipher.key = key
        iv = cipher.random_iv # GCM default IV length is 12 bytes

        File.open(dest, "wb") do |out|
          out.write(MAGIC)
          out.write([VERSION, kdf].pack("C2"))
          out.write(salt)
          out.write(iv)
          File.open(source, "rb") do |input|
            out.write(cipher.update(input.read(CHUNK))) until input.eof?
          end
          out.write(cipher.final)
          out.write(cipher.auth_tag(TAG_LEN))
        end
        dest
      end

      def decrypt(source, dest)
        File.open(source, "rb") do |input|
          salt, iv = read_header(input, source)
          _kdf, key = derive_key(salt) # kdf flag informs nothing we don't already know from config

          cipher = OpenSSL::Cipher.new(CIPHER)
          cipher.decrypt
          cipher.key = key
          cipher.iv = iv
          cipher.auth_tag = read_tag(source)

          stream_plaintext(input, dest, cipher, source)
        end
        dest
      end

      private

      def read_header(input, source)
        header = input.read(HEADER_LEN).to_s
        raise Error, "#{source} is not a PgKeeper-encrypted file (too short)" if header.bytesize < HEADER_LEN

        magic = header.byteslice(0, MAGIC.bytesize)
        raise Error, "#{source} is not a PgKeeper-encrypted file (bad magic)" unless magic == MAGIC

        version = header.getbyte(MAGIC.bytesize)
        raise Error, "unsupported encryption version #{version} in #{source}" unless version == VERSION

        salt = header.byteslice(MAGIC.bytesize + 2, SALT_LEN)
        iv = header.byteslice(MAGIC.bytesize + 2 + SALT_LEN, IV_LEN)
        [salt, iv]
      end

      # Read the GCM tag from the last TAG_LEN bytes of the file.
      def read_tag(source)
        size = File.size(source)
        raise Error, "#{source} is truncated (no auth tag)" if size < HEADER_LEN + TAG_LEN

        File.binread(source, TAG_LEN, size - TAG_LEN)
      end

      # Stream the ciphertext region [HEADER_LEN, filesize - TAG_LEN) through the
      # cipher; +cipher.final+ verifies the tag and raises on tampering.
      def stream_plaintext(input, dest, cipher, source)
        remaining = File.size(source) - HEADER_LEN - TAG_LEN
        File.open(dest, "wb") do |out|
          while remaining.positive?
            chunk = input.read([CHUNK, remaining].min)
            break if chunk.nil?

            remaining -= chunk.bytesize
            out.write(cipher.update(chunk))
          end
          out.write(cipher.final)
        end
      rescue OpenSSL::Cipher::CipherError
        FileUtils.rm_f(dest)
        raise Error, "decryption failed for #{source}: wrong key or corrupted/tampered file"
      end

      def derive_key(salt)
        case @key_material[:kind]
        when :raw
          [KDF_RAW, @key_material[:key]]
        when :passphrase
          key = OpenSSL::PKCS5.pbkdf2_hmac(
            @key_material[:passphrase], salt,
            Crypto::KeyMaterial::PBKDF2_ITERATIONS, 32, OpenSSL::Digest.new("SHA256")
          )
          [KDF_PBKDF2, key]
        else
          raise ConfigError, "invalid key material for AES encryption"
        end
      end
    end
  end
end
