"""Run with python3 -m unittest discover -s tests -p 'test_*.py'.

Render checks require PyYAML, Helm, Kustomize, and decrypted dev TLS fixtures
(disposable certificates are sufficient). Make checks need only Python and Make.
"""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MakeTests(unittest.TestCase):
    def make(self, *args):
        return subprocess.run(
            ["make", "--no-print-directory", *args], cwd=ROOT,
            text=True, capture_output=True,
        )

    def test_environment_selection(self):
        for env in ("dev", "stage", "prod"):
            self.assertEqual(self.make("k8s-validate", f"K8S_ENV={env}").returncode, 0)
        for env in ("", "dev stage", "unknown", "%", "d%"):
            with self.subTest(env=env):
                self.assertNotEqual(self.make("k8s-validate", f"K8S_ENV={env}").returncode, 0)
        with tempfile.TemporaryDirectory() as directory:
            cluster = Path(directory) / "prod-us-east-1-01"
            cluster.mkdir()
            (cluster / "kustomization.yaml").write_text("resources: []\n")
            result = self.make("k8s-validate", f"K8S_CLUSTER_DIR={directory}",
                               f"K8S_ENV={cluster.name}")
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.make("k8s-validate", f"K8S_CLUSTER_PATH={cluster}",
                               "K8S_ENV=custom", "K8S_ENVIRONMENTS=custom")
            self.assertEqual(result.returncode, 0, result.stderr)
            (cluster / "kustomization.yaml").unlink()
            self.assertNotEqual(self.make("k8s-validate", f"K8S_CLUSTER_DIR={directory}",
                                          f"K8S_ENV={cluster.name}").returncode, 0)

    def test_atomic_render(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "render.yaml"
            renderer = Path(directory) / "renderer"
            renderer.write_text('#!/bin/sh\nprintf "new manifest\\n"\nexit "${RENDER_EXIT:-0}"\n')
            renderer.chmod(0o755)
            output.write_text("previous manifest\n")
            args = ("k8s-render", f"K8S_RENDER_FILE={output}", f"K8S_TOOLS_ALIAS={renderer}")
            result = self.make(*args, "RENDER_EXIT=1", "--eval=export RENDER_EXIT")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_text(), "previous manifest\n")
            self.assertEqual(list(Path(directory).glob("render.yaml.*")), [])
            result = self.make(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text(), "new manifest\n")
            self.assertEqual(list(Path(directory).glob("render.yaml.*")), [])


@unittest.skipUnless(shutil.which("kustomize") and shutil.which("helm"),
                     "Kustomize and Helm are required")
class RenderTests(unittest.TestCase):
    def render(self, path):
        import yaml
        result = subprocess.run(
            ["kustomize", "build", str(path), "--enable-helm",
             "--load-restrictor=LoadRestrictionsNone"],
            cwd=ROOT, text=True, capture_output=True, check=True,
        )
        return [obj for obj in yaml.safe_load_all(result.stdout) if obj]

    def test_child_roots_match_aggregate(self):
        def identity(obj):
            meta = obj["metadata"]
            return obj["apiVersion"], obj["kind"], meta.get("namespace", ""), meta["name"]

        for env in ("dev", "stage", "prod"):
            with self.subTest(env=env):
                cluster = ROOT / "clusters" / env
                aggregate = {identity(obj): obj for obj in self.render(cluster)}
                children = {}
                namespaces = set()
                for child in ("controllers", "configs", "apps"):
                    objects = self.render(cluster / child)
                    namespaces.update(obj["metadata"]["name"] for obj in objects
                                      if obj["kind"] == "Namespace")
                    for obj in objects:
                        key = identity(obj)
                        self.assertNotIn(key, children, "Resource has multiple owners")
                        children[key] = obj
                        meta = obj["metadata"]
                        self.assertEqual(meta["labels"]["environment"], env)
                        self.assertEqual(meta["labels"]["app.kubernetes.io/part-of"], "template-k8s")
                        if meta.get("namespace"):
                            self.assertIn(meta["namespace"], namespaces)
                self.assertEqual(aggregate, children)
