defmodule Echo.Router do
  use Plug.Router

  plug(Plug.Static, at: "/", from: :echo)
  plug(:match)
  plug(:dispatch)

  get "/ws" do
    WebSockAdapter.upgrade(conn, Echo.PeerHandler, %{}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
