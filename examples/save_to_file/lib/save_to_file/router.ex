defmodule SaveToFile.Router do
  use Plug.Router

  @assets "assets"

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_file(conn, 200, "#{@assets}/index.html")
  end

  get "/script.js" do
    send_file(conn, 200, "#{@assets}/script.js")
  end

  get "/ws" do
    WebSockAdapter.upgrade(conn, SaveToFile.PeerHandler, %{}, [])
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
