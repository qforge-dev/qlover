defmodule Qlover.Attribution do
  @moduledoc false

  # Pure per-test-file attribution helpers. Every function here is total
  # over plain data (no Mix, cover, or filesystem access) so each branch
  # is cheaply unit-testable. IO lives in `Mix.Tasks.Qlover`.
  #
  # Soundness shape: only *decreases* in coverage need fresh proof, and
  # only changed tests can decrease anything. A changed test's old
  # references (pinned in the baseline snapshot) conservatively bound
  # what it could have covered, closed transitively over lib edges. New
  # test files only add coverage, so they need no proof — but they still
  # run, so a red new test aborts before gating.

  @doc false
  def record_filename(relpath) do
    :crypto.hash(:sha256, relpath) |> Base.encode16(case: :lower) |> Kernel.<>(".term")
  end

  @doc false
  def decode_record(contents) do
    case decode_term(contents) do
      %{path: path, sha: sha, modules: modules, defined: defined}
      when is_binary(path) and (is_binary(sha) or is_nil(sha)) and is_list(modules) and
             is_list(defined) ->
        if Enum.all?(modules, &is_binary/1) and Enum.all?(defined, &is_binary/1) do
          {:ok, %{path: path, sha: sha, modules: modules, defined: defined}}
        else
          :error
        end

      _other ->
        :error
    end
  end

  @doc false
  def code_file?(relpath) do
    String.ends_with?(relpath, ".ex") or String.ends_with?(relpath, ".exs")
  end

  @doc false
  def beam_module_string(beam) when is_binary(beam) do
    Path.basename(beam, ".beam")
  end

  @doc false
  def beam_filename(module_string) when is_binary(module_string) do
    module_string <> ".beam"
  end

  @doc false
  def diff_tests(baseline_tests, current_tests) do
    added = for {rel, _sha} <- current_tests, not is_map_key(baseline_tests, rel), do: rel

    {removed, modified} =
      Enum.reduce(baseline_tests, {[], []}, fn {rel, entry}, {removed, modified} ->
        case Map.fetch(current_tests, rel) do
          :error -> {[rel | removed], modified}
          {:ok, sha} when sha != entry.sha -> {removed, [rel | modified]}
          {:ok, _sha} -> {removed, modified}
        end
      end)

    %{added: Enum.sort(added), removed: Enum.sort(removed), modified: Enum.sort(modified)}
  end

  @doc false
  def closure(seeds, edges) do
    seeds |> Enum.uniq() |> bfs(edges, MapSet.new()) |> MapSet.to_list() |> Enum.sort()
  end

  @doc false
  def affected_modules(changed_refs_list, lib_edges) do
    seeds = changed_refs_list |> List.flatten() |> Enum.uniq()
    closure(seeds, lib_edges)
  end

  @doc false
  def referencing_files(modules, test_refs) do
    wanted = MapSet.new(modules)

    for(
      {rel, mods} <- test_refs,
      not MapSet.disjoint?(MapSet.new(mods), wanted),
      do: rel
    )
    |> Enum.sort()
  end

  @doc false
  def runnable_files(files, compiled_dirs, project_root) do
    Enum.reject(files, &under_compiled?(&1, compiled_dirs, project_root))
  end

  defp under_compiled?(rel, compiled_dirs, project_root) do
    abs = expand_path(rel, project_root)
    Enum.any?(compiled_dirs, &(abs == &1 or String.starts_with?(abs, &1 <> "/")))
  end

  defp expand_path(rel, project_root) do
    if Path.type(rel) == :absolute, do: rel, else: Path.join(project_root, rel)
  end

  @doc false
  def group_by_defined(records) do
    Enum.reduce(records, %{}, fn record, acc ->
      Enum.reduce(record.defined, acc, fn mod, acc ->
        Map.update(
          acc,
          mod,
          MapSet.new(record.modules),
          &MapSet.union(&1, MapSet.new(record.modules))
        )
      end)
    end)
    |> Map.new(fn {mod, set} -> {mod, set |> MapSet.to_list() |> Enum.sort()} end)
  end

  @doc false
  def filter_lib_edges(grouped, current_beams) do
    Map.filter(grouped, fn {mod, _mods} ->
      Map.has_key?(current_beams, beam_filename(mod))
    end)
  end

  @doc false
  def union_refs(baseline_tests, fresh_records, current_tests) do
    Map.new(current_tests, fn {rel, sha} ->
      mods =
        cond do
          fresh_match?(Map.get(fresh_records, rel), sha) -> fresh_records[rel].modules
          baseline_match?(Map.get(baseline_tests, rel), sha) -> baseline_tests[rel].modules || []
          true -> []
        end

      {rel, mods}
    end)
  end

  @doc false
  def snapshot_tests(current_tests, baseline_tests, fresh_records) do
    Map.new(current_tests, fn {rel, sha} ->
      {rel, %{sha: sha, modules: snapshot_modules(rel, sha, baseline_tests, fresh_records)}}
    end)
  end

  @doc false
  def snapshot_librefs(baseline_librefs, fresh_by_module, changed_modules) do
    changed = MapSet.new(changed_modules)

    refreshed = Map.filter(fresh_by_module, fn {mod, _mods} -> MapSet.member?(changed, mod) end)

    Map.merge(baseline_librefs, refreshed, fn _mod, old, fresh ->
      old |> MapSet.new() |> MapSet.union(MapSet.new(fresh)) |> MapSet.to_list() |> Enum.sort()
    end)
  end

  @doc false
  def unknown_files(snapshot_tests) do
    for({rel, %{modules: nil}} <- snapshot_tests, do: rel)
    |> Enum.sort()
  end

  @doc false
  def prune_records(entries, current_test_files, beamed_modules) do
    for(
      {filename, result} <- entries,
      not keep_record?(result, current_test_files, beamed_modules),
      do: filename
    )
    |> Enum.sort()
  end

  defp keep_record?({:ok, %{path: path, defined: defined}}, current_test_files, beamed_modules) do
    MapSet.member?(current_test_files, path) or
      Enum.any?(defined, &MapSet.member?(beamed_modules, &1))
  end

  defp keep_record?(:error, _current_test_files, _beamed_modules), do: false

  @doc false
  def valid_tests?(tests) do
    is_map(tests) and
      Enum.all?(tests, fn
        {rel, %{sha: sha, modules: modules}} when is_binary(rel) and is_binary(sha) ->
          is_nil(modules) or (is_list(modules) and Enum.all?(modules, &is_binary/1))

        _other ->
          false
      end)
  end

  @doc false
  def valid_librefs?(librefs) do
    is_map(librefs) and
      Enum.all?(librefs, fn
        {mod, mods} when is_binary(mod) and is_list(mods) ->
          Enum.all?(mods, &is_binary/1)

        _other ->
          false
      end)
  end

  @doc false
  def plan(
        %{
          beam_changed: beam_changed,
          current_beams: current_beams,
          baseline_tests: baseline_tests,
          current_tests: current_tests,
          union_refs: union_refs,
          lib_edges: lib_edges,
          fresh_lib_edges: fresh_lib_edges,
          compiled_dirs: compiled_dirs,
          project_root: project_root
        } = input
      ) do
    diff = diff_tests(baseline_tests, current_tests)
    changed = diff.added ++ diff.removed ++ diff.modified

    if Enum.any?(changed, &(not code_file?(&1))) do
      {:full, :test_fixtures}
    else
      changed_code = Enum.filter(diff.modified ++ diff.removed, &code_file?/1)

      if Enum.any?(changed_code, &unknown_refs?(baseline_tests, &1)) do
        {:full, :unattributed}
      else
        old_seeds = Enum.flat_map(changed_code, &baseline_tests[&1].modules)
        affected = closure(old_seeds, lib_edges)
        beam_mods = Enum.map(beam_changed, &beam_module_string/1)
        deleted_mods = Map.get(input, :beam_deleted, [])
        fresh_closure = fresh_closure(beam_mods, lib_edges, fresh_lib_edges)
        prove_mods = Enum.uniq(beam_mods ++ affected ++ fresh_closure)

        prove =
          prove_mods
          |> Enum.map(&beam_filename/1)
          |> Enum.filter(&Map.has_key?(current_beams, &1))
          |> Enum.sort()

        # Expansion matches only modules that can actually be proven
        # (have current beams) plus deleted ones: tracer noise such as
        # ExUnit.Case or Kernel appears in every file's references and
        # must never widen the run, while a surviving test that still
        # references a deleted module must run to surface the breakage.
        expand_mods =
          ((prove |> Enum.map(&beam_module_string/1)) ++ deleted_mods) |> Enum.uniq()

        test_changed = Enum.any?(diff.added ++ diff.modified, &code_file?/1)

        run =
          if test_changed or deleted_mods != [] do
            (Enum.filter(diff.added ++ diff.modified, &code_file?/1) ++
               referencing_files(expand_mods, union_refs))
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.filter(&Map.has_key?(current_tests, &1))
            |> runnable_files(compiled_dirs, project_root)
          else
            # Pure lib change: the stale subset already covers every
            # referencer (trusted by the soundness contract), so no
            # expansion run is needed.
            []
          end

        {:incremental, %{prove: prove, run: run, test_changed: test_changed}}
      end
    end
  end

  defp unknown_refs?(baseline_tests, rel) do
    case Map.fetch(baseline_tests, rel) do
      {:ok, %{modules: modules}} when is_list(modules) -> false
      _other -> true
    end
  end

  defp fresh_closure(beam_mods, lib_edges, fresh_lib_edges) do
    merged = Map.merge(lib_edges, fresh_lib_edges)

    beam_mods
    |> Enum.filter(&Map.has_key?(fresh_lib_edges, &1))
    |> Enum.flat_map(&closure([&1], merged))
    |> Enum.uniq()
  end

  defp snapshot_modules(rel, sha, baseline_tests, fresh_records) do
    cond do
      not code_file?(rel) -> []
      fresh_match?(Map.get(fresh_records, rel), sha) -> fresh_records[rel].modules
      baseline_match?(Map.get(baseline_tests, rel), sha) -> baseline_tests[rel].modules
      true -> nil
    end
  end

  defp fresh_match?(%{sha: sha, modules: modules}, sha) when is_list(modules), do: true
  defp fresh_match?(_other, _sha), do: false

  defp baseline_match?(%{sha: sha}, sha), do: true
  defp baseline_match?(_other, _sha), do: false

  defp bfs([], _edges, visited), do: visited

  defp bfs([mod | rest], edges, visited) do
    if MapSet.member?(visited, mod) do
      bfs(rest, edges, visited)
    else
      bfs(rest ++ Map.get(edges, mod, []), edges, MapSet.put(visited, mod))
    end
  end

  defp decode_term(contents) do
    :erlang.binary_to_term(contents)
  rescue
    _error -> :invalid
  end
end
