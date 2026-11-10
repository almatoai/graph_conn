defmodule NoGun.RestClient do
  @moduledoc "A REST-only GraphConn client, which must compile without gun."
  use GraphConn, otp_app: :no_gun
end
