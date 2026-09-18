defmodule Qlover.ReleaseScriptTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @root Path.expand("..", __DIR__)

  test "default patch commits the changelog and publishes only after the annotated tag is pushed",
       %{tmp_dir: dir} do
    fixture = fixture(dir)
    {output, code} = run(fixture, [])
    assert code == 0, output
    assert File.read!(Path.join(fixture.work, "VERSION")) == "1.2.4\n"
    assert git!(fixture, ["log", "-1", "--format=%s"]) == "Release v1.2.4"
    assert git!(fixture, ["status", "--porcelain"]) == ""
    assert git!(fixture, ["cat-file", "-t", "refs/tags/v1.2.4"]) == "tag"
    assert_pushed(fixture, "1.2.4")
    assert File.read!(fixture.notes) |> String.trim() == "### Added\n\n- New feature."
    changelog = File.read!(Path.join(fixture.work, "CHANGELOG.md"))
    assert changelog =~ ~r/## \[Unreleased\]\n\n## \[1\.2\.4\] - \d{4}-\d{2}-\d{2}/
    assert changelog =~ "## [1.2.3] - 2026-01-01"
    assert File.read!(fixture.log) =~ "publish v1.2.4"
  end

  test "minor, major and explicit versions bump the intended components", %{tmp_dir: dir} do
    for {arg, expected} <- [{"minor", "1.3.0"}, {"major", "2.0.0"}, {"3.2.1", "3.2.1"}] do
      fixture = fixture(Path.join(dir, arg))
      {output, code} = run(fixture, [arg])
      assert code == 0, output
      assert_pushed(fixture, expected)
    end
  end

  test "help and rejected version arguments leave the checkout untouched", %{tmp_dir: dir} do
    fixture = fixture(dir)
    {help, 0} = run(fixture, ["--help"])
    assert help =~ "Usage: ./release"

    for args <- [["1.2.3"], ["1.1.9"], ["01.3.0"], ["1.3.0-rc.1"], ["oops"], ["patch", "extra"]] do
      {_, code} = run(fixture, args)
      assert code != 0
      assert git!(fixture, ["rev-parse", "HEAD"]) == fixture.initial
      assert git!(fixture, ["status", "--porcelain"]) == ""
      refute File.exists?(fixture.log)
    end
  end

  test "dirty or non-main checkouts and existing remote tags are rejected", %{tmp_dir: dir} do
    fixture = fixture(dir)
    pending = Path.join(fixture.work, "pending.txt")
    File.write!(pending, "user work")
    {dirty, 1} = run(fixture, [])
    assert dirty =~ "commit or stash"
    assert File.read!(pending) == "user work"
    File.rm!(pending)

    git!(fixture, ["checkout", "-b", "feature"])
    {branch, 1} = run(fixture, [])
    assert branch =~ "switch to main"
    git!(fixture, ["checkout", "main"])

    git!(fixture, ["tag", "v1.2.4"])
    {local, 1} = run(fixture, [])
    assert local =~ "already exists locally"
    git!(fixture, ["push", "origin", "v1.2.4"])
    git!(fixture, ["tag", "-d", "v1.2.4"])
    {remote, 1} = run(fixture, [])
    assert remote =~ "already exists on origin"
    assert git!(fixture, ["rev-parse", "HEAD"]) == fixture.initial
    refute File.exists?(fixture.log)
  end

  test "failed checks do not bump, commit, push or publish", %{tmp_dir: dir} do
    fixture = fixture(dir)
    {_, code} = run(fixture, [], [{"QLOVER_RELEASE_CHECK_FAILURE", "1"}])
    assert code != 0
    assert File.read!(Path.join(fixture.work, "VERSION")) == "1.2.3\n"
    assert git!(fixture, ["rev-parse", "HEAD"]) == fixture.initial
    assert git!(fixture, ["status", "--porcelain"]) == ""
    refute File.read!(fixture.log) =~ "publish"
  end

  test "a rejected push never publishes and leaves both remote refs unchanged", %{tmp_dir: dir} do
    fixture = fixture(dir)
    executable!(Path.join(fixture.remote, "hooks/pre-receive"), "#!/bin/sh\nexit 1\n")
    {_, code} = run(fixture, [])
    assert code != 0

    assert git!(fixture, ["--git-dir=#{fixture.remote}", "rev-parse", "refs/heads/main"]) ==
             fixture.initial

    assert git!(fixture, ["ls-remote", "--tags", "origin", "refs/tags/v1.2.4"]) == ""
    refute File.read!(fixture.log) =~ "publish"
  end

  test "failed GitHub publication explains how to retry the already-pushed version", %{
    tmp_dir: dir
  } do
    fixture = fixture(dir)
    {output, 1} = run(fixture, [], [{"QLOVER_RELEASE_PUBLISH_FAILURE", "1"}])
    assert_pushed(fixture, "1.2.4")
    assert output =~ "v1.2.4 is already pushed"
    assert output =~ "gh release create v1.2.4 --repo qforge-dev/qlover --verify-tag"
  end

  defp fixture(dir) do
    work = Path.join(dir, "work")
    remote = Path.join(dir, "remote.git")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(Path.join(work, "scripts"))
    File.mkdir_p!(bin)

    fixture = %{
      work: work,
      remote: remote,
      bin: bin,
      log: Path.join(dir, "events"),
      notes: Path.join(dir, "notes")
    }

    git!(fixture, ["init", "--bare", remote])
    git!(fixture, ["init", "-b", "main"])
    git!(fixture, ["config", "user.name", "Release Test"])
    git!(fixture, ["config", "user.email", "release@example.invalid"])
    File.cp!(Path.join(@root, "release"), Path.join(work, "release"))
    File.chmod!(Path.join(work, "release"), 0o755)

    File.cp!(
      Path.join(@root, "scripts/check-release-version"),
      Path.join(work, "scripts/check-release-version")
    )

    File.write!(Path.join(work, "VERSION"), "1.2.3\n")

    File.write!(Path.join(work, "CHANGELOG.md"), """
    # Changelog

    ## [Unreleased]

    ### Added

    - New feature.

    ## [1.2.3] - 2026-01-01

    - Previous release.
    """)

    File.write!(Path.join(work, "scripts/check"), """
    echo quality >> "$QLOVER_RELEASE_LOG"
    test "${QLOVER_RELEASE_CHECK_FAILURE:-0}" = 0
    """)

    executable!(Path.join(bin, "mix"), """
    #!/usr/bin/env bash
    set -euo pipefail
    echo "mix $*" >> "$QLOVER_RELEASE_LOG"
    if [[ "$1" == run ]]; then
      test "$QLOVER_EXPECTED_VERSION" = "$(cat VERSION)"
    else
      test "$MIX_ENV" = dev
      [[ "$*" == 'docs --warnings-as-errors' || "$*" == 'deps.get --check-locked' ]]
    fi
    """)

    executable!(Path.join(bin, "gh"), """
    #!/usr/bin/env bash
    set -euo pipefail
    case "$1 $2" in
      'repo view') echo qforge-dev/qlover ;;
      'release view') exit 1 ;;
      'release create')
        tag=$3
        test "$(git rev-parse HEAD)" = "$(git --git-dir="$QLOVER_RELEASE_REMOTE" rev-parse "refs/tags/$tag^{}")"
        test "$(git rev-parse HEAD)" = "$(git --git-dir="$QLOVER_RELEASE_REMOTE" rev-parse refs/heads/main)"
        echo "publish $tag" >> "$QLOVER_RELEASE_LOG"
        while [[ $# -gt 0 ]]; do
          if [[ "$1" == --notes-file ]]; then cp "$2" "$QLOVER_RELEASE_NOTES"; break; fi
          shift
        done
        test "${QLOVER_RELEASE_PUBLISH_FAILURE:-0}" = 0
        ;;
      *) exit 2 ;;
    esac
    """)

    git!(fixture, ["add", "."])
    git!(fixture, ["commit", "-m", "Initial"])
    git!(fixture, ["remote", "add", "origin", remote])
    git!(fixture, ["push", "-u", "origin", "main"])
    Map.put(fixture, :initial, git!(fixture, ["rev-parse", "HEAD"]))
  end

  defp run(fixture, args, extra_env \\ []) do
    System.cmd(Path.join(fixture.work, "release"), args,
      cd: fixture.work,
      stderr_to_stdout: true,
      env: env(fixture) ++ extra_env
    )
  end

  defp assert_pushed(fixture, version) do
    sha = git!(fixture, ["rev-parse", "HEAD"])
    assert git!(fixture, ["--git-dir=#{fixture.remote}", "rev-parse", "refs/heads/main"]) == sha

    assert git!(fixture, ["--git-dir=#{fixture.remote}", "rev-parse", "refs/tags/v#{version}^{}"]) ==
             sha
  end

  defp git!(fixture, args) do
    {output, code} =
      System.cmd("git", args, cd: fixture.work, env: env(fixture), stderr_to_stdout: true)

    assert code == 0, "git #{Enum.join(args, " ")}: #{output}"
    String.trim(output)
  end

  defp env(fixture) do
    [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"PATH", fixture.bin <> ":" <> System.fetch_env!("PATH")},
      {"QLOVER_RELEASE_LOG", fixture.log},
      {"QLOVER_RELEASE_REMOTE", fixture.remote},
      {"QLOVER_RELEASE_NOTES", fixture.notes}
    ]
  end

  defp executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
