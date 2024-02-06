defmodule SaveToFile.Router do
  use Plug.Router

  plug(Plug.Static, at: "/", from: "assets")
  plug(:match)
  plug(:dispatch)

  get "/ws" do
    WebSockAdapter.upgrade(conn, SaveToFile.PeerHandler, %{}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
