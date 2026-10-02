defmodule Qlover.Coverage do
  @moduledoc false

  # Keep Mix's instrumentation and HTML reports. Attributed runs defer gating
  # to the parent, which saves complete evidence before enforcing coverage.
  def attributed_supported?, do: attributed_supported?(System.otp_release(), System.version())

  def attributed_supported?("29", elixir) when is_binary(elixir) do
    Version.match?(elixir, ">= 1.20.2 and < 1.21.0")
  end

  def attributed_supported?(_otp, _elixir), do: false

  def prepare(args) do
    opts = Mix.Project.config()[:test_coverage] || []

    if "--cover" in args and is_binary(System.get_env("QLOVER_ATTR_REPORT")) and
         attributed_supported?() do
      test_opts = Mix.Project.config()[:test_elixirc_options] || []
      tracers = Enum.uniq([Qlover.Coverage.Runtime | Keyword.get(test_opts, :tracers, [])])

      Code.compiler_options(
        tracers: Enum.uniq([Qlover.Coverage.Runtime | Code.get_compiler_option(:tracers)])
      )

      Mix.ProjectStack.merge_config(
        test_coverage: Keyword.put(opts, :tool, __MODULE__),
        test_elixirc_options: Keyword.put(test_opts, :tracers, tracers)
      )

      nil
    else
      prepare_native(args, opts)
    end
  end

  defp prepare_native(args, opts) do
    if "--cover" in args and not exporting?(args, opts) and
         Keyword.get(opts, :summary, true) != false and
         Keyword.get(opts, :tool, Mix.Tasks.Test.Coverage) == Mix.Tasks.Test.Coverage do
      Mix.ProjectStack.merge_config(test_coverage: Keyword.put(opts, :summary, false))
      opts
    end
  end

  # Mix coverage tool contract. The child writes only a run report; the parent
  # commits it after the entire test command has exited successfully.
  def start(compile_path, opts) do
    Mix.shell().info("Instrumenting attributed coverage ...")
    Code.ensure_loaded!(ExUnit.Runner)
    beams = Mix.Tasks.Qlover.beam_hashes(compile_path)
    instrument_started = System.monotonic_time(:microsecond)

    {inventory, instrument_stats} =
      Qlover.Coverage.Instrumenter.instrument_with_stats!(
        compile_path,
        opts[:ignore_modules] || []
      )

    instrument_us = System.monotonic_time(:microsecond) - instrument_started
    files = Qlover.TestCounts.test_files(Mix.Tasks.Qlover.settings([], []))
    runtime = Qlover.Coverage.Runtime.start!(files)

    finish = fn ->
      for {name, _} <- inventory do
        unless :code.which(String.to_atom(name)) == ~c"qlover_instrumented" do
          raise "coverage target #{name} was reloaded during the test run"
        end
      end

      collect_started = System.monotonic_time(:microsecond)
      {hits, suite, stats} = Qlover.Coverage.Runtime.finish!(runtime, inventory)

      report = %{
        vsn: 3,
        otp: System.otp_release(),
        elixir: System.version(),
        backend: :sys_coverage,
        run: :crypto.strong_rand_bytes(16),
        complete: true,
        beams: beams,
        inventory: inventory,
        hits: hits,
        suite: suite,
        metrics:
          Map.merge(Map.merge(stats, instrument_stats), %{
            instrument_us: instrument_us,
            collect_us: System.monotonic_time(:microsecond) - collect_started
          })
      }

      path = System.fetch_env!("QLOVER_ATTR_REPORT")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :erlang.term_to_binary(report, [:compressed]))

      unless opts[:export] do
        rows =
          for {name, %{lines: lines}} <- inventory do
            hit =
              [suite | Map.values(hits)]
              |> Enum.flat_map(&Map.get(&1, name, []))
              |> MapSet.new()

            {String.to_atom(name), {Enum.count(lines, &MapSet.member?(hit, &1)), length(lines)}}
          end

        results =
          for {module, {covered, total}} <- rows,
              total > 0,
              line <- 1..total,
              do: {{module, line}, {if(line <= covered, do: 1, else: 0), 1}}

        summary = Keyword.get(opts, :summary, true)

        if summary != false do
          summarize(results, Enum.map(rows, &elem(&1, 0)), nil)
        end
      end
    end

    Process.put({__MODULE__, :finish}, finish)
    fn -> finish(nil) end
  end

  def read_report(path) do
    # `:safe` rejects atoms absent from this VM. The collector runs in the
    # child, so load its known metric keys before decoding its report.
    Code.ensure_loaded!(Qlover.Coverage.Runtime)
    Code.ensure_loaded!(Qlover.Coverage.Instrumenter)

    with {:ok, bytes} <- File.read(path),
         %{
           vsn: 3,
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
         } = report <-
           :erlang.binary_to_term(bytes, [:safe]),
         true <-
           otp == System.otp_release() and elixir == System.version() and is_map(beams) and
             is_map(inventory) and is_map(hits) and is_map(suite) and is_map(metrics) and
             is_binary(run) and byte_size(run) == 16 do
      report
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def prepare_suite do
    Mix.ProjectStack.merge_config(test_load_filters: [], test_ignore_filters: [~r/.*/])
  end

  def finish(nil) do
    case Process.delete({__MODULE__, :finish}) do
      nil -> :ok
      callback -> callback.()
    end
  end

  def finish(opts) do
    Mix.ProjectStack.merge_config(test_coverage: opts)
    {:result, results, _failures} = :cover.analyse(:coverage, :line)
    ignore = Keyword.get(opts, :ignore_modules, [])
    modules = Enum.reject(:cover.modules(), &ignored?(&1, ignore))
    summary = Keyword.get(opts, :summary, true)
    threshold = if is_list(summary), do: Keyword.get(summary, :threshold, 90), else: 90
    summarize(results, modules, threshold)
  end

  def summarize(results, modules, threshold) do
    keep = MapSet.new(modules)

    lines =
      Enum.reduce(results, %{}, fn {{module, line} = key, {covered, _}}, acc ->
        if line != 0 and MapSet.member?(keep, module) do
          Map.update(acc, key, covered > 0, &(&1 or covered > 0))
        else
          acc
        end
      end)

    counts =
      Enum.reduce(lines, %{}, fn {{module, _line}, hit?}, acc ->
        hit = if hit?, do: 1, else: 0
        Map.update(acc, module, {hit, 1}, fn {covered, total} -> {covered + hit, total + 1} end)
      end)

    rows = for module <- modules, do: {inspect(module), Map.get(counts, module, {0, 0})}

    rows =
      Enum.sort_by(rows, fn {name, {covered, total}} -> {hundredths(covered, total), name} end)

    width = Enum.reduce(rows, 10, fn {name, _}, width -> max(width, String.length(name)) end)
    separator = "|------------|-#{String.duplicate("-", width)}-|"

    Mix.shell().info("| Percentage | #{String.pad_trailing("Module", width)} |")
    Mix.shell().info(separator)
    Enum.each(rows, &print_row(&1, width))
    Mix.shell().info(separator)

    {covered, total} =
      Enum.reduce(rows, {0, 0}, fn {_, {covered, total}}, {sum, count} ->
        {sum + covered, count + total}
      end)

    print_row({"Total", {covered, total}}, width)
    Mix.shell().info("")

    # Compare counts, never the floored display. A genuine 100% still passes.
    if threshold != nil and covered * 100 < total * threshold do
      Mix.shell().info("Coverage test failed, threshold not met:\n")
      Mix.shell().info("    Coverage:  #{percentage(covered, total)}%")
      Mix.shell().info("    Threshold: #{format_hundredths(floor(threshold * 100))}%\n")
      exit({:shutdown, 3})
    end

    :ok
  end

  def percentage(covered, total), do: format_hundredths(hundredths(covered, total))

  defp hundredths(_covered, 0), do: 10_000
  defp hundredths(covered, total), do: div(covered * 10_000, total)

  defp format_hundredths(value) do
    "#{div(value, 100)}.#{value |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp print_row({name, {covered, total}}, width) do
    percent = percentage(covered, total) |> String.pad_leading(9)
    Mix.shell().info("| #{percent}% | #{String.pad_trailing(name, width)} |")
  end

  defp ignored?(module, ignores) do
    Enum.any?(ignores, fn
      %Regex{} = regex -> Regex.match?(regex, inspect(module))
      other -> module == other
    end)
  end

  defp exporting?(args, opts) do
    opts[:export] != nil or
      Enum.any?(
        args,
        &(&1 == "--export-coverage" or String.starts_with?(&1, "--export-coverage="))
      )
  end
end
