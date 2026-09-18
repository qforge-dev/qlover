defmodule Qlover.Coverage do
  @moduledoc false

  # Keep Mix's instrumentation and HTML reports. For qlover full runs only,
  # replace its rounded summary with a floored display and an exact gate.
  def prepare(args) do
    opts = Mix.Project.config()[:test_coverage] || []

    if "--cover" in args and not exporting?(args, opts) and
         Keyword.get(opts, :summary, true) != false and
         Keyword.get(opts, :tool, Mix.Tasks.Test.Coverage) == Mix.Tasks.Test.Coverage do
      Mix.ProjectStack.merge_config(test_coverage: Keyword.put(opts, :summary, false))
      opts
    end
  end

  def finish(nil), do: :ok

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
    if covered * 100 < total * threshold do
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
