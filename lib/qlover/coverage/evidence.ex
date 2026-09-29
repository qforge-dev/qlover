defmodule Qlover.Coverage.Evidence do
  @moduledoc false

  alias Mix.Tasks.Qlover
  alias Elixir.Qlover.TestCounts

  def valid?(nil), do: true

  def valid?(%{
        vsn: 1,
        otp: otp,
        elixir: elixir,
        complete: true,
        inventory: inventory,
        sources: sources,
        fingerprint: fingerprint,
        dependencies: dependencies,
        suite: suite,
        last_run: %{id: run_id, metrics: metrics},
        rows: rows
      }) do
    otp == System.otp_release() and elixir == System.version() and is_map(inventory) and
      is_map(sources) and is_binary(dependencies) and
      fingerprint == fingerprint(inventory, sources) and
      is_map(rows) and is_map(suite) and is_binary(run_id) and byte_size(run_id) == 16 and
      is_map(metrics) and
      Enum.all?(suite, &valid_hits?(&1, inventory)) and
      Enum.all?(inventory, fn
        {name, %{source: source, lines: lines, probes: probes}} ->
          is_binary(name) and is_binary(source) and is_list(lines) and is_map(probes) and
            Enum.all?(lines, &(is_integer(&1) and &1 > 0))

        _ ->
          false
      end) and
      Enum.all?(rows, fn
        {file, %{sha: sha, hits: hits}} ->
          is_binary(file) and is_binary(sha) and is_map(hits) and
            Enum.all?(hits, &valid_hits?(&1, inventory))

        _ ->
          false
      end)
  end

  def valid?(_), do: false

  defp valid_hits?({mod, lines}, inventory) do
    is_binary(mod) and is_list(lines) and Map.has_key?(inventory, mod) and
      Enum.all?(lines, &(&1 in inventory[mod].lines))
  end

  def sources(directory) do
    directory
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
    |> Map.new(fn beam ->
      path = Path.join(directory, beam) |> String.to_charlist()

      source =
        case :beam_lib.chunks(path, [:compile_info]) do
          {:ok, {_, [compile_info: info]}} ->
            info[:source] && source_path(to_string(info[:source]))

          _ ->
            nil
        end

      # A separate source-map identity is required: stable BEAM hashes omit
      # the Line chunk and cannot distinguish line shifts.
      bytes =
        if source && File.regular?(source),
          do: File.read!(source),
          else: File.read!(to_string(path))

      {beam, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    end)
  end

  # A BEAM copied from another worktree may still name that worktree's
  # absolute source path. Never read its old source to validate *this* tree.
  def source_path(path) do
    root = File.cwd!()
    expanded = Path.expand(path)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      expanded
    else
      (Mix.Project.config()[:elixirc_paths] || ["lib"])
      |> Enum.find_value(fn directory ->
        marker = "/" <> Path.basename(directory) <> "/"

        case String.split(expanded, marker, parts: 2) do
          [_, tail] ->
            candidate = Path.join([root, directory, tail])
            if File.regular?(candidate), do: candidate

          _ ->
            nil
        end
      end)
    end
  end

  def dependencies(compile_path) do
    directory = compile_path |> Path.expand() |> Path.dirname() |> Path.dirname()

    payload =
      directory
      |> Path.join("*/ebin")
      |> Path.wildcard()
      |> Enum.reject(&(Path.expand(&1) == Path.expand(compile_path)))
      |> Enum.map(fn dir -> {Path.basename(Path.dirname(dir)), Qlover.beam_hashes(dir)} end)
      |> Enum.sort()

    digest(payload)
  end

  def fingerprint(inventory, sources), do: digest({inventory, sources})

  defp digest(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
  end

  def owners(nil, _beams), do: []

  def owners(evidence, beams) do
    modules = MapSet.new(Enum.map(beams, &Path.rootname/1))

    for {file, %{hits: hits}} <- evidence.rows,
        Enum.any?(Map.keys(hits), &MapSet.member?(modules, &1)),
        do: file
  end

  def full!(settings, report, snapshot) do
    verify_report!(report, snapshot.beams)
    hashes = Qlover.test_hashes(settings)
    files = TestCounts.test_files(settings)

    rows =
      Map.new(files, fn file ->
        {file, %{sha: Map.fetch!(hashes, file), hits: Map.get(report.hits, file, %{})}}
      end)

    source_hashes = sources(settings.compile_path)

    evidence = %{
      vsn: 1,
      otp: System.otp_release(),
      elixir: System.version(),
      inventory: report.inventory,
      sources: source_hashes,
      fingerprint: fingerprint(report.inventory, source_hashes),
      dependencies: dependencies(settings.compile_path),
      suite: report.suite,
      last_run: %{id: report.run, metrics: report.metrics},
      rows: rows,
      complete: true
    }

    gate!(evidence, %{})
    write_html!(settings, evidence)
    evidence
  end

  def advance!(settings, baseline, plan) do
    previous = baseline.attributed
    hashes = Qlover.test_hashes(settings)
    runnable = TestCounts.test_files(settings) |> MapSet.new()
    changed = Qlover.changed_beams(baseline.beams, Qlover.beam_hashes(settings.compile_path))
    changed_names = MapSet.new(Enum.map(changed, &Path.rootname/1))

    report = settings.coverage

    if plan.run != [] and report == nil do
      Mix.raise("attributed coverage report missing after focused test run")
    end

    current_beams = Qlover.beam_hashes(settings.compile_path)
    if report, do: verify_report!(report, current_beams)
    current_modules = Enum.map(Map.keys(current_beams), &Path.rootname/1)

    inventory =
      if report do
        report.inventory
      else
        previous.inventory
        |> Map.take(current_modules)
        |> Map.drop(MapSet.to_list(changed_names))
        |> Map.merge(offline_inventory!(settings, changed, current_beams))
      end

    suite =
      if report,
        do: report.suite,
        else:
          previous.suite |> Map.take(current_modules) |> Map.drop(MapSet.to_list(changed_names))

    # Every rerun replaces the entire row. A deleted row cannot retain any
    # historical hits; untouched rows are valid only for the same module map.
    rows =
      previous.rows
      |> Map.filter(fn {file, %{sha: sha}} ->
        hashes[file] == sha and MapSet.member?(runnable, file) and file not in plan.run
      end)
      |> Map.new(fn {file, row} ->
        removed = Map.keys(row.hits) -- Map.keys(inventory)
        {file, %{row | hits: Map.drop(row.hits, MapSet.to_list(changed_names) ++ removed)}}
      end)

    rows =
      Enum.reduce(plan.run, rows, fn file, acc ->
        Map.put(acc, file, %{sha: Map.fetch!(hashes, file), hits: Map.get(report.hits, file, %{})})
      end)

    # Missing ownership is not equivalent to an empty row. The latter is
    # explicit evidence that a successfully executed file hit no target line.
    missing = Enum.reject(runnable, &Map.has_key?(rows, &1))

    if missing != [],
      do: Mix.raise("missing attributed rows for #{inspect(missing)}; run full coverage")

    source_hashes = sources(settings.compile_path)

    evidence = %{
      previous
      | inventory: inventory,
        sources: source_hashes,
        fingerprint: fingerprint(inventory, source_hashes),
        dependencies: dependencies(settings.compile_path),
        suite: suite,
        last_run:
          if(report, do: %{id: report.run, metrics: report.metrics}, else: previous.last_run),
        rows: rows
    }

    hint =
      if changed != [] and report == nil,
        do:
          "\n  No known tests own the changed lines. If they are dynamically covered, run mix test.qlover --no-stale.",
        else: ""

    gate!(evidence, previous.rows, hint)

    if changed != [] and report == nil do
      # There is no valid positive proof for newly changed executable code in
      # a zero-test run. If it has no executable points, a full run is still
      # needed to check behavior that static inventory cannot observe.
      Mix.raise("changed application code without fresh test execution needs a full run")
    end

    write_html!(settings, evidence)
    evidence
  end

  defp offline_inventory!(_settings, [], _beams), do: %{}

  defp offline_inventory!(settings, changed, beams) do
    ignores = (Mix.Project.config()[:test_coverage] || [])[:ignore_modules] || []

    inventory =
      Elixir.Qlover.Coverage.Instrumenter.inventory!(settings.compile_path, changed, ignores)

    if Qlover.beam_hashes(settings.compile_path) != beams do
      Mix.raise("application beams changed while building coverage inventory; run full coverage")
    end

    inventory
  end

  defp write_html!(settings, evidence) do
    for {mod, %{source: source, lines: lines}} <- evidence.inventory do
      path = Path.expand(source, settings.project_root)

      if File.regular?(path) do
        executable = MapSet.new(lines)

        covered =
          [evidence.suite | Enum.map(Map.values(evidence.rows), & &1.hits)]
          |> Enum.flat_map(&Map.get(&1, mod, []))
          |> MapSet.new()

        body =
          path
          |> File.stream!()
          |> Enum.with_index(1)
          |> Enum.map_join("", fn {text, number} ->
            state =
              cond do
                MapSet.member?(covered, number) -> "covered"
                MapSet.member?(executable, number) -> "missing"
                true -> "other"
              end

            "<span class=\"#{state}\">#{number}: #{escape(text)}</span>"
          end)

        html =
          "<!doctype html><meta charset=\"utf-8\"><title>#{escape(mod)}</title>" <>
            "<style>.covered{background:#dfd}.missing{background:#fdd}</style>" <>
            "<h1>#{escape(mod)}</h1><pre>#{body}</pre>"

        output = Path.join(settings.output, mod <> ".html")
        File.mkdir_p!(Path.dirname(output))
        temp = output <> ".#{System.pid()}-#{System.unique_integer([:positive])}.tmp"
        File.write!(temp, html)
        File.rename!(temp, output)
      end
    end

    :ok
  end

  defp escape(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp verify_report!(
         %{
           vsn: 2,
           otp: otp,
           elixir: elixir,
           backend: :sys_coverage,
           complete: true,
           beams: beams,
           inventory: inventory,
           hits: hits,
           suite: suite,
           run: run,
           metrics: metrics
         },
         current_beams
       )
       when is_map(inventory) and is_map(hits) and is_map(suite) and is_binary(run) and
              byte_size(run) == 16 and is_map(metrics) do
    ignores = (Mix.Project.config()[:test_coverage] || [])[:ignore_modules] || []

    expected =
      current_beams
      |> Map.keys()
      |> Enum.map(&Path.rootname/1)
      |> Enum.reject(fn name ->
        module = String.to_atom(name)

        module in [Elixir.Qlover.Coverage.Runtime, Elixir.Qlover.Coverage.Instrumenter] or
          Enum.any?(ignores, fn
            %Regex{} = regex -> Regex.match?(regex, inspect(module))
            other -> other == module
          end)
      end)
      |> MapSet.new()

    if otp != System.otp_release() or elixir != System.version() or beams != current_beams or
         MapSet.new(Map.keys(inventory)) != expected or
         Enum.any?([suite | Map.values(hits)], fn modules ->
           Enum.any?(modules, fn {mod, lines} ->
             not Map.has_key?(inventory, mod) or
               not Enum.all?(lines, &(&1 in inventory[mod].lines))
           end)
         end) do
      Mix.raise("incompatible or incomplete attributed coverage report")
    end

    :ok
  end

  defp verify_report!(_, _), do: Mix.raise("incomplete attributed coverage report")

  defp gate!(evidence, prior_rows), do: gate!(evidence, prior_rows, "")

  defp gate!(%{inventory: inventory, rows: rows, suite: suite}, prior_rows, hint) do
    failures =
      for {mod, %{source: source, lines: lines}} <- inventory,
          covered =
            [suite | Enum.map(Map.values(rows), & &1.hits)]
            |> Enum.flat_map(&Map.get(&1, mod, []))
            |> MapSet.new(),
          missing = Enum.reject(lines, &MapSet.member?(covered, &1)),
          missing != [],
          do: {mod, source, length(lines) - length(missing), length(lines), missing}

    if failures != [] do
      details =
        Enum.map_join(failures, "\n", fn {mod, source, covered, total, missing} ->
          prior_owners =
            for {file, %{hits: hits}} <- prior_rows,
                Enum.any?(missing, &(&1 in Map.get(hits, mod, []))),
                do: file

          "  #{mod}: #{covered}/#{total} lines (#{source}:#{Enum.join(missing, ",")}; " <>
            "prior owners: #{inspect(prior_owners)})"
        end)

      Mix.raise("qlover coverage is incomplete:\n" <> details <> hint)
    end

    :ok
  end
end
