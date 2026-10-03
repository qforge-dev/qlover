defmodule Qlover.Native do
  @moduledoc false
  require Mix.Compilers.Elixir, as: Compiler
  @continuation {__MODULE__, :continuation}
  @inputs {__MODULE__, :inputs}
  @warm {__MODULE__, :warm}

  def compile do
    # Erlang's incremental compiler uses whole-second mtimes. A changed native
    # request can arrive inside that second, so don't let it certify old code.
    # Unchanged requests never enter BEAM; Elixir-only projects avoid this path.
    erlang = Mix.Project.config()[:erlc_paths] || ["src"]

    if System.get_env("QLOVER_RECEIPT") &&
         Enum.any?(erlang, &(Path.wildcard(Path.join(&1, "**/*.erl")) != [])) do
      Mix.Task.run("compile.erlang", ["--force"])
    end

    Mix.Task.run("compile")
  end

  def measure(stage, fun) do
    if System.get_env("QLOVER_TIMINGS") == "1" do
      start = System.monotonic_time(:microsecond)

      try do
        fun.()
      after
        elapsed = System.monotonic_time(:microsecond) - start
        IO.puts(:stderr, "qlover timing #{stage}: #{elapsed}us")
      end
    else
      fun.()
    end
  end

  def prewarm do
    path = System.fetch_env!("QLOVER_RECEIPT")
    [_code, baseline, beams] = read_strings(File.read!(path <> ".preload"))
    Qlover.Inputs.start()
    baseline = Mix.Tasks.Qlover.read_baseline!(baseline)
    if evidence = Map.get(baseline, :attributed), do: Qlover.Coverage.Evidence.prewarm(evidence)
    :persistent_term.put(@warm, Qlover.Inputs.snapshot())
    Qlover.Coverage.Instrumenter.prewarm(beams)
  rescue
    _ -> :ok
  after
    Qlover.Inputs.stop()
  end

  def memo_input(key, fun) do
    case :persistent_term.get(@inputs, nil) do
      nil ->
        Qlover.Inputs.fetch(key, fun)

      inputs ->
        case Map.fetch(inputs, key) do
          {:ok, value} ->
            value

          :error ->
            value = fun.()
            :persistent_term.put(@inputs, Map.put(inputs, key, value))
            value
        end
    end
  end

  def test_hashes(settings, fallback) do
    if System.get_env("QLOVER_RECEIPT") do
      roots = Enum.map(settings.test_paths, &Path.expand(&1, settings.project_root))
      native_pairs(["--file-hashes", settings.project_root | roots]) |> Map.new()
    else
      fallback.()
    end
  end

  def records(directory, fallback) do
    if System.get_env("QLOVER_RECEIPT") do
      native_pairs(["--record-files", directory])
      |> Enum.map(fn {file, bytes} -> {file, Qlover.Attribution.decode_record(bytes)} end)
    else
      fallback.()
    end
  end

  defp native_pairs(args) do
    {bytes, 0} = System.cmd(System.fetch_env!("QLOVER_CLIENT"), args)
    bytes |> read_strings() |> Enum.chunk_every(2) |> Enum.map(fn [a, b] -> {a, b} end)
  end

  def prepare(settings) do
    Process.delete({__MODULE__, :gate})

    if path = System.get_env("QLOVER_RECEIPT") do
      roots = measure(:input_roots, fn -> input_roots(settings) end)
      write_strings(path <> ".roots", roots)
      code = Path.dirname(to_string(:code.which(__MODULE__))) |> Path.expand()
      source = Mix.Project.deps_paths()[:qlover] || settings.project_root
      warm_roots = [code, Path.join(source, "lib"), Path.join(source, "mix.exs")]

      write_strings(
        path <> ".toolchain",
        toolchain_inputs() ++ warm_roots ++ runtime_inputs()
      )

      write_strings(path <> ".preload", [
        code,
        Path.expand(settings.baseline),
        Path.expand(settings.compile_path)
      ])

      measure(:fingerprint_restore, fn ->
        {_, 0} =
          System.cmd(System.fetch_env!("QLOVER_CLIENT"), [
            "--prepare",
            path <> ".roots",
            path
          ])

        restore_memo(path)
      end)

      Qlover.Inputs.restore(Map.merge(:persistent_term.get(@warm, %{}), Qlover.Inputs.snapshot()))
      :persistent_term.erase(@warm)
    end
  end

  def verify_inputs! do
    if path = System.get_env("QLOVER_RECEIPT") do
      {_, 0} =
        System.cmd(System.fetch_env!("QLOVER_CLIENT"), [
          "--snapshot",
          path <> ".roots",
          path <> ".after"
        ])

      unless File.read!(path <> ".before") == File.read!(path <> ".after") do
        Mix.raise("qlover inputs changed during test execution; baseline not updated")
      end

      if inputs = :persistent_term.get(@inputs, nil), do: Qlover.Inputs.restore(inputs)
    end
  end

  def run_tests(task, args) do
    base = Path.join(Mix.Project.manifest_path(), "qlover-native-#{System.pid()}")
    paths = {base, base <> ".coverage"}
    System.put_env("QLOVER_ATTR_REPORT", elem(paths, 1))
    # Registered before test helpers: their exit callbacks must succeed before
    # any baseline is committed, just as with the isolated child runner.
    System.at_exit(fn status -> complete(status, paths) end)
    # Compiler reference records are outputs of test-file compilation. Unlike
    # the verified source fingerprints, these cannot cross the test boundary.
    inputs = Map.reject(Qlover.Inputs.snapshot(), fn {key, _} -> match?({:records, _}, key) end)
    :persistent_term.put(@inputs, inputs)
    Qlover.Inputs.stop()
    Qlover.TestCounts.install(base)
    project = Mix.Project.config()

    try do
      if task == "suite", do: Qlover.Coverage.prepare_suite()
      coverage = Qlover.Coverage.prepare(args)
      Mix.Task.run("test", args)
      Qlover.Coverage.finish(coverage)
      {:deferred, paths}
    after
      Mix.ProjectStack.merge_config(
        Keyword.merge([test_load_filters: nil, test_ignore_filters: nil], project)
      )
    end
  end

  def finalize(callback), do: :persistent_term.put(@continuation, callback)

  defp complete(status, paths) do
    try do
      case :persistent_term.get(@continuation, nil) do
        nil -> :ok
        callback -> measure(:finalize, fn -> callback.(status) end)
      end
    after
      :persistent_term.erase(@continuation)
      :persistent_term.erase(@inputs)
      for path <- Tuple.to_list(paths), do: File.rm(path)
    end
  end

  def reports({counts, coverage}) do
    case Qlover.TestCounts.read_report(counts) do
      nil -> {1, nil}
      report -> {0, Map.put(report, :coverage, Qlover.Coverage.read_report(coverage))}
    end
  end

  def gate_result(code, message), do: Process.put({__MODULE__, :gate}, {code, message})

  def receipt(settings, counts) do
    with path when is_binary(path) <- System.get_env("QLOVER_RECEIPT"),
         {code, message} <- Process.delete({__MODULE__, :gate}) do
      summary = Qlover.TestCounts.summary(counts, %{ran: 0, skipped: 0})

      write_strings(path, [
        Integer.to_string(code),
        summary <> "\n" <> message,
        Path.expand(settings.baseline),
        Path.expand(settings.output)
      ])

      measure(:memo_export, fn -> write_memo(path, settings) end)
    end
  end

  defp restore_memo(path) do
    terms = read_strings(File.read!(path <> ".restored"))

    cache =
      Map.new(terms, fn bytes -> bytes |> Base.decode64!() |> :erlang.binary_to_term([:safe]) end)

    Qlover.Inputs.restore(cache)
  rescue
    _ -> Qlover.Inputs.start()
  end

  defp write_memo(path, settings) do
    common =
      Enum.map(settings.gate_paths, &Path.expand/1) ++
        [Path.dirname(to_string(:code.which(__MODULE__)))]

    entries =
      Enum.flat_map(Qlover.Inputs.snapshot(), fn {key, value} ->
        roots = memo_roots(key, settings)

        if roots == [] do
          []
        else
          roots = Enum.map(roots, &Path.expand/1) ++ common

          [
            Base.encode64(:erlang.term_to_binary({key, value}, [:compressed])),
            Integer.to_string(length(roots)) | roots
          ]
        end
      end)

    write_strings(path <> ".memo.raw", entries)
  end

  defp memo_roots({:beams, dir}, _), do: [dir]
  defp memo_roots({:raw_beams, dir}, _), do: [dir]
  defp memo_roots({:sources, dir}, settings), do: [dir | source_roots(settings)]
  defp memo_roots({:dependencies, dir}, _), do: [dir |> Path.dirname() |> Path.dirname()]
  defp memo_roots({:tests, paths, _}, _), do: paths
  defp memo_roots({:gate, paths, _}, _), do: paths
  defp memo_roots(_, _), do: []

  defp read_strings(<<count::unsigned-big-32, bytes::binary>>) do
    {strings, <<>>} =
      Enum.reduce(1..count//1, {[], bytes}, fn _,
                                               {acc, <<size::unsigned-big-32, rest::binary>>} ->
        <<value::binary-size(^size), tail::binary>> = rest
        {[value | acc], tail}
      end)

    Enum.reverse(strings)
  end

  defp input_roots(settings) do
    deps = Mix.Project.deps_paths() |> Map.values()

    source_dirs = [
      "lib",
      "src",
      "include",
      "c_src",
      "priv",
      "config",
      "test",
      "mix.exs",
      "mix.lock",
      "VERSION",
      "rebar.config",
      "rebar.lock",
      "Makefile"
    ]

    dependency_inputs = for dep <- deps, dir <- source_dirs, do: Path.join(dep, dir)
    build = settings.compile_path |> Path.dirname() |> Path.dirname()
    beams = Path.wildcard(Path.join(build, "*/ebin"))
    # Parent directory detects added/removed dependencies; scanner omits .mix
    # scratch files and instrumented caches, which are outputs of this run.
    roots =
      source_roots(settings) ++
        settings.test_paths ++
        settings.gate_paths ++
        [
          "src",
          "include",
          "c_src",
          "priv",
          "mix.exs",
          "mix.lock",
          "VERSION",
          "mise.toml",
          ".tool-versions",
          build
        ] ++
        dependency_inputs ++ beams

    Enum.map(roots ++ manifest_inputs(build, settings) ++ toolchain_inputs(), &Path.expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp manifest_inputs(build, settings) do
    projects =
      Map.new(Mix.Project.deps_paths(), fn {app, path} -> {Atom.to_string(app), path} end)

    for manifest <- Path.wildcard(Path.join(build, "*/.mix/compile.elixir"), match_dot: true),
        root =
          Map.get(
            projects,
            manifest |> Path.dirname() |> Path.dirname() |> Path.basename(),
            settings.project_root
          ),
        {_, sources} = Compiler.read_manifest(manifest),
        {source, record} <- sources,
        path <- [source | Enum.map(Compiler.source(record, :external), &elem(&1, 0))] do
      Path.expand(path, root)
    end
  end

  defp source_roots(settings) do
    settings.elixirc_paths ++
      (Mix.Project.config()[:erlc_paths] || ["src"]) ++ ["include", "c_src"]
  end

  defp toolchain_inputs do
    commands = Enum.map(["mix", "elixir", "erl"], &System.find_executable/1)

    libraries =
      for app <- [:elixir, :mix, :ex_unit], do: Path.join(to_string(:code.lib_dir(app)), "ebin")

    (commands ++
       libraries ++ [to_string(:code.which(:sys_coverage)), to_string(:code.which(:compile))])
    |> Enum.filter(&is_binary/1)
  end

  defp runtime_inputs do
    root = to_string(:code.root_dir())

    Path.wildcard(Path.join(root, "lib/*/ebin")) ++
      Path.wildcard(Path.join(root, "erts-*/bin")) ++
      [Path.join(root, "bin"), Path.join(root, "releases/start_erl.data")]
  end

  defp write_strings(path, strings) do
    body = Enum.map(strings, fn s -> [<<byte_size(s)::unsigned-big-32>>, s] end)
    File.write!(path, [<<length(strings)::unsigned-big-32>>, body])
  end
end
