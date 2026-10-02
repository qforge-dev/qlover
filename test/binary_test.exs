defmodule Qlover.BinaryTest do
  use ExUnit.Case, async: false
  alias Qlover.Binary
  @moduletag :tmp_dir
  @variables ~w(MIX_HOME QLOVER_BINARY_PATH QLOVER_BUILD QLOVER_OFFLINE QLOVER_RELEASE_TAG QLOVER_RELEASE_ID QLOVER_DOWNLOAD_BASE_URL)

  setup %{tmp_dir: dir} do
    old = Map.new(@variables, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(old, fn {key, value} -> set_env(key, value) end) end)
    Enum.each(@variables, &System.delete_env/1)
    System.put_env("MIX_HOME", dir)
    System.put_env("QLOVER_RELEASE_TAG", "dev")
    System.put_env("QLOVER_RELEASE_ID", "unit-sha")
    :ok
  end

  test "supported release targets and checksums are explicit" do
    for {os, arch, target} <- [
          {:darwin, "arm64", "aarch64-apple-darwin"},
          {:darwin, "aarch64-apple-darwin", "aarch64-apple-darwin"},
          {:darwin, "x86_64-apple-darwin", "x86_64-apple-darwin"},
          {:linux, "arm64", "aarch64-unknown-linux-gnu"},
          {:linux, "aarch64-linux-gnu", "aarch64-unknown-linux-gnu"},
          {:linux, "x86_64-pc-linux-gnu", "x86_64-unknown-linux-gnu"}
        ],
        do: assert(Binary.target_for({:unix, os}, arch) == {:ok, target})

    for {os, arch} <- [
          {{:unix, :linux}, "riscv64"},
          {{:unix, :darwin}, "ppc"},
          {{:win32, :nt}, "x86_64"},
          {{:unix, :linux}, "x86_64-linux-musl"}
        ],
        do: assert({:error, _} = Binary.target_for(os, arch))

    name = Binary.artifact_name("v1.2.3", "aarch64-apple-darwin")
    assert :ok = Binary.verify_checksum("binary", checksum("binary", name), name)
    assert {:error, _} = Binary.verify_checksum("tampered", checksum("binary", name), name)
    assert {:error, _} = Binary.verify_checksum("binary", "invalid\n", name)
  end

  test "downloads are verified, cached, repaired and usable offline" do
    fetch = fetcher("native executable")
    path = Binary.install!(fetch: fetch)
    assert File.read!(path) == "native executable"
    assert Binary.install!(fetch: fn _ -> flunk("cached install downloaded") end) == path
    System.put_env("QLOVER_OFFLINE", "1")
    assert Binary.install!() == path
    File.write!(path, "corrupt")
    assert_raise Mix.Error, ~r/not cached/, fn -> Binary.install!() end
    System.delete_env("QLOVER_OFFLINE")
    assert Binary.install!(fetch: fetch) == path
    assert File.read!(path) == "native executable"

    assert_raise Mix.Error, ~r/checksum/, fn ->
      Binary.install!(force: true, fetch: fn _ -> "bad" end)
    end

    assert File.read!(path) == "native executable"
  end

  test "explicit paths, release overrides, custom mirrors and source fallback", %{tmp_dir: dir} do
    path = Path.join(dir, "explicit")
    System.put_env("QLOVER_BINARY_PATH", path)
    assert_raise Mix.Error, ~r/does not point/, fn -> Binary.install!() end
    File.write!(path, "explicit")
    assert Binary.install!() == path
    System.delete_env("QLOVER_BINARY_PATH")
    System.delete_env("QLOVER_RELEASE_ID")
    assert Binary.release_info() == %{tag: "dev", id: "dev"}
    System.put_env("QLOVER_DOWNLOAD_BASE_URL", "https://mirror.invalid/releases/")
    fetch = fetcher("mirror")

    Binary.install!(
      fetch: fn url ->
        assert String.starts_with?(url, "https://mirror.invalid/releases/dev/")
        fetch.(url)
      end
    )

    System.put_env("QLOVER_BUILD", "source")

    build = fn native ->
      File.mkdir_p!(Path.join(native, "target/release"))
      File.write!(Path.join(native, "target/release/qlover"), "source")
    end

    installed = Binary.install!(root: dir, force: true, build: build)
    assert File.read!(installed) == "source"
  end

  test "git installs are pinned to HEAD and exact release tags", %{tmp_dir: dir} do
    System.delete_env("QLOVER_RELEASE_TAG")
    version = File.read!(Path.expand("../VERSION", __DIR__)) |> String.trim()
    stable = %{tag: "v#{version}", id: "v#{version}"}
    assert Binary.release_info(dir) == stable

    for args <- [
          ["init", "-b", "main"],
          ["config", "user.name", "Test"],
          ["config", "user.email", "test@example.invalid"],
          ["commit", "--allow-empty", "-m", "test"]
        ] do
      assert {_, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    end

    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: dir)
    assert Binary.release_info(dir) == %{tag: "dev", id: String.trim(sha)}
    assert {_, 0} = System.cmd("git", ["tag", "v#{version}"], cd: dir)
    assert Binary.release_info(dir) == stable
  end

  test "HTTP failures fail closed and TLS verification is enabled" do
    request = fn :get, _, options, _ ->
      assert options[:ssl][:verify] == :verify_peer
      assert options[:timeout] == 60_000
      {:ok, {{~c"HTTP/1.1", 200, ~c"OK"}, [], "binary"}}
    end

    assert Binary.fetch!("https://example.invalid/binary", request) == "binary"

    for result <- [{:error, :timeout}, {:ok, {{~c"HTTP/1.1", 404, ~c"Not Found"}, [], ""}}] do
      assert_raise Mix.Error, ~r/download failed/, fn ->
        Binary.fetch!("https://example.invalid", fn _, _, _, _ -> result end)
      end
    end

    assert_raise Mix.Error, ~r/download failed/, fn -> Binary.fetch!("invalid-url") end
  end

  test "source build errors never install a binary", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/unsupported qlover platform/, fn ->
      Binary.install!(os: {:win32, :nt}, architecture: "x86_64")
    end

    File.mkdir_p!(Path.join(dir, "native"))
    File.write!(Path.join(dir, "native/Cargo.toml"), "invalid toml !")
    assert_raise Mix.Error, ~r/cargo failed/, fn -> Binary.install!(root: dir, source: true) end
  end

  defp fetcher(body) do
    {:ok, target} = Binary.target_for(:os.type(), :erlang.system_info(:system_architecture))
    name = Binary.artifact_name(Binary.release_info().id, target)
    fn url -> if String.ends_with?(url, "/SHA256SUMS"), do: checksum(body, name), else: body end
  end

  defp checksum(body, name), do: "#{Base.encode16(:crypto.hash(:sha256, body))}  #{name}\n"
  defp set_env(key, nil), do: System.delete_env(key)
  defp set_env(key, value), do: System.put_env(key, value)
end
