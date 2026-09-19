#!/usr/bin/env python3
"""Call one bound Symphony MCP request. Descriptor carries no Linear credentials."""
import json
import socket
import sys


def call(descriptor, request):
    with open(descriptor, encoding="utf-8") as stream:
        binding = json.load(stream)
    with socket.create_connection(("127.0.0.1", binding["port"]), timeout=60) as client:
        client.sendall((json.dumps({"token": binding["token"], "request": request}) + "\n").encode())
        with client.makefile("rb") as response:
            return json.loads(response.readline(1_048_577))


if __name__ == "__main__":
    try:
        print(json.dumps(call(sys.argv[1], json.load(sys.stdin)), ensure_ascii=False))
    except (OSError, ValueError, KeyError, IndexError):
        print(json.dumps({"error": "Symphony tool binding unavailable"}))
        sys.exit(1)
