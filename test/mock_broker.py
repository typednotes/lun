"""Credential-free wire-contract double. This is not a signature verifier."""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        call = request["call"]
        valid = (self.path == "/v0/egress" and call["kind"] == "connector"
                 and "url" not in call and call["operation"] == "objects.read"
                 and call["resource"] == ["reports", "invoice.json"]
                 and request["orgId"] == "org-1" and call["account"] == "user-1/conn-1")
        if valid:
            result = json.dumps({"resource": call["resource"], "operation": call["operation"]}).encode()
            body = {"status": 200, "headers": {}, "body": result.hex()}
            self.send_response(200)
        else:
            body = {"error": "wire-contract-refused"}
            self.send_response(403)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
