defmodule GraphConn.CredoChecks.LazyLoggerMessageTest do
  use Credo.Test.Case

  alias GraphConn.CredoChecks.LazyLoggerMessage

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:credo)
    :ok
  end

  describe "flags" do
    test "a bound message logged as a bare variable" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          Logger.info(message)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 4 == issue.line_no end)
    end

    test "a bound message interpolated into the logged string" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          Logger.debug("[M] #{message}")
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 4 == issue.line_no end)
    end

    test "a bound message piped into Logger" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          message |> Logger.warning()
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 4 == issue.line_no end)
    end

    test "a bound message logged with metadata" do
      ~S'''
      defmodule M do
        def f(params, id) do
          message = "params #{inspect(params)}"
          Logger.error(message, req_id: id)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 4 == issue.line_no end)
    end

    test "a bound message passed to Logger.log/2" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          Logger.log(:info, message)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 4 == issue.line_no end)
    end

    test "a bound message with other statements before the Logger call" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          send(self(), :before)
          Logger.info(message)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 5 == issue.line_no end)
    end
  end

  describe "flags, through concatenation and nesting" do
    test "a bound message concatenated into the logged string" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          Logger.info("prefix " <> message)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 4 == issue.line_no end)
    end

    test "a bound message logged inside a nested if" do
      ~S'''
      defmodule M do
        def f(params, flag) do
          message = "params #{inspect(params)}"

          if flag do
            Logger.info(message)
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 6 == issue.line_no end)
    end

    test "a bound message logged inside a case clause block" do
      ~S'''
      defmodule M do
        def f(params, result) do
          message = "params #{inspect(params)}"

          case result do
            :ok ->
              send(self(), :ok)
              Logger.warning("[M] #{message}")

            _error ->
              :error
          end
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> assert_issue(fn issue -> assert 8 == issue.line_no end)
    end
  end

  describe "allows" do
    test "a message rebound from itself, which counts as a use" do
      ~S'''
      defmodule M do
        def f(params) do
          message = "params #{inspect(params)}"
          message = message <> "!"
          Logger.info(message)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end

    test "a variable passed only as metadata" do
      ~S'''
      defmodule M do
        def f(params) do
          detail = inspect(params)
          Logger.info("x", detail: detail)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end

    test "a message built inside the Logger call" do
      ~S'''
      defmodule M do
        def f(params) do
          Logger.info("params #{inspect(params)}")
          "params #{inspect(params)}" |> Logger.info()
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end

    test "a function-valued message" do
      ~S'''
      defmodule M do
        def f(params) do
          log = fn -> "params #{inspect(params)}" end
          Logger.debug(log)
          Logger.debug(fn -> "again #{inspect(params)}" end)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end

    test "a message also used outside the Logger call" do
      ~S'''
      defmodule M do
        def f(body, frame_bytes) do
          message = "Response was too big (#{frame_bytes} bytes)"
          Logger.warning("[ActionHandler] #{message}, sending an error instead", req_id: body.id)
          error = %{req_id: body.id, action_error: message}
          Jason.encode!(%{error: error})
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end

    test "a message passed in rather than bound in the block" do
      ~S'''
      defmodule M do
        def f(message) do
          send(self(), :before)
          Logger.info(message)
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end

    test "a bound message given to something other than Logger" do
      ~S'''
      defmodule M do
        def f(invalid) do
          message = "got: #{inspect(invalid)}"
          raise ArgumentError, message
        end
      end
      '''
      |> to_source_file()
      |> run_check(LazyLoggerMessage)
      |> refute_issues()
    end
  end
end
