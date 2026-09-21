#!/usr/bin/env python3
"""queue-site-command.py — queue a command for one of your Fin sites, by hand.

Sites have no inbound path by design (docs/SITES.md): the only way to reach one is
to leave it a command in `fin-sites.commands`, which it drains on its next
heartbeat (worst case ~20s later). `POST /sites/{id}/commands` does exactly this
over the API, gated on the caller's own user auth — this script does the same
write directly against DynamoDB with an AWS admin profile instead, for exactly the
case that endpoint can't help with: an operator at a terminal, not the app.

    queue-site-command.py <siteId> restart
    queue-site-command.py <siteId> update
    queue-site-command.py <siteId> stop
    queue-site-command.py <siteId> drain
    queue-site-command.py --list                 # show every site's id, name, state
"""
import argparse
import datetime
import json
import sys
import uuid

import boto3
from botocore.exceptions import ClientError

TABLE = "fin-sites"
VALID_KINDS = ("restart", "update", "stop", "drain")


def _now_iso():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def list_sites(ddb):
    paginator = ddb.get_paginator("scan")
    rows = []
    for page in paginator.paginate(TableName=TABLE):
        rows.extend(page.get("Items", []))
    rows.sort(key=lambda r: r.get("displayName", {}).get("S", ""))
    for row in rows:
        print("{id}  {name:<28} {state:<10} last beat {beat}".format(
            id=row["siteId"]["S"],
            name=row.get("displayName", {}).get("S", "?"),
            state=row.get("state", {}).get("S", "?"),
            beat=row.get("lastHeartbeatAt", {}).get("S", "never"),
        ))


def queue_command(ddb, site_id, kind, args_json):
    args = json.loads(args_json) if args_json else {}
    for attempt in range(5):
        try:
            item = ddb.get_item(TableName=TABLE, Key={"siteId": {"S": site_id}})["Item"]
        except KeyError:
            sys.exit(f"no such site: {site_id}")
        rev = int(item["rev"]["N"])
        pending = item.get("commands", {"L": []})["L"]
        command = {
            "M": {
                "id": {"S": "c-" + str(uuid.uuid4())},
                "kind": {"S": kind},
                "args": {"M": {k: {"S": str(v)} for k, v in args.items()}},
                "queuedAt": {"S": _now_iso()},
            }
        }
        try:
            ddb.update_item(
                TableName=TABLE,
                Key={"siteId": {"S": site_id}},
                UpdateExpression="SET commands = :c, rev = :next",
                ConditionExpression="rev = :rev",
                ExpressionAttributeValues={
                    ":c": {"L": pending + [command]},
                    ":rev": {"N": str(rev)},
                    ":next": {"N": str(rev + 1)},
                },
            )
            name = item.get("displayName", {}).get("S", site_id)
            print(f"queued {kind!r} for {name} ({site_id}) — rev {rev} -> {rev + 1}, "
                  f"delivered on its next heartbeat (~20s)")
            return
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") != "ConditionalCheckFailedException":
                raise
            continue  # another writer won the race; re-read and retry
    sys.exit("gave up after 5 retries — the site row keeps changing underneath this write")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("site_id", nargs="?", help="the site's siteId (see --list)")
    parser.add_argument("kind", nargs="?", choices=VALID_KINDS, help="command to queue")
    parser.add_argument("--args", help="JSON object of extra args for the command", default=None)
    parser.add_argument("--profile", default="levi", help="AWS profile (default: levi)")
    parser.add_argument("--list", action="store_true", help="list every site instead of queuing a command")
    parsed = parser.parse_args()

    ddb = boto3.Session(profile_name=parsed.profile).client("dynamodb", region_name="us-west-2")

    if parsed.list:
        list_sites(ddb)
        return
    if not parsed.site_id or not parsed.kind:
        parser.error("site_id and kind are required unless --list is given")
    queue_command(ddb, parsed.site_id, parsed.kind, parsed.args)


if __name__ == "__main__":
    main()
