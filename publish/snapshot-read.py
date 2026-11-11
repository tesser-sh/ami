#!/usr/bin/env python3
"""Reads an EBS snapshot into a sparse raw file with the EBS direct API.
usage: snapshot-read.py <region> <snapshot id> <out file>"""
import base64, hashlib, os, sys
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

region, snapshot, out = sys.argv[1:4]
ebs = boto3.client("ebs", region_name=region, config=Config(max_pool_connections=64, retries={"max_attempts": 10, "mode": "adaptive"}))

blocks, size, block_size, token = [], 0, 0, None
while True:
    page = ebs.list_snapshot_blocks(SnapshotId=snapshot, **({"NextToken": token} if token else {}))
    blocks += [(b["BlockIndex"], b["BlockToken"]) for b in page["Blocks"]]
    size, block_size, token = page["VolumeSize"], page["BlockSize"], page.get("NextToken")
    if not token:
        break

fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.ftruncate(fd, size * 2**30)

def fetch(block):
    index, block_token = block
    got = ebs.get_snapshot_block(SnapshotId=snapshot, BlockIndex=index, BlockToken=block_token)
    data = got["BlockData"].read()
    if got["ChecksumAlgorithm"] != "SHA256" or base64.b64encode(hashlib.sha256(data).digest()).decode() != got["Checksum"]:
        raise SystemExit(f"{snapshot} block {index}: checksum mismatch")
    if any(data):
        os.pwrite(fd, data, index * block_size)
    return len(data)

with ThreadPoolExecutor(32) as pool:
    read = sum(pool.map(fetch, blocks))
os.fsync(fd)
os.close(fd)
print(f"snapshot-read: {snapshot} {size} GiB, {len(blocks)} blocks of {block_size} bytes, {read} bytes read")
