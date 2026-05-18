Application.put_env(:arex, :url, System.get_env("AREX_URL") || "http://localhost:2480")
Application.put_env(:arex, :user, System.get_env("AREX_USER") || "root")
Application.put_env(:arex, :pwd, System.get_env("AREX_PWD") || "playwithdata")
Application.put_env(:arex, :db, System.get_env("AREX_DB") || "Imported")
Application.put_env(:arex, :language, "sql")

ExUnit.start()
