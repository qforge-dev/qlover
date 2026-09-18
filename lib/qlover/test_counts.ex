defmodule Qlover.TestCounts do
  @moduledoc false

  # Runs in the child VM. An after-suite callback preserves the host's
  # formatters and counts generated tests and doctests without parsing stdout.
  def install(path) do
    {:ok, _} = Application.ensure_all_started(:ex_unit)
    ExUnit.after_suite(fn result -> write_report(path, result) end)
  end

  def write_report(path, result) do
    files = Map.new(Code.required_files(), &{Path.relative_to_cwd(&1), 0})

    files =
      Enum.reduce(:code.all_loaded(), files, fn {module, _}, files ->
        if function_exported?(module, :__ex_unit__, 0) do
          test_module = module.__ex_unit__()
          file = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
          Map.update(files, file, length(test_module.tests), &(&1 + length(test_module.tests)))
        else
          files
        end
      end)

    report = %{
      ran: result.total - result.skipped - result.excluded,
      skipped: result.skipped + result.excluded,
      runs: 1,
      files: files
    }

    report =
      case read_report(path) do
        nil ->
          report

        prior ->
          %{
            report
            | ran: prior.ran + report.ran,
              skipped: prior.skipped + report.skipped,
              runs: prior.runs + 1,
              files: Map.merge(prior.files, files)
          }
      end

    File.write!(path, :erlang.term_to_binary(report))
  end

  def read_report(path) do
    with {:ok, bytes} <- File.read(path),
         %{ran: ran, skipped: skipped, files: files} = report <- :erlang.binary_to_term(bytes),
         true <- is_integer(ran) and ran >= 0 and is_integer(skipped) and skipped >= 0,
         true <- is_integer(report[:runs]) and report.runs > 0,
         true <- is_map(files) and Enum.all?(files, &valid_count?/1) do
      report
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp valid_count?({file, count}), do: is_binary(file) and is_integer(count) and count >= 0

  def valid_inventory?(counts) do
    is_map(counts) and
      Enum.all?(counts, fn
        {file, %{sha: sha, count: count}} when is_binary(file) and is_binary(sha) ->
          is_nil(count) or (is_integer(count) and count >= 0)

        _ ->
          false
      end)
  end

  def inventory(settings, baseline, report) do
    hashes = Mix.Tasks.Qlover.test_hashes(settings)
    old = Map.get(baseline, :test_counts, %{})
    fresh = if report, do: report.files, else: %{}

    files = Enum.uniq(test_files(settings) ++ Map.keys(old) ++ Map.keys(fresh))

    for file <- files, sha = hashes[file], sha != nil, into: %{} do
      count =
        case {Map.fetch(fresh, file), old[file]} do
          {{:ok, count}, _} -> count
          {:error, %{sha: ^sha, count: count}} -> count
          _ -> nil
        end

      {file, %{sha: sha, count: count}}
    end
  end

  def summary(counts, report) do
    values = Enum.map(counts, fn {_, entry} -> entry.count end)
    runs = if report, do: Map.get(report, :runs, 1), else: 1
    total = if Enum.all?(values, &is_integer/1), do: Enum.sum(values) * runs
    ran = if report, do: report.ran
    not_run = if total != nil and ran != nil, do: max(total - ran, 0)

    text = "qlover: ran #{number(ran)} tests; didn't run #{number(not_run)} tests."

    cond do
      report == nil -> text <> " Test run did not report counts."
      total == nil -> text <> " A full run is needed to count the remaining tests."
      report.skipped > 0 -> text <> " #{report.skipped} skipped/excluded by ExUnit."
      true -> text
    end
  end

  defp number(nil), do: "unknown"
  defp number(n), do: to_string(n)

  defp test_files(settings) do
    project = Mix.Project.config()
    filters = project[:test_load_filters]
    pattern = project[:test_pattern] || if(filters, do: "*.{ex,exs}", else: "*_test.exs")

    settings.test_paths
    |> Enum.map(&Path.expand(&1, settings.project_root))
    |> Mix.Utils.extract_files(pattern)
    |> Enum.map(&Path.relative_to(&1, settings.project_root))
    |> Enum.filter(fn file -> is_nil(filters) or Enum.any?(filters, &matches?(file, &1)) end)
  end

  defp matches?(file, %Regex{} = regex), do: Regex.match?(regex, file)
  defp matches?(file, exact) when is_binary(exact), do: file == exact
  defp matches?(file, fun), do: fun.(file)
end
