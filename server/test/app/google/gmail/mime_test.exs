defmodule App.Google.Gmail.MimeTest do
  use ExUnit.Case, async: true

  alias App.Google.Gmail.Mime

  test "builds a plain message with the expected headers and body" do
    raw =
      Mime.build(%{
        from: "me@x.com",
        to: "you@y.com",
        subject: "Hi",
        body: "first line\nsecond line"
      })

    assert raw =~ "From: me@x.com\r\n"
    assert raw =~ "To: you@y.com\r\n"
    assert raw =~ "Subject: Hi\r\n"
    assert raw =~ "Content-Type: text/plain; charset=UTF-8\r\n"
    # blank line separates headers from body
    assert raw =~ "\r\n\r\nfirst line\nsecond line"
    # no threading headers on a plain send
    refute raw =~ "In-Reply-To:"
  end

  test "a reply adds In-Reply-To and References" do
    raw =
      Mime.build(%{
        from: "me@x.com",
        to: "you@y.com",
        subject: "Re: Hi",
        body: "ok",
        in_reply_to: "<abc@mail>",
        references: "<root@mail> <abc@mail>"
      })

    assert raw =~ "In-Reply-To: <abc@mail>\r\n"
    assert raw =~ "References: <root@mail> <abc@mail>\r\n"
  end

  test "strips CR/LF from to and subject to prevent header injection" do
    raw =
      Mime.build(%{
        from: "me@x.com",
        to: "you@y.com\r\nBcc: evil@z.com",
        subject: "Hi\r\nX-Injected: yes",
        body: "body"
      })

    refute raw =~ "\r\nBcc: evil@z.com"
    refute raw =~ "\r\nX-Injected: yes"
    assert raw =~ "To: you@y.comBcc: evil@z.com\r\n"
    assert raw =~ "Subject: HiX-Injected: yes\r\n"
  end

  test "encode/1 is url-safe base64 of build/1 with no padding" do
    attrs = %{from: "me@x.com", to: "you@y.com", subject: "Hi", body: "b"}
    assert Mime.encode(attrs) == Base.url_encode64(Mime.build(attrs), padding: false)
  end

  test "a nil subject becomes an empty Subject header" do
    raw = Mime.build(%{from: "me@x.com", to: "you@y.com", subject: nil, body: "b"})
    assert raw =~ "Subject: \r\n"
  end
end
