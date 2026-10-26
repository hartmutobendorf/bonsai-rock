# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../hack/little-surgery'

class LittleSurgeryTest < Minitest::Test
  def setup
    @tools = Object.new
    @work = Dir.mktmpdir('bonsai-test')
    @oci = File.join(@work, 'oci')
    @stage = File.join(@work, 'stage')
    FileUtils.mkdir_p(File.join(@stage, 'etc'))
    File.write(File.join(@stage, 'etc/passwd'),
               "root:x:0:0:root:/root:/bin/false\n" \
               "_daemon_:x:584792:584792::/var/lib/pebble/default:/usr/bin/false\n")
    File.write(File.join(@stage, 'etc/group'), "root:x:0:\n_daemon_:x:584792:\n")
    File.write(File.join(@stage, 'etc/shadow'), "_daemon_:!:20000::::::\n")
    File.chmod(0o600, File.join(@stage, 'etc/shadow'))
    FileUtils.mkdir_p(File.join(@stage, 'var/lib/pebble/default/layers'))
    File.chmod(0o1777, File.join(@stage, 'var/lib/pebble/default'))
    File.write(File.join(@stage, 'var/lib/pebble/default/layers/service.yaml'), "services: {}\n")
    @tools.send(:run, umoci, 'init', '--layout', @oci)
    @tools.send(:run, umoci, 'new', '--image', "#{@oci}:#{IMG_TAG}")
  end

  def teardown
    FileUtils.remove_entry(@work)
  end

  def pack_base(arch = 'amd64')
    tar = File.join(@work, 'base.tar')
    @tools.send(:tar_dir, @stage, tar)
    @tools.send(:run, umoci, 'raw', 'add-layer', '--image', "#{@oci}:#{IMG_TAG}", tar)
    @tools.send(:run, umoci, 'config', '--image', "#{@oci}:#{IMG_TAG}",
        '--architecture', arch, '--config.user', '584792',
        '--config.entrypoint', '/usr/bin/pebble', '--config.entrypoint', 'enter')
  end

  def blob(descriptor)
    algorithm, digest = descriptor.fetch('digest').split(':')
    JSON.parse(File.read(File.join(@oci, 'blobs', algorithm, digest)))
  end

  def manifest
    blob(JSON.parse(File.read(File.join(@oci, 'index.json'))).fetch('manifests').first)
  end

  def test_identity_and_layers_on_both_architectures
    %w[amd64 arm64].each do |arch|
      pack_base(arch)
      shards = File.join(@work, 'shards')
      FileUtils.mkdir_p(shards)
      File.write(File.join(shards, 'model-00001-of-00001.gguf'), 'synthetic model')
      File.write(File.join(shards, 'NOTICE'), 'synthetic notice')
      @tools.send(:inject_layers, @oci, shards)
      before = manifest
      config_before = blob(before.fetch('config'))

      @tools.send(:normalize_runtime_user, @oci)

      after = manifest
      config_after = blob(after.fetch('config'))
      assert_equal before.fetch('layers'), after.fetch('layers')[0...-1]
      assert_equal config_before.fetch('rootfs').fetch('diff_ids'),
                   config_after.fetch('rootfs').fetch('diff_ids')[0...-1]
      assert_equal arch, config_after.fetch('architecture')
      assert_equal config_before.fetch('config').merge('User' => '1000:1000'),
                   config_after.fetch('config')

      rootfs = File.join(@work, "unpacked-#{arch}")
      @tools.send(:run, umoci, 'raw', 'unpack', '--rootless', '--image', "#{@oci}:#{IMG_TAG}", rootfs)
      assert_equal "root:x:0:0:root:/root:/bin/false\n" \
                   "_daemon_:x:1000:1000::/var/lib/pebble/default:/usr/bin/false\n",
                   File.read(File.join(rootfs, 'etc/passwd'))
      assert_equal "root:x:0:\n_daemon_:x:1000:\n", File.read(File.join(rootfs, 'etc/group'))
      assert_equal "_daemon_:!:20000::::::\n", File.read(File.join(rootfs, 'etc/shadow'))
      assert_equal 0o644, File.stat(File.join(rootfs, 'etc/passwd')).mode & 0o777
      assert_equal 0o644, File.stat(File.join(rootfs, 'etc/group')).mode & 0o777
      # Rootless umoci may strip the sticky bit; the unchanged base layer above
      # additionally guarantees that original ownership and modes are retained.
      assert_equal 0o777, File.stat(File.join(rootfs, 'var/lib/pebble/default')).mode & 0o777
      assert_equal 'synthetic model', File.read(File.join(rootfs, DEST, 'model-00001-of-00001.gguf'))
      assert_equal 'synthetic notice', File.read(File.join(rootfs, DOC_DEST, 'NOTICE'))
    end
  end

  def test_rejects_uid_collision
    File.open(File.join(@stage, 'etc/passwd'), 'a') { |f| f.puts 'other:x:1000:10::/:/bin/false' }
    assert_rejected('UID/GID 1000 already used in /etc/passwd')
  end

  def test_rejects_gid_collision
    File.open(File.join(@stage, 'etc/group'), 'a') { |f| f.puts 'other:x:1000:' }
    assert_rejected('UID/GID 1000 already used in /etc/group')
  end

  def test_rejects_missing_account
    File.write(File.join(@stage, 'etc/passwd'), "root:x:0:0::/:/bin/false\n")
    assert_rejected('expected one _daemon_ entry in /etc/passwd')
  end

  def test_rejects_duplicate_group
    File.open(File.join(@stage, 'etc/group'), 'a') { |f| f.puts '_daemon_:x:42:' }
    assert_rejected('expected one _daemon_ entry in /etc/group')
  end

  def assert_rejected(message)
    pack_base
    before = manifest
    _, stderr = capture_io do
      error = assert_raises(SystemExit) { @tools.send(:normalize_runtime_user, @oci) }
      refute error.success?
    end
    assert_includes stderr, message
    assert_equal before, manifest
  end
end
