defmodule Qlover.Coverage.Instrumenter do
  @moduledoc false

  # sys_coverage is the same (undocumented) executable-line transform used by
  # OTP cover. Fail closed if its representation changes.
  def instrument!(directory, ignores) do
    {inventory, _stats} = instrument_with_stats!(directory, ignores)
    inventory
  end

  def instrument_with_stats!(directory, ignores) do
    files = directory |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".beam"))
    collect!(directory, files, ignores, true)
  end

  # Extract the identical cover probe inventory without loading any module or
  # running a test. Used to reject obviously uncovered, unreferenced new code.
  def inventory!(directory, beams, ignores) do
    {inventory, _stats} = collect!(directory, beams, ignores, false)
    inventory
  end

  defp collect!(directory, files, ignores, load?) do
    unless System.otp_release() == "29" and
             Code.ensure_loaded?(:sys_coverage) and
             function_exported?(:sys_coverage, :cover_transform, 2) do
      raise "attributed coverage requires the tested OTP 29 cover transform"
    end

    identity =
      {File.cwd!(), System.version(), :erlang.system_info(:version), :compile.module_info(:md5),
       :sys_coverage.module_info(:md5), __MODULE__.module_info(:md5)}

    {inventory, stats, modules} =
      files
      |> Enum.sort()
      |> Enum.map(fn file -> {file, file |> Path.rootname() |> String.to_atom()} end)
      |> Enum.reject(fn {_, module} ->
        module in [Qlover.Coverage.Runtime, __MODULE__] or ignored?(module, ignores)
      end)
      |> Task.async_stream(
        fn {file, module} -> artifact!(directory, file, module, identity, load?) end,
        max_concurrency: min(System.schedulers_online(), 8),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce({%{}, %{instrument_cache_hits: 0, instrument_cache_misses: 0}, []}, fn
        {:ok, {module, inventory, binary, cached?}}, {acc, stats, modules} ->
          counter = if cached?, do: :instrument_cache_hits, else: :instrument_cache_misses

          {Map.put(acc, Atom.to_string(module), inventory),
           Map.update!(stats, counter, &(&1 + 1)),
           [{module, ~c"qlover_instrumented", binary} | modules]}

        {:exit, reason}, _ ->
          exit(reason)
      end)

    if load?, do: load_batch!(modules)
    {inventory, stats}
  end

  defp artifact!(directory, file, module, identity, load?) do
    path = Path.join(directory, file)
    beam = File.read!(path)
    # Full BEAM bytes include line/debug information: executable hashes alone
    # cannot safely key probes after source-line shifts or compiler changes.
    key = :crypto.hash(:sha256, :erlang.term_to_binary({identity, beam}, [:deterministic]))

    cache =
      Path.join([Path.dirname(directory), ".mix", "qlover_instrumented", Base.encode16(key)])

    case read_cached(cache, key, module) do
      {:ok, inventory, binary} ->
        {module, inventory, binary, true}

      :error ->
        {inventory, binary} = transform!(beam, file, module, load?)
        if load?, do: write_cached(cache, {key, module, inventory, binary})
        {module, inventory, binary, false}
    end
  end

  defp transform!(beam, file, module, load?) do
    case :beam_lib.chunks(beam, [:abstract_code, :compile_info]) do
      {:ok, {^module, chunks}} ->
        {:raw_abstract_v1, forms} = Keyword.fetch!(chunks, :abstract_code)
        info = Keyword.fetch!(chunks, :compile_info)

        source =
          info[:source]
          |> to_string()
          |> Qlover.Coverage.Evidence.source_path()
          |> then(fn source -> if source, do: Path.relative_to_cwd(source), else: file end)

        {marked, probes} = mark!(forms)
        binary = if load?, do: compile!(rewrite(marked, module), module, source)

        {%{
           source: source,
           lines: probes |> Map.values() |> Enum.reject(&(&1 == 0)) |> Enum.uniq() |> Enum.sort(),
           probes: probes
         }, binary}

      other ->
        raise "cannot read coverage abstract code for #{file}: #{inspect(other)}"
    end
  end

  defp mark!(forms) do
    map = :ets.new(:qlover_probe_map, [:set, :private])

    try do
      index = fn _mod, fun, arity, clause, line ->
        key = {fun, arity, clause, line}

        case :ets.lookup(map, key) do
          [{^key, id}] ->
            id

          [] ->
            id = :ets.info(map, :size) + 1
            :ets.insert(map, {key, id})
            id
        end
      end

      {:ok, marked} = :sys_coverage.cover_transform(forms, index)
      {marked, :ets.tab2list(map) |> Map.new(fn {{_, _, _, line}, id} -> {id, line} end)}
    after
      :ets.delete(map)
    end
  end

  defp compile!(forms, module, source) do
    opts = [:binary, :return_errors, :return_warnings, {:source, to_charlist(source)}]

    case :compile.forms(forms, opts) do
      {:ok, ^module, binary} -> binary
      # Elixir-generated pinned receive refs can warn as Erlang; success is valid.
      {:ok, ^module, binary, _warnings} -> binary
      other -> raise "cannot instrument #{inspect(module)}: #{inspect(other)}"
    end
  end

  defp read_cached(path, key, module) do
    with {:ok, <<checksum::binary-size(32), payload::binary>>} <- File.read(path),
         true <- :crypto.hash(:sha256, payload) == checksum,
         {^key, ^module, %{source: source, lines: lines, probes: probes} = inventory, binary}
         when is_binary(source) and is_list(lines) and is_map(probes) and is_binary(binary) <-
           :erlang.binary_to_term(payload, [:safe]) do
      {:ok, inventory, binary}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp write_cached(path, artifact) do
    payload = :erlang.term_to_binary(artifact, [:compressed])
    temp = path <> ".#{System.pid()}-#{System.unique_integer([:positive])}.tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, [:crypto.hash(:sha256, payload), payload]) do
        File.rename(temp, path)
      end
    after
      File.rm(temp)
    end
  end

  defp load!(module, binary) do
    case :code.load_binary(module, ~c"qlover_instrumented", binary) do
      {:module, ^module} -> :ok
      other -> raise "cannot load instrumented #{inspect(module)}: #{inspect(other)}"
    end
  end

  defp load_batch!(modules) do
    case :code.atomic_load(modules) do
      :ok ->
        :ok

      # OTP cannot atomically load modules with on_load callbacks. Fall back to
      # the ordinary loader for that case, preserving callback semantics.
      {:error, reasons} ->
        if Enum.all?(reasons, fn {_, reason} -> reason in [:on_load_not_allowed, :not_purged] end) do
          fallback = MapSet.new(Enum.map(reasons, &elem(&1, 0)))

          {ordinary, batch} =
            Enum.split_with(modules, fn {module, _, _} -> MapSet.member?(fallback, module) end)

          Enum.each(ordinary, fn {module, _, binary} -> load!(module, binary) end)
          if batch != [], do: load_batch!(batch)
        else
          raise "cannot load instrumented modules: #{inspect(reasons)}"
        end
    end
  end

  defp rewrite({:executable_line, anno, id}, module) do
    {:call, anno, {:remote, anno, {:atom, anno, Qlover.Coverage.Runtime}, {:atom, anno, :hit}},
     [{:atom, anno, module}, {:integer, anno, id}]}
  end

  defp rewrite(tuple, module) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.map(&rewrite(&1, module)) |> List.to_tuple()
  end

  defp rewrite(list, module) when is_list(list), do: Enum.map(list, &rewrite(&1, module))
  defp rewrite(other, _module), do: other

  defp ignored?(module, ignores) do
    Enum.any?(ignores, fn
      %Regex{} = regex -> Regex.match?(regex, inspect(module))
      other -> module == other
    end)
  end
end
