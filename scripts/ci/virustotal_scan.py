#!/usr/bin/env python3
"""Uploads a file to VirusTotal and writes what VirusTotal reports to a Markdown file.

Used by the release workflow, and only when the repository has a VT_API_KEY secret. It reports
exactly what VirusTotal returns (how many vendors flagged the file); it never writes a "clean"
claim of its own. If anything goes wrong it writes nothing and exits 0, so a VirusTotal outage
cannot block a release.

Usage: virustotal_scan.py <file> <output.md>      (API key in the VT_API_KEY environment variable)
"""
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

API = "https://www.virustotal.com/api/v3"


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def multipart(path):
    boundary = uuid.uuid4().hex
    name = os.path.basename(path)
    with open(path, "rb") as handle:
        content = handle.read()
    head = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{name}"\r\n'
        "Content-Type: application/octet-stream\r\n\r\n"
    ).encode()
    tail = f"\r\n--{boundary}--\r\n".encode()
    return boundary, head + content + tail


def call(url, key, data=None, content_type=None):
    request = urllib.request.Request(url, data=data, headers={"x-apikey": key})
    if content_type:
        request.add_header("Content-Type", content_type)
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def summarize(stats, sha256, filename):
    """Turns VirusTotal's counts into one honest sentence plus a link to the full report."""
    malicious = int(stats.get("malicious", 0))
    suspicious = int(stats.get("suspicious", 0))
    checked = sum(int(stats.get(k, 0)) for k in ("malicious", "suspicious", "undetected", "harmless"))
    link = f"https://www.virustotal.com/gui/file/{sha256}"
    line = (
        f"**VirusTotal scan of `{filename}`:** {malicious} of {checked} security vendors flagged it as "
        f"malicious and {suspicious} as suspicious. [Full report]({link}). "
        f"SHA-256: `{sha256}`."
    )
    if malicious or suspicious:
        line += (
            " Flags on a program that records keyboard and mouse input can be false positives, "
            "but read the report before running it."
        )
    return line


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 0
    path, output = sys.argv[1], sys.argv[2]
    key = os.environ.get("VT_API_KEY", "")
    if not key:
        print("VT_API_KEY not set; skipping.")
        return 0
    try:
        sha256 = sha256_of(path)
        boundary, body = multipart(path)
        upload = call(f"{API}/files", key, body, f"multipart/form-data; boundary={boundary}")
        analysis_id = upload["data"]["id"]
        for attempt in range(40):
            time.sleep(15)
            result = call(f"{API}/analyses/{analysis_id}", key)
            attributes = result["data"]["attributes"]
            print(f"attempt {attempt + 1}: status {attributes.get('status')}")
            if attributes.get("status") == "completed":
                with open(output, "w") as handle:
                    handle.write(summarize(attributes["stats"], sha256, os.path.basename(path)) + "\n")
                print(open(output).read())
                return 0
        print("VirusTotal did not finish in time; no result written.")
    except (urllib.error.URLError, KeyError, ValueError, OSError) as error:
        print(f"VirusTotal step failed ({error}); no result written.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
