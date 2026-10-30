#!/usr/bin/env python3
"""Deployment regression checks with isolated configs and fake RPC/signing tools."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


# 敏感值哨兵：任何一步把它写进 stdout/stderr 都视为回归。
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
            print(data["code"].get(args[1].lower(), "0x01"))
        elif args[0] == "call":
            if args[2] == "SPLITS()(uint256[])" and os.environ.get("MOCK_EMPTY_SPLITS"):
                print("[]")
            else:
                key = args[1].lower() + "/" + args[2]
                print(os.environ.get("BAD_VALUE", "ERROR") if key == os.environ.get("BAD_CALL") else data["calls"][key])
        else:
            raise AssertionError(args)
    elif tool == "mktemp":
        if "-d" in args:
            print(tempfile.mkdtemp(dir=os.environ["MOCK_TMP"]))
        else:
            fd, path = tempfile.mkstemp(dir=os.environ["MOCK_TMP"])
            os.close(fd)
            print(path)
    elif args[0] == "script":
        # 凭据哨兵：密码不得进进程参数，密码文件必须已写入且非空。
        if "--password" in args:
            print("CREDENTIAL_IN_ARGV", file=sys.stderr)
        password_file = args[args.index("--password-file") + 1] if "--password-file" in args else None
        if not password_file or not Path(password_file).is_file():
            print("PASSWORD_FILE_MISSING", file=sys.stderr)
        else:
            print("PASSWORD_SHA=" + hashlib.sha256(Path(password_file).read_bytes()).hexdigest(),
                  file=sys.stderr)
        if os.environ.get("DEPLOY_FAIL"):
            return 1
        # 成功广播会刷新 run-latest.json 的 timestamp；缺失文件不重建，STALE_BROADCAST 模拟过期产物。
        broadcast = os.environ.get("MOCK_BROADCAST")
        if broadcast and Path(broadcast).exists():
            artifact = json.loads(Path(broadcast).read_text())
            artifact["timestamp"] = 0 if os.environ.get("STALE_BROADCAST") else int(time.time() * 1000)
            Path(broadcast).write_text(json.dumps(artifact, indent=2))
        for key, value in data["env"].items():
            if key in data["contracts"] and key != os.environ.get("OMIT_ADDRESS"):
                print(key + "= " + value)
    elif args[0] == "inspect":
        if os.environ.get("INSPECT_FAIL"):
            return 1
        # 真实 forge inspect 靠 cwd 定位 foundry.toml：不在项目根必须失败，
        # 否则脚本漏掉 cd 的回归无法被发现。
        project_root = os.environ.get("MOCK_PROJECT_ROOT")
        if project_root and os.path.realpath(os.getcwd()) != os.path.realpath(project_root):
            return 1
        code = data["inspect"][args[1]]
        provided = {}
        for index, arg in enumerate(args):
            if arg == "--libraries":
                fqn, address = args[index + 1].rsplit(":", 1)
                provided[fqn] = address[2:].lower()
        for fqn, canonical in data["library_canonical"].items():
            if fqn in provided:
                code = code.replace(canonical, provided[fqn])
        print(code)
    elif args[0] == "verify-contract":
        if os.environ.get("VERIFY_FAIL") == args[2]:
            return 1
    else:
        raise AssertionError(args)
    return 0


def params_loader_cases() -> None:
    """params.sh：1e 写法展开、行尾注释、引号内 # 保留、逗号项去空格。"""
    repo = Path(__file__).resolve().parents[1]
    cases = [
        ("A=1e17\n", "100000000000000000"),
        ("A=3e15  # 0.30%\n", "3000000000000000"),
        ("A=1_000\n", "1000"),
        ('A="a # b"\n', "a # b"),
        ("A=1e17, 4e17\n", "100000000000000000,400000000000000000"),
        ("A=x1e5y\n", "x1e5y"),
    ]
    with tempfile.TemporaryDirectory(prefix="params-loader-test-") as directory:
        path = Path(directory) / "case.params"
        for text, expected in cases:
            path.write_text(text)
            result = subprocess.run(
                ["bash", "-c", '. "$1"; params_load "$2"; printf "%s" "$A"',
                 "bash", str(repo / "script/deploy/params.sh"), str(path)],
                text=True, capture_output=True)
            assert result.returncode == 0, (text, result.stderr)
            assert result.stdout == expected, (text, result.stdout)


def main():
    params_loader_cases()
    action = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="action-deploy-test-") as directory:
        root = Path(directory)
        deploy = root / "script/deploy"
        shutil.copytree(action / "script/deploy", deploy)
        network = root / "script/network/test"
        network.mkdir(parents=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for tool in ("cast", "forge", "osascript", "mktemp"):
            stub = bin_dir / tool
            stub.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                            + shlex.quote(str(Path(__file__).resolve())) + " --fake " + tool + ' "$@"\n')
            stub.chmod(0o755)
        names = ["ACTION_TARGET", "LP_EXECUTOR", "GROUP_ACTION_EXECUTOR", "GROUP_SERVICE_EXECUTOR"]
        env = {name + "_ADDRESS": f"0x{index + 10:040x}" for index, name in enumerate(names)}
        contracts = list(env)
        libraries = [
            {"name": "GroupActionJoin", "path": "src/GroupActionJoin.sol",
             "field": "GROUP_ACTION_JOIN_LIBRARY_ADDRESS", "executor": "GROUP_ACTION_EXECUTOR"},
            {"name": "GroupActionManager", "path": "src/GroupActionManager.sol",
             "field": "GROUP_ACTION_MANAGER_LIBRARY_ADDRESS", "executor": "GROUP_ACTION_EXECUTOR"},
            {"name": "GroupActionVerify", "path": "src/GroupActionVerify.sol",
             "field": "GROUP_ACTION_VERIFY_LIBRARY_ADDRESS", "executor": "GROUP_ACTION_EXECUTOR"},
            {"name": "GroupRecipients", "path": "src/GroupRecipients.sol",
             "field": "GROUP_RECIPIENTS_LIBRARY_ADDRESS", "executor": "GROUP_SERVICE_EXECUTOR"},
        ]
        env.update({lib["field"]: f"0x{index + 20:040x}" for index, lib in enumerate(libraries)})
        env.update({"CHAIN_ID": "97", "RPC_URL": "http://invalid.local", "ETHERSCAN_API_KEY": "test-key",
                    "LOVE20_TOKEN_ADDRESS": "0x" + "90" * 20,
                    "MINT_ADDRESS": "0x" + "ab" * 20, "STAKE_ADDRESS": "0x" + "cd" * 20,
                    "VOTE_ADDRESS": "0x" + "12" * 20, "SUBMIT_ADDRESS": "0x" + "34" * 20,
                    "MEMBER_NFT_ADDRESS": "0x" + "56" * 20, "PHASE_ADDRESS": "0x" + "78" * 20,
                    "LAUNCH_ADDRESS": "0x" + "9a" * 20,
                    "PAIR_FACTORY_ADDRESS": "0x" + "9b" * 20,
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
        getters("GROUP_SERVICE_EXECUTOR", {
            "groupActionExecutorAddress()(address)": "GROUP_ACTION_EXECUTOR_ADDRESS"
        })
        # cast 的数组返回逐元素带科学计数法标注；21_check.sh 的 strip_sci_notation 会归一化。
        getters("GROUP_ACTION_EXECUTOR", {"SPLITS()(uint256[])":
                "[100000000000000000 [1e17], 400000000000000000 [4e17], 700000000000000000 [7e17]]"})
        getters("STAKE", {"MEMBER_NFT_ADDRESS()(address)": "MEMBER_NFT_ADDRESS",
                "PHASE_ADDRESS()(address)": "PHASE_ADDRESS",
                "VOTE_ADDRESS()(address)": "VOTE_ADDRESS",
                "LAUNCH_ADDRESS()(address)": "LAUNCH_ADDRESS",
                "PAIR_FACTORY_ADDRESS()(address)": "PAIR_FACTORY_ADDRESS",
                "ROUTER_ADDRESS()(address)": "PAIR_FACTORY_ADDRESS"})
        getters("LAUNCH", {"PAIR_FACTORY_ADDRESS()(address)": "PAIR_FACTORY_ADDRESS"})
        code = {}
        for lib in libraries:
            executor = env[lib["executor"] + "_ADDRESS"].lower()
            code[executor] = code.get(executor, "0x") + env[lib["field"]][2:].lower()
        executor_contracts = {
            "GROUP_ACTION_EXECUTOR": "GroupActionExecutor",
            "GROUP_SERVICE_EXECUTOR": "GroupServiceExecutor",
        }
        inspect = {
            contract: code[env[executor + "_ADDRESS"].lower()]
            for executor, contract in executor_contracts.items()
        }
        # 两个普通合约不链接库，产物与链上应直接一致，用于覆盖「无库也要逐字节比对」。
        for field, contract, body in (("ACTION_TARGET_ADDRESS", "ActionTarget", "aa"),
                                      ("LP_EXECUTOR_ADDRESS", "LpExecutor", "bb")):
            address = env[field].lower()
            code[address] = "0x" + body * 20
            inspect[contract] = code[address]
        # 库的 runtime code 内嵌自身地址（部署时由 constructor 写入），编译产物里该位置是
        # 20 字节零。21_check.sh 按入账地址替换这一处后再比对，故链上取真实地址、产物取零。
        library_placeholder = "73" + "0" * 40
        for lib in libraries:
            address = env[lib["field"]].lower()
            code[address] = "0x73" + address[2:] + "30"
            inspect[lib["name"]] = "0x" + library_placeholder + "30"
        library_canonical = {
            lib["path"] + ":" + lib["name"]: env[lib["field"]][2:].lower() for lib in libraries
        }
        data_path, log_path = root / "rpc.json", root / "calls.log"
        tmp_dir = root / "tmp"
        tmp_dir.mkdir()
        data_path.write_text(json.dumps({
            "env": env, "contracts": contracts, "calls": calls, "code": code,
            "inspect": inspect, "library_canonical": library_canonical}))
        network.joinpath("network.params").write_text("CHAIN_ID=97\nRPC_URL=http://invalid.local\n")
        core_names = ["LOVE20_TOKEN", "MEMBER_NFT", "PHASE", "LAUNCH", "MINT", "STAKE", "SUBMIT", "VOTE"]
        network.joinpath("addresses.core.params").write_text("\n".join(
            name + "_ADDRESS=" + env[name + "_ADDRESS"] for name in core_names) + "\n")
        network.joinpath("action.params").write_text(
            "GROUP_ACTION_SPLITS=" + env["GROUP_ACTION_SPLITS"] + "\n")
        saved = network / "addresses.action.params"
        all_fields = [name + "_ADDRESS" for name in names] + [lib["field"] for lib in libraries]

        def fqn(lib):
            return lib["path"] + ":" + lib["name"]

        def address_file_text(omit=None, overrides=None):
            overrides = overrides or {}
            return "\n".join(field + "=" + overrides.get(field, env[field])
                             for field in all_fields if field != omit) + "\n"

        # Foundry 广播产物：库地址只从这里可见（被自动 CREATE2 部署，不进部署日志）。
        broadcast = root / "broadcast/DeployAction.s.sol/97/run-latest.json"
        broadcast.parent.mkdir(parents=True)

        def write_broadcast(omit=None, executor_addresses=None, extra_return=False, extra_library=False):
            # 故意打乱顺序：任何按位置切片解析库的回归都会与期望映射不符。
            order = ["GroupRecipients", "GroupActionVerify", "GroupActionJoin", "GroupActionManager"]
            entries = [fqn(lib) + ":" + env[lib["field"]]
                       for name in order for lib in libraries
                       if lib["name"] == name and lib["field"] != omit]
            if extra_library:
                entries.append("src/ExtraLibrary.sol:ExtraLibrary:0x" + "99" * 20)
            addrs = executor_addresses or [env[name + "_ADDRESS"] for name in names]
            value = "(" + ", ".join(addrs) + ")"
            returns = {"addrs": {
                "internal_type": "struct DeployAction.DeploymentAddresses",
                "value": value}}
            if extra_return:
                returns["extra"] = {"value": value}
            broadcast.write_text(json.dumps(
                {"transactions": [], "libraries": entries, "returns": returns, "timestamp": 0}, indent=2))

        write_broadcast()
        # 步骤自行载入地址文件：先写入一份与 env 一致的已部署地址，供独立运行的 21_check / 31_verify 读取。
        saved.write_text(address_file_text())
        base = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "MOCK_DATA": str(data_path),
                "MOCK_LOG": str(log_path), "MOCK_BROADCAST": str(broadcast), "MOCK_TMP": str(tmp_dir),
                "MOCK_PROJECT_ROOT": str(root), **env}
        checks = 0

        def write_account(password_line=""):
            # 正确用法：keystore 名称 + 账户地址 + 可选密码。
            network.joinpath(".account").write_text(
                "KEYSTORE_ACCOUNT=test-keystore\nACCOUNT_ADDRESS=0x" + "f5" * 20 + "\n" + password_line)

        def run(script, success=True, args=(), cwd=None, **extra):
            nonlocal checks
            log_path.write_text("")
            result = subprocess.run(["bash", str(deploy / script), *args], env={**base, **extra},
                                    cwd=cwd or root, text=True, capture_output=True)
            assert (result.returncode == 0) == success, (script, extra, result.stdout, result.stderr)
            output = result.stdout + result.stderr
            assert SECRET_PASSWORD not in output
            for marker in ("CREDENTIAL_IN_ARGV", "PASSWORD_FILE_MISSING"):
                assert marker not in output, (marker, output)
            log = [json.loads(line) for line in log_path.read_text().splitlines()]
            for call in log:
                if call[:2] == ["forge", "script"] and "--password-file" in call:
                    assert not Path(call[call.index("--password-file") + 1]).exists(), call
            checks += 1
            return result, log

        def forge_script_call(log):
            return next(call for call in log if call[:2] == ["forge", "script"])

        def library_args(call):
            # 多个库以重复 --libraries 传入，而不是逗号拼接的单个值。
            return [call[index + 1] for index, arg in enumerate(call) if arg == "--libraries"]

        def verify_calls(log):
            return [call for call in log if call[:2] == ["forge", "verify-contract"]]

        def source_of(call):
            return call[call.index("verify-contract") + 2]

        def verifies_by_source(log):
            return {source_of(call): call for call in verify_calls(log)}

        def expected_library_args(executor):
            return [fqn(lib) + ":" + env[lib["field"]] for lib in libraries if lib["executor"] == executor]

        def assert_verify_plan(log):
            assert len(verify_calls(log)) == len(all_fields), log
            by_source = verifies_by_source(log)
            expected_sources = ["src/ActionTarget.sol:ActionTarget", "src/LpExecutor.sol:LpExecutor",
                                "src/GroupActionExecutor.sol:GroupActionExecutor",
                                "src/GroupServiceExecutor.sol:GroupServiceExecutor",
                                *[fqn(lib) for lib in libraries]]
            assert all(source in by_source for source in expected_sources), (expected_sources, log)
            group_action = by_source["src/GroupActionExecutor.sol:GroupActionExecutor"]
            assert library_args(group_action) == expected_library_args("GROUP_ACTION_EXECUTOR")
            group_service = by_source["src/GroupServiceExecutor.sol:GroupServiceExecutor"]
            assert library_args(group_service) == expected_library_args("GROUP_SERVICE_EXECUTOR")
            for source in ("src/ActionTarget.sol:ActionTarget", "src/LpExecutor.sol:LpExecutor",
                           *[fqn(lib) for lib in libraries]):
                assert library_args(by_source[source]) == []

        write_account()

        # 从项目外的目录运行：forge inspect 靠 cwd 定位 foundry.toml，脚本必须自行切换，
        # 否则会被误报成「runtime unavailable」。fake inspect 会拒绝非项目根目录。
        run("21_check.sh", True, ("test",), cwd=root.parent)

        run("21_check.sh", args=("test",))
        # 地址文件键集合不符（漏改键名，包括漏掉库地址）必须显式失败。
        saved.write_text(address_file_text(omit="GROUP_RECIPIENTS_LIBRARY_ADDRESS")
                         + "GROUPSERVICE_ADDR=" + env["GROUP_SERVICE_EXECUTOR_ADDRESS"] + "\n")
        result, _ = run("21_check.sh", False, ("test",))
        assert "key set mismatch" in result.stdout + result.stderr, result.stdout + result.stderr
        # 地址格式非法（这里是零地址）：在逐项 cast 之前显式失败，不误报成「未部署」。
        saved.write_text(address_file_text(overrides={"GROUP_ACTION_JOIN_LIBRARY_ADDRESS": "0x0"}))
        result, _ = run("21_check.sh", False, ("test",))
        assert "missing or invalid" in result.stdout + result.stderr, result.stdout + result.stderr
        saved.write_text(address_file_text())
        # 同一 Executor 内互换两个库地址：仅检查地址出现会误通过，完整字节码比对必须失败。
        saved.write_text(address_file_text(overrides={
            "GROUP_ACTION_JOIN_LIBRARY_ADDRESS": env["GROUP_ACTION_VERIFY_LIBRARY_ADDRESS"],
            "GROUP_ACTION_VERIFY_LIBRARY_ADDRESS": env["GROUP_ACTION_JOIN_LIBRARY_ADDRESS"]}))
        result, _ = run("21_check.sh", False, ("test",))
        assert "GroupActionExecutor runtime does not match" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        # 库自身 runtime 与构建产物不符（地址指向别的实现）：同样必须失败。
        saved.write_text(address_file_text(overrides={
            "GROUP_RECIPIENTS_LIBRARY_ADDRESS": "0x" + "77" * 20}))
        result, _ = run("21_check.sh", False, ("test",))
        assert "GroupRecipients runtime does not match" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        saved.write_text(address_file_text())
        # 空数组表示不分层：链上 SPLITS 也应为空时通过。
        params_path = network / "action.params"
        params_text = params_path.read_text()
        params_path.write_text("GROUP_ACTION_SPLITS=\n")
        run("21_check.sh", args=("test",), MOCK_EMPTY_SPLITS="1")
        params_path.write_text(params_text)
        for contract, signature in [("ACTION_TARGET", "mintAddress()(address)"), ("ACTION_TARGET", "voteAddress()(address)"),
                ("ACTION_TARGET", "submitAddress()(address)"), ("ACTION_TARGET", "memberNFTAddress()(address)"),
                ("ACTION_TARGET", "phaseAddress()(address)"), ("LP_EXECUTOR", "actionTarget()(address)"),
                ("GROUP_SERVICE_EXECUTOR", "initialized()(bool)"),
                ("STAKE", "MEMBER_NFT_ADDRESS()(address)"),
                ("LAUNCH", "PAIR_FACTORY_ADDRESS()(address)"),
                ("GROUP_ACTION_EXECUTOR", "SPLITS()(uint256[])")]:
            wrong_value = "0x" + "98" * 20 if signature.endswith("(address)") else "false" if signature.endswith("(bool)") else "[999]"
            run("21_check.sh", False, ("test",), BAD_CALL=env[contract + "_ADDRESS"].lower() + "/" + signature, BAD_VALUE=wrong_value)
        # 地址无代码时每个对象只计一次失败（4 合约 + 4 库 + Stake 派生源 3 = 11），
        # 不因 runtime 比对重复计数。
        result, _ = run("21_check.sh", False, ("test",), RPC_CODE_ERROR="1")
        assert "11 verification(s) failed" in result.stdout, result.stdout
        run("21_check.sh", False, ("test",), INSPECT_FAIL="1")
        run("21_check.sh", False, ("test",), RPC_CHAIN="56")
        # 地址比较大小写不敏感：配置写大写、链上读到小写，仍应通过（配置值由步骤自行载入）。
        core_path = network.joinpath("addresses.core.params")
        core_text = core_path.read_text()
        core_path.write_text(core_text.replace(env["MINT_ADDRESS"], env["MINT_ADDRESS"].upper().replace("0X", "0x")))
        run("21_check.sh", args=("test",))
        core_path.write_text(core_text)
        saved.write_text("# previous deployment\n")
        for extra in ({"RPC_CHAIN": "56"}, {"DEPLOY_FAIL": "1"}, {"OMIT_ADDRESS": "ACTION_TARGET_ADDRESS"},
                      {"STALE_BROADCAST": "1"},
                      {"BAD_CALL": env["ACTION_TARGET_ADDRESS"] + "/mintAddress()(address)"}):
            result, _ = run("one_click_deploy.sh", False, ("test",), **extra)
            assert saved.read_text() == "# previous deployment\n"
            output = result.stdout + result.stderr
            if "BAD_CALL" in extra:
                assert "New deployment addresses" in output, output
                assert "ACTION_TARGET_ADDRESS=" in output, output
                assert "Broadcast artifact:" in output, output
                assert "The previously saved addresses were restored." in output, output
            if "Deployment log:" in output:
                kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
                assert kept_log.exists(), kept_log
                kept_log.unlink()
        # 广播前失败的备份与密码文件、广播后失败保留的日志清理后，临时目录应为空。
        assert not list(tmp_dir.iterdir()), list(tmp_dir.iterdir())
        # broadcast 回填的 Executor 地址与部署日志不一致：也必须在写入前失败。
        wrong = [env[name + "_ADDRESS"] for name in names]
        wrong[2] = "0x" + "99" * 20
        write_broadcast(executor_addresses=wrong)
        result, _ = run("one_click_deploy.sh", False, ("test",))
        assert "does not match deployed executors" in result.stdout + result.stderr, result.stdout + result.stderr
        assert saved.read_text() == "# previous deployment\n"
        write_broadcast()
        result, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert command[command.index("--chain-id") + 1] == "97"
        assert command[command.index("--account") + 1] == "test-keystore"
        assert command[command.index("--sender") + 1] == "0x" + "f5" * 20
        assert "--unlocked" not in command and "--private-key" not in command
        # 留空 KEYSTORE_PASSWORD：弹窗一次读取（osascript）。密码经临时文件传给 forge，
        # 不进 argv；文件内容即弹窗读到的值。
        assert "--password" not in command, command
        assert "PASSWORD_SHA=" + hashlib.sha256(b"test-password").hexdigest() in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        # splits 以 --sig "run(uint256[])" 传入；环境里不串用调用方传入的依赖地址。
        assert "[100000000000000000,400000000000000000,700000000000000000]" in command, command
        assert "env:MINT_ADDRESS=" + env["MINT_ADDRESS"] in command, command
        assert "env:STAKE_ADDRESS=" + env["STAKE_ADDRESS"] in command, command
        assert all(field + "=" + env[field] in saved.read_text() for field in all_fields), saved.read_text()
        assert_verify_plan(log)
        # .account 配了非空 KEYSTORE_PASSWORD 就直接用它解锁，不弹窗。
        write_account("KEYSTORE_PASSWORD=" + SECRET_PASSWORD + "\n")
        result, log = run("one_click_deploy.sh", args=("test",))
        command = forge_script_call(log)
        assert "--password" not in command, command
        assert "PASSWORD_SHA=" + hashlib.sha256(SECRET_PASSWORD.encode()).hexdigest() in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert not any(call[0] == "osascript" for call in log), log
        # 显式留空等同未配置：仍走弹窗。
        write_account("KEYSTORE_PASSWORD=\n")
        result, log = run("one_click_deploy.sh", args=("test",))
        assert "--password" not in forge_script_call(log)
        assert "PASSWORD_SHA=" + hashlib.sha256(b"test-password").hexdigest() in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert len([call for call in log if call[0] == "osascript"]) == 1, log
        write_account()
        # .account 缺 KEYSTORE_ACCOUNT / ACCOUNT_ADDRESS，或整个文件缺失：广播前即失败，不弹窗不广播。
        network.joinpath(".account").write_text("UNRELATED=x\n")
        run("11_deploy.sh", False, ("test",))
        network.joinpath(".account").unlink()
        run("11_deploy.sh", False, ("test",))
        write_account()
        # 广播失败：合约可能已部分上链，必须保留日志并打印路径。
        saved_before = saved.read_text()
        result, _ = run("11_deploy.sh", False, ("test",), DEPLOY_FAIL="1")
        output = result.stdout + result.stderr
        assert "contracts may already be on chain" in output, output
        assert "Deployment log:" in output, output
        kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
        assert kept_log.exists(), kept_log
        kept_log.unlink()
        assert saved.read_text() == saved_before, saved.read_text()
        # broadcast 缺库条目或整个文件缺失：部署后也不得写半截地址文件。
        write_broadcast(omit="GROUP_RECIPIENTS_LIBRARY_ADDRESS")
        result, _ = run("11_deploy.sh", False, ("test",))
        assert "GROUP_RECIPIENTS_LIBRARY_ADDRESS" in result.stdout + result.stderr, result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        write_broadcast()
        broadcast.unlink()
        result, _ = run("11_deploy.sh", False, ("test",))
        assert "Missing broadcast artifact" in result.stdout + result.stderr, result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        write_broadcast()
        # 产物存在但不是本次运行写出：拒绝复用。
        result, _ = run("11_deploy.sh", False, ("test",), STALE_BROADCAST="1")
        assert "was not updated by this deployment" in result.stdout + result.stderr, result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        # 多个 struct 返回值会让抓取绑定到错误 tuple：必须显式失败。
        write_broadcast(extra_return=True)
        result, _ = run("11_deploy.sh", False, ("test",))
        assert "Expected exactly one executor return value" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        write_broadcast()
        # 产物出现未知库：不能静默忽略。
        write_broadcast(extra_library=True)
        result, _ = run("11_deploy.sh", False, ("test",))
        assert "Expected 4 linked libraries, found 5" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        assert saved.read_text() == saved_before, saved.read_text()
        # 广播已上链后校验失败：日志必须保留，地址记录只能从它恢复。
        output = result.stdout + result.stderr
        assert "Deployment log:" in output, output
        kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
        assert kept_log.exists(), kept_log
        kept_log.unlink()
        write_broadcast()
        run("11_deploy.sh", args=("test",))
        assert all(field + "=" + env[field] in saved.read_text() for field in all_fields), saved.read_text()
        saved_before = saved.read_text()
        result, _ = run("11_deploy.sh", False, ("test",), OMIT_ADDRESS="GROUP_SERVICE_EXECUTOR_ADDRESS")
        output = result.stdout + result.stderr
        assert "GROUP_SERVICE_EXECUTOR_ADDRESS" in output, output
        assert "contracts may already be on chain" in output, output
        assert "Deployment log:" in output, output
        kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
        assert kept_log.exists(), kept_log
        kept_log.unlink()
        assert saved.read_text() == saved_before, saved.read_text()
        # 地址文件写入失败不得截断旧记录（同目录临时文件 + mv）。
        network.chmod(0o555)
        try:
            result, _ = run("11_deploy.sh", False, ("test",))
        finally:
            network.chmod(0o755)
        output = result.stdout + result.stderr
        assert "contracts may already be on chain" in output, output
        assert saved.read_text() == saved_before, saved.read_text()
        kept_log = Path(output.split("Deployment log:", 1)[1].splitlines()[0].strip())
        assert kept_log.exists(), kept_log
        kept_log.unlink()
        # 地址文件缺库地址且环境未提供：验证步必须在提交任何请求前失败。
        saved.write_text(address_file_text(omit="GROUP_ACTION_JOIN_LIBRARY_ADDRESS"))
        missing_library = base.pop("GROUP_ACTION_JOIN_LIBRARY_ADDRESS")
        result, log = run("31_verify.sh", False, ("test",))
        base["GROUP_ACTION_JOIN_LIBRARY_ADDRESS"] = missing_library
        assert "GROUP_ACTION_JOIN_LIBRARY_ADDRESS" in result.stdout + result.stderr, result.stdout + result.stderr
        assert not any(call[0] == "forge" for call in log)
        saved.write_text(address_file_text())
        result, _ = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/ActionTarget.sol:ActionTarget")
        assert "Source verification succeeded" not in result.stdout
        result, log = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/GroupServiceExecutor.sol:GroupServiceExecutor")
        assert source_of(verify_calls(log)[-1]) == "src/GroupServiceExecutor.sol:GroupServiceExecutor", log
        result, log = run("31_verify.sh", False, ("test",), VERIFY_FAIL="src/GroupActionJoin.sol:GroupActionJoin")
        assert any(source_of(call) == "src/GroupActionJoin.sol:GroupActionJoin" for call in log), log
        assert "Source verification succeeded" not in result.stdout
        _, log = run("31_verify.sh", args=("test",))
        assert_verify_plan(log)
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
