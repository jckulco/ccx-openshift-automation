#!/usr/bin/env python3
"""Aplica templates/*.set.json sobre los TOML silent de IBM y los pasa por los validadores pydantic de IBM."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

import toml

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
IBM = os.path.join(ROOT, ".work", "ibm-content-cortex-containers", "scripts")
spec = importlib.util.spec_from_file_location("config_models", os.path.join(IBM, "helper_scripts/utilities/config_models.py"))
m = importlib.util.module_from_spec(spec)
sys.modules["config_models"] = m
spec.loader.exec_module(m)

SUBST = {"@NS@": "ibm-content", "@ENTITLEMENT_KEY@": "A" * 120, "@LICENSE_METRIC@": "CCx.Pre.AU",
         "@IDP_DISCOVERY_URL@": "https://kc.example.com/realms/ccx/.well-known/openid-configuration",
         "@BLOCK_SC@": "ocs-storagecluster-ceph-rbd"}
cases = [("silent_install_deployoperator", m.validate_deploy_operator_config),
         ("silent_install_prerequisites", m.validate_prerequisites_config)]
bad = 0
for name, fn in cases:
    tmp = tempfile.mkdtemp()
    dst = os.path.join(tmp, name + ".toml")
    shutil.copy(os.path.join(IBM, "silent_config", name + ".toml"), dst)
    spec_txt = open(os.path.join(ROOT, "templates", name + ".set.json")).read()
    for k, v in SUBST.items():
        spec_txt = spec_txt.replace(k, v)
    json.loads(spec_txt)
    subprocess.run([sys.executable, os.path.join(ROOT, "tools", "toml_set.py"), dst, "-"], input=spec_txt, text=True, check=True)
    ok, _cfg, errs = fn(toml.load(dst))
    print(name, "OK" if ok else "ERRORES: %s" % errs)
    bad += 0 if ok else 1
sys.exit(1 if bad else 0)
