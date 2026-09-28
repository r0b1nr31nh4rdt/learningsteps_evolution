#!/usr/bin/env python3
"""Fills an empty LearningSteps database with 5 demo entries (fixed ones plus random ones).

Runs against the public API, not the database: the database is only
reachable from inside the VNet, the API from anywhere (laptop, pipeline).
If the API already returns entries, nothing is changed, so the script can run
after every deployment. After terraform destroy + apply the database is empty
and gets demo data again.

Usage:
    python3 scripts/seed_demo_data.py http://<ingress-ip>
    API_URL=http://<ingress-ip> python3 scripts/seed_demo_data.py

Only the Python standard library is used, so it runs on any CI runner.
"""
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

NUMBER_OF_ENTRIES = 5
WAIT_FOR_API_SECONDS = 180

# Always created, so they survive every rebuild of the database.
PINNED_ENTRIES = [
    ("Completed the K8s LAN Party (Wiz) Kubernetes security CTF: https://k8slanparty.com/certificate/VAUi7WX3",
     "Thinking like an attacker inside a cluster: DNS recon, reaching other pods, getting around network boundaries",
     "Check my own NetworkPolicies against what I learned and switch AKS to Entra ID"),
]

# Pool of demo entries; the rest up to NUMBER_OF_ENTRIES is picked at random.
DEMO_ENTRIES = [
    ("Wrote the Terraform files for VNet, AKS, PostgreSQL and Key Vault",
     "PostgreSQL Flexible Server was blocked in my first region",
     "Check SKU availability before choosing a region"),
    ("Containerized the FastAPI app and pushed the image to ACR",
     "The image built on an ARM Mac did not run on the amd64 nodes",
     "Build with --platform linux/amd64"),
    ("Connected the pods to Key Vault with workload identity",
     "Understanding how a ServiceAccount becomes an Azure identity",
     "Turn off the API token automount on all ServiceAccounts"),
    ("Deployed the API to AKS behind the NGINX ingress",
     "kubectl said 'no such host' because the cluster was stopped",
     "Check the power state before debugging DNS"),
    ("Added NetworkPolicies with default deny",
     "Forgot DNS at first, so the database name could not be resolved",
     "Allow Prometheus to scrape the metrics port"),
    ("Load-tested the API and watched the HPA scale",
     "Pods stayed Pending because the nodes were full",
     "Enable the cluster autoscaler"),
    ("Replaced the per-request connection pool with one pool per pod",
     "The database ran out of connections under load",
     "Move the pool size into a ConfigMap"),
    ("Learned the difference between PUT and PATCH",
     "The PATCH endpoint required all fields",
     "Merge partial updates with the stored entry"),
    ("Practiced PostgreSQL JSONB queries",
     "Indexing JSON fields for fast searches",
     "Try a GIN index on a larger data set"),
    ("Set up gitleaks as a pre-commit hook",
     "Deciding which findings are false positives",
     "Run secret scanning in the pipeline as well"),
    ("Scanned the Terraform code with Trivy",
     "Two critical findings conflict with the pipeline's access",
     "Document the accepted risks with a reason"),
    ("Read about the Twelve-Factor App",
     "Where to draw the line between config and code",
     "Keep all environment-specific values out of the image"),
    ("Explored kubectl describe and events for debugging",
     "Reading scheduler messages like 'Insufficient cpu'",
     "Practice troubleshooting a CrashLoopBackOff"),
    ("Studied Azure RBAC roles for Key Vault",
     "Role assignments take a few minutes to become active",
     "Scope roles to single secrets where possible"),
    ("Wrote a Kubernetes Job for the database schema",
     "A Job cannot be changed after it has been created",
     "Automate the schema job in the pipeline"),
]


def request(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)


def wait_for_api(base_url):
    """Right after a deployment the ingress IP or the pods may not be ready yet."""
    deadline = time.time() + WAIT_FOR_API_SECONDS
    while True:
        try:
            request("GET", f"{base_url}/health")
            return
        except (urllib.error.URLError, OSError) as error:
            if time.time() > deadline:
                sys.exit(f"API not reachable at {base_url} after {WAIT_FOR_API_SECONDS}s: {error}")
            print(f"Waiting for {base_url} ...")
            time.sleep(5)


def main():
    base_url = (sys.argv[1] if len(sys.argv) > 1 else os.getenv("API_URL", "")).rstrip("/")
    if not base_url:
        sys.exit(__doc__)

    wait_for_api(base_url)

    count = request("GET", f"{base_url}/entries")["count"]
    if count > 0:
        print(f"Database already has {count} entries, nothing to seed.")
        return

    entries = PINNED_ENTRIES + random.sample(DEMO_ENTRIES, NUMBER_OF_ENTRIES - len(PINNED_ENTRIES))
    print(f"Database is empty, creating {len(entries)} demo entries:")
    for work, struggle, intention in entries:
        entry = request("POST", f"{base_url}/entries",
                        {"work": work, "struggle": struggle, "intention": intention})["entry"]
        print(f"  {entry['id']}  {work}")


if __name__ == "__main__":
    main()
