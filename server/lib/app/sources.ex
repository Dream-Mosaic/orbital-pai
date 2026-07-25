defmodule App.Sources do
  @moduledoc """
  Behaviour for an external semantic source (Gmail, Calendar). `list_refs` returns cheap identity +
  change-detection refs; `to_point` builds the embeddable text + Qdrant payload for one ref. The
  `App.Sources.Ingester` drives them uniformly. `reconcile_mode` chooses how vanished items are
  pruned: `:full` (set-diff against the live list — Calendar) or `:age_out` (drop rows older than a
  cutoff — Gmail).
  """

  @type ref :: %{external_id: String.t(), content_hash: String.t(), raw: term()}
  @type point :: %{embed_text: String.t(), payload: map(), at: DateTime.t() | nil}

  @callback source_key() :: String.t()
  @callback connector() :: atom()
  @callback reconcile_mode() :: :full | :age_out
  @callback list_refs(account :: struct()) :: {:ok, [ref()]} | {:error, term()}
  @callback to_point(account :: struct(), ref()) :: {:ok, point()} | {:error, term()}
end
