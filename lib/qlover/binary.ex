defmodule Qlover.Binary do
  @moduledoc "Installs the native client from checksum-verified, platform-specific releases."
  @root Path.expand("../..", __DIR__)
  @version_file Path.join(@root, "VERSION")
  @external_resource @version_file
  @version @version_file |> File.read!() |> String.trim()

  def install!(opts \\ []) do
    case System.get_env("QLOVER_BINARY_PATH") do
      path when is_binary(path) and path != "" -> explicit!(path)
      _ -> managed!(opts)
    end
  end

  def target_for({:unix, :darwin}, arch) do
    case to_string(arch) do
      "aarch64" <> _ -> {:ok, "aarch64-apple-darwin"}
      "arm64" <> _ -> {:ok, "aarch64-apple-darwin"}
      "x86_64" <> _ -> {:ok, "x86_64-apple-darwin"}
      other -> {:error, "unsupported qlover architecture: #{other}"}
    end
  end

  def target_for({:unix, :linux}, arch) do
    case to_string(arch) do
      "aarch64" <> rest -> linux("aarch64", rest)
      "arm64" <> rest -> linux("aarch64", rest)
      "x86_64" <> rest -> linux("x86_64", rest)
      other -> {:error, "unsupported qlover architecture: #{other}"}
    end
  end

  def target_for(os, arch), do: {:error, "unsupported qlover platform: #{inspect(os)} / #{arch}"}
  def artifact_name(id, target), do: "qlover-#{id}-#{target}"

  def verify_checksum(body, manifest, name) do
    expected =
      Enum.find_value(String.split(manifest, "\n", trim: true), fn line ->
        case Regex.run(~r/^([a-fA-F0-9]{64})\s+\*?(.+)$/, line) do
          [_, sha, ^name] -> String.downcase(sha)
          _ -> nil
        end
      end)

    cond do
      expected == nil -> {:error, "checksum missing for #{name}"}
      expected != digest(body) -> {:error, "checksum mismatch for #{name}"}
      true -> :ok
    end
  end

  def release_info(root \\ @root) do
    case System.get_env("QLOVER_RELEASE_TAG") do
      tag when is_binary(tag) and tag != "" ->
        %{tag: tag, id: System.get_env("QLOVER_RELEASE_ID") || tag}

      _ ->
        inferred_release(root)
    end
  end

  defp inferred_release(root) do
    stable = "v#{@version}"

    if File.exists?(Path.join(root, ".git")) and System.find_executable("git") do
      {tag, _} =
        System.cmd(
          "git",
          ["-C", root, "describe", "--tags", "--exact-match", "--match", "v*", "HEAD"],
          stderr_to_stdout: true
        )

      {sha, status} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"], stderr_to_stdout: true)

      if String.trim(tag) != stable and status == 0,
        do: %{tag: "dev", id: String.trim(sha)},
        else: %{tag: stable, id: stable}
    else
      %{tag: stable, id: stable}
    end
  end

  defp managed!(opts) do
    root = Keyword.get(opts, :root, @root)
    release = release_info(root)

    target =
      case target_for(
             Keyword.get(opts, :os, :os.type()),
             Keyword.get(opts, :architecture, :erlang.system_info(:system_architecture))
           ) do
        {:ok, target} -> target
        {:error, message} -> Mix.raise(message)
      end

    home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")
    destination = Path.join([home, "qlover", release.id, target, "qlover"])

    cond do
      valid_cache?(destination) and not Keyword.get(opts, :force, false) ->
        destination

      Keyword.get(opts, :source, false) or System.get_env("QLOVER_BUILD") == "source" ->
        build!(root, destination, opts)

      System.get_env("QLOVER_OFFLINE") in ["1", "true"] ->
        Mix.raise("qlover executable is not cached and QLOVER_OFFLINE is set")

      true ->
        download!(release, target, destination, opts)
    end
  end

  defp explicit!(path) do
    path = Path.expand(path)

    if File.regular?(path),
      do: path,
      else: Mix.raise("QLOVER_BINARY_PATH does not point to a file: #{path}")
  end

  defp linux(arch, rest) do
    if String.contains?(rest, "musl"),
      do: {:error, "no prebuilt qlover binary for musl"},
      else: {:ok, "#{arch}-unknown-linux-gnu"}
  end

  defp valid_cache?(path) do
    with {:ok, body} <- File.read(path), {:ok, sha} <- File.read(path <> ".sha256") do
      digest(body) == sha
    else
      _ -> false
    end
  end

  defp download!(release, target, destination, opts) do
    base =
      System.get_env("QLOVER_DOWNLOAD_BASE_URL") ||
        "https://github.com/qforge-dev/qlover/releases/download"

    url = String.trim_trailing(base, "/") <> "/" <> release.tag
    artifact = artifact_name(release.id, target)
    fetch = Keyword.get(opts, :fetch, &fetch!/1)
    manifest = fetch.(url <> "/SHA256SUMS")
    body = fetch.(url <> "/" <> artifact)

    case verify_checksum(body, manifest, artifact) do
      :ok -> write!(destination, body)
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc false
  def fetch!(url, request \\ &:httpc.request/4) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    req = {String.to_charlist(url), [{~c"user-agent", ~c"qlover-mix/#{@version}"}]}

    case request.(:get, req, [autoredirect: true, timeout: 60_000, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _, body}} when status in 200..299 ->
        body

      {:ok, {{_, status, reason}, _, _}} ->
        Mix.raise("download failed (#{status} #{reason}): #{url}")

      {:error, reason} ->
        Mix.raise("download failed (#{inspect(reason)}): #{url}")
    end
  end

  defp build!(root, destination, opts) do
    build = Keyword.get(opts, :build, &cargo!/1)
    build.(Path.join(root, "native"))
    write!(destination, File.read!(Path.join(root, "native/target/release/qlover")))
  end

  defp cargo!(root) do
    {_, status} =
      System.cmd("cargo", ["build", "--release", "--locked"],
        cd: root,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("cargo failed to build qlover")
  end

  defp write!(destination, body) do
    File.mkdir_p!(Path.dirname(destination))
    temp = destination <> ".#{System.pid()}-#{System.unique_integer([:positive])}.tmp"
    File.write!(temp, body)
    File.chmod!(temp, 0o755)
    File.rename!(temp, destination)
    File.write!(temp, digest(body))
    File.rename!(temp, destination <> ".sha256")
    destination
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
