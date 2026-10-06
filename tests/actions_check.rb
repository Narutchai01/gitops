#!/usr/bin/env ruby
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

ROOT = File.expand_path('..', __dir__)

class ActionsCheck < Minitest::Test
  def test_rc_tag_generation_and_validation
    in_repo do |repo|
      output = run_action('prepare-rc', repo, 'release-branch' => 'release/1.2.3')
      assert_equal '1.2.3', output.fetch('version')
      assert_equal 'v1.2.3-rc.1', output.fetch('tag')

      git(repo, 'tag', 'v1.2.3-rc.9')
      git(repo, 'tag', 'v1.2.3-rc.10')
      output = run_action('prepare-rc', repo, 'release-branch' => 'release/1.2.3')
      assert_equal 'v1.2.3-rc.11', output.fetch('tag')

      assert_failure { run_action('prepare-rc', repo, 'release-branch' => 'foo/1.2.3') }
    end
  end

  def test_production_requires_rc_matching_commit_and_tree
    in_repo do |repo|
      write(repo, 'package.json', '{"name":"app","version":"1.2.3"}')
      write(repo, 'src.txt', 'tested')
      release_sha = commit(repo, 'release')
      git(repo, 'tag', '-a', 'v1.2.3-rc.1', '-m', 'RC')

      write(repo, 'package.json', '{"name":"app","version":"1.2.4"}')
      main_sha = commit(repo, 'main version')
      output = run_action('prepare-production', repo,
        'release-branch' => 'release/1.2.3', 'release-sha' => release_sha, 'main-sha' => main_sha)
      assert_equal 'v1.2.3-rc.1', output.fetch('rc-tag')
      assert_equal 'v1.2.3', output.fetch('final-tag')

      assert_failure do
        run_action('prepare-production', repo,
          'release-branch' => 'release/1.2.3', 'release-sha' => main_sha, 'main-sha' => main_sha)
      end

      write(repo, 'src.txt', 'untested change')
      changed_sha = commit(repo, 'main source change')
      assert_failure do
        run_action('prepare-production', repo,
          'release-branch' => 'release/1.2.3', 'release-sha' => release_sha, 'main-sha' => changed_sha)
      end

      assert_failure do
        run_action('prepare-production', repo,
          'release-branch' => 'release/2.0.0', 'release-sha' => release_sha, 'main-sha' => changed_sha)
      end
    end
  end

  def test_go_production_requires_the_entire_tree_to_match
    in_repo do |repo|
      write(repo, 'go.mod', "module example.test/app\n\ngo 1.20\n")
      write(repo, 'main.go', "package app\n\nfunc Value() int { return 1 }\n")
      write(repo, 'go.sum', '')
      release_sha = commit(repo, 'release')
      git(repo, 'tag', '-a', 'v1.2.3-rc.1', '-m', 'RC')
      git(repo, 'commit', '--allow-empty', '-qm', 'main merge')
      main_sha = git(repo, 'rev-parse', 'HEAD')

      output = run_action('prepare-production', repo,
        {'release-branch' => 'release/1.2.3', 'release-sha' => release_sha,
         'main-sha' => main_sha, 'allow-package-version-change' => 'false'})
      assert_equal 'v1.2.3', output.fetch('final-tag')

      {
        'main.go' => "package app\n\nfunc Value() int { return 2 }\n",
        'go.mod' => "module example.test/app\n\ngo 1.21\n",
        'go.sum' => "example.test/dependency v1.0.0 h1:changed\n",
        'README.md' => "changed\n"
      }.each do |path, content|
        git(repo, 'reset', '--hard', release_sha)
        write(repo, path, content)
        changed_sha = commit(repo, "change #{path}")
        assert_failure do
          run_action('prepare-production', repo,
            {'release-branch' => 'release/1.2.3', 'release-sha' => release_sha,
             'main-sha' => changed_sha, 'allow-package-version-change' => 'false'})
        end
      end
    end
  end

  def test_go_quality_runs_vet_and_tests
    in_repo do |repo|
      write(repo, 'go.mod', "module example.test/app\n\ngo 1.20\n")
      write(repo, 'main.go', "package app\n\nfunc Value() int { return 1 }\n")
      write(repo, 'main_test.go', <<~GO)
        package app

        import "testing"

        func TestValue(t *testing.T) {
          if Value() != 1 { t.Fatal("wrong value") }
        }
      GO
      run_action('go-quality', repo)

      write(repo, 'main_test.go', File.read(File.join(repo, 'main_test.go')).sub('Value() != 1', 'Value() != 2'))
      error = assert_raises(RuntimeError) { run_action('go-quality', repo) }
      assert_includes error.message, 'go test ./...'

      write(repo, 'main.go', <<~GO)
        package app

        import "fmt"

        func Value() int {
          fmt.Printf("%d", "bad")
          return 1
        }
      GO
      error = assert_raises(RuntimeError) { run_action('go-quality', repo) }
      assert_includes error.message, 'go vet ./...'
    end
  end

  def test_release_tag_conflict_and_idempotency
    in_repo do |repo|
      original = git(repo, 'rev-parse', 'HEAD')
      git(repo, 'tag', '-a', 'v1.2.3', '-m', 'Existing tag')
      write(repo, 'changed.txt', 'changed')
      changed = commit(repo, 'changed')

      assert_failure do
        run_action('create-release', repo,
          {'tag' => 'v1.2.3', 'sha' => changed, 'token' => 'test'}, mock_bin: mock_gh(repo))
      end

      log = File.join(repo, 'gh.log')
      run_action('create-release', repo,
        {'tag' => 'v1.2.3', 'sha' => original, 'token' => 'test'},
        mock_bin: mock_gh(repo), extra_env: {'GH_MOCK_EXISTS' => 'true', 'MOCK_LOG' => log})
      assert_empty File.exist?(log) ? File.read(log) : ''
    end
  end

  def test_rc_tag_is_not_idempotent
    in_repo do |repo|
      sha = git(repo, 'rev-parse', 'HEAD')
      log = File.join(repo, 'gh.log')
      run_action('create-release', repo,
        {'tag' => 'v1.2.3-rc.1', 'sha' => sha, 'prerelease' => 'true', 'token' => 'test'},
        mock_bin: mock_gh(repo), extra_env: {'MOCK_LOG' => log})
      assert_includes File.read(log), '--prerelease'

      assert_failure do
        run_action('create-release', repo,
          {'tag' => 'v1.2.3-rc.1', 'sha' => sha, 'prerelease' => 'true', 'token' => 'test'}, mock_bin: mock_gh(repo))
      end
    end
  end

  def test_promote_image_rejects_a_digest_mismatch
    in_repo do |repo|
      bin = File.join(repo, 'bin')
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, 'docker'), <<~SH)
        #!/bin/sh
        [ "$3" = "inspect" ] || exit 0
        case "$4" in
          *:v1.2.3-rc.1) digest="$MOCK_SOURCE_DIGEST" ;;
          *:v1.2.3) digest="$MOCK_FINAL_DIGEST" ;;
          *:latest) digest="$MOCK_LATEST_DIGEST" ;;
          *) exit 2 ;;
        esac
        echo "Digest: $digest"
      SH
      File.chmod(0o755, File.join(bin, 'docker'))

      base_env = {
        'PATH' => "#{bin}:#{ENV.fetch('PATH')}",
        'MOCK_SOURCE_DIGEST' => 'sha256:tested',
        'MOCK_FINAL_DIGEST' => 'sha256:wrong',
        'MOCK_LATEST_DIGEST' => 'sha256:tested'
      }
      assert_failure do
        run_action('promote-image', repo,
          {'registry' => 'ghcr.io', 'image-name' => 'acme/app', 'rc-tag' => 'v1.2.3-rc.1',
           'final-tag' => 'v1.2.3', 'token' => 'test'}, extra_env: base_env)
      end

      base_env['MOCK_FINAL_DIGEST'] = 'sha256:tested'
      output = run_action('promote-image', repo,
        {'registry' => 'ghcr.io', 'image-name' => 'acme/app', 'rc-tag' => 'v1.2.3-rc.1',
         'final-tag' => 'v1.2.3', 'token' => 'test'}, extra_env: base_env)
      assert_equal 'sha256:tested', output.fetch('digest')
    end
  end

  def test_workflows_keep_jobs_and_reference_remote_actions
    expected = {
      'release-rc-nextjs.yml' => {
        'prepare' => [[], %w[version tag]],
        'quality' => [%w[prepare], []],
        'build' => [%w[prepare quality], %w[digest]],
        'create-tag' => [%w[prepare build], []]
      },
      'release-rc-go.yml' => {
        'prepare' => [[], %w[version tag]],
        'quality' => [%w[prepare], []],
        'build' => [%w[prepare quality], %w[digest]],
        'create-tag' => [%w[prepare build], []]
      },
      'release-next.yml' => {
        'prepare' => [[], %w[version rc-tag final-tag]],
        'promote' => [%w[prepare], %w[digest]],
        'release' => [%w[prepare promote], []]
      },
      'release-go.yml' => {
        'release' => [[], []]
      }
    }
    expected.each do |filename, jobs|
      workflow = load_yaml(File.join(ROOT, '.github/workflows', filename))
      assert_equal jobs.keys, workflow.fetch('jobs').keys
      workflow.fetch('jobs').each_value do |job|
        job.fetch('steps', []).each do |step|
          next unless step['uses']&.start_with?('narutchai01/gitops/.github/actions/')

          action, ref = step.fetch('uses').split('@', 2)
          assert_equal 'main', ref
          assert File.file?(File.join(ROOT, action.sub('narutchai01/gitops/', '')) + '/action.yml')
        end
      end
      jobs.each do |name, (needs, outputs)|
        job = workflow.fetch('jobs').fetch(name)
        assert_equal needs, job.fetch('needs', [])
        assert_equal outputs, job.fetch('outputs', {}).keys
      end
    end

    action_files = Dir[File.join(ROOT, '.github/actions/*/action.yml')]
    assert_equal 7, action_files.length
    action_files.each do |path|
      action = load_yaml(path)
      assert_equal 'composite', action.dig('runs', 'using')
      action.fetch('runs').fetch('steps').each do |step|
        assert step['uses'] || step['run']
        assert step['shell'] if step['run']
      end
    end

    go_release = load_yaml(File.join(ROOT, '.github/workflows/release-go.yml'))
    call = go_release.fetch('jobs').fetch('release')
    assert_equal 'narutchai01/gitops/.github/workflows/release-next.yml@main', call.fetch('uses')
    assert_equal 'false', call.fetch('with').fetch('allow-package-version-change').to_s
    assert_equal %w[release-branch release-sha main-sha allow-package-version-change], call.fetch('with').keys

    go_quality = load_yaml(File.join(ROOT, '.github/actions/go-quality/action.yml'))
    setup_go = go_quality.fetch('runs').fetch('steps').find { |step| step['uses'] == 'actions/setup-go@v7' }
    assert_equal 'go.mod', setup_go.fetch('with').fetch('go-version-file')
    assert_equal ['go vet ./...', 'go test ./...'], go_quality.fetch('runs').fetch('steps').select { |step| step['run'] }.map { |step| step.fetch('run') }
  end

  private

  def in_repo
    Dir.mktmpdir('gitops-actions') do |dir|
      repo = File.join(dir, 'repo')
      bare = File.join(dir, 'origin.git')
      FileUtils.mkdir_p(repo)
      git(repo, 'init', '-q')
      git(repo, 'config', 'user.name', 'Test')
      git(repo, 'config', 'user.email', 'test@example.com')
      git(repo, 'init', '--bare', '-q', bare)
      git(repo, 'remote', 'add', 'origin', bare)
      write(repo, 'seed.txt', 'seed')
      git(repo, 'add', '.')
      git(repo, 'commit', '-qm', 'seed')
      yield repo
    end
  end

  def git(repo, *args)
    stdout, stderr, status = Open3.capture3('git', *args, chdir: repo)
    raise "git #{args.join(' ')} failed: #{stderr}#{stdout}" unless status.success?
    stdout.strip
  end

  def write(repo, path, content)
    File.write(File.join(repo, path), content)
  end

  def commit(repo, message)
    git(repo, 'add', '.')
    git(repo, 'commit', '-qm', message)
    git(repo, 'rev-parse', 'HEAD')
  end

  def run_action(name, repo, overrides = {}, mock_bin: nil, extra_env: {})
    metadata = load_yaml(File.join(ROOT, '.github/actions', name, 'action.yml'))
    inputs = metadata.fetch('inputs', {}).transform_values { |input| input.fetch('default', '') }.merge(overrides)
    output_path = File.join(File.dirname(repo), 'action-output')
    File.write(output_path, '')
    env = {'GITHUB_OUTPUT' => output_path}.merge(extra_env)
    env['PATH'] = "#{mock_bin}:#{ENV.fetch('PATH')}" if mock_bin
    metadata.fetch('runs').fetch('steps').each do |step|
      next unless step['run']

      step.fetch('env', {}).each do |key, value|
        env[key] = value.gsub(/\$\{\{\s*inputs\.([\w-]+)(?:\s*\|\|\s*github\.(repository|sha))?\s*\}\}/) do
          input_name, fallback = Regexp.last_match.captures
          inputs.fetch(input_name, '').then { |input| input.empty? ? (fallback == 'repository' ? 'acme/app' : 'deadbeef') : input }
        end
      end
      stdout, stderr, status = Open3.capture3(env, 'bash', '--noprofile', '--norc', '-eo', 'pipefail', '-c', step.fetch('run'), chdir: repo)
      raise "#{name} failed at #{step.fetch('run')}: #{stderr}#{stdout}" unless status.success?
    end
    File.readlines(output_path, chomp: true).to_h { |line| line.split('=', 2) }
  end

  def mock_gh(repo)
    dir = File.join(repo, 'mock-bin')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'gh'), <<~SH)
      #!/bin/sh
      case "$1 $2" in
        "release view") [ "$GH_MOCK_EXISTS" = "true" ] ;;
        "release list") echo "${PREVIOUS_RELEASE:-}" ;;
        "release create") echo "$*" >> "${MOCK_LOG:-/dev/null}" ;;
        *) exit 2 ;;
      esac
    SH
    File.chmod(0o755, File.join(dir, 'gh'))
    dir
  end

  def assert_failure
    error = assert_raises(RuntimeError) { yield }
    refute_empty error.message
  end

  def load_yaml(path)
    YAML.safe_load(File.read(path), aliases: true)
  end
end
