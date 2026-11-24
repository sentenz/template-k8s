"""Add an isolated CoreDNS server block. Preserve concurrent and unrelated edits."""
import json
import subprocess
import sys

context, action, address, *hosts = sys.argv[1:]
kubectl = ["kubectl", "--context", context, "-n", "kube-system"]
cm = json.loads(subprocess.check_output(kubectl + ["get", "cm", "coredns", "-o", "json"]))
old = cm["data"]["Corefile"]
begin, end = "# BEGIN template-k8s sigstore\n", "# END template-k8s sigstore\n"
base = old
if begin in old:
    before, after = old.split(begin)
    _, after = after.split(end)
    base = before + after
block = ""
if action == "install":
    if any(h in base for h in hosts):
        sys.exit("Existing DNS configuration mentions a requested host. Configure DNS externally.")
    block = begin + " ".join(hosts) + " {\n    hosts {\n        " + address + " " + " ".join(hosts)
    block += "\n        ttl 30\n    }\n}\n" + end
new = block + base
if new != old:
    patch = [{"op": "test", "path": "/data/Corefile", "value": old},
             {"op": "replace", "path": "/data/Corefile", "value": new}]
    subprocess.run(kubectl + ["patch", "cm", "coredns", "--type=json", "-p", json.dumps(patch)], check=True)
