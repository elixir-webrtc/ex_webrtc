defmodule WHEPFromFile.Router do
  use Plug.Router

  plug(Plug.Static, at: "/", from: "assets")
  plug(:match)
  plug(:dispatch)

  alias WHEPFromFile.{Viewer, ViewerSupervisor}

  post "/api/whep" do
    with {:ok, offer, _} <- read_body(conn),
         viewer_id <- unique_viewer_id(),
         {:ok, _viewer_pid} <- ViewerSupervisor.start_child(viewer_id),
         {:ok, answer} <- Viewer.watch_stream(viewer_id, offer) do
      conn
      |> put_resp_content_type("application/sdp")
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("location", "/api/resource/#{viewer_id}")
      |> send_resp(201, answer)
    end
  end

  patch "/api/resource/:viewer_id" do
    # Ice candidates trickle
    send_resp(conn, 204, "ok")
  end

  delete "/api/resource/:viewer_id" do
    :ok = Viewer.stop_stream(viewer_id)

    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp unique_viewer_id,
    do: for(_ <- 1..10, into: "", do: <<Enum.random(~c"0123456789abcdef")>>)
end
