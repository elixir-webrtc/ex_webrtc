defmodule Dtmf.Router do
  use Plug.Router

  plug(Plug.Static, at: "/", from: :dtmf)
  plug(:match)
  plug(:dispatch)

  get "/ws" do
    WebSockAdapter.upgrade(conn, Dtmf.PeerHandler, %{}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
