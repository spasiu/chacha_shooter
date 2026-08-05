#!/usr/bin/env python3
"""Everyday commands for this project, so nobody has to remember the flags.

    python3 dev.py run       play it
    python3 dev.py server    run the dedicated multiplayer server
    python3 dev.py web       export the browser build into build/web
    python3 dev.py linux     export the dedicated server for the host
    python3 dev.py serve     host build/web and the game server together
    python3 dev.py deploy    put a new version on the public host
    python3 dev.py import    reimport assets after adding new ones

`serve` is the one to use for letting other people in: it puts the page on one
port and the game server on another, and the browser build works out the second
from the first. Both have to be reachable from wherever the players are.

Works from any directory: every path is worked out from where this file sits
rather than from the shell's, and is then passed to Godot relative to wherever
you happen to be. Nothing here has the project's location baked into it, so
moving or renaming the folder does not break it.
"""

import argparse
import http.server
import os
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path


def _game_is_up(port: int, timeout: float = 0.4) -> bool:
    """Whether anything is actually listening on the game port. Asked rather
    than assumed: a `Popen` handle says the process was started, which is a
    different question from whether it got as far as opening its socket, and a
    different question again from whether it is still there an hour later."""
    try:
        socket.create_connection(("127.0.0.1", port), timeout=timeout).close()
        return True
    except OSError:
        return False


def _wait_for_game(port: int, seconds: float = 25.0) -> bool:
    """Block until the game server answers, or give up. It has a map to read
    before it listens, so the first few seconds after starting it are a window
    in which every join would be turned away -- and a player who is turned away
    does not retry, they just end up alone in their own world."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if _game_is_up(port):
            return True
        time.sleep(0.25)
    return False


def _supervise_game(port: int, spawn, stop: threading.Event) -> None:
    """Keep a game server on the port for as long as the page is being served.

    Without this the pair fails in the least helpful way there is: the page
    carries on being served perfectly, so the tunnel looks healthy and the game
    still loads, but every socket is refused and every player lands in a world
    of their own. Nobody reports "the server died" -- they report that they
    cannot see each other, which sounds like a game bug and is not one.

    Restarting is the right answer rather than exiting, because the page server
    is usually the thing behind a tunnel with a URL that has been handed out:
    taking it down to punish a crashed child helps nobody.
    """
    process = None
    while not stop.is_set():
        if process is not None and process.poll() is None:
            stop.wait(2.0)
            continue
        if process is not None:
            print(
                "\n! the game server exited (code %s); starting another.\n"
                "  players who joined while it was gone are on their own and"
                " need to reload." % process.returncode,
                flush=True,
            )
        process = spawn()
        if not _wait_for_game(port, 25.0):
            print(
                "\n! the game server was started but never opened port %d.\n"
                "  run it on its own to see why:  python3 dev.py server"
                % port,
                flush=True,
            )
        stop.wait(2.0)
    if process is not None and process.poll() is None:
        process.terminate()
        process.wait()


def _copy_stream(source: socket.socket, sink: socket.socket) -> None:
    """Shovel bytes one way until the source dries up, then let the other end
    know it is over. Errors are the normal way a connection ends here -- a
    player closing the tab is a reset, not a fault -- so they are not reported."""
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            sink.sendall(chunk)
    except OSError:
        pass
    finally:
        try:
            sink.shutdown(socket.SHUT_WR)
        except OSError:
            pass

PROJECT = Path(__file__).resolve().parent
WEB_OUT = PROJECT / "build" / "web"
WEB_PRESET = "Web"
DEFAULT_PORT = 8099
# Where the dedicated server listens. Has to match Net.DEFAULT_PORT, which is
# what the browser build assumes when the page does not say otherwise.
GAME_PORT = 8100
SERVER_SCENE = "res://scenes/server.tscn"
# Path on the page's own origin that `serve` forwards to the game server. Has to
# match Net.PROXY_PATH, which is what the browser build asks for whenever the
# page arrived over https.
WS_PATH = "/ws"

# Where the engine usually lives on macOS. Overridable, because it is the one
# thing here that genuinely is machine-specific.
MAC_GODOT = Path("/Applications/Godot.app/Contents/MacOS/Godot")

# --- the host the game is played on -------------------------------------------
#
# A Lightsail box running nginx for the page and one systemd service for the
# game. Defaults rather than constants: every one of these is a command line
# flag, so a second host is a flag and not an edit.
DEPLOY_HOST = "15.223.69.70"
DEPLOY_USER = "admin"
DEPLOY_KEY = "~/.ssh/id_ed25519"
# nginx serves the page straight out of a checkout of this repository, which is
# why the browser build has to travel by commit and not by scp.
REMOTE_REPO = "/home/admin/chacha_shooter"
REMOTE_BINARY = "/opt/kilroy/kilroy_server"
REMOTE_SERVICE = "kilroy"
PUBLIC_URL = "https://15.223.69.70.sslip.io"

LINUX_PRESET = "Linux Server"
LINUX_OUT = PROJECT / "build" / "linux" / "kilroy_server"

# The three files worth compressing, and the reason this command exists at all.
# nginx runs with `gzip_static on`, which means it serves `index.wasm.gz` in
# preference to `index.wasm` and never checks which is newer. Pull a new build
# without remaking these and every player keeps getting the old one, silently,
# while the files on disk look exactly right.
COMPRESSED = ("index.wasm", "index.pck", "index.js")


def godot() -> str:
    """The engine binary: the GODOT environment variable first, then the usual
    macOS app bundle, then whatever is on PATH."""
    override = os.environ.get("GODOT")
    if override:
        # An override that does not exist is a typo, not a reason to quietly
        # run some other engine than the one that was asked for.
        if not Path(override).exists():
            sys.exit("GODOT is set to %s, which does not exist." % override)
        return override
    if MAC_GODOT.exists():
        return str(MAC_GODOT)
    found = shutil.which("godot")
    if found:
        return found
    sys.exit(
        "Cannot find Godot. Install it, or point at it with:\n"
        "  GODOT=/path/to/Godot python3 dev.py <command>"
    )


def project_arg() -> str:
    """The project directory, expressed relative to wherever this was run from.
    Just `.` in the normal case of running it from the project root."""
    try:
        relative = os.path.relpath(PROJECT, Path.cwd())
    except ValueError:
        # Different drive on Windows; nothing relative to say.
        return str(PROJECT)
    # Only worth it while the project is at or below the current directory.
    # From somewhere unrelated the relative form is a wall of `..` that is
    # longer and harder to read than the real path.
    return relative if not relative.startswith("..") else str(PROJECT)


def run(args: list[str]) -> int:
    cmd = [godot(), *args]
    # Flushed, or Python's buffering puts this after the engine's own output
    # whenever the command is piped somewhere.
    print("$", " ".join(cmd), flush=True)
    return subprocess.call(cmd, cwd=Path.cwd())


def cmd_run(_opts) -> int:
    """Play it, in a window, exactly as a player would get it."""
    return run(["--path", project_arg()])


def server_command(port: int) -> list[str]:
    """Engine arguments for the dedicated server. The scene is named outright
    rather than left to the project's main scene, so the server never so much
    as builds the join screen; `--server` after the `--` is what tells Net to
    listen instead of trying to connect somewhere."""
    return [
        "--headless", "--path", project_arg(), SERVER_SCENE,
        "--", "--server", "--port=%d" % port,
    ]


def cmd_server(opts) -> int:
    """Run the dedicated server on its own. Everything it needs is in the
    project, so this is the same command a host would run."""
    return run(server_command(opts.game_port))


def cmd_import(_opts) -> int:
    """Bring new or changed assets into the import cache. The export does this
    on its own most of the time, but not always, and it is cheap to be sure."""
    return run(["--headless", "--path", project_arg(), "--import"])


def cmd_web(opts) -> int:
    """Export the browser build. Overwrites build/web."""
    WEB_OUT.mkdir(parents=True, exist_ok=True)
    if opts.reimport:
        code = cmd_import(opts)
        if code != 0:
            return code
    out = os.path.relpath(WEB_OUT / "index.html", Path.cwd())
    code = run([
        "--headless", "--path", project_arg(), "--export-release", WEB_PRESET, out
    ])
    if code == 0:
        size = sum(f.stat().st_size for f in WEB_OUT.glob("*") if f.is_file())
        print("\nbuilt %s (%.0f MB)" % (WEB_OUT, size / 1_000_000))
        print("serve it with:  python3 dev.py serve")
    return code


def cmd_serve(opts) -> int:
    """Host the exported build, and the game server behind the same port.

    The page is static files and the game is a WebSocket server that has to be a
    real Godot process, because it holds the terrain. They are two servers, but
    they are deliberately reachable through one port: this one forwards WS_PATH
    straight through to the game.

    That matters the moment the game is not on localhost. Anything fronting it
    with TLS -- a tunnel like ngrok, or a real reverse proxy -- gives the page an
    https origin, and a browser on an https page will not open a plain ws://
    socket. A wss:// one needs a certificate, which the game server has not got.
    A path on the origin the page already came from sidesteps both, needs no
    second tunnel, and is what the browser build asks for on its own.

    Threaded because a WebSocket is held open for as long as somebody is
    playing. Serving from a single thread would let the first player to connect
    block every page load behind them.

    The HTTP side sends the cross-origin isolation headers Godot asks for. The
    build is exported without thread support so it does not strictly need them,
    but they cost nothing and keep the door open if threads are turned back on.
    No-store is there because a stale browser cache looks exactly like a build
    that did not take.
    """
    if not (WEB_OUT / "index.html").exists():
        sys.exit("Nothing built yet. Run:  python3 dev.py web")

    # The page port is taken first, before anything is started. Doing it the
    # other way round -- which is how this used to read -- means a second
    # `serve` spawns a game server, discovers the page port is busy, and takes
    # its own child back down again on the way out, which is a lot of moving
    # parts for a command that was never going to work.
    socketserver.ThreadingTCPServer.allow_reuse_address = True
    socketserver.ThreadingTCPServer.daemon_threads = True
    try:
        pages = socketserver.ThreadingTCPServer(("", opts.port), _make_handler(
            str(WEB_OUT), opts.game_port
        ))
    except OSError as err:
        sys.exit(
            "Cannot serve on port %d: %s\n"
            "Something is already there -- most likely a `serve` you have"
            " forgotten about." % (opts.port, err)
        )

    stop = threading.Event()
    keeper = None
    if not opts.no_server:
        if _game_is_up(opts.game_port):
            sys.exit(
                "A game server is already listening on port %d.\n"
                "Stop it first, or serve pages alone with:  python3 dev.py"
                " serve --no-server" % opts.game_port
            )
        print("starting the game server; it has a map to read...", flush=True)
        keeper = threading.Thread(
            target=_supervise_game,
            args=(
                opts.game_port,
                lambda: subprocess.Popen([godot(), *server_command(opts.game_port)]),
                stop,
            ),
            daemon=True,
        )
        keeper.start()
        if not _wait_for_game(opts.game_port, 30.0):
            print(
                "! it has not come up yet. Serving anyway -- it will be picked"
                " up whenever it does.",
                flush=True,
            )

    # Flushed, like `run` above and for the same reason: the game server is a
    # separate process writing to the same terminal, and unflushed output here
    # would turn up somewhere after it.
    #
    # The page port is the only one worth typing anywhere, and saying so plainly
    # is worth the extra lines: opening the game port in a browser instead
    # produces a wall of 'invalid header upgrade' from the engine, which reads
    # like a fault and is not one.
    lines = ["serving %s\n" % WEB_OUT, "  open  http://localhost:%d" % opts.port]
    if not opts.no_server:
        lines.append(
            "\nport %d carries the page and the game (%s -> :%d), so a tunnel or"
            " proxy\nneeds to point at that one port and nothing else."
            % (opts.port, WS_PATH, opts.game_port)
        )
    else:
        lines.append(
            "\npages only. Nothing is answering %s, so every player will be"
            " alone\nuntil a game server is up:  python3 dev.py server"
            % WS_PATH
        )
    lines.append("\nctrl-c to stop")
    print("\n".join(lines), flush=True)

    try:
        with pages:
            pages.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        # Leaving either half holding its port would make the next `serve` look
        # like a firewall problem.
        stop.set()
        if keeper is not None:
            keeper.join(timeout=10.0)
    return 0


def _make_handler(directory: str, game_port: int):
    """The request handler, built round the two things it needs to know. A
    factory rather than a closure inside `cmd_serve` so that the serving loop
    below reads as what it is."""

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=directory, **kw)

        def do_GET(self):
            if self.path.split("?")[0] == WS_PATH:
                self._relay_to_game()
                return
            super().do_GET()

        def _relay_to_game(self):
            """Hand this connection to the game server and get out of the way.

            Once a WebSocket is established it is just a byte stream in both
            directions, so there is no framing to understand here: forward the
            handshake exactly as it arrived, let the game server answer it, and
            then copy bytes until one side stops. Rewriting any of it would only
            create ways to get it wrong.
            """
            try:
                upstream = socket.create_connection(("127.0.0.1", game_port))
            except OSError:
                # Worth saying out loud rather than only in the response. This
                # is the failure that looks like a game bug from the outside:
                # the page still loads, so the only symptom anybody reports is
                # that they cannot see each other.
                print(
                    "! refused a join: nothing listening on port %d."
                    " Everyone who tries now lands in a world of their own."
                    % game_port,
                    flush=True,
                )
                self.send_error(502, "game server is not running")
                return

            self.close_connection = True
            request = ["GET %s HTTP/1.1" % self.path]
            request += ["%s: %s" % (k, v) for k, v in self.headers.items()]
            upstream.sendall(("\r\n".join(request) + "\r\n\r\n").encode("latin-1"))

            # Safe to read the raw socket rather than self.rfile: a client waits
            # for the 101 before it sends a single frame, so nothing of the
            # conversation is ever sitting in the buffered reader.
            downstream = self.connection
            pump = threading.Thread(
                target=_copy_stream, args=(upstream, downstream), daemon=True
            )
            pump.start()
            _copy_stream(downstream, upstream)
            pump.join(timeout=1.0)
            upstream.close()

        def end_headers(self):
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            self.send_header("Cache-Control", "no-store")
            super().end_headers()

        def log_message(self, *a):
            pass

    return Handler


def cmd_linux(opts) -> int:
    """Export the dedicated server for the host. One file, with the pack
    embedded, so the machine it runs on needs neither Godot nor the project."""
    LINUX_OUT.parent.mkdir(parents=True, exist_ok=True)
    out = os.path.relpath(LINUX_OUT, Path.cwd())
    code = run([
        "--headless", "--path", project_arg(), "--export-release", LINUX_PRESET, out
    ])
    if code == 0 and LINUX_OUT.exists():
        print("\nbuilt %s (%.0f MB)" % (LINUX_OUT, LINUX_OUT.stat().st_size / 1_000_000))
    return code


def _git(*args: str) -> str:
    """A git command's output, or an empty string if git had nothing to say."""
    result = subprocess.run(
        ["git", *args], cwd=PROJECT, capture_output=True, text=True
    )
    return result.stdout.strip()


def _ssh_base(opts) -> list[str]:
    return [
        "ssh", "-i", os.path.expanduser(opts.key),
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
        "%s@%s" % (opts.user, opts.host),
    ]


def _remote(opts, script: str) -> int:
    """Run a line of shell on the host, showing what was asked for. Failures are
    the caller's to interpret: half of them here mean something different from
    the other half."""
    print("$ ssh %s@%s %s" % (opts.user, opts.host, script), flush=True)
    return subprocess.call([*_ssh_base(opts), script])


def _remote_output(opts, script: str) -> str:
    result = subprocess.run(
        [*_ssh_base(opts), script], capture_output=True, text=True
    )
    return result.stdout.strip()


def _deploy_web(opts) -> int:
    """Get the browser build onto the host, by way of the repository.

    The page is served out of a checkout, so the only way a new build reaches
    the host is as a commit that has been pushed. That is worth checking before
    anything is pulled rather than after: a pull that quietly does nothing is
    indistinguishable, from the outside, from a deploy that worked.
    """
    if not opts.no_export:
        code = cmd_web(opts)
        if code != 0:
            return code

    dirty = _git("status", "--porcelain", "--", "build/web")
    if dirty:
        if not opts.push:
            print(
                "\n! build/web has changes that are not committed, so the host has"
                "\n  nothing to pull. Commit and push them, or re-run with --push:"
                "\n\n    git add build/web && git commit -m 'rebuild web' && git push\n",
                file=sys.stderr,
            )
            return 1
        print("\n--- committing the browser build")
        if subprocess.call(["git", "add", "build/web"], cwd=PROJECT) != 0:
            return 1
        if subprocess.call(
            ["git", "commit", "-m", "Rebuild the browser build."], cwd=PROJECT
        ) != 0:
            return 1

    if opts.push and _git("rev-list", "--count", "@{u}..HEAD") not in ("", "0"):
        print("\n--- pushing")
        if subprocess.call(["git", "push"], cwd=PROJECT) != 0:
            return 1

    print("\n--- updating the page on %s" % opts.host)
    # Only recompress what the pull actually changed.
    #
    # This is the difference between a returning player downloading nothing and
    # downloading ten megabytes. nginx builds its ETag out of the file's mtime
    # and size, and a browser with the old copy revalidates against that ETag.
    # `gzip -f` on every deploy rewrote the .gz whether or not its source had
    # moved, which gave it a fresh mtime, a fresh ETag, and a full re-download
    # for everybody -- even on a deploy that only touched a script.
    #
    # The engine is in `index.wasm` and changes about never; the game is in the
    # far smaller `index.pck`. Left alone, the ten-megabyte half stays in the
    # cache across all the deploys that do not touch it.
    compress = "".join(
        'if [ -f {f} ] && {{ [ ! -f {f}.gz ] || [ {f} -nt {f}.gz ]; }}; then'
        ' gzip -9 -k -f {f}; echo "  recompressed {f}";'
        ' else echo "  {f} unchanged, kept its cache"; fi; '.format(f=name)
        for name in COMPRESSED
    )
    code = _remote(opts, (
        "set -e; cd %s && git pull --ff-only && cd build/web && %s"
        " echo pulled $(git -C %s rev-parse --short HEAD)"
    ) % (REMOTE_REPO, compress, REMOTE_REPO))
    if code != 0:
        return code

    # Whether the host ended up on the commit that was just built. It will not
    # have if the push went to a branch nobody there is following, which is the
    # one way to do everything right and still deploy nothing.
    local = _git("rev-parse", "HEAD")
    remote = _remote_output(opts, "git -C %s rev-parse HEAD" % REMOTE_REPO)
    if local and remote and local != remote:
        print(
            "\n! the host is on %s but this checkout is on %s."
            "\n  The page on the host is not the one just built."
            % (remote[:9], local[:9]),
            file=sys.stderr,
        )
        return 1
    return 0


def _deploy_server(opts) -> int:
    """Replace the dedicated server and restart it.

    Restarting is not free: it drops everyone who is playing, and the terrain
    goes back to how the map ships, because the master copy of what has been
    shot away lives in that process and nowhere else.
    """
    if not opts.no_export:
        code = cmd_linux(opts)
        if code != 0:
            return code
    if not LINUX_OUT.exists():
        print(
            "No %s to deploy. Build it with:  python3 dev.py linux" % LINUX_OUT,
            file=sys.stderr,
        )
        return 1

    print("\n--- uploading %.0f MB" % (LINUX_OUT.stat().st_size / 1_000_000))
    code = subprocess.call([
        "scp", "-i", os.path.expanduser(opts.key), "-o", "BatchMode=yes",
        str(LINUX_OUT), "%s@%s:/tmp/kilroy_server" % (opts.user, opts.host),
    ])
    if code != 0:
        return code

    # Stopped before it is moved over, because Linux refuses to overwrite the
    # file a running process was loaded from and the error for it says only
    # "Text file busy", which is not a sentence anyone connects to this.
    print("\n--- restarting %s" % REMOTE_SERVICE)
    code = _remote(opts, (
        "set -e;"
        " sudo systemctl stop %s;"
        " sudo mv /tmp/kilroy_server %s;"
        " sudo chmod +x %s;"
        " sudo chown %s:%s %s;"
        " sudo systemctl start %s;"
        " sleep 8;"
        " systemctl is-active %s"
    ) % (
        REMOTE_SERVICE, REMOTE_BINARY, REMOTE_BINARY,
        opts.user, opts.user, REMOTE_BINARY, REMOTE_SERVICE, REMOTE_SERVICE,
    ))
    if code != 0:
        print(
            "\n! the service did not come back. What it said:", file=sys.stderr
        )
        _remote(opts, "sudo journalctl -u %s -n 30 --no-pager" % REMOTE_SERVICE)
        return code

    # The line only the server scene prints. Asked for because the service being
    # up says the process started, which is a different question from whether it
    # started as a server rather than as a game with nobody at the keyboard.
    log = _remote_output(
        opts, "sudo journalctl -u %s -n 20 --no-pager" % REMOTE_SERVICE
    )
    if "listening on port" not in log:
        print("\n! the server is up but never said it was listening:\n%s" % log,
              file=sys.stderr)
        return 1
    for line in log.splitlines()[-3:]:
        print("  %s" % line.split("]: ")[-1])
    return 0


def _check_live(opts) -> int:
    """Ask the public URL whether any of this worked. Cheap, and it catches the
    failure that no step above can see: the page being served as something other
    than a page, which a browser answers by offering to download the game."""
    import urllib.request

    url = opts.url.rstrip("/") + "/"
    try:
        with urllib.request.urlopen(url, timeout=20) as response:
            kind = response.headers.get("Content-Type", "")
            print("\n%s  %s  %s" % (url, response.status, kind))
            if not kind.startswith("text/html"):
                print(
                    "! served as %s rather than text/html, which a browser will"
                    " download instead of run." % kind,
                    file=sys.stderr,
                )
                return 1
    except Exception as err:  # noqa: BLE001 -- any failure here is the same news
        print("\n! %s is not answering: %s" % (url, err), file=sys.stderr)
        return 1
    return 0


def cmd_deploy(opts) -> int:
    """Put a new version on the host.

    Two halves, deployed together by default because they have to agree. The
    browser build and the dedicated server exchange a protocol number on every
    join, and a client whose number differs is refused outright -- so shipping
    one without the other does not degrade the game, it empties it. The number
    covers the weapon catalogue too, which means editing LoadoutConfig.ITEMS is
    a server change however much it reads like a client one.

    --web-only is for when nothing the server runs has moved: no restart, and
    nobody playing is thrown out.
    """
    if opts.web_only and opts.server_only:
        print("--web-only and --server-only ask for opposite things.",
              file=sys.stderr)
        return 1

    if not opts.server_only:
        code = _deploy_web(opts)
        if code != 0:
            return code
    if not opts.web_only:
        code = _deploy_server(opts)
        if code != 0:
            return code

    code = _check_live(opts)
    if code == 0:
        print("\ndeployed.  %s" % opts.url)
    return code


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    subs = parser.add_subparsers(dest="command")

    subs.add_parser("run", help="play it").set_defaults(func=cmd_run)

    web = subs.add_parser("web", help="export the browser build")
    web.add_argument(
        "--reimport", action="store_true", help="reimport assets first"
    )
    web.set_defaults(func=cmd_web)

    serve = subs.add_parser("serve", help="host the browser build and the game")
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--game-port", type=int, default=GAME_PORT)
    serve.add_argument(
        "--no-server", action="store_true",
        help="pages only; use when a game server is already running"
    )
    serve.set_defaults(func=cmd_serve)

    game = subs.add_parser("server", help="run the dedicated game server")
    game.add_argument("--game-port", type=int, default=GAME_PORT)
    game.set_defaults(func=cmd_server)

    imp = subs.add_parser("import", help="reimport assets")
    imp.set_defaults(func=cmd_import)

    linux = subs.add_parser("linux", help="export the dedicated server binary")
    linux.set_defaults(func=cmd_linux)

    dep = subs.add_parser("deploy", help="put a new version on the host")
    dep.add_argument(
        "--web-only", action="store_true",
        help="page only; leaves the game server and everyone on it alone"
    )
    dep.add_argument(
        "--server-only", action="store_true", help="game server only"
    )
    dep.add_argument(
        "--push", action="store_true",
        help="commit and push the browser build rather than refusing without it"
    )
    dep.add_argument(
        "--no-export", action="store_true",
        help="deploy what is already in build/, without rebuilding it"
    )
    dep.add_argument("--reimport", action="store_true")
    dep.add_argument("--host", default=DEPLOY_HOST)
    dep.add_argument("--user", default=DEPLOY_USER)
    dep.add_argument("--key", default=DEPLOY_KEY)
    dep.add_argument("--url", default=PUBLIC_URL)
    dep.set_defaults(func=cmd_deploy)

    opts = parser.parse_args()
    if opts.command is None:
        parser.print_help()
        return 0
    return opts.func(opts)


if __name__ == "__main__":
    raise SystemExit(main())
