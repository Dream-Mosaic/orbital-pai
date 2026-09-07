defmodule AppWeb.AppLink do
  @moduledoc """
  Deep links back into the native app.

  These are NOT OAuth redirect URIs. Google never sees them and has no opinion about them: by
  the time one is built, the OAuth flow is completely finished — the code was exchanged and the
  account stored — and all that is left is telling the system browser it can hand control back
  to the app it was launched from. That is why adding a connector needs no Google Cloud change
  (see `AppWeb.GoogleAuthController.connect/2`'s `return` param).

  ## Why these carry a status and nothing else

  Any app installed on the device can fire `orbital://connectors?...` at us — an `intent-filter`
  is open to all callers, not just to our own server. So everything here is treated as
  attacker-controllable on arrival, and the payload is kept to a single allowlisted enum the
  client can validate exhaustively. A human-readable `message=` would be more convenient and
  would hand any installed app a text banner inside Henry to write whatever it liked.

  Nothing is lost by that: the panel refetches its `state` on resume, so the account list
  already shows the specifics. The status only has to say which of the two sentences to render
  while that refetch is in flight.
  """

  # Matches `android:scheme` in native/android/app/src/main/AndroidManifest.xml and `kScheme`
  # in native/lib/deep_link.dart. Chosen to match the applicationId (com.orbital.pai).
  # Changing it means changing all three, and reinstalling the app — the intent-filter is read
  # at install time.
  @scheme "orbital"

  @doc """
  The link that returns to the Connectors panel after a connect/disconnect flow.

  `kind` is the flash kind the web branch would have used, so both branches of
  `GoogleAuthController.finish/3` describe the same outcome from one value.
  """
  def connectors(kind),
    do: "#{@scheme}://connectors?" <> URI.encode_query(%{"status" => status(kind)})

  defp status(:info), do: "ok"
  defp status(_), do: "error"
end
