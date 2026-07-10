ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(App.Repo, :manual)

# Mox: the text model is mocked; TTS uses a fixed fake so timing is deterministic.
Mox.defmock(App.TextModelMock, for: App.Adapters.TextModel)
Application.put_env(:app, :text_model, App.TextModelMock)
Application.put_env(:app, :tts, App.Test.Fakes.Tts)
Application.put_env(:app, :stt, App.Test.Fakes.Stt)
Application.put_env(:app, :brain_stream, App.Test.Fakes.BrainStream)
Application.put_env(:app, :embeddings, App.Test.Fakes.Embeddings)
Application.put_env(:app, :vector_store, App.Test.Fakes.VectorStore)
