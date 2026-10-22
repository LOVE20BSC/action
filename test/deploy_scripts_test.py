#!/usr/bin/env python3
"""Deployment regression checks with isolated configs and fake RPC/signing tools."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


# 敏感值哨兵：任何一步把它们写进 stdout/stderr 都视为回归。
SECRET_KEY = "do-not-print-this-key"
SECRET_PASSWORD = "do-not-print-this-password"


def fake_tool(tool, args):
    data = json.loads(Path(os.environ["MOCK_DATA"]).read_text())
    with Path(os.environ["MOCK_LOG"]).open("a") as log:
        log.write(json.dumps([tool, *args] + [f"env:{k}={os.environ.get(k)}" for k in
                                              ("MINT_ADDRESS", "STAKE_ADDRESS", "GROUP_ACTION_SPLITS")]) + "\n")
    if tool == "osascript":
        print("test-password")
    elif tool == "cast":
        if args[0] == "chain-id":
            print(os.environ.get("RPC_CHAIN", data["env"]["CHAIN_ID"]))
        elif args[0] == "code":
            if os.environ.get("RPC_CODE_ERROR"):
                return 1
            print("0x01")
        elif args[0] == "call":
            key = args[1].lower() + "/" + args[2]
            print(os.environ.get("BAD_VALUE", "ERROR") if key == os.environ.get("BAD_CALL") else data["calls"][key])
        else:
            raise AssertionError(args)
    elif args[0] == "script":
        if os.environ.get("DEPLOY_FAIL"):
            return 1
        for key, value in data["env"].items():
            if key in data["contracts"] and key != os.environ.get("OMIT_ADDRESS"):
                print(key + "= " + value)
    elif args[0] == "verify-contract":
        if os.environ.get("VERIFY_FAIL") == args[2]:
            return 1
    else:
        raise AssertionError(args)
    return 0


def main():
    action = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="action-deploy-test-") as directory:
        root = Path(directory)
        deploy = root / "script/deploy"
        shutil.copytree(action / "script/deploy", deploy)
        network = root / "script/network/test"
        network.mkdir(parents=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("cast", "forge", "osascript"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)
        names = ["ACTION_TARGET", "LP_EXECUTOR", "GROUP_ACTION_EXECUTOR", "GROUP_SERVICE_EXECUTOR"]
        env = {name + "_ADDRESS": f"0x{index + 10:040x}" for index, name in enumerate(names)}
        contracts = list(env)
        env.update({"CHAIN_ID": "97", "RPC_URL": "http://invalid.local", "ETHERSCAN_API_KEY": "test-key",
                    "MINT_ADDRESS": "0x" + "ab" * 20, "STAKE_ADDRESS": "0x" + "cd" * 20,
                    "VOTE_ADDRESS": "0x" + "12" * 20, "SUBMIT_ADDRESS": "0x" + "34" * 20,
                    "MEMBER_NFT_ADDRESS": "0x" + "56" * 20, "PHASE_ADDRESS": "0x" + "78" * 20,
                    "GROUP_ACTION_SPLITS": "100000000000000000,400000000000000000,700000000000000000"})
        calls = {}

        def getters(contract, fields):
            for signature, value in fields.items():
                calls[env[contract + "_ADDRESS"].lower() + "/" + signature] = env.get(value, value)

        getters("ACTION_TARGET", {"initialized()(bool)": "true", "mintAddress()(address)": "MINT_ADDRESS",
                "voteAddress()(address)": "VOTE_ADDRESS", "submitAddress()(address)": "SUBMIT_ADDRESS",
                "memberNFTAddress()(address)": "MEMBER_NFT_ADDRESS", "phaseAddress()(address)": "PHASE_ADDRESS"})
        for name in ("LP_EXECUTOR", "GROUP_ACTION_EXECUTOR", "GROUP_SERVICE_EXECUTOR"):
            getters(name, {"initialized()(bool)": "true", "actionTarget()(address)": "ACTION_TARGET_ADDRESS"})
        # cast 的数组返回逐元素带科学计数法标注；21_check.sh 的 strip_sci_notation 会归一化。
        getters("GROUP_ACTION_EXECUTOR", {"SPLITS()(uint256[])":
                "[100000000000000000 [1e17], 400000000000000000 [4e17], 700000000000000000 [7e17]]"})
        data_path, log_path = root / "rpc.json", root / "calls.log"
        data_path.write_text(json.dumps({"env": env, "contracts": contracts, "calls": calls}))
        network.joinpath("network.params").write_text("CHAIN_ID=97\nRPC_URL=http://invalid.local\n")
        network.joinpath("addresses.core.params").write_text("\n".join(
            key + "=" + value for key, value in env.items() if key.endswith("_ADDRESS")) + "\n")
        network.joinpath("action.params").write_text(
            "GROUP_ACTION_SPLITS=" + env["GROUP_ACTION_SPLITS"] + "\n")
        saved = network / "addresses.action.params"
        # 步骤自行载入地址文件：先写入一份与 env 一致的已部署地址，供独立运行的 21_check / 31_verify 读取。
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names) + "\n")
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path),
                "MOCK_LOG": str(log_path), **env}
        checks = 0

        def write_account(password_line=""):
            network.joinpath(".account").write_text(
                "KEYSTORE_ACCOUNT=test-keystore\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\nPRIVATE_KEY=" + SECRET_KEY + "\n" + password_line)

        def run(script, success=True, args=(), **extra):
            nonlocal checks
            log_path.write_text("")
            result = subprocess.run(["bash", str(deploy / script), *args], env={**base, **extra}, text=True, capture_output=True)
            assert (result.returncode == 0) == success, (script, extra, result.stdout, result.stderr)
            assert not any(secret in result.stdout + result.stderr for secret in (SECRET_KEY, SECRET_PASSWORD))
            checks += 1
            return result, [json.loads(line) for line in log_path.read_text().splitlines()]

        def forge_script_call(log):
            return next(call for call in log if call[:2] == ["forge", "script"])

        write_account()

        run("21_check.sh", args=("test",))
        # 地址文件键集合不符（漏改键名）必须显式失败。
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names[:-1]) + "\nGROUPSERVICE_ADDR=" + env["GROUP_SERVICE_EXECUTOR_ADDRESS"] + "\n")
        result, _ = run("21_check.sh", False, ("test",))
        assert "key set mismatch" in result.stdout + result.stderr, result.stdout + result.stderr
        saved.write_text("\n".join(name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in names) + "\n")
        for contract, signature in [("ACTION_TARGET", "mintAddress()(address)"), ("ACTION_TARGET", "voteAddress()(address)"),
                ("ACTION_TARGET", "submitAddress()(address)"), ("ACTION_TARGET", "memberNFTAddress()(address)"),
                ("ACTION_TARGET", "phaseAddress()(address)"), ("LP_EXECUTOR", "actionTarget()(address)"),
                ("GROUP_SERVICE_EXECUTOR", "initialized()(bool)"),
                ("GROUP_ACTION_EXECUTOR", "SPLITS()(uint256[])")]:
            wrong_value = "0x" + "98" * 20 if signature.endswith("(address)") else "false" if signature.endswith("(bool)") else "[999]"
            run("21_check.sh", False, ("test",), BAD_CALL=env[contract + "_ADDRESS"].lower() + "/" + signature, BAD_VALUE=wrong_value)
        run("21_check.sh", False, ("test",), RPC_CODE_ERROR="1")
        run("21_check.sh", False, ("test",), RPC_CHAIN="56")
        # 地址比较大小写不敏感：配置写大写、链上读到小写，仍应通过（配置值由步骤自行载入）。
        core_path = network.joinpath("addresses.core.params")
        core_text = core_path.read_text()
        core_path.write_text(core_text.replace(env["MINT_ADDRESS"], env["MINT_ADDRESS"].upper().replace("0X", "0x")))
        run("21_check.sh", args=("test",))
        core_path.write_text(core_text)
        saved.write_text("# previous deployment\n")
        for extra in ({"RPC_CHAIN": "56"}, {"DEPLOY_FAIL": "1"}, {"OMIT_ADDRESS": "ACTION_TARGET_ADDRESS"},
                      {"BAD_CALL": env["ACTION_TARGET_ADDRESS"] + "/mintAddress()(address)"}):
            run("one_click_deploy.sh", False, ("test",), **extra)
            assert saved.read_text() == "# previous deployment\n"
        _, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert command[command.index("--chain-id") + 1] == "97"
        assert command[command.index("--account") + 1] == "test-keystore"
        assert command[command.index("--sender") + 1] == "0x" + "f5" * 20
        assert "--unlocked" not in command and "--private-key" not in command
        # 留空 KEYSTORE_PASSWORD：弹窗一次读取（osascript），直接用读取值解锁。
        assert command[command.index("--password") + 1] == "test-password"
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        # splits 以 --sig "run(uint256[])" 传入；环境里不串用调用方传入的依赖地址。
        assert "[100000000000000000,400000000000000000,700000000000000000]" in command, command
        assert "env:MINT_ADDRESS=" + env["MINT_ADDRESS"] in command, command
        assert "env:STAKE_ADDRESS=" + env["STAKE_ADDRESS"] in command, command
        assert len([call for call in log if call[:2] == ["forge", "verify-contract"]]) == 4
        assert "ACTION_TARGET_ADDRESS=" in saved.read_text()
        # .account 配了非空 KEYSTORE_PASSWORD 就直接用它解锁，不弹窗。
        write_account("KEYSTORE_PASSWORD=" + SECRET_PASSWORD + "\n")
        _, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert command[command.index("--password") + 1] == SECRET_PASSWORD
        assert not any(call[0] == "osascript" for call in log), log
        # 显式留空等同未配置：仍走弹窗。
        write_account("KEYSTORE_PASSWORD=\n")
        _, log = run("one_click_deploy.sh", args=("test",))
        assert forge_script_call(log)[forge_script_call(log).index("--password") + 1] == "test-password"
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        write_account()
        # .account 缺 KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS，或整个文件缺失：广播前即失败，不弹窗不广播。
        network.joinpath(".account").write_text("PRIVATE_KEY=" + SECRET_KEY + "\n")
        run("11_deploy.sh", False, ("test",))
        network.joinpath(".account").unlink()
        run("11_deploy.sh", False, ("test",))
        write_account()
        # core 依赖地址不是已部署合约：广播前失败（cast code 拿不到字节码）。
        run("11_deploy.sh", False, ("test",), RPC_CODE_ERROR="1")
        run("11_deploy.sh", args=("test",))
        saved_before = saved.read_text()
        result, _ = run("11_deploy.sh", False, ("test",), OMIT_ADDRESS="GROUP_SERVICE_EXECUTOR_ADDRESS")
        assert "GROUP_SERVICE_EXECUTOR_ADDRESS" in result.stdout + result.stderr, result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        result, _ = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/ActionTarget.sol:ActionTarget")
        assert "all 4 contracts" not in result.stdout
        result, log = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/GroupServiceExecutor.sol:GroupServiceExecutor")
        assert len([call for call in log if call[:2] == ["forge", "verify-contract"]]) == 4
        _, log = run("31_verify.sh", args=("test",))
        verifies = [call for call in log if call[:2] == ["forge", "verify-contract"]]
        assert len(verifies) == 4
        for source in ("src/ActionTarget.sol:ActionTarget", "src/LpExecutor.sol:LpExecutor",
                       "src/GroupActionExecutor.sol:GroupActionExecutor",
                       "src/GroupServiceExecutor.sol:GroupServiceExecutor"):
            assert any(call[3] == source for call in verifies), (source, log)
        # 缺 ETHERSCAN_API_KEY：验证步失败且不提交任何验证请求。
        with network.joinpath("network.params").open("a") as config:
            config.write("ETHERSCAN_API_KEY=\n")
        _, log = run("31_verify.sh", False, ("test",))
        assert not any(call[0] == "forge" for call in log)
        # 本地链跳过开源验证。
        network.joinpath("network.params").write_text("CHAIN_ID=31337\nRPC_URL=http://invalid.local\n")
        result, log = run("31_verify.sh", args=("test",))
        assert "Skip" in result.stdout, result.stdout
        assert not any(call[0] == "forge" for call in log)
        # 结构约束：无 00_init；入口不 source 任何文件；步骤自行载入配置。
        def code_lines(path):
            return [ln.strip() for ln in path.read_text().splitlines()
                    if ln.strip() and not ln.strip().startswith("#")]

        for name in ("11_deploy.sh", "21_check.sh", "31_verify.sh", "one_click_deploy.sh"):
            assert not any("00_init" in ln for ln in code_lines(deploy / name)), name
        assert not any(ln.startswith("source") for ln in code_lines(deploy / "one_click_deploy.sh")), "入口不应 source 任何文件"
        assert any(ln.startswith("source") for ln in code_lines(deploy / "11_deploy.sh")), "步骤应自行载入配置"
        print(f"Passed {checks} isolated deployment checks (no network calls or broadcasts).")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake":
        sys.exit(fake_tool(sys.argv[2], sys.argv[3:]))
    main()
