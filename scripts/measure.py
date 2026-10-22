import json, re, subprocess, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
forge = pathlib.Path.home() / "workspace/projects/rebuilds/.foundry/forge"
proc = subprocess.run([str(forge), "test"], cwd=root, capture_output=True, text=True)
out = proc.stdout
(root / "outputs" / "run_log.txt").write_text(out)
passed = len(re.findall(r"\[PASS\]", out))
failed = len(re.findall(r"\[FAIL", out))
metrics = {
    "repo": "cross-chain-bridge",
    "toolchain": "forge 1.0.0, solc 0.8.24, local EVM (forge test), mock endpoint and mock tokens",
    "tests_total": passed + failed,
    "tests_passed": passed,
    "tests_failed": failed,
    "round_trip": "lock 100 tokens on source bridge, deliver, 100 wrapped minted to receiver",
    "replay_test": "delivering the same message twice reverts on the nonce check; balance stays at the first mint",
    "note": "Two bridge instances on one local EVM stand in for two chains. No real LayerZero endpoint, no deployment, no cross chain timing measured.",
}
(root / "outputs" / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
print(json.dumps(metrics, indent=2))
sys.exit(0 if failed == 0 else 1)
