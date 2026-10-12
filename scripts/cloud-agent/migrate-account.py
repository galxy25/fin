#!/usr/bin/env python3
"""migrate-account.py — copy Fin's stateful data from one AWS account to another.

The blue/green move in docs/aws-migration-plan.md: the live (blue) stack keeps
running untouched while its data is copied into the green account, and the same
command run again at cutover (with the control plane quiesced) makes green an
exact replica. Every step is idempotent and read-only on the source side.

    migrate-account.py s3        [--delete]   agent + model-factory buckets
    migrate-account.py legal     [--delete]   the privacy/terms/support pages
    migrate-account.py dynamodb  [--delete]   every fin-* table
    migrate-account.py secrets                fin/service-creds secrets (values never printed)
    migrate-account.py all       [--delete]

--delete also removes destination objects/items/keys absent from the source, so
the final pass leaves green equal to blue rather than a superset of it.

Profiles: FIN_SRC_PROFILE (default levi), FIN_DST_PROFILE (default llc). Bucket
names follow the account id, as control-plane/deploy.sh derives them. The
destination tables must already exist (deploy.sh creates them).
"""
import argparse
import os
import sys

import boto3
from botocore.exceptions import ClientError

REGION = "us-west-2"
LEGAL_REGION = "us-east-1"
TABLES = (
    "fin-agents", "fin-cloud-workers", "fin-device-tokens", "fin-enroll-tokens",
    "fin-messages", "fin-relay-workers", "fin-sessions", "fin-sites",
    "fin-thread-events", "fin-users",
)
SECRET_PREFIXES = ("fin/service-creds/", "users/")
LEGAL_BUCKETS = {"011183829623": "fin-africanintellect-legal"}


def account(session):
    return session.client("sts").get_caller_identity()["Account"]


def legal_bucket(acct):
    return LEGAL_BUCKETS.get(acct, "fin-legal-{}".format(acct))


def ensure_bucket(s3, bucket, region):
    try:
        s3.head_bucket(Bucket=bucket)
        return
    except ClientError:
        pass
    kwargs = {"Bucket": bucket}
    if region != "us-east-1":
        kwargs["CreateBucketConfiguration"] = {"LocationConstraint": region}
    s3.create_bucket(**kwargs)
    s3.put_public_access_block(Bucket=bucket, PublicAccessBlockConfiguration={
        "BlockPublicAcls": True, "IgnorePublicAcls": True,
        "BlockPublicPolicy": True, "RestrictPublicBuckets": True,
    })
    print("created bucket {}".format(bucket))


def listing(s3, bucket):
    out = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            out[obj["Key"]] = (obj["Size"], obj["ETag"])
    return out


def copy_bucket(src_s3, dst_s3, src_bucket, dst_bucket, region, delete):
    """Streams each object through this machine (no cross-account grant on the
    source, so blue's policies never change), keeping Content-Type and user
    metadata. Skips keys whose size and ETag already match: single-part ETags
    are content MD5s, and anything this script uploaded is single-part."""
    ensure_bucket(dst_s3, dst_bucket, region)
    src = listing(src_s3, src_bucket)
    dst = listing(dst_s3, dst_bucket)
    copied = skipped = 0
    for key, (size, etag) in sorted(src.items()):
        if dst.get(key) == (size, etag):
            skipped += 1
            continue
        obj = src_s3.get_object(Bucket=src_bucket, Key=key)
        put = {"Bucket": dst_bucket, "Key": key, "Body": obj["Body"].read(),
               "Metadata": obj.get("Metadata", {})}
        for field in ("ContentType", "CacheControl", "ContentEncoding", "ContentDisposition"):
            if obj.get(field):
                put[field] = obj[field]
        dst_s3.put_object(**put)
        copied += 1
    removed = 0
    if delete:
        for key in sorted(set(dst) - set(src)):
            dst_s3.delete_object(Bucket=dst_bucket, Key=key)
            removed += 1
    print("{} -> {}: {} copied, {} unchanged, {} removed".format(
        src_bucket, dst_bucket, copied, skipped, removed))


def do_s3(src, dst, delete):
    src_acct, dst_acct = account(src), account(dst)
    src_s3, dst_s3 = src.client("s3", region_name=REGION), dst.client("s3", region_name=REGION)
    for stem in ("fin-agent-directives-", "fin-model-factory-"):
        copy_bucket(src_s3, dst_s3, stem + src_acct, stem + dst_acct, REGION, delete)


def do_legal(src, dst, delete):
    src_acct, dst_acct = account(src), account(dst)
    copy_bucket(src.client("s3", region_name=LEGAL_REGION), dst.client("s3", region_name=LEGAL_REGION),
                legal_bucket(src_acct), legal_bucket(dst_acct), LEGAL_REGION, delete)


def key_of(table_desc):
    return [k["AttributeName"] for k in table_desc["KeySchema"]]


def do_dynamodb(src, dst, delete):
    src_ddb, dst_ddb = src.client("dynamodb", region_name=REGION), dst.client("dynamodb", region_name=REGION)
    for table in TABLES:
        keys = key_of(dst_ddb.describe_table(TableName=table)["Table"])
        items = [i for p in src_ddb.get_paginator("scan").paginate(TableName=table, ConsistentRead=True)
                 for i in p.get("Items", [])]
        # Raw attribute-value maps through the low-level client keep N/S/B/L/M exactly.
        for start in range(0, len(items), 25):
            batch = {table: [{"PutRequest": {"Item": i}} for i in items[start:start + 25]]}
            while batch:
                batch = dst_ddb.batch_write_item(RequestItems=batch).get("UnprocessedItems") or None
        removed = 0
        if delete:
            have = {tuple(repr(i[k]) for k in keys) for i in items}
            for page in dst_ddb.get_paginator("scan").paginate(TableName=table, ProjectionExpression=", ".join("#k{}".format(n) for n in range(len(keys))),
                                                              ExpressionAttributeNames={"#k{}".format(n): k for n, k in enumerate(keys)}):
                for i in page.get("Items", []):
                    if tuple(repr(i[k]) for k in keys) not in have:
                        dst_ddb.delete_item(TableName=table, Key={k: i[k] for k in keys})
                        removed += 1
        print("{}: {} items written, {} removed".format(table, len(items), removed))


def do_secrets(src, dst):
    src_sm, dst_sm = src.client("secretsmanager", region_name=REGION), dst.client("secretsmanager", region_name=REGION)
    for page in src_sm.get_paginator("list_secrets").paginate():
        for meta in page["SecretList"]:
            name = meta["Name"]
            meta = src_sm.describe_secret(SecretId=name)  # list_secrets can omit Description
            if not name.startswith(SECRET_PREFIXES) or "/fin/service-creds/" not in "/" + name:
                continue
            value = src_sm.get_secret_value(SecretId=name)
            payload = {"SecretString": value["SecretString"]} if "SecretString" in value else {"SecretBinary": value["SecretBinary"]}
            try:
                dst_sm.create_secret(Name=name, Tags=meta.get("Tags", []),
                                     Description=meta.get("Description", ""), **payload)
                print("{}: created".format(name))
            except ClientError as error:
                if error.response["Error"]["Code"] != "ResourceExistsException":
                    raise
                dst_sm.put_secret_value(SecretId=name, **payload)
                # GET /secrets shows the description as the app's label.
                dst_sm.update_secret(SecretId=name, Description=meta.get("Description", ""))
                print("{}: updated".format(name))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("what", choices=("s3", "legal", "dynamodb", "secrets", "all"))
    parser.add_argument("--delete", action="store_true")
    args = parser.parse_args()
    src = boto3.Session(profile_name=os.environ.get("FIN_SRC_PROFILE", "levi"))
    dst = boto3.Session(profile_name=os.environ.get("FIN_DST_PROFILE", "llc"))
    if account(src) == account(dst):
        sys.exit("source and destination are the same account")
    if args.what in ("s3", "all"):
        do_s3(src, dst, args.delete)
    if args.what in ("legal", "all"):
        do_legal(src, dst, args.delete)
    if args.what in ("dynamodb", "all"):
        do_dynamodb(src, dst, args.delete)
    if args.what in ("secrets", "all"):
        do_secrets(src, dst)


if __name__ == "__main__":
    main()
