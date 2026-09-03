defmodule Cairn.StreamUrlTest do
  use ExUnit.Case, async: true

  alias Cairn.StreamUrl

  describe "split_authority/1" do
    test "cuts at the last @ of the authority, and only inside the authority" do
      assert StreamUrl.split_authority("rtsp://user:sec@ret@host/s") ==
               {"rtsp://", "user:sec@ret", "host/s"}

      assert StreamUrl.split_authority("rtsp://SEC@RET@host/") == {"rtsp://", "SEC@RET", "host/"}
      assert StreamUrl.split_authority("rtsp://host/s") == {"rtsp://", nil, "host/s"}
      assert StreamUrl.split_authority("http://h/p?x=1@2") == {"http://", nil, "h/p?x=1@2"}
    end

    test "round-trips through join_authority/3" do
      for url <- ["rtsp://user:sec@ret@host/s", "rtsp://host/s", "http://h/p?x=1@2", "h/p"] do
        {scheme, userinfo, rest} = StreamUrl.split_authority(url)
        assert StreamUrl.join_authority(scheme, userinfo, rest) == url
      end
    end
  end

  describe "an @ inside the credential" do
    test "is consumed through the last @ of the authority" do
      assert StreamUrl.strip_credentials("rtsp://user:sec@ret@host/s") == "rtsp://host/s"

      assert StreamUrl.mask("rtsp://user:sec@ret@host/s") == "rtsp://user:•••••@host/s"
      assert StreamUrl.mask("rtsp://SEC@RET@host/s") == "rtsp://•••••@host/s"
    end

    # The path's own `@` (before the query starts) is the ambiguity rule now,
    # not this describe's "last @ of the authority" reading: a password
    # holding a raw `@` and `/` would produce the identical bytes, so masking
    # runs through the LAST `@` before the query rather than the authority's.
    test "an @ in the path before the query is the ambiguity rule, not this one" do
      url = "rtsp://u:p@host/path@x?password=p"
      assert StreamUrl.ambiguous?(url)
      assert StreamUrl.mask(url) == "rtsp://•••••@x?password=•••••"
    end
  end

  describe "mask/1" do
    test "hides rtsp credentials" do
      assert StreamUrl.mask("rtsp://admin:s3cret@10.0.0.5:554/s1") ==
               "rtsp://admin:•••••@10.0.0.5:554/s1"

      assert StreamUrl.mask("rtsp://10.0.0.5:554/s1") == "rtsp://10.0.0.5:554/s1"
    end

    # Cameras that authenticate on the password alone: the userinfo is there,
    # with nothing before the colon.
    test "hides a password whose username is empty" do
      assert StreamUrl.mask("rtsp://:secret@host/s") == "rtsp://:•••••@host/s"
    end

    # A colonless userinfo is `credentialed?/1`-true, so the form refuses to
    # prefill it; rendering it verbatim in the row would hand back what the
    # form withheld. Which half of `user:pass` it is cannot be known, so all
    # of it goes.
    test "hides a colonless userinfo whole" do
      assert StreamUrl.mask("rtsp://SECRET@host/s") == "rtsp://•••••@host/s"
      refute StreamUrl.mask("rtsp://SECRET@host/s") =~ "SECRET"
      assert StreamUrl.credentialed?("rtsp://SECRET@host/s")
    end

    test "hides credential query params (http-flv style)" do
      assert StreamUrl.mask(
               "http://10.0.0.5/flv?port=1935&stream=ch0&user=admin&password=hunter2"
             ) ==
               "http://10.0.0.5/flv?port=1935&stream=ch0&user=•••••&password=•••••"

      assert StreamUrl.mask("http://10.0.0.5/flv?Token=abc&x=1") ==
               "http://10.0.0.5/flv?Token=•••••&x=1"
    end

    # The camera reads `?pass%77ord=` as `password`, so the raw spelling is
    # not what decides: an escape in the key would otherwise be a way to get a
    # credential rendered in the clear.
    test "hides a percent-encoded key" do
      assert StreamUrl.mask("http://10.0.0.5/live?pass%77ord=hunter2") ==
               "http://10.0.0.5/live?pass%77ord=•••••"

      assert StreamUrl.credentialed?("http://10.0.0.5/live?pass%77ord=hunter2")
    end

    # `%FF` is a well-formed escape whose decoding is not valid UTF-8, which
    # `String.downcase/1` may refuse: the key is then judged raw, and the
    # credential beside it is still masked.
    test "an escape that decodes to invalid UTF-8 is judged on the raw key" do
      assert StreamUrl.mask("http://10.0.0.5/live?pass%FFword=1&password=hunter2") ==
               "http://10.0.0.5/live?pass%FFword=1&password=•••••"

      assert StreamUrl.credentialed?("http://10.0.0.5/live?pass%FFword=1&password=hunter2")
      refute StreamUrl.credentialed?("http://10.0.0.5/live?pass%FFword=1")
    end

    test "a malformed escape is judged on the raw key" do
      assert StreamUrl.mask("http://10.0.0.5/live?%zz=1&password=hunter2") ==
               "http://10.0.0.5/live?%zz=1&password=•••••"

      refute StreamUrl.credentialed?("http://10.0.0.5/live?%zz=1")
    end

    test "hides the vendor spellings of the same secret" do
      for key <- ~w(psw passwd auth key apikey api_key session) do
        assert StreamUrl.mask("http://10.0.0.5/live?#{key}=hunter2&channel=1") ==
                 "http://10.0.0.5/live?#{key}=•••••&channel=1"
      end
    end
  end

  describe "access_token" do
    test "is a credential the mask and the prefill rule both see" do
      url = "http://cam.lan/flv?stream=ch0&access_token=SECRET"
      assert StreamUrl.mask(url) == "http://cam.lan/flv?stream=ch0&access_token=•••••"
      assert StreamUrl.credentialed?(url)
    end
  end

  describe "mask/1 and credentialed?/1 on a non-string" do
    # A row's `rtsp_url` is whatever its settings column holds: a hand-edited
    # or migrated row can carry a number, which the loader skips — and the
    # edit page still has to render, so it can be fixed.
    test "read as nothing to show rather than raising" do
      assert StreamUrl.mask(123) == ""
      assert StreamUrl.mask(nil) == ""
      refute StreamUrl.credentialed?(123)
      refute StreamUrl.credentialed?(nil)
    end
  end

  describe "credentialed?/1" do
    test "userinfo and credential query params count, a plain URL does not" do
      assert StreamUrl.credentialed?("rtsp://admin:s3cret@10.0.0.5:554/s1")
      assert StreamUrl.credentialed?("http://10.0.0.5/live?psw=hunter2")
      refute StreamUrl.credentialed?("rtsp://10.0.0.5:554/s1")
      refute StreamUrl.credentialed?("http://10.0.0.5/live?channel=1&subtype=0")
    end

    test "an empty username still leaves userinfo to hide" do
      assert StreamUrl.credentialed?("rtsp://:secret@host/s")
    end
  end

  describe "credential_query_pairs/1" do
    test "returns the recognized pairs verbatim, in order, and none for a plain URL" do
      url = "http://cam.lan/flv?stream=ch0&user=admin&password=x"
      assert StreamUrl.credential_query_pairs(url) == ["user=admin", "password=x"]
      assert StreamUrl.credential_query_pairs("http://cam.lan/flv?stream=ch0") == []
    end

    test "a userinfo credential has no query pairs to carry" do
      assert StreamUrl.credential_query_pairs("rtsp://admin:s3cret@10.0.0.5:554/s1") == []
    end

    test "a non-string URL yields none" do
      assert StreamUrl.credential_query_pairs(nil) == []
    end
  end

  describe "strip_credentials/1" do
    test "drops the userinfo and every credential query pair, keeping the rest" do
      assert StreamUrl.strip_credentials("rtsp://u:pw@h/1") == "rtsp://h/1"

      assert StreamUrl.strip_credentials("http://h/flv?stream=ch0&user=admin&password=x&app=bcs") ==
               "http://h/flv?stream=ch0&app=bcs"

      assert StreamUrl.strip_credentials("http://h/flv?user=admin&password=x") == "http://h/flv"
      assert StreamUrl.strip_credentials("rtsp://h/1") == "rtsp://h/1"
    end
  end

  describe "userinfo/1 and user/1" do
    test "the userinfo is whatever precedes the last @, the username decoded" do
      assert StreamUrl.userinfo("rtsp://u:pw@h/1") == "u:pw"
      assert StreamUrl.userinfo("rtsp://h/1") == nil
      assert StreamUrl.userinfo(nil) == nil

      assert StreamUrl.user("rtsp://%20u:pw@h/1") == " u"
      assert StreamUrl.user("rtsp://h/1") == nil
      assert StreamUrl.user(123) == nil
    end

    # `mask/1` treats a colonless userinfo as a password whole, so it is not a
    # username the form may prefill.
    test "a colonless userinfo is not a username" do
      assert StreamUrl.user("rtsp://SECRET@h/1") == nil
    end

    # A hand-edited or migrated row can hold a malformed escape, and the form
    # is the only place to repair it — `URI.decode/1` raises on one, and a
    # well-formed `%FF` decodes to a binary that is not valid UTF-8.
    test "an escape that cannot be decoded to UTF-8 keeps the raw username" do
      assert StreamUrl.user("rtsp://bad%zz:pw@h/1") == "bad%zz"
      assert StreamUrl.user("rtsp://u%FF:pw@h/1") == "u%FF"
    end
  end

  describe "compose/3" do
    test "splices the username and password in, encoding both" do
      assert StreamUrl.compose("rtsp://cam.lan/main", "ops", "new pass") ==
               "rtsp://ops:new%20pass@cam.lan/main"
    end

    test "a blank field keeps what the URL already carried" do
      assert StreamUrl.compose("rtsp://alice:x@cam.lan/main", "", "pw") ==
               "rtsp://alice:pw@cam.lan/main"

      assert StreamUrl.compose("rtsp://alice:x@cam.lan/main", "bob", "") ==
               "rtsp://bob:x@cam.lan/main"

      assert StreamUrl.compose("rtsp://alice:x@cam.lan/main", "", "") ==
               "rtsp://alice:x@cam.lan/main"
    end

    # Cameras that authenticate on the password alone.
    test "a password with no username composes password-only userinfo" do
      assert StreamUrl.compose("rtsp://h/1", "", "pw") == "rtsp://:pw@h/1"
    end

    test "an @ inside the saved password is not mistaken for the host boundary" do
      assert StreamUrl.compose("rtsp://user:sec@ret@host/s", "", "new") ==
               "rtsp://user:new@host/s"
    end

    # The colonless userinfo is the password everywhere else in the module;
    # reading it as a username here republished it as the form's `value=`.
    test "a typed password replaces a colonless userinfo, keeping its shape" do
      assert StreamUrl.compose("rtsp://SECRET@h/1", "", "pw") == "rtsp://pw@h/1"
      refute StreamUrl.compose("rtsp://SECRET@h/1", "", "pw") =~ "SECRET"
    end

    test "a typed username makes a colonless userinfo the password" do
      assert StreamUrl.compose("rtsp://SECRET@h/1", "user", "") == "rtsp://user:SECRET@h/1"
    end

    # `user@host` is colonless, which this module reads as password-only: the
    # name would come back as `nil` from `user/1` and be hidden by `mask/1`.
    test "a username typed onto a bare URL gets an explicit empty password slot" do
      composed = StreamUrl.compose("rtsp://cam.lan/main", "ops", "")

      assert composed == "rtsp://ops:@cam.lan/main"
      assert StreamUrl.user(composed) == "ops"
      assert StreamUrl.mask(composed) == "rtsp://ops:•••••@cam.lan/main"
    end

    test "a colonless userinfo nobody typed over is untouched" do
      assert StreamUrl.compose("rtsp://SECRET@h/1", "", "") == "rtsp://SECRET@h/1"
    end
  end

  describe "an ambiguous @" do
    @ambiguous "rtsp://u:pa/ss@cam.lan/main"

    test "is a credential the mask hides whole" do
      assert StreamUrl.ambiguous?(@ambiguous)
      assert StreamUrl.mask(@ambiguous) == "rtsp://•••••@cam.lan/main"
      refute StreamUrl.mask(@ambiguous) =~ "pa/ss"
      assert StreamUrl.credentialed?(@ambiguous)
    end

    # A raw `?` or `#` in a password ends the readable authority inside the
    # password (`u:pa`, holding no `@`), so the structural rule sees nothing —
    # which rendered the password and prefilled it. The display rule reaches
    # past both characters to the URL's last `@`.
    for {name, url, password} <- [
          {"?", "rtsp://u:pa?ss@cam.lan/main", "pa?ss"},
          {"#", "rtsp://u:pa#ss@cam.lan/main", "pa#ss"}
        ] do
      test "a raw #{name} in the password is out of the structural rule's reach, not the display rule's" do
        url = unquote(url)

        refute StreamUrl.ambiguous?(url)
        assert StreamUrl.display_ambiguous?(url)
        assert StreamUrl.mask(url) == "rtsp://•••••@cam.lan/main"
        refute StreamUrl.mask(url) =~ unquote(password)
        assert StreamUrl.credentialed?(url)
        assert StreamUrl.user(url) == nil
        assert StreamUrl.userinfo(url) == nil
        assert StreamUrl.compose(url, "ops", "pw") == url
      end
    end

    test "strips through the last such @, and offers no username" do
      assert StreamUrl.strip_credentials(@ambiguous) == "rtsp://cam.lan/main"
      assert StreamUrl.user(@ambiguous) == nil
      assert StreamUrl.userinfo(@ambiguous) == nil
    end

    # Splicing would have to pick a boundary, and the wrong pick rewrites the
    # host.
    test "is never spliced into" do
      assert StreamUrl.compose(@ambiguous, "ops", "pw") == @ambiguous
    end

    # The authority reads as ordinary userinfo `u:p` at host `h` — but a
    # password `p/live` would produce these identical bytes, so this is now
    # refused the same as an @-after-path authority with no userinfo at all:
    # this module cannot tell "normal credential, @ in the path" from
    # "credential holding a raw / and @" apart, and a wrong guess on either
    # renders half a password or points a stripped/composed URL at the wrong
    # authority.
    test "an @ past the path of an otherwise-normal authority is ambiguous too" do
      url = "rtsp://u:p@h/live@1"
      assert StreamUrl.ambiguous?(url)
      assert StreamUrl.mask(url) == "rtsp://•••••@1"
      refute StreamUrl.mask(url) =~ "live"
      assert StreamUrl.credentialed?(url)
      assert StreamUrl.strip_credentials(url) == "rtsp://1"
      assert StreamUrl.user(url) == nil
      assert StreamUrl.userinfo(url) == nil
      assert StreamUrl.compose(url, "ops", "pw") == url
    end

    # A password containing both a raw `@` and a raw `/` reads exactly like
    # ordinary userinfo `user:sec` at host `ret` whose path happens to hold an
    # `@` — the previous test's shape — so it gets the same wide refusal:
    # masked/stripped through the LAST `@`, never split apart or spliced into.
    @raw_slash_password "rtsp://user:sec@ret/part@host/live"

    test "a password holding a raw @ and / is masked through the last @" do
      url = @raw_slash_password
      assert StreamUrl.ambiguous?(url)
      assert StreamUrl.mask(url) == "rtsp://•••••@host/live"
      refute StreamUrl.mask(url) =~ "sec"
      refute StreamUrl.mask(url) =~ "ret/part"
      assert StreamUrl.credentialed?(url)
    end

    test "a password holding a raw @ and / strips through the last @, offering no username" do
      url = @raw_slash_password
      assert StreamUrl.strip_credentials(url) == "rtsp://host/live"
      assert StreamUrl.user(url) == nil
      assert StreamUrl.userinfo(url) == nil
    end

    test "a password holding a raw @ and / is never spliced into" do
      url = @raw_slash_password
      assert StreamUrl.compose(url, "ops", "pw") == url
    end

    # A stored value malformed this way reads as bare everywhere —
    # `split_authority/1` finds no `//` to open an authority in — so the
    # readout rendered the password and the form's prefill rule called the
    # row clean.
    @no_slashes "rtsp:/user:secret@host/live"

    test "a //-less URL with an @ is ambiguous like the @-after-path form" do
      url = @no_slashes

      assert StreamUrl.ambiguous?(url)
      assert StreamUrl.credentialed?(url)
      assert StreamUrl.mask(url) == "•••••@host/live"
      refute StreamUrl.mask(url) =~ "secret"
    end

    test "a //-less URL strips through its @, and offers no username" do
      url = @no_slashes

      assert StreamUrl.strip_credentials(url) == "host/live"
      assert StreamUrl.user(url) == nil
      assert StreamUrl.userinfo(url) == nil
    end

    test "a //-less URL is never spliced into" do
      url = @no_slashes

      assert StreamUrl.compose(url, "ops", "pw") == url
    end

    # The structural rule stops at the `?`, so the rewrite leaves the query
    # alone; the display rule does not, so the readout hides it.
    test "a //-less URL with no @ before the query is bare to a rewrite, not to the readout" do
      refute StreamUrl.ambiguous?("rtsp:/host/live?to=me@h")
      assert StreamUrl.display_ambiguous?("rtsp:/host/live?to=me@h")
      assert StreamUrl.mask("rtsp:/host/live") == "rtsp:/host/live"
    end

    # The accepted cost of the display rule: an `@` that really is part of a
    # query value is masked through anyway, because a raw `?` in a password
    # produces the same bytes and this module cannot tell them apart. The URL
    # opens blank in the form and gets retyped — the price of never rendering
    # the other reading's password.
    test "a legitimate @ in a query value is over-masked, and left alone by a strip" do
      url = "http://h/p?x=me@h"

      refute StreamUrl.ambiguous?(url)
      assert StreamUrl.display_ambiguous?(url)
      assert StreamUrl.mask(url) == "http://•••••@h"
      assert StreamUrl.credentialed?(url)
      assert StreamUrl.userinfo(url) == nil
      assert StreamUrl.compose(url, "ops", "pw") == url

      assert StreamUrl.strip_credentials(url) == url
    end

    test "neither rule reads a non-binary" do
      refute StreamUrl.ambiguous?(nil)
      refute StreamUrl.display_ambiguous?(nil)
    end
  end

  describe "mask/1 with a fragment" do
    test "a fragment after a credential-keyed pair survives the mask" do
      assert StreamUrl.mask("http://h/live.flv?user=u&password=pw#frag") ==
               "http://h/live.flv?user=•••••&password=•••••#frag"
    end

    test "a fragment with no query is left alone" do
      assert StreamUrl.mask("rtsp://u:pw@h/s#frag") == "rtsp://u:•••••@h/s#frag"
    end
  end

  describe "same_endpoint?/2 with an ambiguous URL" do
    test "an ambiguous URL is the same endpoint as nothing" do
      refute StreamUrl.same_endpoint?("rtsp://u:pa/ss@evil/live", "rtsp://evil/live")
      refute StreamUrl.same_endpoint?("rtsp://evil/live", "rtsp://u:pa/ss@evil/live")
      refute StreamUrl.same_endpoint?("rtsp://u:pa/ss@h/live", "rtsp://u:pa/ss@h/live")
    end

    # A display-ambiguous URL still parses an apparent authority
    # (`http://attacker.lan`) here; if `endpoint/1` accepted that reading,
    # this URL would compare equal to the camera's real endpoint and
    # `Settings.seed_userinfo/2` would copy its saved password onto the
    # attacker's host.
    test "a display-ambiguous URL is the same endpoint as nothing" do
      refute StreamUrl.same_endpoint?(
               "http://attacker.lan?x@camera.lan/live&password=secret",
               "http://attacker.lan/new"
             )
    end
  end

  describe "mask/1 with a credential pair after a query @" do
    test "the pair is masked though the collapse took the ? that opened it" do
      masked = StreamUrl.mask("http://h/p?user=admin@example.com&password=pw")
      refute masked =~ "pw"
      refute masked =~ "admin"
      assert masked == "http://•••••@•••••&password=•••••"
    end

    test "a non-credential query @ still collapses, and the pair after it is masked" do
      masked = StreamUrl.mask("http://h/p?x=me@h2&password=pw")
      refute masked =~ "pw"
      assert masked == "http://•••••@h2&password=•••••"
    end

    # Masking pairs first replaced `password=x` whole — taking the URL's only
    # `@` with it, so the display rule then found nothing and the readout
    # showed `u:pa`.
    test "a credential pair inside the password keeps the @ the display rule reads" do
      url = "rtsp://u:pa?password=x@cam/main"
      masked = StreamUrl.mask(url)

      assert masked == "rtsp://•••••@•••••"
      refute masked =~ "pa"
      refute masked =~ "x"
      assert StreamUrl.credentialed?(url)
    end
  end

  describe "a // that opens no authority" do
    # Splitting on the first `//` read `cam/live&password=x` as the authority,
    # which put the real query out of `credentialed?/1`'s reach and let the
    # form prefill the password into a rendered `value=`.
    test "a // reached after a path and a query is not an authority opener" do
      url = "rtsp:/broken?next=http://cam/live&password=x"
      masked = StreamUrl.mask(url)

      assert StreamUrl.split_authority(url) == {"", nil, url}
      assert StreamUrl.credentialed?(url)
      refute masked =~ "password=x"
      assert masked =~ "password=•••••"
    end

    test "a legitimate later // still splits at the first" do
      assert StreamUrl.split_authority("rtsp://h/p?next=http://x") ==
               {"rtsp://", nil, "h/p?next=http://x"}
    end
  end

  describe "compose/3 with no authority" do
    test "a URL with no authority to splice into is returned as typed" do
      assert StreamUrl.compose("rtsp:/cam/main", "ops", "pw") == "rtsp:/cam/main"
      assert StreamUrl.compose("rtsp://", "ops", "pw") == "rtsp://"
      assert StreamUrl.compose("cam/main", "ops", "pw") == "cam/main"
    end
  end

  describe "a // behind something that is not a scheme" do
    test "opens no authority, so the credential before it fails closed" do
      url = "rtsp:user:s3cret@//host/live"
      masked = StreamUrl.mask(url)
      refute masked =~ "s3cret"
      assert StreamUrl.credentialed?(url)
      assert StreamUrl.user(url) == nil
      assert StreamUrl.compose(url, "ops", "pw") == url
    end

    test "a scheme with digits, plus, dot or dash still opens one" do
      assert {"rtsp+tls://", nil, "h/s"} = StreamUrl.split_authority("rtsp+tls://h/s")
      assert {"//", nil, "h/s"} = StreamUrl.split_authority("//h/s")
    end
  end

  describe "mask/1 with an @ inside a credential value" do
    test "nothing after the value's last @ survives" do
      masked = StreamUrl.mask("http://h/p?password=a@example.com")
      refute masked =~ "example.com"
      refute masked =~ "a@"
      assert masked == "http://•••••@•••••"
    end
  end

  describe "credential_key?/1" do
    test "names the vendor spellings, whatever their case" do
      assert StreamUrl.credential_key?("password")
      assert StreamUrl.credential_key?("Access_Token")
      assert StreamUrl.credential_key?("USER")
      refute StreamUrl.credential_key?("channel")
      refute StreamUrl.credential_key?("")
    end

    # The camera decodes the key before reading it, so an escape anywhere in
    # it would otherwise walk a credential past both the mask and the prefill.
    test "decodes the key before judging it" do
      assert StreamUrl.credential_key?("pass%77ord")
      assert StreamUrl.credential_key?("access%5Ftoken")
      assert StreamUrl.credential_key?("access_%74oken")
    end

    # A malformed escape has no decoding, and a well-formed one can decode to
    # invalid UTF-8; the raw key is then all there is to judge.
    test "falls back to the raw key when there is no decoding to judge" do
      refute StreamUrl.credential_key?("%zz")
      refute StreamUrl.credential_key?("pass%FFword")
      refute StreamUrl.credential_key?("PASS%zzWORD")
      # `%70assword` decodes to `password` even though the raw key is not one.
      assert StreamUrl.credential_key?("%70assword")
    end
  end

  describe "same_endpoint?/2" do
    test "compares the scheme and host[:port], ignoring path, query and credential" do
      assert StreamUrl.same_endpoint?("rtsp://cam.lan:554/main", "rtsp://u:p@cam.lan:554/sub?x=1")
      refute StreamUrl.same_endpoint?("rtsp://cam.lan/main", "rtsp://other.lan/main")
      refute StreamUrl.same_endpoint?("rtsp://cam.lan/main", "rtsp://cam.lan:554/main")
      refute StreamUrl.same_endpoint?("rtsp://cam.lan/main", "http://cam.lan/main")
      refute StreamUrl.same_endpoint?("rtsp://cam.lan/main", nil)
    end

    test "a URL with no host is the same endpoint as nothing, another hostless one included" do
      refute StreamUrl.same_endpoint?("rtsp:", "rtsp:/old/path?password=x")
      refute StreamUrl.same_endpoint?("rtsp://", "rtsp://")
      assert StreamUrl.same_endpoint?("rtsp://h/a", "rtsp://h/b")
    end
  end
end
