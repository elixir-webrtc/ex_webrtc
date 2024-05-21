defmodule WhipWhep.Router do
  use Plug.Router

  alias ExWebRTC.PeerConnection
  alias WhipWhep.{Forwarder, PeerSupervisor}

  @token Application.compile_env!(:whip_whep, :token)

  plug(Plug.Logger)
  plug(Corsica, origins: "*")
  plug(Plug.Static, at: "/", from: :whip_whep)
  plug(:match)
  plug(:dispatch)

  # TODO: the HTTP responsed are not completely compliant with the RFCs

  post "/whip" do
    with :ok <- authenticate(conn),
         {:ok, offer_sdp, conn} <- get_body(conn, "application/sdp"),
         {:ok, pc, pc_id, answer_sdp} <- PeerSupervisor.start_whip(offer_sdp),
         :ok <- Forwarder.connect_input(pc) do
      conn
      |> put_resp_header("location", "/resource/#{pc_id}")
      |> put_resp_content_type("application/sdp")
      |> resp(201, answer_sdp)
    else
      {:error, _other} -> resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  post "/whep" do
    with {:ok, offer_sdp, conn} <- get_body(conn, "application/sdp"),
         {:ok, pc, pc_id, answer_sdp} <- PeerSupervisor.start_whep(offer_sdp),
         :ok <- Forwarder.connect_output(pc) do
      # TODO: use proper status codes in case of error
      conn
      |> put_resp_header("location", "/resource/#{pc_id}")
      |> put_resp_content_type("application/sdp")
      |> resp(201, answer_sdp)
    else
      {:error, _res} -> resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  patch "/resource/:resource_id" do
    name = PeerSupervisor.pc_name(resource_id)

    case get_body(conn, "application/trickle-ice-sdpfrag") do
      {:ok, body, conn} ->
        # TODO: this is not compliant with the RFC
        candidate =
          body
          |> Jason.decode!()
          |> ExWebRTC.ICECandidate.from_json()

        :ok = PeerConnection.add_ice_candidate(name, candidate)
        resp(conn, 204, "")

      {:error, _res} ->
        resp(conn, 400, "Bad request")
    end
    |> send_resp()
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp authenticate(conn) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- token == @token do
      :ok
    else
      _other -> {:error, :unauthorized}
    end
  end

  defp get_body(conn, content_type) do
    with [^content_type] <- get_req_header(conn, "content-type"),
         {:ok, body, conn} <- read_body(conn) do
      {:ok, body, conn}
    else
      headers when is_list(headers) -> {:error, :unsupported_media}
      _other -> {:error, :bad_request}
    end
  end
end
