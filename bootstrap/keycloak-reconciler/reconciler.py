#!/usr/bin/env python3
"""
Keycloak Reconciler
Reads declarative spec.json, calls Keycloak Admin REST API to ensure
groups, clients, and mappers exist. Pushes non-public client secrets to Vault.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
KC_URL = os.environ["KEYCLOAK_ADMIN_URL"]
KC_REALM = os.environ.get("KEYCLOAK_REALM", "platform")
KC_ADMIN_USER = os.environ["KEYCLOAK_ADMIN_USER"]
KC_ADMIN_PASS = os.environ["KEYCLOAK_ADMIN_PASSWORD"]
VAULT_ADDR = os.environ.get("VAULT_ADDR", "http://vault-active.vault:8200")
VAULT_TOKEN = os.environ.get("VAULT_ADMIN_TOKEN", "")

BASE = f"{KC_URL}/admin/realms/{KC_REALM}"

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def hdrs(token: str) -> dict:
    return {"Content-Type": "application/json", "Authorization": f"Bearer {token}"}

def get(path: str, token: str):
    url = path if path.startswith("http") else f"{KC_URL}{path}"
    req = urllib.request.Request(url, headers=hdrs(token))
    try:
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        print(f"  [W] GET {path} -> {e.code}")
        return None

def post(path: str, body: dict | list, token: str) -> str | None:
    url = path if path.startswith("http") else f"{KC_URL}{path}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=hdrs(token), method="POST"
    )
    try:
        with urllib.request.urlopen(req) as r:
            loc = r.headers.get("Location", "")
            return loc.split("/")[-1]
    except urllib.error.HTTPError as e:
        print(f"  [W] POST {path} -> {e.code}")
        return None

def post_raw(path: str, body: dict | list, token: str) -> bytes | None:
    url = path if path.startswith("http") else f"{KC_URL}{path}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=hdrs(token), method="POST"
    )
    try:
        with urllib.request.urlopen(req) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        print(f"  [W] POST_raw {path} -> {e.code}")
        return None

def put(path: str, body: list | dict, token: str) -> bool:
    url = path if path.startswith("http") else f"{KC_URL}{path}"
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=hdrs(token), method="PUT"
    )
    try:
        with urllib.request.urlopen(req):
            return True
    except urllib.error.HTTPError as e:
        print(f"  [W] PUT {path} -> {e.code}")
        return False

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def get_token() -> str:
    url = f"{KC_URL}/realms/master/protocol/openid-connect/token"
    payload = (
        f"client_id=admin-cli&"
        f"username={urllib.parse.quote(KC_ADMIN_USER)}&"
        f"password={urllib.parse.quote(KC_ADMIN_PASS)}&"
        "grant_type=password"
    )
    req = urllib.request.Request(
        url, data=payload.encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"}, method="POST"
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["access_token"]

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

def find_group(token: str, name: str, parent_id: str | None = None) -> str | None:
    """Find group by name (and optional parentId). Return first matching id."""
    groups = get(f"{BASE}/groups", token) or []
    for g in groups:
        if g["name"] == name:
            if parent_id is None or g.get("parentId") == parent_id:
                return g["id"]
    # Search sub-groups recursively
    for g in groups:
        if g.get("subGroups"):
            for sg in g["subGroups"]:
                if sg["name"] == name and (parent_id is None or sg.get("id") == parent_id or g.get("id") == parent_id):
                    return sg["id"]
    return None

def ensure_group(token: str, grp: dict, parent_id: str | None = None) -> str | None:
    name = grp["name"]
    gid = find_group(token, name, parent_id)
    if gid:
        print(f"[GROUP] {grp['path']} exists (id={gid[:8]}...)")
    else:
        body = {"name": name}
        if parent_id:
            req_path = f"{BASE}/groups/{parent_id}/children"
        else:
            req_path = f"{BASE}/groups"
        gid = post(req_path, body, token)
        if gid:
            print(f"[GROUP] created {grp['path']} (id={gid[:8]}...)")
        else:
            print(f"[GROUP] FAILED {grp['path']}")
            return None
    if gid:
        assign_group_roles(token, gid, grp.get("realmRoles", []))
        for sg in grp.get("subGroups", []):
            ensure_group(token, sg, gid)
    return gid

def assign_group_roles(token: str, group_id: str, desired: list[str]):
    assigned = get(f"{BASE}/groups/{group_id}/roles/realm-mapping/assigned", token) or []
    assigned_names = {r["name"] for r in assigned}
    for role in desired:
        if role not in assigned_names:
            available = get(f"{BASE}/groups/{group_id}/roles/realm-mapping/available", token) or []
            role_obj = next((r for r in available if r["name"] == role), None)
            if role_obj:
                post_raw(f"{BASE}/groups/{group_id}/roles/realm-mapping", [role_obj], token)
                print(f"  assigned role {role}")

# ---------------------------------------------------------------------------
# Clients
# ---------------------------------------------------------------------------

def find_client(token: str, client_id: str) -> str | None:
    clients = get(f"{BASE}/clients", token) or []
    for c in clients:
        if c["clientId"] == client_id:
            return c["id"]
    return None

def ensure_client(token: str, cli: dict) -> tuple[str | None, bool]:
    """Returns (client_id, was_created)."""
    cid = cli["clientId"]
    existing_id = find_client(token, cid)
    body = {
        "clientId": cid,
        "publicClient": cli.get("publicClient", True),
        "standardFlowEnabled": cli.get("standardFlowEnabled", True),
        "directAccessGrantsEnabled": cli.get("directAccessGrantsEnabled", False),
        "serviceAccountsEnabled": cli.get("serviceAccountsEnabled", False),
        "redirectUris": cli.get("redirectUris", []),
        "webOrigins": cli.get("webOrigins", ["*"]),
    }
    if existing_id:
        print(f"[CLIENT] {cid} exists (id={existing_id[:8]}...)")
        put(f"{BASE}/clients/{existing_id}", body, token)
        cli_id = existing_id
        was_created = False
    else:
        cli_id = post(f"{BASE}/clients", body, token)
        was_created = True
        if cli_id:
            print(f"[CLIENT] created {cid} (id={cli_id[:8]}...)")
    # Assign default client scopes
    if cli_id and cli.get("defaultClientScopes"):
        all_scopes = get(f"{BASE}/client-scopes", token) or []
        scope_ids = [s["id"] for s in all_scopes if s["name"] in cli["defaultClientScopes"]]
        if scope_ids:
            if put(f"{BASE}/clients/{cli_id}/default-client-scopes", scope_ids, token):
                print(f"  assigned default scopes: {cli['defaultClientScopes']}")
    return cli_id, was_created

# ---------------------------------------------------------------------------
# Vault
# ---------------------------------------------------------------------------

def push_to_vault(key: str, value: str):
    """Push a key-value pair to Vault KVv2."""
    if not VAULT_TOKEN:
        print(f"  [VAULT] skipping {key} (no token)")
        return
    payload = json.dumps({"data": {key: value}}).encode()
    req = urllib.request.Request(
        f"{VAULT_ADDR}/v1/secret/data/keycloak",
        data=payload,
        headers={"X-Vault-Token": VAULT_TOKEN, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as r:
            print(f"  [VAULT] pushed {key} -> {r.status}")
    except urllib.error.HTTPError as e:
        # If conflict (no cas), retry without cas
        print(f"  [VAULT] error pushing {key}: {e.code}")

def push_client_secret(token: str, cli_id: str, vault_key: str, was_created: bool):
    if not was_created:
        print(f"  [VAULT] skip existing client (no rotation)")
        return
    raw = post_raw(f"{BASE}/clients/{cli_id}/client-secret", {}, token)
    if raw:
        secret_val = json.loads(raw).get("value", "")
        if secret_val:
            push_to_vault(vault_key, secret_val)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    with open("/spec/spec.json") as f:
        spec = json.load(f)

    token = get_token()
    print(f"[OK] Authenticated to Keycloak ({KC_REALM})")

    for grp in spec.get("groups", []):
        ensure_group(token, grp)

    for cli in spec.get("clients", []):
        cli_id, was_created = ensure_client(token, cli)
        if cli_id and not cli.get("publicClient", True) and cli.get("vaultSecretKey"):
            push_client_secret(token, cli_id, cli["vaultSecretKey"], was_created)

    print("[OK] Reconciliation complete")

if __name__ == "__main__":
    main()
