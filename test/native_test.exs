defmodule Qlover.NativeTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  @root Path.expand("..", __DIR__)
  @binary Path.join(@root, "native/target/release/qlover")

  setup_all do
    {output, code} =
      System.cmd("cargo", ["build", "--release", "--locked"],
        cd: Path.join(@root, "native"),
        stderr_to_stdout: true
      )

    assert code == 0, output
    :ok
  end

  setup %{tmp_dir: dir} do
    fixture(dir)
    on_exit(fn -> native(dir, ["--stop"]) end)
    :ok
  end

  test "warm results retain coverage failures, edits invalidate, failed tests never cache", %{
    tmp_dir: dir
  } do
    {full, 0} = native(dir)
    assert full =~ "ran 1 tests; didn't run 0 tests"
    {warm, 0} = native(dir)
    assert warm =~ "reusing verified coverage (daemon)"
    assert warm =~ "ran 0 tests; didn't run 1 tests"
    source = Path.join(dir, "lib/example.ex")

    File.write!(
      source,
      "defmodule NativeFixture do\n  def value, do: :ok\n  def unused, do: :unused\nend\n"
    )

    {partial, 1} = native(dir)
    assert partial =~ "coverage is incomplete"
    {cached, 1} = native(dir)
    assert cached =~ "reusing verified coverage (daemon)"
    assert cached =~ "coverage is incomplete"
    test = Path.join(dir, "test/example_test.exs")
    File.write!(test, String.replace(File.read!(test), "== :ok", "== :bad"))

    for _ <- 1..2 do
      {failed, code} = native(dir)
      assert code != 0
      refute failed =~ "reusing verified coverage (daemon)"
      assert failed =~ "not gating"
    end
  end

  test "the installer produces an executable client", %{tmp_dir: dir} do
    path = Path.join(dir, "bin/qlover")
    Mix.Tasks.Qlover.Install.run(["--source", "--force", "--path", path])
    {help, 0} = System.cmd(path, ["--help"])
    assert help =~ "Persistent native coordinator"
  end

  test "prewarmed workers are single use and never retain test VM state", %{tmp_dir: dir} do
    test = Path.join(dir, "test/example_test.exs")
    original = File.read!(test)

    for n <- 1..3 do
      assertion = """
      (assert(:persistent_term.get(:qlover_isolation, nil) == nil);
       :persistent_term.put(:qlover_isolation, :dirty);
       File.write!("worker-pids", System.pid() <> "\\n", [:append]);
       assert(NativeFixture.value() == :ok))
      """

      File.write!(
        test,
        String.replace(original, "assert(NativeFixture.value() == :ok)", assertion) <>
          "\n# #{n}\n"
      )

      {output, 0} = native(dir)
      assert output =~ "ran 1 tests;"
      if n > 1, do: assert(output =~ "using prewarmed isolated worker")
    end

    pids = dir |> Path.join("worker-pids") |> File.read!() |> String.split()
    assert length(Enum.uniq(pids)) == 3
  end

  test "a dead spare falls back to a fresh worker", %{tmp_dir: dir} do
    assert {_, 0} = native(dir)
    {status, 0} = native(dir, ["--status"])
    [_, pid] = Regex.run(~r/spare worker: Some\((\d+)\)/, status)
    assert {_, 0} = System.cmd("kill", ["-KILL", pid])
    test = Path.join(dir, "test/example_test.exs")
    File.write!(test, File.read!(test) <> "\n# changed\n")
    {output, 0} = native(dir)
    refute output =~ "using prewarmed isolated worker"
    assert output =~ "ran 1 tests;"
  end

  test "prewarming can be disabled", %{tmp_dir: dir} do
    for _ <- 1..2 do
      {output, 0} = native(dir, ["--no-stale"], [{"QLOVER_PREWARM", "0"}])
      refute output =~ "using prewarmed isolated worker"
    end

    {status, 0} = native(dir, ["--status"])
    assert status =~ "spare worker: None"
  end

  test "preloaded evidence cannot hide a baseline changed after prewarming", %{tmp_dir: dir} do
    assert {_, 0} = native(dir)
    File.rm_rf!(Path.join(dir, "cache"))
    project = Path.join(dir, "mix.exs")

    File.write!(
      project,
      File.read!(project) <> "\nFile.write!(\"cover/.qlover_baseline\", \"corrupt\")\n"
    )

    {output, 0} = native(dir)
    assert output =~ "using prewarmed isolated worker"
    assert output =~ "baseline missing/invalid"
    assert output =~ "ran 1 tests;"
  end

  test "idle expiry and explicit shutdown allow a clean restart", %{tmp_dir: dir} do
    env = [{"QLOVER_IDLE_TIMEOUT", "1"}]
    assert {_, 0} = native(dir, [], env)
    Process.sleep(1_200)
    {status, 0} = native(dir, ["--status"], env)
    assert status =~ "not running"
    {restarted, 0} = native(dir, [], env)
    refute restarted =~ "reusing verified coverage (daemon)"
    assert {_, 0} = native(dir, ["--stop"], env)
  end

  test "inputs modified by a test cannot acquire a reusable baseline", %{tmp_dir: dir} do
    test = Path.join(dir, "test/example_test.exs")

    File.write!(
      test,
      String.replace(
        File.read!(test),
        "assert(NativeFixture.value() == :ok)",
        "File.write!(\"lib/new.ex\", \"# changed during run\\n\")"
      )
    )

    {output, code} = native(dir)
    assert code != 0
    assert output =~ "inputs changed during test execution"
    refute File.exists?(Path.join(dir, "cover/.qlover_baseline"))
  end

  test "same-project concurrent clients serialize and separate worktrees remain independent", %{
    tmp_dir: dir
  } do
    results =
      1..3 |> Task.async_stream(fn _ -> native(dir) end, timeout: 60_000) |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {_, 0}}, &1))

    assert Enum.count(results, fn {:ok, {out, _}} -> out =~ "ran 1 tests;" end) == 1,
           inspect(results)

    other = Path.join(dir, "other")
    fixture(other)
    on_exit(fn -> native(other, ["--stop"]) end)
    {second, 0} = native(other)
    assert second =~ "ran 1 tests;"
    {first_status, 0} = native(dir, ["--status"])
    {second_status, 0} = native(other, ["--status"])
    refute first_status == second_status
    native(dir, ["--stop"])
    {warm, 0} = native(other)
    assert warm =~ "reusing verified coverage (daemon)"
  end

  test "exit callback failures do not advance the baseline", %{tmp_dir: dir} do
    {_, 0} = native(dir)
    baseline = File.read!(Path.join(dir, "cover/.qlover_baseline"))
    helper = Path.join(dir, "test/test_helper.exs")

    File.write!(
      helper,
      File.read!(helper) <> "\nSystem.at_exit(fn _ -> exit({:shutdown, 7}) end)\n"
    )

    {output, code} = native(dir)
    assert code != 0
    refute output =~ "reusing verified coverage (daemon)"
    assert baseline == File.read!(Path.join(dir, "cover/.qlover_baseline"))
  end

  test "disconnecting a client cancels its worker and releases the project queue", %{tmp_dir: dir} do
    test = Path.join(dir, "test/example_test.exs")
    original = File.read!(test)

    File.write!(
      test,
      String.replace(
        original,
        "assert(NativeFixture.value() == :ok)",
        "(IO.puts(\"NATIVE_WORKER_READY\"); Process.sleep(:infinity))"
      )
    )

    port =
      Port.open({:spawn_executable, @binary}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, dir},
        {:env,
         [{~c"ERL_FLAGS", ~c"+S 2"}, {~c"QLOVER_CACHE_DIR", to_charlist(Path.join(dir, "cache"))}]}
      ])

    await_output(port, "")
    {:os_pid, pid} = Port.info(port, :os_pid)
    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
    assert_receive {^port, {:exit_status, _}}, 5_000
    File.write!(test, original)
    task = Task.async(fn -> native(dir) end)
    {recovered, 0} = Task.await(task, 15_000)
    assert recovered =~ "ran 1 tests;"
  end

  test "external compiler resources invalidate the daemon", %{tmp_dir: dir} do
    resource = Path.join(dir, "external.txt")
    File.write!(resource, "before")
    source = Path.join(dir, "lib/example.ex")

    File.write!(source, """
    defmodule NativeFixture do
      @external_resource #{inspect(resource)}
      @value File.read!(@external_resource)
      def value, do: @value
    end
    """)

    test = Path.join(dir, "test/example_test.exs")
    File.write!(test, String.replace(File.read!(test), "== :ok", "in [\"before\", \"after\"]"))
    assert {_, 0} = native(dir)
    {warm, 0} = native(dir)
    assert warm =~ "reusing verified coverage (daemon)"
    File.write!(resource, "after")
    {changed, 0} = native(dir)
    refute changed =~ "reusing verified coverage (daemon)"
    assert changed =~ "ran 1 tests;"
  end

  test "a killed daemon releases its socket and a replacement client restarts it", %{tmp_dir: dir} do
    assert {_, 0} = native(dir)
    {status, 0} = native(dir, ["--status"])
    [_, pid] = Regex.run(~r/daemon (\d+)/, status)
    assert {_, 0} = System.cmd("kill", ["-KILL", pid])
    {recovered, 0} = native(dir)
    refute recovered =~ "reusing verified coverage (daemon)"
    replacement = Path.join(dir, "replacement-qlover")
    File.cp!(@binary, replacement)

    {restarted, 0} =
      System.cmd(replacement, [],
        cd: dir,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2"}, {"QLOVER_CACHE_DIR", Path.join(dir, "cache")}]
      )

    refute restarted =~ "reusing verified coverage (daemon)"
    {next_status, 0} = native(dir, ["--status"])
    refute next_status == status
  end

  defp await_output(port, output) do
    if String.contains?(output, "NATIVE_WORKER_READY") do
      :ok
    else
      receive do
        {^port, {:data, bytes}} -> await_output(port, output <> bytes)
        {^port, {:exit_status, code}} -> flunk("worker exited #{code}: #{output}")
      after
        15_000 -> flunk("worker did not start: #{output}")
      end
    end
  end

  test "environment changes, baseline removal and forced runs invalidate cached results", %{
    tmp_dir: dir
  } do
    assert {_, 0} = native(dir)
    {different, 0} = native(dir, [], [{"QLOVER_NATIVE_TEST_ENV", "changed"}])
    refute different =~ "reusing verified coverage (daemon)"
    refute different =~ "using prewarmed isolated worker"
    File.rm!(Path.join(dir, "cover/.qlover_baseline"))
    {missing, 0} = native(dir)
    refute missing =~ "reusing verified coverage (daemon)"
    assert File.regular?(Path.join(dir, "cover/.qlover_baseline"))

    for _ <- 1..2 do
      {forced, 0} = native(dir, ["--no-stale"])
      assert forced =~ "ran 1 tests;"
    end
  end

  defp fixture(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "test"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule NativeFixture.MixProject do
      use Mix.Project
      def project, do: [app: :native_fixture, version: "0.1.0",
        deps: [{:qlover, path: #{inspect(@root)}, runtime: false}],
        elixirc_options: [tracers: [Qlover.Tracer]],
        test_elixirc_options: [tracers: [Qlover.Tracer]]]
    end
    """)

    File.write!(
      Path.join(dir, "lib/example.ex"),
      "defmodule NativeFixture do\n  def value, do: :ok\nend\n"
    )

    File.write!(Path.join(dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(dir, "test/example_test.exs"), """
    defmodule NativeFixtureTest do
      use ExUnit.Case
      test "value", do: assert(NativeFixture.value() == :ok)
    end
    """)
  end

  defp native(dir, args \\ [], env \\ []) do
    System.cmd(@binary, args,
      cd: dir,
      stderr_to_stdout: true,
      env: [{"ERL_FLAGS", "+S 2"}, {"QLOVER_CACHE_DIR", Path.join(dir, "cache")} | env]
    )
  end
end
