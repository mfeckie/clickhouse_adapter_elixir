defmodule ChCodecTest do
  use ExUnit.Case
  doctest ChCodec

  test "greets the world" do
    assert ChCodec.hello() == :world
  end
end
