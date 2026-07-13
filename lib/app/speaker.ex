defmodule App.Speaker do
  @moduledoc """
  Voice Lock context: enrollment clips -> per-user voiceprint, gate-event log,
  mode/threshold prefs, and the verifier seam (app env :speaker_verifier).
  Spec: docs/superpowers/specs/2026-07-12-voice-lock-design.md.
  """
  import Ecto.Query
  alias App.Repo
  alias App.Speaker.{Enrollment, Gate, GateEvent}

  @min_clip_bytes 6 * 32_000
  @max_clip_bytes 15 * 32_000
  @rms_floor 200.0
  @keep_events 100

  def verifier, do: Application.get_env(:app, :speaker_verifier, App.Speaker.Ortex)
  def model_id, do: Application.get_env(:app, :speaker_model_id, "ecapa512-2026-07")

  # ---- enrollment ----

  @doc "Quality-check, embed, and upsert one enrollment clip (slot 1..3)."
  def enroll_clip(user_id, slot, pcm16) when slot in 1..3 and is_binary(pcm16) do
    with :ok <- clip_quality(pcm16),
         {:ok, emb} <- verifier().embed(pcm16) do
      %Enrollment{}
      |> Ecto.Changeset.change(
        user_id: user_id,
        slot: slot,
        audio: pcm16,
        embedding: to_blob(emb),
        model_id: model_id()
      )
      |> Repo.insert(
        on_conflict: {:replace, [:audio, :embedding, :model_id, :updated_at]},
        conflict_target: [:user_id, :slot]
      )

      broadcast_changed(user_id)
      :ok
    end
  end

  defp clip_quality(pcm) when byte_size(pcm) < @min_clip_bytes, do: {:error, :too_short}

  defp clip_quality(pcm) do
    sample = binary_part(pcm, 0, min(byte_size(pcm), 10 * 32_000))

    {sum, n} =
      for(<<s::16-signed-little <- sample>>,
        reduce: {0.0, 0},
        do: ({acc, c} -> {acc + s * s, c + 1})
      )

    if :math.sqrt(sum / max(n, 1)) >= @rms_floor, do: :ok, else: {:error, :too_quiet}
  end

  def enrolled_slots(user_id) do
    Repo.all(from e in Enrollment, where: e.user_id == ^user_id, select: e.slot, order_by: e.slot)
  end

  @doc "Normalized mean of the user's clip embeddings; lazily re-embeds stored audio on model change."
  def voiceprint(user_id) do
    case Repo.all(from e in Enrollment, where: e.user_id == ^user_id) do
      [] ->
        :none

      rows ->
        rows = Enum.map(rows, &refresh_embedding/1)
        vecs = Enum.map(rows, &from_blob(&1.embedding))
        dims = length(hd(vecs))

        sums =
          Enum.reduce(vecs, List.duplicate(0.0, dims), fn v, acc ->
            Enum.zip_with(v, acc, &+/2)
          end)

        norm = :math.sqrt(Enum.reduce(sums, 0.0, &(&2 + &1 * &1)))
        if norm > 0.0, do: {:ok, Enum.map(sums, &(&1 / norm))}, else: :none
    end
  end

  defp refresh_embedding(%Enrollment{} = row) do
    current = model_id()

    with true <- row.model_id != current,
         true <- verifier().ready?(),
         {:ok, emb} <- verifier().embed(row.audio) do
      row
      |> Ecto.Changeset.change(embedding: to_blob(emb), model_id: current)
      |> Repo.update!()
    else
      _ -> row
    end
  end

  # ---- runtime state for the Conversation FSM ----

  @doc "The FSM's voice_lock cache for a user id (nil user -> nil)."
  def voice_lock_state(user_id) do
    case App.Users.get(user_id) do
      nil ->
        nil

      user ->
        %{
          user_id: user.id,
          mode: String.to_existing_atom(user.voice_lock_mode),
          threshold: user.voice_lock_threshold || App.Config.default().voice_lock_threshold,
          voiceprint:
            with({:ok, v} <- voiceprint(user.id), do: v)
            |> then(&if(&1 == :none, do: nil, else: &1))
        }
    end
  end

  def set_mode(%App.Users.User{} = user, mode) when mode in ~w(off shadow enforce) do
    with {:ok, user} <- App.Users.update_prefs(user, %{voice_lock_mode: mode}) do
      broadcast_changed(user.id)
      {:ok, user}
    end
  end

  # ---- events ----

  @doc "Insert a gate event and prune to the newest #{@keep_events} for that user."
  def log_event(attrs) do
    %GateEvent{}
    |> Ecto.Changeset.change(
      Map.take(attrs, [:user_id, :decision, :reason, :score, :speech_ms, :transcript, :mode])
    )
    |> Repo.insert!()

    user_id = attrs.user_id

    keep =
      from(e in GateEvent,
        where: e.user_id == ^user_id,
        order_by: [desc: e.id],
        limit: @keep_events,
        select: e.id
      )

    Repo.delete_all(
      from e in GateEvent, where: e.user_id == ^user_id and e.id not in subquery(keep)
    )

    :ok
  end

  def recent_drops(user_id, limit \\ 20) do
    Repo.all(
      from e in GateEvent,
        where: e.user_id == ^user_id and e.decision in ["drop", "would_drop"],
        order_by: [desc: e.id],
        limit: ^limit
    )
  end

  @doc "Print score distributions per decision/reason — the shadow-calibration helper (iex)."
  def calibration_report(user_id) do
    events = Repo.all(from e in GateEvent, where: e.user_id == ^user_id and not is_nil(e.score))

    events
    |> Enum.group_by(&{&1.decision, &1.reason})
    |> Enum.each(fn {{d, r}, es} ->
      scores = es |> Enum.map(& &1.score) |> Enum.sort()
      mid = Enum.at(scores, div(length(scores), 2))

      IO.puts(
        "#{d}/#{r}: n=#{length(scores)} min=#{List.first(scores)} median=#{mid} max=#{List.last(scores)}"
      )
    end)
  end

  # ---- plumbing ----

  def broadcast_changed(user_id),
    do: Phoenix.PubSub.broadcast(App.PubSub, "voice_lock:#{user_id}", {:voice_lock_changed})

  def max_clip_bytes, do: @max_clip_bytes

  @doc false
  def to_blob(floats), do: for(f <- floats, into: <<>>, do: <<f::float-32-little>>)

  @doc false
  def from_blob(blob), do: for(<<f::float-32-little <- blob>>, do: f)

  defdelegate score(a, b), to: Gate
end
