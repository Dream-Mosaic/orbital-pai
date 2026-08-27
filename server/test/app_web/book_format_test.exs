defmodule AppWeb.BookFormatTest do
  use ExUnit.Case, async: true
  alias AppWeb.BookFormat
  alias App.Garden.{Note, Plant}

  describe "fmt_noted/1" do
    test "a dated note (noted_on set) formats noted_on, not inserted_at" do
      note = %Note{noted_on: ~D[2026-07-20], inserted_at: ~U[2026-01-01 00:00:00Z]}
      assert BookFormat.fmt_noted(note) == "Jul 20"
    end

    # The PRIMARY production path: Garden.add_note/3 defaults noted_on to nil, and the channel
    # calls the 2-arity form (books_channel.ex:135), so every note typed into the Books panel,
    # native or web, takes this arm.
    test "an undated note (noted_on nil) falls back to the day it was written" do
      note = %Note{noted_on: nil, inserted_at: ~U[2026-03-05 10:00:00Z]}
      assert BookFormat.fmt_noted(note) == "Mar 5"
    end
  end

  describe "latest_note_line/1" do
    test "a plant with notes returns the LATEST note's body — notes are preloaded oldest-first" do
      plant = %Plant{notes: [%Note{body: "first flowers"}, %Note{body: "fruit set"}]}
      assert BookFormat.latest_note_line(plant) == "fruit set"
    end

    test "a plant with no notes returns the literal \"Notes\"" do
      assert BookFormat.latest_note_line(%Plant{notes: []}) == "Notes"
    end
  end
end
