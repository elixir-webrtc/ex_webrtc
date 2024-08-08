defmodule Chat.Router do
  use Plug.Router

  plug(Plug.Static, at: "/", from: :chat)
  plug(:match)
  plug(:dispatch)

  get "/ws" do
    WebSockAdapter.upgrade(conn, Chat.PeerHandler, %{}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
