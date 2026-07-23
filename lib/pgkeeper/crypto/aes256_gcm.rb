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

      # Key material is the descriptor produced by {Crypto::KeyMaterial}: either a
      # raw 32-byte key or a passphrase to stretch with PBKDF2.
      #
      # A single +key:+ is the common case. +keys:+ takes a list (primary first)
      # to support graceful key rotation: encryption always uses the primary key,
      # while decryption tries every key in turn, so backups written under a
      # since-retired passphrase stay restorable and verifiable.
      def initialize(key: nil, keys: nil)
        @keys = (keys || [key]).compact
        raise ConfigError, "AES encryption requires at least one key" if @keys.empty?
      end

      def name = "aes256gcm"
      def extension = "enc"

      def encrypt(source, dest)
        salt = OpenSSL::Random.random_bytes(SALT_LEN)
        kdf, key = derive_key(@keys.first, salt)

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

      # Try each configured key in turn (there is more than one only mid-rotation)
      # until one authenticates. Structural problems — bad magic, truncation —
      # are raised immediately since no key can fix them; only a GCM auth failure
      # (wrong key) falls through to the next candidate.
      def decrypt(source, dest)
        last_error = nil
        @keys.each do |material|
          return decrypt_with(source, dest, material)
        rescue OpenSSL::Cipher::CipherError => e
          last_error = e
        end

        FileUtils.rm_f(dest)
        raise Error, "decryption failed for #{source}: wrong key or corrupted/tampered file " \
                     "(tried #{@keys.length} key(s))#{" — #{last_error.message}" if last_error}"
      end

      private

      def decrypt_with(source, dest, material)
        File.open(source, "rb") do |input|
          salt, iv = read_header(input, source)
          _kdf, key = derive_key(material, salt) # kdf flag informs nothing we don't already know from config

          cipher = OpenSSL::Cipher.new(CIPHER)
          cipher.decrypt
          cipher.key = key
          cipher.iv = iv
          cipher.auth_tag = read_tag(source)

          stream_plaintext(input, dest, cipher, source)
        end
        dest
      end

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
        # A wrong key or a tampered/corrupt file. Clean up the partial output and
        # let {#decrypt} decide whether another key might work or it's terminal.
        FileUtils.rm_f(dest)
        raise
      end

      def derive_key(material, salt)
        case material[:kind]
        when :raw
          [KDF_RAW, material[:key]]
        when :passphrase
          key = OpenSSL::PKCS5.pbkdf2_hmac(
            material[:passphrase], salt,
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
