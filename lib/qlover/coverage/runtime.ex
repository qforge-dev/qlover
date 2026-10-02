defmodule Qlover.Coverage.Runtime do
  @moduledoc false
  import Bitwise
  @table :qlover_attributed_hits
  @files {__MODULE__, :files}

  # Compiler callbacks execute synchronously around file evaluation. Store the
  # file on each loading-time hit; a process can require several nested files.
  def trace(:start, env), do: enter(env.file)
  def trace(:stop, _env), do: leave()
  def trace(_event, _env), do: :ok

  def enter(file) do
    Process.put(@files, [file | Process.get(@files, [])])
    :ok
  end

  def leave do
    case Process.get(@files, []) do
      [_ | [_ | _] = rest] -> Process.put(@files, rest)
      _ -> Process.delete(@files)
    end

    :ok
  end

  def start!(files \\ []) do
    :ets.new(@table, [:named_table, :public, :set, {:write_concurrency, true}])
    runnable = Map.new(files, &{Path.expand(&1), &1})

    tracer =
      spawn_link(fn ->
        trace_loop(%{parents: %{}, contexts: %{}, loading: %{}, runnable: runnable})
      end)

    session = :trace.session_create(:qlover_coverage, tracer, [])

    unless :trace.function(session, {ExUnit.Runner, :exec_test_setup, 2}, true, [:local]) == 1 and
             :trace.function(session, {ExUnit.Runner, :run_module, 5}, true, [:local]) == 1 do
      raise "unsupported ExUnit runner: cannot establish synchronous test ownership"
    end

    :trace.function(session, {__MODULE__, :enter, 1}, true, [:local])
    :trace.function(session, {__MODULE__, :leave, 0}, true, [:local])

    :trace.process(session, :all, true, [:procs, :call, :set_on_spawn])
    {session, tracer, self()}
  end

  def hit(module, id) do
    context =
      case Process.get(@files) do
        nil -> self()
        files -> {self(), files}
      end

    word = div(id, 60)
    key = {@table, context, module, word}
    seen = Process.get(key, 0)
    bit = 1 <<< rem(id, 60)

    if (seen &&& bit) == 0 do
      seen = seen ||| bit
      Process.put(key, seen)
      :ets.insert(@table, {{context, module, word}, seen})
    end

    :ok
  end

  def finish!({session, tracer, suite_pid}, inventory) do
    {:message_queue_len, pending} = Process.info(tracer, :message_queue_len)
    ref = :trace.delivered(session, :all)

    receive do
      {:trace_delivered, :all, ^ref} -> :ok
    after
      10_000 -> raise "attributed coverage trace did not drain"
    end

    send(tracer, {:snapshot, self()})

    state =
      receive do
        {:trace_snapshot, ^tracer, state} -> state
      after
        10_000 -> raise "attributed coverage collector did not respond"
      end

    :trace.session_destroy(session)

    unsettled =
      for {pid, _} <- state.parents,
          owner(pid, state) != nil,
          Process.alive?(pid),
          do: pid

    if unsettled != [] do
      raise "attributed coverage has #{length(unsettled)} unfinished test descendant(s)"
    end

    records = :ets.tab2list(@table)

    {hits, suite} =
      records
      |> Enum.reduce({%{}, %{}}, fn {{context, module, word}, mask}, {files, suite} ->
        {pid, source} = hit_owner(context, state)
        name = Atom.to_string(module)

        if info = inventory[name] do
          lines =
            for bit <- 0..59,
                (mask &&& 1 <<< bit) != 0,
                line = info.probes[word * 60 + bit],
                is_integer(line) and line > 0,
                into: MapSet.new(),
                do: line

          cond do
            MapSet.size(lines) == 0 ->
              {files, suite}

            is_binary(file = source) ->
              files =
                Map.update(files, file, %{name => lines}, fn modules ->
                  Map.update(modules, name, lines, &MapSet.union(&1, lines))
                end)

              {files, suite}

            pid == suite_pid ->
              {files, Map.update(suite, name, lines, &MapSet.union(&1, lines))}

            true ->
              {files, suite}
          end
        else
          {files, suite}
        end
      end)

    normalize = fn modules ->
      Map.new(modules, fn {mod, lines} -> {mod, lines |> MapSet.to_list() |> Enum.sort()} end)
    end

    stats = %{
      hit_records: length(records),
      traced_processes: map_size(state.parents),
      unknown_hit_records:
        Enum.count(records, fn {{context, _, _}, _mask} ->
          {pid, file} = hit_owner(context, state)
          pid != suite_pid and file == nil
        end),
      pending_traces_at_seal: pending,
      collector_bytes:
        :ets.info(@table, :memory) * :erlang.system_info(:wordsize) +
          elem(Process.info(tracer, :memory), 1)
    }

    {Map.new(hits, fn {file, modules} -> {file, normalize.(modules)} end), normalize.(suite),
     stats}
  end

  defp owner(pid, state) do
    loading_file(Map.get(state.loading, pid, []), state) || execution_owner(pid, state)
  end

  defp execution_owner(pid, state) do
    case state.contexts[pid] do
      nil ->
        case state.parents[pid] do
          nil -> nil
          {_parent, inherited} -> inherited
        end

      file ->
        file
    end
  end

  defp hit_owner({pid, files}, state), do: {pid, loading_file(files, state) || owner(pid, state)}
  defp hit_owner(pid, state), do: {pid, owner(pid, state)}

  defp loading_file(files, state), do: Enum.find_value(files, &Map.get(state.runnable, &1))

  defp trace_loop(state) do
    receive do
      {:snapshot, from} ->
        send(from, {:trace_snapshot, self(), state})
        trace_loop(state)

      {:trace, pid, :spawn, child, _mfa} ->
        inherited = owner(pid, state)
        trace_loop(put_in(state, [:parents, child], {pid, inherited}))

      {:trace, pid, :call, {__MODULE__, :enter, [file]}} ->
        trace_loop(
          update_in(state.loading, &Map.update(&1, pid, [file], fn stack -> [file | stack] end))
        )

      {:trace, pid, :call, {__MODULE__, :leave, []}} ->
        trace_loop(
          update_in(
            state.loading,
            &Map.update(&1, pid, [], fn
              [_ | rest] -> rest
              [] -> []
            end)
          )
        )

      {:trace, pid, :call, {ExUnit.Runner, :run_module, [_config, mod | _]}} when is_atom(mod) ->
        trace_loop(context(state, pid, mod))

      {:trace, pid, :call, {ExUnit.Runner, :exec_test_setup, [%ExUnit.Test{module: mod} | _]}} ->
        trace_loop(context(state, pid, mod))

      {:trace, pid, :call, {mod, :__ex_unit__, [:setup_all, _]}} ->
        trace_loop(context(state, pid, mod))

      _other ->
        trace_loop(state)
    end
  end

  defp context(state, pid, module) do
    source = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to_cwd()
    put_in(state, [:contexts, pid], source)
  end
end
