# 1Password fuzzel integration + nixpkgs search keybinds
{
  config,
  lib,
  pkgs,
  username,
  ...
}:
let
  cfg = config.modules.desktop.full.op-fuzzel;

  python = pkgs.python3.withPackages (ps: [
    ps.onepassword-sdk
  ]);

  socketPath = "\${XDG_RUNTIME_DIR}/op-fuzzel.sock";

  opIpcLib = "${pkgs._1password-gui}/share/1password/libop_sdk_ipc_client.so";

  daemon = pkgs.writeScriptBin "op-fuzzel-daemon" ''
    #!${python}/bin/python3
    import asyncio
    import json
    import os
    import signal
    import subprocess
    import sys
    import time
    import re
    from urllib.parse import urlparse

    # Monkeypatch SDK library search for NixOS
    import onepassword.desktop_core as _dc
    _orig_find = _dc.find_1password_lib_path
    def _nixos_find_lib():
        nix_path = "${opIpcLib}"
        if os.path.exists(nix_path):
            return nix_path
        return _orig_find()
    _dc.find_1password_lib_path = _nixos_find_lib

    SOCKET_PATH = os.path.expandvars("${socketPath}")
    CLEAR_SECONDS = 30
    CLIPHIST_SECONDS = 5
    NOTIFY = "${pkgs.libnotify}/bin/notify-send"
    WL_COPY = "${pkgs.wl-clipboard}/bin/wl-copy"
    WL_PASTE = "${pkgs.wl-clipboard}/bin/wl-paste"
    CLIPHIST = "${pkgs.cliphist}/bin/cliphist"
    FUZZEL = "${pkgs.fuzzel}/bin/fuzzel"
    HYPRCTL = "${pkgs.hyprland}/bin/hyprctl"

    client = None
    items_cache = []
    refresh_task = None
    REFRESH_INTERVAL = 300  # 5 minutes

    def notify(msg, urgency="normal", timeout=3000):
        subprocess.Popen([NOTIFY, "-u", urgency, "-t", str(timeout), "1Password", msg])

    async def _periodic_refresh_loop():
        while True:
            await asyncio.sleep(REFRESH_INTERVAL)
            if client is not None:
                print("Periodic refresh...", flush=True)
                await refresh_items()
                notify("Items refreshed.", timeout=2000)

    def start_periodic_refresh():
        global refresh_task
        if refresh_task is not None:
            refresh_task.cancel()
        refresh_task = asyncio.get_event_loop().create_task(_periodic_refresh_loop())

    async def do_auth(account_name):
        global client
        from onepassword import Client, DesktopAuth
        try:
            notify("Authenticating...")
            client = await Client.authenticate(
                auth=DesktopAuth(account_name=account_name),
                integration_name="op-fuzzel",
                integration_version="v1.0.0",
            )
            notify("Authenticated. Loading items...")
            await refresh_items()
            start_periodic_refresh()
            notify(f"Ready. {len(items_cache)} items loaded.")
            return "ok"
        except Exception as e:
            notify(f"Auth failed: {e}", urgency="critical")
            return f"error: {e}"

    def extract_domain(url):
        try:
            if not url.startswith(("http://", "https://")):
                url = "https://" + url
            host = urlparse(url).hostname or ""
            return host.lower().rstrip(".")
        except Exception:
            return ""

    def domain_base(fqdn):
        parts = fqdn.split(".")
        if len(parts) >= 2:
            return ".".join(parts[-2:])
        return fqdn

    async def resolve_usernames(entries):
        if not client or not entries:
            return
        for i, entry in enumerate(entries):
            try:
                val = await client.secrets.resolve(
                    f"op://{entry['vault_id']}/{entry['item_id']}/username"
                )
                if val:
                    entry["username"] = val
            except Exception:
                pass

    async def refresh_items():
        global items_cache
        if client is None:
            return
        items_cache = []
        try:
            vaults = await client.vaults.list()
            for vault in vaults:
                items = await client.items.list(vault.id)
                for item in items:
                    domains = []
                    for w in item.websites:
                        d = extract_domain(w.url)
                        if d:
                            domains.append(d)
                    items_cache.append({
                        "vault_id": vault.id,
                        "vault_name": vault.title,
                        "item_id": item.id,
                        "title": item.title,
                        "username": "",
                        "domains": domains,
                    })
            await resolve_usernames(items_cache)
        except Exception as e:
            notify(f"Failed to list items: {e}", urgency="critical")

    def get_active_url_domain():
        try:
            result = subprocess.run(
                [HYPRCTL, "activewindow", "-j"],
                capture_output=True, text=True, timeout=2
            )
            if result.returncode != 0:
                return None
            data = json.loads(result.stdout)
            window_class = data.get("class", "")
            window_title = data.get("title", "")

            is_browser = any(
                b in window_class.lower()
                for b in ["zen", "firefox", "brave", "chromium", "chrome"]
            )
            if not is_browser:
                return None

            title = re.sub(
                r"\s*[\u2014\u2013\u2015\u00ad\u002d]\s*(Zen Browser|Firefox|Brave|Chromium|Google Chrome)\s*$",
                "", window_title
            )

            domain_matches = re.findall(
                r'[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?'
                r'(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*'
                r'\.(?:com|org|net|io|dev|co|uk|de|fr|jp|au|ca|us|eu|me|app|xyz|info|biz|tv|ai|gg|sh)',
                title
            )
            if domain_matches:
                return domain_matches[-1].lower()
            return None
        except Exception:
            return None

    async def get_password(vault_id, item_id):
        ref = f"op://{vault_id}/{item_id}/password"
        try:
            return await client.secrets.resolve(ref)
        except Exception as e:
            notify(f"Failed to get password: {e}", urgency="critical")
            return None

    def secure_copy(password):
        subprocess.run([WL_COPY, password], capture_output=True, timeout=5)

        notify(f"Password copied. Clearing in {CLEAR_SECONDS}s.")

        pid = os.fork()
        if pid == 0:
            try:
                # Remove from cliphist after a few seconds
                time.sleep(CLIPHIST_SECONDS)
                subprocess.run(
                    [CLIPHIST, "delete"],
                    input=password.encode(),
                    capture_output=True, timeout=5
                )
                # Clear clipboard after remaining time
                time.sleep(max(0, CLEAR_SECONDS - CLIPHIST_SECONDS))
                result = subprocess.run(
                    [WL_PASTE, "--no-newline"],
                    capture_output=True, timeout=2
                )
                if result.stdout.decode() == password:
                    subprocess.run([WL_COPY, "--clear"])
                    notify("Clipboard cleared.", timeout=2000)
            except Exception:
                pass
            os._exit(0)

    async def show_fuzzel(browser_mode=False):
        if client is None:
            notify("Not authenticated.", urgency="critical")
            return "error: not authenticated"

        if not items_cache:
            notify("No items found.")
            return "error: no items"

        active_domain = None
        if browser_mode:
            active_domain = get_active_url_domain()
            if active_domain is None:
                notify("Active window is not a browser.", urgency="critical")
                return "error: not a browser"

        if active_domain:
            active_base = domain_base(active_domain)

            exact = []
            base_matches = []
            for entry in items_cache:
                item_bases = [domain_base(d) for d in entry["domains"]]
                if active_domain in entry["domains"]:
                    exact.append(entry)
                elif active_base in item_bases:
                    base_matches.append(entry)

            display_items = exact + base_matches
            if not display_items:
                notify(f"No logins for {active_domain}.")
                return "error: no matches"
            prompt = f"1Password ({active_domain}): "
        else:
            display_items = sorted(items_cache, key=lambda e: e["title"].lower())
            prompt = "1Password: "

        # Build fuzzel input: "Title  —  username" or just "Title"
        fuzzel_lines = []
        line_to_entry = {}
        for entry in display_items:
            if entry["username"]:
                line = f"{entry['title']}  \u2014  {entry['username']}"
            else:
                line = entry["title"]
            if line in line_to_entry:
                existing = line_to_entry.pop(line)
                eu = f"  \u2014  {existing['username']}" if existing["username"] else ""
                renamed = f"{existing['title']}{eu} ({existing['vault_name']})"
                fuzzel_lines = [renamed if l == line else l for l in fuzzel_lines]
                line_to_entry[renamed] = existing
                eu = f"  \u2014  {entry['username']}" if entry["username"] else ""
                line = f"{entry['title']}{eu} ({entry['vault_name']})"
            fuzzel_lines.append(line)
            line_to_entry[line] = entry

        try:
            proc = subprocess.run(
                [FUZZEL, "--dmenu", "--prompt", prompt, "--width", "50", "--lines", "15"],
                input="\n".join(fuzzel_lines),
                capture_output=True, text=True
            )
            if proc.returncode != 0:
                return "cancelled"
            selected = proc.stdout.strip()
        except Exception as e:
            notify(f"Fuzzel failed: {e}", urgency="critical")
            return f"error: {e}"

        entry = line_to_entry.get(selected)
        if entry is None:
            notify("Could not match selection.", urgency="critical")
            return "error: match failed"

        password = await get_password(entry["vault_id"], entry["item_id"])
        if password is None:
            notify("No password field found.", urgency="critical")
            return "error: no password"

        secure_copy(password)
        return "ok"

    async def handle_client(reader, writer):
        try:
            data = await asyncio.wait_for(reader.read(4096), timeout=30)
            command = data.decode().strip()

            if command == "auth":
                result = "error: account name required. Usage: op-auth <account-name>"
            elif command.startswith("auth "):
                account_name = command[5:].strip()
                if not account_name or account_name.startswith("-"):
                    result = "error: account name required. Usage: op-auth <account-name>"
                else:
                    result = await do_auth(account_name)
            elif command == "show-fuzzel":
                result = await show_fuzzel(browser_mode=False)
            elif command == "show-browser-fuzzel":
                result = await show_fuzzel(browser_mode=True)
            elif command == "refresh":
                await refresh_items()
                result = f"ok: {len(items_cache)} items"
            elif command == "status":
                result = "authenticated" if client else "not authenticated"
            elif command == "quit":
                result = "bye"
                writer.write(result.encode())
                await writer.drain()
                writer.close()
                asyncio.get_event_loop().stop()
                return
            else:
                result = f"error: unknown command: {command}"

            writer.write(result.encode())
            await writer.drain()
        except asyncio.TimeoutError:
            writer.write(b"error: timeout")
            await writer.drain()
        except Exception as e:
            try:
                writer.write(f"error: {e}".encode())
                await writer.drain()
            except Exception:
                pass
        finally:
            writer.close()

    async def main():
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)

        server = await asyncio.start_unix_server(handle_client, path=SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o600)

        notify("Daemon started.", timeout=5000)

        async with server:
            await server.serve_forever()

    if __name__ == "__main__":
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        try:
            asyncio.run(main())
        except KeyboardInterrupt:
            if os.path.exists(SOCKET_PATH):
                os.unlink(SOCKET_PATH)
  '';

  ctl = pkgs.writeShellScriptBin "op-fuzzel-ctl" ''
    set -euo pipefail
    SOCKET="${socketPath}"

    if [ ! -S "$SOCKET" ]; then
      echo "op-fuzzel daemon is not running." >&2
      exit 1
    fi

    CMD="''${1:-status}"
    shift 2>/dev/null || true
    if [ -n "''${*:-}" ]; then
      CMD="$CMD $*"
    fi

    echo -n "$CMD" | ${pkgs.socat}/bin/socat - UNIX-CONNECT:"$SOCKET"
    echo
  '';

  opFuzzel = pkgs.writeShellScriptBin "op-fuzzel" ''
    exec ${ctl}/bin/op-fuzzel-ctl show-fuzzel
  '';

  opFuzzelBrowser = pkgs.writeShellScriptBin "op-fuzzel-browser" ''
    exec ${ctl}/bin/op-fuzzel-ctl show-browser-fuzzel
  '';

  opAuth = pkgs.writeShellScriptBin "op-auth" ''
    exec ${ctl}/bin/op-fuzzel-ctl auth "$@"
  '';

  # Nixpkgs search: fuzzel prompt -> open in browser
  nixSearch = pkgs.writeShellScriptBin "nix-search-fuzzel" ''
    query=$(${pkgs.fuzzel}/bin/fuzzel --dmenu --prompt "nixpkgs: " --width 40 --lines 0 < /dev/null)
    [ -z "$query" ] && exit 0
    exec ${pkgs.xdg-utils}/bin/xdg-open "https://search.nixos.org/packages?channel=unstable&query=$query"
  '';

  # Nixpkgs search from clipboard
  nixSearchClipboard = pkgs.writeShellScriptBin "nix-search-clipboard" ''
    query=$(${pkgs.wl-clipboard}/bin/wl-paste --no-newline 2>/dev/null)
    [ -z "$query" ] && exit 0
    exec ${pkgs.xdg-utils}/bin/xdg-open "https://search.nixos.org/packages?channel=unstable&query=$query"
  '';
in
{
  options.modules.desktop.full.op-fuzzel = {
    enable = lib.mkEnableOption "1Password fuzzel integration";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      daemon
      ctl
      opFuzzel
      opFuzzelBrowser
      opAuth
      nixSearch
      nixSearchClipboard
      pkgs.socat
    ];
  };
}
