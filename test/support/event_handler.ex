defmodule GraphConn.Test.EventHandler do
  @moduledoc !"""
             Each execute function is executed in different task process.
             """

  use GraphConn.EventHandler

  @impl GraphConn.EventHandler
  def register() do
    filter = "&(element.ogit/_type = ogit/Automation/AutomationIssue)"

    %{
      "filter-id": "hdw-GraphConn.Test.EventHandler-#{filter}",
      "filter-type": "jfilter",
      "filter-content": "#{filter}"
    }
    |> register()
  end
end
