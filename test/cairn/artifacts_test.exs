defmodule Cairn.ArtifactsTest do
  # One VM environment variable, which several tests set.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias Cairn.Artifacts
  alias Cairn.Artifacts.{Fetcher, HTTP}

  @wait 2_000
  @content "the runtime library"
  @sha256 :sha256 |> :crypto.hash(@content) |> Base.encode16(case: :lower)
  @env "CAIRN_ARTIFACTS_TEST_LIBRARY"
  @artifact %{name: "lib.so", url: "https://h/lib.so", sha256: @sha256, backend: "rknn"}

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_artifacts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.delete_env(@env)

    on_exit(fn ->
      File.rm_rf(dir)
      System.delete_env(@env)
    end)

    n = System.unique_integer([:positive])
    %{dir: dir, store: :"artifacts_test_#{n}", fetcher: :"artifacts_test_fetcher_#{n}"}
  end

  defp sha_of(content), do: :sha256 |> :crypto.hash(content) |> Base.encode16(case: :lower)

  defp artifact(extra \\ %{}), do: Map.merge(@artifact, extra)

  defp named(content), do: %{name: content, url: "https://h/#{content}", sha256: sha_of(content)}

  defp start_store(ctx, artifacts) do
    opts = [name: ctx.store, dir: ctx.dir, artifacts: artifacts, fetcher: ctx.fetcher]
    start_supervised!(%{id: ctx.store, start: {Artifacts, :start_link, [opts]}})
  end

  # Each attempt reports itself, then its task and the partials left before it,
  # then does what `behaviour` says for its number.
  defp start_fetcher(ctx, behaviour, opts \\ []) do
    test = self()
    attempts = :atomics.new(1, [])

    fetch = fn artifact, path ->
      n = :atomics.add_get(attempts, 1, 1)
      send(test, {:attempt, n, artifact, Artifacts.unusable(ctx.store)})
      send(test, {:task, n, self(), Path.wildcard(Path.join(ctx.dir, "*.part"))})
      behaviour.(n, path)
    end

    defaults = [name: ctx.fetcher, artifacts: ctx.store, fetch: fetch, reload: reloading(:ok)]
    opts = Keyword.merge(defaults ++ [initial_backoff_ms: 10, max_backoff_ms: 40], opts)

    start_supervised!(%{id: ctx.fetcher, start: {Fetcher, :start_link, [opts]}})
  end

  defp reloading(answer) do
    test = self()

    fn ->
      send(test, :reloaded)
      if answer == :ok, do: {:ok, %{}, []}, else: answer
    end
  end

  defp writes(content), do: fn _n, path -> File.write(path, content) end

  # By the hash in the partial's name.
  defp writes_named(contents),
    do: fn _n, path -> File.write(path, Enum.find(contents, &(path =~ sha_of(&1)))) end

  defp file(ctx), do: Path.join(ctx.dir, @sha256)

  # Queues behind the fetcher's pass in progress, if any.
  defp refute_attempted(ctx) do
    :sys.get_state(ctx.fetcher)
    refute_received {:attempt, _n, _artifact, _unusable}
  end

  describe "the store at start" do
    test "a valid file is kept, not fetched and not hashed again; a new want/2 fetches", ctx do
      File.write!(file(ctx), @content)
      start_store(ctx, [artifact()])
      start_fetcher(ctx, writes_named(["b"]))

      assert Artifacts.unusable(ctx.store) == %{}
      assert Artifacts.path(String.upcase(@sha256), ctx.store) == file(ctx)
      refute_attempted(ctx)
      File.write!(file(ctx), "junk")
      Artifacts.want([artifact()], ctx.store)
      :sys.get_state(ctx.store)
      assert Artifacts.path(@sha256, ctx.store) == file(ctx)
      refute_attempted(ctx)
      Artifacts.want([named("b")], ctx.store)
      assert_receive {:attempt, 1, %{name: "b"}, _unusable}, @wait
      assert_receive :reloaded, @wait
      assert Artifacts.missing(ctx.store) == []
    end

    test "with no store nothing is known; a corrupt file is deleted, then fetched", ctx do
      assert Artifacts.unusable(ctx.store) == %{}
      assert Artifacts.missing(ctx.store) == []
      assert Artifacts.path(@sha256, ctx.store) == nil

      File.write!(file(ctx), "not it")
      start_store(ctx, [artifact()])
      refute File.exists?(file(ctx))
      assert %{"rknn" => [%{name: "lib.so", failure: nil}]} = Artifacts.unusable(ctx.store)
      assert Artifacts.path(@sha256, ctx.store) == nil

      start_fetcher(ctx, writes(@content))
      assert_receive {:attempt, 1, %{url: "https://h/lib.so"}, _unusable}, @wait
      assert_receive :reloaded, @wait
      assert File.read!(file(ctx)) == @content
      assert Artifacts.path(@sha256, ctx.store) == file(ctx)
    end

    test "partials and a symlink to the right bytes are removed; the fetcher is woken", ctx do
      partial = Path.join(ctx.dir, "#{@sha256}.123.part")
      File.write!(partial, "half")
      target = Path.join(ctx.dir, "elsewhere")
      File.write!(target, @content)
      File.ln_s!(target, file(ctx))
      Process.register(self(), ctx.fetcher)
      start_store(ctx, [artifact()])

      refute File.exists?(partial)
      assert {:error, :enoent} = File.lstat(file(ctx))
      assert File.read!(target) == @content
      assert %{"rknn" => [_missing]} = Artifacts.unusable(ctx.store)
      assert_receive {:"$gen_cast", :work}, @wait
    end

    # Exported before the file exists; a restart's own value is not the
    # operator's; the operator's is neither fetched, checked nor replaced.
    test "env: names the file's path, unless the operator set it", ctx do
      start_store(ctx, [artifact(%{env: @env})])
      assert System.get_env(@env) == file(ctx)
      refute File.exists?(file(ctx))
      stop_supervised!(ctx.store)
      start_store(ctx, [artifact(%{env: @env})])
      assert %{"rknn" => [_missing]} = Artifacts.unusable(ctx.store)
      assert System.get_env(@env) == file(ctx)

      stop_supervised!(ctx.store)
      System.put_env(@env, "/opt/vendor/lib.so")
      start_store(ctx, [artifact(%{env: @env})])
      start_fetcher(ctx, writes(@content))
      assert System.get_env(@env) == "/opt/vendor/lib.so"
      assert Artifacts.path(@sha256, ctx.store) == "/opt/vendor/lib.so"
      assert Artifacts.unusable(ctx.store) == %{}
      refute_attempted(ctx)
    end

    test "want/2 drops env:, and a malformed entry is ignored", ctx do
      pid = start_store(ctx, [artifact(%{size: "7"}), artifact(%{size: 0}), artifact(%{env: :x})])
      assert Artifacts.missing(ctx.store) == []
      Artifacts.want([:junk, %{name: "x"}, artifact(%{env: @env})], ctx.store)
      :sys.get_state(ctx.store)
      assert System.get_env(@env) == nil
      assert [%{name: "lib.so"}] = Artifacts.missing(ctx.store)
      assert Process.whereis(ctx.store) == pid
    end
  end

  describe "the fetcher" do
    for {wrong, extra, written, failure} <- [
          {"hashes wrong", %{}, "wrong",
           "the download hashes to " <>
             Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower)},
          {"is the wrong size", %{size: 20}, @content, "the download is 19 bytes, not 20"}
        ] do
      # The second failure repeats the first's text, so only the first reloads.
      test "a download that #{wrong} is refused and left nowhere, and reloads once", ctx do
        url = "https://user:pw@h/lib.so?token=t"
        start_store(ctx, [artifact(Map.put(unquote(Macro.escape(extra)), :url, url))])

        log =
          capture_log(fn ->
            start_fetcher(ctx, writes(unquote(written)), reload: reloading({:error, ["refused"]}))
            unusable = %{"rknn" => [%{name: "lib.so", failure: unquote(failure)}]}
            assert_receive {:attempt, 3, _artifact, ^unusable}, @wait
          end)

        assert_receive {:task, 3, _task, []}, @wait
        refute File.exists?(file(ctx))
        assert_received :reloaded
        refute_received :reloaded
        assert log =~ "not fetched from https://h/lib.so: "
        refute log =~ ~r/refused|token|user:pw/
        stop_supervised!(ctx.fetcher)
      end
    end

    # Each failure's text differs from the last, so each reloads, as the
    # verified file does: eight reloads, which exit, raise, answer oddly or refuse.
    test "a fetch or reload that raises, throws, exits, is killed, hangs or answers oddly",
         ctx do
      start_store(ctx, [artifact()])
      reloads = :counters.new(1, [])

      reload = fn ->
        :counters.add(reloads, 1, 1)

        case :counters.get(reloads, 1) do
          1 -> exit(:config_server_down)
          2 -> raise "boom"
          3 -> :weird
          8 -> {:error, ["camera rtsp://secret"]}
          _n -> {:ok, %{}, []}
        end
      end

      behaviour = fn
        1, _path -> raise "no route"
        2, _path -> throw(:nope)
        3, _path -> exit(:gone)
        4, _path -> {:error, {:http_status, 404}}
        5, _path -> Process.exit(self(), :kill)
        6, _path -> :weird
        7, _path -> Process.sleep(:infinity)
        _n, path -> File.write(path, @content)
      end

      log =
        capture_log(fn ->
          pid = start_fetcher(ctx, behaviour, attempt_timeout_ms: 500, reload: reload)

          for {n, expected} <- [
                {2, "the fetch raised: no route"},
                {3, "the fetch threw :nope"},
                {4, "the fetch exited: :gone"},
                {5, "{:http_status, 404}"},
                {6, "the fetch exited: :killed"},
                {7, "the fetch answered :weird"},
                {8, "the fetch took longer than 0 s"}
              ] do
            assert_receive {:attempt, ^n, _artifact, %{"rknn" => [%{failure: ^expected}]}}, @wait
            # Doubling from 10 ms, capped at 40.
            if n == 5, do: assert(%{backoff: 40} = :sys.get_state(ctx.fetcher))

            if n == 7 do
              assert_receive {:task, 7, task, _partials}, @wait
              ref = Process.monitor(task)
              assert_receive {:DOWN, ^ref, :process, ^task, :killed}, @wait
            end
          end

          assert %{backoff: 10, retry: nil} = :sys.get_state(ctx.fetcher)
          assert Process.whereis(ctx.fetcher) == pid
        end)

      assert Artifacts.missing(ctx.store) == []
      assert :counters.get(reloads, 1) == 8
      assert log =~ "refused, with 1 error(s)"
      refute log =~ "rtsp://secret"
    end

    test "a retry that fired behind a :work cast does not start a second chain", ctx do
      start_store(ctx, [artifact()])
      fails = fn _n, _path -> {:error, :down} end
      start_fetcher(ctx, fails, initial_backoff_ms: 50, max_backoff_ms: 10_000)
      assert_receive {:attempt, 1, _artifact, _unusable}, @wait
      %{retry: {_timer, ref}} = :sys.get_state(ctx.fetcher)

      :sys.suspend(ctx.fetcher)
      GenServer.cast(ctx.fetcher, :work)
      send(ctx.fetcher, {:retry, ref})
      :sys.resume(ctx.fetcher)

      assert_receive {:attempt, 2, _artifact, _unusable}, @wait
      # One chain: attempts 3, 4 and 5 start 100, 300 and 700 ms after attempt
      # 2; a second would bring attempt 5 inside this window.
      refute_receive {:attempt, 5, _artifact, _unusable}, 500
      assert_receive {:attempt, 3, _artifact, _unusable}, @wait
      stop_supervised!(ctx.fetcher)
    end

    test "after_boot: true holds until boot_done/1, and a restart does not hold again", ctx do
      start_store(ctx, [artifact()])
      pid = start_fetcher(ctx, writes_named([@content, "b"]), after_boot: true)
      GenServer.cast(ctx.fetcher, :work)
      refute_attempted(ctx)
      Fetcher.boot_done(ctx.fetcher)
      assert_receive {:attempt, 1, _artifact, _unusable}, @wait
      assert_receive :reloaded, @wait
      Process.exit(pid, :kill)
      Artifacts.want([named("b")], ctx.store)
      assert_receive {:attempt, 2, %{name: "b"}, _unusable}, @wait
    end
  end

  describe "the https fetch's hops" do
    defp hops(answers) do
      test = self()

      fn url, _path, limits ->
        send(test, {:request, url, limits})
        Map.fetch!(answers, url)
      end
    end

    test "a redirect is followed, relative to the URL that answered it; 64 MiB by default" do
      request =
        hops(%{
          "https://a/x" => {:redirect, "https://b/y?sig=1"},
          "https://b/y?sig=1" => {:redirect, "/z"},
          "https://b/z" => :ok
        })

      assert :ok = HTTP.fetch(%{url: "https://a/x", size: 10}, "unused", request)
      assert_received {:request, "https://a/x", %{max_bytes: 10}}
      assert_received {:request, "https://b/z", _limits}

      assert :ok = HTTP.fetch(%{url: "https://b/z"}, "unused", request)
      assert_received {:request, "https://b/z", %{max_bytes: 67_108_864}}
    end

    test "every hop must be https, and three redirects are followed but not a fourth" do
      assert {:error, "refusing http://a: not https"} =
               HTTP.fetch(%{url: "http://a/x"}, "unused", hops(%{}))

      refute_received {:request, _url, _limits}
      request = hops(%{"https://a/x" => {:redirect, "http://b/y"}})

      assert {:error, "refusing http://b: not https"} =
               HTTP.fetch(%{url: "https://a/x"}, "unused", request)

      chain = for n <- 0..3, into: %{}, do: {"https://a/#{n}", {:redirect, "https://a/#{n + 1}"}}

      assert {:error, "more than 3 redirects"} =
               HTTP.fetch(%{url: "https://a/0"}, "unused", hops(chain))

      request = hops(Map.put(chain, "https://a/4", :ok))
      assert :ok = HTTP.fetch(%{url: "https://a/1"}, "unused", request)
    end
  end
end
