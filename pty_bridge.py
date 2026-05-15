#!/usr/bin/env python3
"""
PTY Bridge — allocates real pseudo-terminals and bridges I/O with an Erlang port
via length-prefixed binary frames.

Wire protocol uses Erlang's {:packet, 4} framing: each frame on stdin/stdout is
preceded by a 4-byte big-endian length prefix. Frame body is 1-byte tag + payload.
"""

import fcntl
import json
import os
import pty
import select
import signal
import struct
import sys
import termios
import time

# Tags
TAG_DATA = 0x00
TAG_CONTROL = 0x01
TAG_SHUTDOWN = 0x02

# Buffer size for PTY reads
PTY_READ_SIZE = 4096


def read_frame(stream):
    """Read a single length-prefixed frame from a binary stream.

    Returns (tag, payload) or None on EOF.
    """
    header = _read_exact(stream, 4)
    if header is None:
        return None
    length = struct.unpack(">I", header)[0]
    if length == 0:
        return None
    body = _read_exact(stream, length)
    if body is None:
        return None
    return body[0], body[1:]


def _read_exact(stream, n):
    """Read exactly n bytes from stream, returning None on EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def write_frame(stream, tag, payload=b""):
    """Write a length-prefixed frame to a binary stream."""
    body = bytes([tag]) + payload
    header = struct.pack(">I", len(body))
    stream.write(header + body)
    stream.flush()


def send_event(stream, event_dict):
    """Send a JSON event frame (tag 0x01)."""
    write_frame(stream, TAG_CONTROL, json.dumps(event_dict).encode("utf-8"))


def set_window_size(fd, cols, rows):
    """Set the PTY window size via ioctl TIOCSWINSZ."""
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def main():
    stdin = sys.stdin.buffer
    stdout = sys.stdout.buffer

    # --- Startup: read init frame ---
    init_frame = read_frame(stdin)
    if init_frame is None:
        log("Failed to read init frame")
        sys.exit(1)

    tag, payload = init_frame
    if tag != TAG_CONTROL:
        log(f"Expected control frame (0x01) for init, got 0x{tag:02x}")
        sys.exit(1)

    try:
        config = json.loads(payload)
    except json.JSONDecodeError as e:
        send_event(stdout, {"type": "error", "message": f"Invalid init JSON: {e}"})
        sys.exit(1)

    if config.get("type") != "init":
        send_event(stdout, {"type": "error", "message": f"Expected init, got {config.get('type')}"})
        sys.exit(1)

    command = config.get("command", "bash")
    args = config.get("args", [])
    cols = config.get("cols", 80)
    rows = config.get("rows", 24)
    extra_env = config.get("env", {})

    # Build child environment
    child_env = os.environ.copy()
    child_env.update(extra_env)
    if "TERM" not in child_env:
        child_env["TERM"] = "xterm-256color"

    # --- Fork PTY ---
    try:
        child_pid, master_fd = pty.fork()
    except OSError as e:
        send_event(stdout, {"type": "error", "message": f"pty.fork() failed: {e}"})
        sys.exit(1)

    if child_pid == 0:
        # Child process
        try:
            os.execvpe(command, [command] + args, child_env)
        except Exception as e:
            # If exec fails, write to stderr and exit
            sys.stderr.write(f"exec failed: {e}\n")
            os._exit(127)

    # Parent process
    set_window_size(master_fd, cols, rows)
    send_event(stdout, {"type": "started", "pid": child_pid})

    # --- Main loop ---
    try:
        run_loop(stdin, stdout, master_fd, child_pid)
    except Exception as e:
        log(f"Unexpected error in main loop: {e}")
        send_event(stdout, {"type": "error", "message": str(e)})
        cleanup(child_pid)
        sys.exit(1)


def run_loop(stdin, stdout, master_fd, child_pid):
    """Multiplex PTY output and stdin frames using select."""
    stdin_fd = stdin.fileno()
    child_exited = False

    while True:
        read_fds = [master_fd, stdin_fd]
        try:
            readable, _, _ = select.select(read_fds, [], [], 1.0)
        except (select.error, ValueError):
            break

        for fd in readable:
            if fd == master_fd:
                try:
                    data = os.read(master_fd, PTY_READ_SIZE)
                    if not data:
                        child_exited = True
                        break
                    write_frame(stdout, TAG_DATA, data)
                except OSError:
                    # EIO means child has exited
                    child_exited = True
                    break

            elif fd == stdin_fd:
                frame = read_frame(stdin)
                if frame is None:
                    # Stdin closed — shut down
                    cleanup(child_pid)
                    return

                tag, payload = frame
                if tag == TAG_DATA:
                    try:
                        os.write(master_fd, payload)
                    except OSError:
                        child_exited = True
                        break

                elif tag == TAG_CONTROL:
                    handle_control(payload, master_fd, child_pid)

                elif tag == TAG_SHUTDOWN:
                    cleanup(child_pid)
                    return

        if child_exited:
            break

        # Check if child has exited (non-blocking)
        exit_code = reap_child(child_pid)
        if exit_code is not None:
            # Drain any remaining PTY output
            drain_pty(master_fd, stdout)
            send_event(stdout, {"type": "exited", "exit_code": exit_code})
            os.close(master_fd)
            return

    # If we broke out of the loop, the child likely exited
    exit_code = reap_child(child_pid)
    if exit_code is None:
        # Wait for real this time
        try:
            _, status = os.waitpid(child_pid, 0)
            exit_code = wait_status_to_code(status)
        except ChildProcessError:
            exit_code = -1

    send_event(stdout, {"type": "exited", "exit_code": exit_code})
    try:
        os.close(master_fd)
    except OSError:
        pass


def handle_control(payload, master_fd, child_pid):
    """Handle a JSON control command."""
    try:
        cmd = json.loads(payload)
    except json.JSONDecodeError:
        log(f"Invalid control JSON: {payload!r}")
        return

    cmd_type = cmd.get("type")
    if cmd_type == "resize":
        cols = cmd.get("cols", 80)
        rows = cmd.get("rows", 24)
        try:
            set_window_size(master_fd, cols, rows)
        except OSError as e:
            log(f"resize failed: {e}")

    elif cmd_type == "signal":
        sig = cmd.get("signal", signal.SIGTERM)
        try:
            os.kill(child_pid, sig)
        except OSError as e:
            log(f"signal {sig} failed: {e}")

    else:
        log(f"Unknown control type: {cmd_type}")


def drain_pty(master_fd, stdout):
    """Read any remaining output from the PTY before closing."""
    while True:
        try:
            readable, _, _ = select.select([master_fd], [], [], 0.05)
            if not readable:
                break
            data = os.read(master_fd, PTY_READ_SIZE)
            if not data:
                break
            write_frame(stdout, TAG_DATA, data)
        except OSError:
            break


def reap_child(pid):
    """Non-blocking check if child has exited. Returns exit code or None."""
    try:
        waited_pid, status = os.waitpid(pid, os.WNOHANG)
        if waited_pid == 0:
            return None
        return wait_status_to_code(status)
    except ChildProcessError:
        return -1


def wait_status_to_code(status):
    """Convert a waitpid status to an exit code."""
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    elif os.WIFSIGNALED(status):
        return -os.WTERMSIG(status)
    return -1


def cleanup(child_pid):
    """Gracefully terminate the child process."""
    try:
        os.kill(child_pid, signal.SIGTERM)
    except OSError:
        return

    for _ in range(10):
        result = reap_child(child_pid)
        if result is not None:
            return
        time.sleep(0.1)

    try:
        os.kill(child_pid, signal.SIGKILL)
        os.waitpid(child_pid, 0)
    except OSError:
        pass


def log(msg):
    """Write a log message to stderr."""
    sys.stderr.write(f"[pty-bridge] {msg}\n")
    sys.stderr.flush()


if __name__ == "__main__":
    main()
