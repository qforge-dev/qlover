defmodule Qlover.Native do
  @moduledoc false
  require Mix.Compilers.Elixir, as: Compiler
  @continuation {__MODULE__, :continuation}
  @inputs {__MODULE__, :inputs}

  def prepare(settings) do
    Process.delete({__MODULE__, :gate})

    if path = System.get_env("QLOVER_RECEIPT") do
      roots = input_roots(settings)
      write_strings(path <> ".roots", roots)

      {_, 0} =
        System.cmd(System.fetch_env!("QLOVER_CLIENT"), [
          "--prepare",
          path <> ".roots",
          path
        ])

      restore_memo(path)
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
    :persistent_term.put(@inputs, Qlover.Inputs.snapshot())
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
        callback -> callback.(status)
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

      write_memo(path, settings)
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
  defp memo_roots({:sources, dir}, settings), do: [dir | settings.elixirc_paths]
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
      settings.elixirc_paths ++
        settings.test_paths ++
        settings.gate_paths ++
        ["priv", "mix.exs", "mix.lock", "VERSION", "mise.toml", ".tool-versions", build] ++
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

  defp toolchain_inputs do
    commands = Enum.map(["mix", "elixir", "erl"], &System.find_executable/1)

    libraries =
      for app <- [:elixir, :mix, :ex_unit], do: Path.join(to_string(:code.lib_dir(app)), "ebin")

    (commands ++
       libraries ++ [to_string(:code.which(:sys_coverage)), to_string(:code.which(:compile))])
    |> Enum.filter(&is_binary/1)
  end

  defp write_strings(path, strings) do
    body = Enum.map(strings, fn s -> [<<byte_size(s)::unsigned-big-32>>, s] end)
    File.write!(path, [<<length(strings)::unsigned-big-32>>, body])
  end
end
