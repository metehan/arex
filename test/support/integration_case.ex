defmodule Arex.IntegrationCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Arex.IntegrationCase
    end
  end

  setup do
    Application.put_env(:arex, :url, System.get_env("AREX_URL") || "http://localhost:2480")
    Application.put_env(:arex, :user, System.get_env("AREX_USER") || "root")
    Application.put_env(:arex, :pwd, System.get_env("AREX_PWD") || "playwithdata")
    Application.put_env(:arex, :db, System.get_env("AREX_DB") || "Imported")
    Application.put_env(:arex, :language, "sql")
    :ok
  end

  def unique_name(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
