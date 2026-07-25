defmodule App.Adapters.Stt do
  @moduledoc """
  Streaming STT. `start_link/1` gets `:owner` (the Conversation pid) and a `:mode`
  (`:auto` | `:manual`); it sends the owner `{:stt_partial, text}` / `{:stt_endpoint, text}`.
  `push/2` feeds it PCM16 frames; `finalize/1` ends a held utterance (manual/PTT mode).
  """
  @callback start_link(opts :: keyword()) :: GenServer.on_start()
  @callback push(stt :: pid(), pcm16 :: binary()) :: :ok
  @callback finalize(stt :: pid()) :: :ok
end
