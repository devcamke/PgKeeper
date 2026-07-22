# frozen_string_literal: true

require "open3"

module PgKeeper
  # Centralized subprocess execution with an optional wall-clock deadline.
  #
  # PgKeeper never reimplements dumping/restoring — it shells out to
  # +pg_dump+/+pg_restore+/+pg_dumpall+/+psql+. The failure this module guards
  # against is the quiet one: a child that hangs forever (a lock wait, a stalled
  # network-mounted PGDATA, a server that accepts the TCP connection but never
  # answers, so libpq never times out). Without a deadline the whole run blocks
  # indefinitely — no backup, and crucially no failure notification, because
  # nothing ever returns to report on.
  #
  # Every external command therefore runs under a timeout. Children are spawned
  # into their own process group (+pgroup: true+); on expiry we signal the whole
  # group +TERM+, give it a short grace, then +KILL+, and raise {TimeoutError}.
  # Killing the group (not just the direct child) matters because +pg_dump+ can
  # fork helper processes for parallel/directory dumps.
  #
  # A nil, zero, or negative timeout means "no deadline" — the historical
  # behaviour, still available for callers that opt out.
  module Subprocess
    module_function

    # Seconds to wait after TERM before escalating to KILL.
    KILL_GRACE_SECONDS = 5

    # Run +cmd+ (an argv array — never a shell string, so there is no shell to
    # inject into) capturing stdout and stderr in full. Returns
    # +[stdout_string, stderr_string, Process::Status]+.
    #
    # Raises {TimeoutError} if +timeout+ seconds elapse first, and
    # {EnvironmentError} if the binary is not on PATH.
    def capture3(env, *cmd, timeout: nil, stdin_data: nil, label: cmd.first)
      popen(env, cmd, label: label) do |stdin, stdout, stderr, wait|
        stdin.write(stdin_data) if stdin_data
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }
        status = await(wait, timeout: timeout, label: label, cmd: cmd)
        [out_reader.value, err_reader.value, status]
      end
    end

    # Like {capture3}, but streams each stderr line to the given block as it
    # arrives — so a long dump's progress reaches the log live rather than only
    # after it finishes. stdout is still captured in full. Returns
    # +[stdout_string, stderr_string, Process::Status]+.
    def stream(env, *cmd, timeout: nil, label: cmd.first)
      popen(env, cmd, label: label) do |stdin, stdout, stderr, wait|
        stdin.close
        out_reader = Thread.new { stdout.read }
        err_buf = +""
        err_reader = Thread.new do
          stderr.each_line do |line|
            err_buf << line
            yield line if block_given?
          end
        end
        status = await(wait, timeout: timeout, label: label, cmd: cmd)
        err_reader.join
        [out_reader.value, err_buf, status]
      end
    end

    # -- internals ---------------------------------------------------------

    def popen(env, cmd, label:, &)
      Open3.popen3(env, *cmd, pgroup: true, &)
    rescue Errno::ENOENT
      raise EnvironmentError, "#{label} not found on PATH"
    end

    # Wait for the child, enforcing the deadline. Returns its Process::Status,
    # or kills the process group and raises {TimeoutError} on expiry.
    def await(wait, timeout:, label:, cmd:)
      return wait.value if timeout.nil? || timeout <= 0
      return wait.value if wait.join(timeout)

      signal_group(wait.pid, "TERM")
      unless wait.join(KILL_GRACE_SECONDS)
        signal_group(wait.pid, "KILL")
        wait.join
      end
      raise TimeoutError.new(
        "#{label} timed out after #{timeout}s and was terminated",
        command: Array(cmd).join(" "), timeout_seconds: timeout
      )
    end

    # Signal a whole process group. +pgroup: true+ makes the child a group
    # leader, so its PGID equals its PID; the negative pid targets the group.
    def signal_group(pid, sig)
      Process.kill("-#{sig}", pid)
    rescue Errno::ESRCH
      nil # already gone — nothing to signal
    end
  end
end
