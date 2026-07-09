defmodule App.Tools.Tool do
  @moduledoc """
  A capability the brain can call. One module per capability; each may expose one or more
  named functions (Weather exposes one, Reminders two), so the contract is
  declarations-plus-dispatch rather than one name per module.
  """

  @doc """
  The function declarations this module contributes, in Gemini `functionDeclaration` shape:
  `[%{name:, description:, parameters:}]`. Names are snake_case and globally unique.
  """
  @callback declarations() :: [map()]

  @doc """
  Run one of this module's functions. `name` disambiguates when the module has several;
  `args` is the decoded argument map (string keys) from Gemini; `ctx` carries
  `%{session_id, config}`. Returns a JSON-encodable result map or an error. The `{:ok, map}`
  result must be JSON-encodable (strings/numbers/lists/maps/nil — no raw structs like
  `DateTime`, tuples, or pids), since it's serialized back into the next Gemini request.
  """
  @callback execute(name :: String.t(), args :: map(), ctx :: map()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Optional: canned "bridge" phrases spoken while this tool runs, keyed by function name. The brain
  picks one at random and speaks it before executing the call, to mask latency. `[]` (or not
  implementing this) means no bridge for that function.
  """
  @callback bridge(name :: String.t()) :: [String.t()]
  @optional_callbacks bridge: 1

  @doc """
  Optional caching: `cache_ttl/1` returns a read tool's TTL in ms (nil = don't cache);
  `cache_invalidates/1` returns the read tool names a write should purge after it succeeds.
  """
  @callback cache_ttl(name :: String.t()) :: non_neg_integer() | nil
  @callback cache_invalidates(name :: String.t()) :: [String.t()]

  @doc """
  Optional: normalize the args used in the cache KEY (not the call), so near-identical calls collide.
  E.g. the brain re-emits drifting `time_min`/`time_max` each turn — Calendar rounds them to the
  minute here so "what's on my calendar today" asked twice hits. Defaults to the raw args.
  """
  @callback cache_key(name :: String.t(), args :: map()) :: term()

  @doc """
  Optional: the per-call execution cap in ms for a function (overrides the registry default). Slow
  multi-account/multi-roundtrip tools (e.g. Gmail search) need more than the 8s default; the brain's
  TTS context is kept alive meanwhile (see BrainStream keepalive). Not implementing it = the default.
  """
  @callback timeout(name :: String.t()) :: non_neg_integer()
  @optional_callbacks cache_ttl: 1, cache_invalidates: 1, cache_key: 2, timeout: 1
end
