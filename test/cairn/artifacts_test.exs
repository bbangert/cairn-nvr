defmodule Cairn.ArtifactsTest do
  # One VM environment variable, which several tests set.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias Cairn.Artifacts
  alias Cairn.Artifacts.{Fetcher, HTTP}
  alias Cairn.Config.Profile

  @wait 2_000
  @content "the runtime library"
  @sha256 :sha256 |> :crypto.hash(@content) |> Base.encode16(case: :lower)
  @env "CAIRN_ARTIFACTS_TEST_LIBRARY"
  @artifact %{name: "lib.so", url: "https://h/lib.so", sha256: @sha256, backend: "fake"}

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

  defp start_store(ctx, artifacts, spec \\ []) do
    opts = [name: ctx.store, dir: ctx.dir, artifacts: artifacts, fetcher: ctx.fetcher]
    start_supervised!(%{id: ctx.store, start: {Artifacts, :start_link, [opts]}}, spec)
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

  defp restore_env(env, nil), do: System.delete_env(env)
  defp restore_env(env, value), do: System.put_env(env, value)

  # Queues behind the fetcher's pass in progress, if any.
  defp refute_attempted(ctx) do
    :sys.get_state(ctx.fetcher)
    refute_received {:attempt, _n, _artifact, _unusable}
  end

  describe "the store at start" do
    # A rung's entry has no backend: missing, it gates nothing here, and the
    # config reads it by hash.
    test "a valid file is kept and not fetched; one without a backend gates none", ctx do
      File.write!(file(ctx), @content)
      start_store(ctx, [artifact(), named("b")])

      assert Artifacts.unusable(ctx.store) == %{}
      assert Artifacts.path(String.upcase(@sha256), ctx.store) == file(ctx)
      assert Artifacts.state(@sha256, ctx.store) == {:ok, file(ctx)}
      assert Artifacts.state(sha_of("b"), ctx.store) == {:missing, nil}
      assert Artifacts.state(sha_of("c"), ctx.store) == {:missing, :unlisted}
      assert Artifacts.name(String.upcase(@sha256), ctx.store) == "lib.so"
      assert Artifacts.name(sha_of("b"), ctx.store) == "b"

      assert [sha_of("c"), "../x", @sha256] |> Enum.map(&Artifacts.name(&1, ctx.store)) == [
               nil,
               nil,
               "lib.so"
             ]

      assert Artifacts.name(@sha256, :no_such_store) == nil
      start_fetcher(ctx, writes_named(["b"]))
      assert_receive {:attempt, 1, %{name: "b"}, _unusable}, @wait
      assert_receive :reloaded, @wait
      refute_attempted(ctx)
      assert Artifacts.state(sha_of("b"), ctx.store) == {:ok, Path.join(ctx.dir, sha_of("b"))}
    end

    test "with no store nothing is known; a corrupt file is deleted, then fetched", ctx do
      assert Artifacts.unusable(ctx.store) == %{}
      assert Artifacts.missing(ctx.store) == []
      assert Artifacts.path(@sha256, ctx.store) == nil
      assert Artifacts.state(@sha256, ctx.store) == {:missing, :not_started}

      File.write!(file(ctx), "not it")
      start_store(ctx, [artifact()])
      refute File.exists?(file(ctx))
      assert %{"fake" => [%{name: "lib.so", failure: nil}]} = Artifacts.unusable(ctx.store)
      assert Artifacts.state(@sha256, ctx.store) == {:missing, nil}

      start_fetcher(ctx, writes(@content))
      assert_receive {:attempt, 1, %{url: "https://h/lib.so"}, _unusable}, @wait
      assert_receive :reloaded, @wait
      assert File.read!(file(ctx)) == @content
      assert Artifacts.path(@sha256, ctx.store) == file(ctx)
    end

    test "a restarting store gates all it published; restarted, it asks for a reload", ctx do
      File.write!(file(ctx), @content)
      Process.register(self(), ctx.fetcher)
      start_store(ctx, [artifact()])
      assert Artifacts.unusable(ctx.store) == %{}
      stop_supervised!(ctx.store)
      refute_received {:"$gen_cast", _message}

      assert %{"fake" => [%{name: "lib.so", failure: :restarting}]} =
               Artifacts.unusable(ctx.store)

      assert Artifacts.unusable(:"#{ctx.store}_never") == %{}
      assert Artifacts.state(@sha256, ctx.store) == {:missing, :restarting}
      start_store(ctx, [artifact()])
      assert_receive {:"$gen_cast", :reload}, @wait
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
      assert %{"fake" => [_missing]} = Artifacts.unusable(ctx.store)
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
      assert %{"fake" => [_missing]} = Artifacts.unusable(ctx.store)
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

    test "a malformed entry is ignored", ctx do
      bad = [
        artifact(%{size: "7"}),
        artifact(%{size: 0}),
        artifact(%{env: :x}),
        :junk,
        %{name: "x"}
      ]

      start_store(ctx, bad ++ [artifact(%{sha256: "not a hash"})])
      assert Artifacts.missing(ctx.store) == []
    end

    # The default is the release's: whatever this board's profiles fetch.
    test "without artifacts:, the set is the board's and its release profiles' rungs", ctx do
      board = Cairn.Board.module()

      expected =
        board.artifacts(%{}) ++ Profile.fetch_entries(Cairn.Config.release_profile_dirs())

      envs = for %{env: env} <- expected, do: {env, System.get_env(env)}
      on_exit(fn -> Enum.each(envs, fn {env, value} -> restore_env(env, value) end) end)

      opts = [name: ctx.store, dir: ctx.dir, fetcher: ctx.fetcher]
      start_supervised!(%{id: ctx.store, start: {Artifacts, :start_link, [opts]}})

      assert Enum.sort(Enum.map(Artifacts.missing(ctx.store), & &1.sha256)) ==
               Enum.sort(Enum.map(expected, &String.downcase(&1.sha256)))

      assert Artifacts.state(sha_of("none"), ctx.store) == {:missing, :unlisted}
    end

    test "fetch_entries/1 takes each well-formed file to fetch once, a twin too" do
      dir = Path.join(System.tmp_dir!(), "cairn_fetch_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      sha = String.upcase(@sha256)
      twin = String.duplicate("EF", 32)

      File.write!(Path.join(dir, "a.yml"), """
      model_ladder:
        - {sha256: #{sha}, url: "https://h/m/x.bin?sig=1"}
        - {sha256: #{sha}, url: "https://h/m/x.bin?sig=1"}
        - {sha256: #{sha}, url: "http://h/x.bin"}
        - {sha256: #{sha}, url: "https://u:p@h/x.bin"}
        - {sha256: #{sha}, url: "https://h/p.bin", pack: p}
        - {sha256: abc, url: "https://h/y.bin"}
        - {url: "https://h/z.bin"}
        - {model: {a: m}, twin_sha256: #{twin}, twin_url: "https://h/t.onnx"}
        - {twin_sha256: #{twin}, twin_url: "https://h/t.onnx", pack: p}
        - {twin_sha256: #{twin}, twin_url: "http://h/t.onnx"}
        - {twin_sha256: #{twin}}
      """)

      File.write!(Path.join(dir, "b.yml"), "model_ladder: [")
      File.write!(Path.join(dir, "c.yml"), "model_ladder: {sha256: #{sha}}")
      File.write!(Path.join(dir, "d.yml"), "model_ladder: [junk, [#{sha}]]")

      assert Profile.fetch_entries([dir]) == [
               %{name: "x.bin", url: "https://h/m/x.bin?sig=1", sha256: @sha256},
               %{name: "t.onnx", url: "https://h/t.onnx", sha256: String.downcase(twin)}
             ]
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
            unusable = %{"fake" => [%{name: "lib.so", failure: unquote(failure)}]}
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
    # verified file does: eight reloads, which exit, raise or answer oddly.
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
            assert_receive {:attempt, ^n, _artifact, %{"fake" => [%{failure: ^expected}]}}, @wait
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
      assert log =~ "config reload after lib.so raised: boom"
    end

    # The fetch stops the store, so the record fails too, and later passes
    # find nothing missing.
    test "a reload refused or raising after a verified file is retried, not the fetch", ctx do
      start_store(ctx, [artifact()], restart: :temporary)
      store = ctx.store
      reloads = :counters.new(1, [])
      test = self()

      reload = fn ->
        :counters.add(reloads, 1, 1)
        n = :counters.get(reloads, 1)
        send(test, {:reload, n})
        if n == 3, do: raise("db down")
        if n < 4, do: {:error, ["camera rtsp://secret", "other"]}, else: {:ok, %{}, []}
      end

      fetch = fn _n, path ->
        :ok = GenServer.stop(store)
        File.write(path, @content)
      end

      log =
        capture_log(fn ->
          start_fetcher(ctx, fetch, reload: reload)
          assert_receive {:reload, 4}, @wait
          assert %{owed: nil, retry: nil} = :sys.get_state(ctx.fetcher)
        end)

      assert_received {:attempt, 1, _artifact, _unusable}
      refute_received {:attempt, 2, _artifact, _unusable}
      assert File.read!(file(ctx)) == @content
      assert log =~ "could not record lib.so"
      assert [_once] = Regex.scan(~r/after lib.so refused, with 2 error\(s\)/, log)
      refute log =~ "rtsp://secret"
      refute log =~ "db down"
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

    # A backoff the test never waits out: only the restart attempts again.
    test "after_boot: true holds until boot_done/1, and a restart does not hold again", ctx do
      start_store(ctx, [artifact()])
      fails = fn _n, _path -> {:error, :down} end
      opts = [after_boot: true, initial_backoff_ms: 60_000, max_backoff_ms: 60_000]
      pid = start_fetcher(ctx, fails, opts)
      GenServer.cast(ctx.fetcher, :work)
      refute_attempted(ctx)
      Fetcher.boot_done(ctx.fetcher)
      assert_receive {:attempt, 1, _artifact, _unusable}, @wait
      Process.exit(pid, :kill)
      assert_receive {:attempt, 2, _artifact, _unusable}, @wait
    end

    test "restarted after boot, it owes a reload: the last one's may have been refused", ctx do
      start_store(ctx, [artifact()])
      test = self()
      reloads = :counters.new(1, [])

      reload = fn ->
        :counters.add(reloads, 1, 1)
        n = :counters.get(reloads, 1)
        send(test, {:reload, n})
        if n == 1, do: {:error, ["db down"]}, else: {:ok, %{}, []}
      end

      # A backoff the test never waits out: only the restart reloads again.
      opts = [
        after_boot: true,
        reload: reload,
        initial_backoff_ms: 60_000,
        max_backoff_ms: 60_000
      ]

      pid = start_fetcher(ctx, writes(@content), opts)
      Fetcher.boot_done(ctx.fetcher)
      assert_receive {:reload, 1}, @wait
      assert %{owed: %{for: "lib.so"}} = :sys.get_state(ctx.fetcher)
      Process.exit(pid, :kill)
      assert_receive {:reload, 2}, @wait
      assert %{owed: nil, retry: nil} = :sys.get_state(ctx.fetcher)

      assert_received {:attempt, 1, _artifact, _unusable}
      refute_received {:attempt, 2, _artifact, _unusable}
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

    test "a redirect is followed, relative to the URL that answered it; 128 MiB by default" do
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
      assert_received {:request, "https://b/z", %{max_bytes: 134_217_728}}
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

    test "a non-200 body is dropped at its first chunk; a 200's is capped", ctx do
      path = Path.join(ctx.dir, "body")
      file = File.open!(path, [:write, :binary, :raw])
      into = HTTP.into(file, 10, System.monotonic_time(:millisecond) + 60_000)

      on = fn status, headers ->
        {Req.new(), Req.Response.new(status: status, headers: headers)}
      end

      assert {:halt, _acc} = into.({:data, "body"}, on.(404, []))

      assert {:halt, {_req, refused}} = into.({:data, "x"}, on.(200, [{"content-length", "11"}]))
      assert {:error, "the response is 11 bytes, more than 10"} = refused.private.failure

      assert {:cont, acc} = into.({:data, "123456"}, on.(200, []))
      assert {:cont, {_req, written}} = into.({:data, "7890"}, acc)
      assert {:halt, {_req, cut}} = into.({:data, "1"}, {Req.new(), written})
      assert {:error, "the response is more than 10 bytes"} = cut.private.failure

      File.close(file)
      assert File.read!(path) == "1234567890"
    end
  end
end
