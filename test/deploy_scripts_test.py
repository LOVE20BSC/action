#!/usr/bin/env python3
"""Deployment regression checks with isolated configs and fake RPC/signing tools."""
import hashlib
import json
import os
import re
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
            code = data["code"].get(args[1].lower(), "0x01")
            if os.environ.get("BAD_CODE", "").lower() == args[1].lower():
                print("0x" + "99" * 200)
            else:
                mutation = os.environ.get("MUTATE")
                if mutation:
                    mutate_address, offset = mutation.rsplit(":", 1)
                    if mutate_address.lower() == args[1].lower():
                        position = 2 + int(offset) * 2
                        code = code[:position] + "99" + code[position + 2:]
                print(code)
        elif args[0] == "call":
            if args[2] == "SPLITS()(uint256[])" and os.environ.get("MOCK_EMPTY_SPLITS"):
                print("[]")
            else:
                key = args[1].lower() + "/" + args[2]
                print(os.environ.get("BAD_VALUE", "ERROR") if key == os.environ.get("BAD_CALL") else data["calls"][key])
        elif args[0] == "abi-encode":
            if os.environ.get("ABI_ENCODE_FAIL") == args[1]:
                return 1
            fail_arg = os.environ.get("ABI_ENCODE_FAIL_ARG")
            if fail_arg and any(arg.lower() == fail_arg.lower() for arg in args[2:]):
                return 1
            print("0x1234")
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
        if args[2] == "artifact":
            refs = data.get("immutables", {}).get(args[1], {})
            # 真实 artifact 同时带 creation 与 deployed 的 linkReferences，二者也有 start：
            # 回填只能读取 deployedBytecode.immutableReferences，不能碰 link 偏移。
            print(json.dumps({
                "bytecode": {"linkReferences": {"src/Lib.sol": {"Lib": [{"start": 180, "length": 20}]}}},
                "deployedBytecode": {
                    "linkReferences": {"src/Lib.sol": {"Lib": [{"start": 150, "length": 20}]}},
                    "immutableReferences": refs,
                },
            }))
            return 0
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


# params.sh 是 core / action / group-chat / dex 四份逐字节相同的副本：每个仓都要能独立部署，
# 文件无法共享，只能靠这个常量防止漂移。改动该文件时四个仓一起改，并同步这四个常量。
PARAMS_SH_SHA256 = "b3a8f64dc87d9e823a364de92e3bc79144d246f1c1a861cdcf95616042b8f840"


CONSTRUCTOR_SLOTS = {
    "ActionTarget": ["MINT_ADDRESS"],
    "LpExecutor": ["ACTION_TARGET_ADDRESS"],
    "GroupActionExecutor": ["ACTION_TARGET_ADDRESS", "GROUP_ACTION_SPLITS"],
    "GroupServiceExecutor": ["GROUP_ACTION_EXECUTOR_ADDRESS"],
}

ADDRESS_VALUE = re.compile(r"0x[0-9a-fA-F]{40}")
UINT_VALUE = re.compile(r"0|[1-9][0-9]*")


def constructor_abi(repo: Path, contract: str) -> list:
    """ABI entries from compiled output: `forge inspect` when available, else the `out/` artifact."""
    try:
        inspected = subprocess.run(["forge", "inspect", contract, "abi", "--json"],
                                   cwd=repo, text=True, capture_output=True)
    except FileNotFoundError:
        inspected = None
    if inspected is not None:
        assert inspected.returncode == 0, (contract, inspected.stderr, inspected.stdout)
        return json.loads(inspected.stdout)
    artifact = repo / "out" / (contract + ".sol") / (contract + ".json")
    assert artifact.is_file(), (f"cannot derive the {contract} constructor ABI: forge is not on PATH "
                                f"and {artifact} is missing; run `forge build` first")
    print(f"warning: forge is not on PATH; using the build artifact {artifact}", file=sys.stderr)
    return json.loads(artifact.read_text())["abi"]


def constructor_layout(repo: Path, contract: str):
    """Return (signature, slot types) for the constructor, derived from the ABI."""
    entries = [entry for entry in constructor_abi(repo, contract) if entry.get("type") == "constructor"]
    assert len(entries) == 1, (contract, entries)
    slot_types = [entry["type"] for entry in entries[0]["inputs"]]
    assert all(slot_type != "tuple" for slot_type in slot_types), (contract, slot_types)
    return "constructor(" + ",".join(slot_types) + ")", slot_types


def constructor_slot_value(slot_type: str, key: str, env: dict) -> str:
    """31_verify passes address/uint values verbatim and uint arrays as a bracketed literal."""
    if slot_type.endswith("[]"):
        items = env[key].split(",") if env[key] else []
        assert all(UINT_VALUE.fullmatch(item.strip()) for item in items), (slot_type, key, env[key])
        return "[" + env[key] + "]"
    if slot_type == "address":
        assert ADDRESS_VALUE.fullmatch(env[key]) is not None, (slot_type, key, env[key])
    elif slot_type.startswith("uint"):
        assert UINT_VALUE.fullmatch(env[key]) is not None, (slot_type, key, env[key])
    else:
        raise AssertionError(f"unsupported ABI type {slot_type} for {key}")
    return env[key]


def verify_constructor_arguments(repo: Path, contract: str, log: list, env: dict) -> None:
    """Per-slot check of the values 31_verify passes: ABI types in CONSTRUCTOR_SLOTS order."""
    signature, slot_types = constructor_layout(repo, contract)
    keys = CONSTRUCTOR_SLOTS[contract]
    assert len(slot_types) == len(keys), (
        f"{contract}: the compiled ABI has {len(slot_types)} constructor slots but CONSTRUCTOR_SLOTS "
        f"lists {len(keys)}; update the slot map together with the constructor", slot_types, keys)
    expected = [constructor_slot_value(slot_type, key, env)
                for key, slot_type in zip(keys, slot_types)]
    encoded = [call for call in log if call[:2] == ["cast", "abi-encode"]]
    matching = [call for call in encoded
                if call[2] == signature and [value for value in call[3:] if not value.startswith("env:")] == expected]
    assert matching, (contract, "no cast abi-encode call matches the compiled signature and expected slots",
                      signature, expected, [call[2:] for call in encoded])
    assert len(matching) == 1, (contract, matching)


def params_shared_copy() -> None:
    """params.sh 必须与四仓共享副本逐字节相同。"""
    repo = Path(__file__).resolve().parents[1]
    digest = hashlib.sha256((repo / "script/deploy/params.sh").read_bytes()).hexdigest()
    assert digest == PARAMS_SH_SHA256, (
        "script/deploy/params.sh 与四仓共享副本不一致（sha256 " + digest + "）；"
        "把同一个文件同步到 core / action / group-chat / dex"
    )


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

    # params_unset_all 的键集来自文件本身：文件定义的键必须被清掉，文件没定义的键不受影响。
    with tempfile.TemporaryDirectory(prefix="params-unset-test-") as directory:
        path = Path(directory) / "case.params"
        path.write_text("A=1\n")
        result = subprocess.run(
            ["bash", "-c",
             '. "$1"; A=inherited; B=inherited; params_unset_all "$2"; printf "%s|%s" "${A:-<unset>}" "${B:-<unset>}"',
             "bash", str(repo / "script/deploy/params.sh"), str(path)],
            text=True, capture_output=True)
        assert result.returncode == 0, (result.stderr,)
        assert result.stdout == "<unset>|inherited", result.stdout


def params_unset_coverage() -> None:
    """每个 source params.sh 的部署脚本都必须在首次 params_load 之前清掉继承值，
    且 params_unset_all 的入参必须覆盖 params_load 读到的每个文件。"""
    repo = Path(__file__).resolve().parents[1]
    scripts = sorted((repo / "script/deploy").glob("*.sh"))
    assert scripts
    for script in scripts:
        text = script.read_text()
        if 'source "$SCRIPT_DIR/params.sh"' not in text:
            continue
        # 只看代码行：注释里出现同名字符串会让下面两条断言一起误通过。
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        assert "params_unset_all " in code, script
        assert code.index("params_unset_all ") < code.index("params_load "), script
        # 续行先拼回一行，否则只看得到首个参数。
        joined = code.replace("\\\n", " ")
        statement = re.search(r"params_unset_all(.*)", joined).group(1).split("\n")[0]
        unset_files = set(re.findall(r'"([^"]+)"', statement))
        load_files = set(re.findall(r'params_load\s+"([^"]+)"', joined))
        assert not load_files - unset_files, (script, load_files - unset_files)


def _params_required_pairs(text: str) -> set:
    """脚本里 params_require_keys/values 声明的 (params 文件名, 键)。"""
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    joined = code.replace("\\\n", " ")
    pairs = set()
    for match in re.finditer(r'params_require_(?:keys|values)\s+"[^"]*/([^"/]+)"([^\n]*)', joined):
        # 只看大写键名：尾部还有 `|| exit 1`。
        pairs.update((match.group(1), key) for key in re.findall(r"\b[A-Z][A-Z0-9_]*\b", match.group(2)))
    return pairs


def _params_loaded_files(text: str) -> set:
    """脚本里 params_load 读取的 params 文件名。"""
    code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
    return set(re.findall(r'params_load\s+"[^"]*/([^"/]+)"', code))


def params_required_consistency() -> None:
    """必填键在调用点声明，没有中心键表：读取同一 params 文件的每个步骤必须声明同一组键。

    11/21/31 各自独立执行，谁都可以单独补一个 params_require_*；漏一处会让该步骤在缺键时
    拿空串继续、而另外两步仍然失败——半红半绿最难定位。
    """
    repo = Path(__file__).resolve().parents[1]
    deploy = repo / "script/deploy"
    assert not (deploy / "params-required.sh").exists(), (
        "必填键在调用点用 params_require_keys/values 声明，不再单设 params-required.sh")
    loaded = {}
    required = {}
    for script in sorted(deploy.glob("*.sh")):
        text = script.read_text()
        if 'source "$SCRIPT_DIR/params.sh"' not in text:
            continue
        for name in _params_loaded_files(text):
            loaded.setdefault(name, set()).add(script.name)
        for pair in _params_required_pairs(text):
            required.setdefault(pair, set()).add(script.name)
    for (file_name, key), scripts in sorted(required.items()):
        missing = loaded.get(file_name, set()) - scripts
        assert not missing, (file_name, key, sorted(missing))


def verifier_skip_never_production() -> None:
    """生产链不能出现在跳过列表：验证默认开启，跳过必须显式且只针对没有浏览器的链。"""
    profile = Path(__file__).resolve().parents[1] / "script/network/verifier.params"
    assert profile.is_file(), "script/network/verifier.params 缺失"
    text = profile.read_text()
    url = re.search(r"^ETHERSCAN_VERIFIER_URL=(.*)$", text, re.MULTILINE)
    skip = re.search(r"^VERIFY_SKIP_CHAIN_IDS=(.*)$", text, re.MULTILINE)
    assert url and url.group(1).strip(), (profile, "ETHERSCAN_VERIFIER_URL 为空")
    assert skip, (profile, "缺少 VERIFY_SKIP_CHAIN_IDS")
    skipped = {item.strip() for item in skip.group(1).split(",") if item.strip()}
    assert not skipped & {"56", "97"}, (profile, sorted(skipped))


def main():
    params_shared_copy()
    params_loader_cases()
    params_unset_coverage()
    params_required_consistency()
    verifier_skip_never_production()
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

        getters("ACTION_TARGET", {"MINT_ADDRESS()(address)": "MINT_ADDRESS",
                "VOTE_ADDRESS()(address)": "VOTE_ADDRESS", "SUBMIT_ADDRESS()(address)": "SUBMIT_ADDRESS",
                "MEMBER_NFT_ADDRESS()(address)": "MEMBER_NFT_ADDRESS", "PHASE_ADDRESS()(address)": "PHASE_ADDRESS"})
        for name in ("LP_EXECUTOR", "GROUP_ACTION_EXECUTOR", "GROUP_SERVICE_EXECUTOR"):
            getters(name, {"ACTION_TARGET_ADDRESS()(address)": "ACTION_TARGET_ADDRESS",
                           "STAKE_ADDRESS()(address)": "STAKE_ADDRESS",
                           "MEMBER_NFT_ADDRESS()(address)": "MEMBER_NFT_ADDRESS",
                           "PHASE_ADDRESS()(address)": "PHASE_ADDRESS"})
        getters("LP_EXECUTOR", {"PAIR_FACTORY_ADDRESS()(address)": "PAIR_FACTORY_ADDRESS"})
        getters("GROUP_ACTION_EXECUTOR", {"VOTE_ADDRESS()(address)": "VOTE_ADDRESS"})
        getters("GROUP_SERVICE_EXECUTOR", {
            "LAUNCH_ADDRESS()(address)": "LAUNCH_ADDRESS",
            "MINT_ADDRESS()(address)": "MINT_ADDRESS",
            "GROUP_ACTION_EXECUTOR_ADDRESS()(address)": "GROUP_ACTION_EXECUTOR_ADDRESS"
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

        # Executor 的协议地址在构造函数写入 immutable：产物槽位为零，链上是真实值。
        # 在 byte 100 放一个 32 字节槽，覆盖 21_check 按 immutableReferences 回填的逻辑。
        def with_immutable(body_hex, fill):
            return body_hex[:200] + fill * 32 + body_hex[264:]

        immutables = {}
        inspect = {}
        for executor, contract in executor_contracts.items():
            address = env[executor + "_ADDRESS"].lower()
            body = code[address][2:] + "ee" * (200 - len(code[address][2:]) // 2)
            code[address] = "0x" + with_immutable(body, "11")
            inspect[contract] = "0x" + with_immutable(body, "00")
            immutables[contract] = {"0": [{"start": 100, "length": 32}]}
        # ActionTarget 不链接库、无 immutable，产物与链上应直接一致。
        address = env["ACTION_TARGET_ADDRESS"].lower()
        code[address] = "0x" + "aa" * 200
        inspect["ActionTarget"] = code[address]
        # LpExecutor 无链接库，但有 immutable。
        lp_body = "bb" * 200
        code[env["LP_EXECUTOR_ADDRESS"].lower()] = "0x" + with_immutable(lp_body, "11")
        inspect["LpExecutor"] = "0x" + with_immutable(lp_body, "00")
        immutables["LpExecutor"] = {"0": [{"start": 100, "length": 32}]}
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
            "inspect": inspect, "immutables": immutables, "library_canonical": library_canonical}))
        network.joinpath("network.params").write_text("CHAIN_ID=97\nRPC_URL=http://invalid.local\n")
        network.parent.joinpath("verifier.params").write_text(
            "ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api\nVERIFY_SKIP_CHAIN_IDS=31337\n")
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
        # 非 immutable 槽位仍须逐字节一致：回填逻辑不能掩盖其它差异。
        result, _ = run("21_check.sh", False, ("test",), BAD_CODE=env["LP_EXECUTOR_ADDRESS"])
        assert "LpExecutor runtime does not match" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        # linkReferences 的 start 不是 immutable：落在该偏移的差异必须失败，不能被回填掩盖。
        result, _ = run("21_check.sh", False, ("test",),
                        MUTATE=f"{env['GROUP_ACTION_EXECUTOR_ADDRESS']}:150")
        assert "GroupActionExecutor runtime does not match" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        # 空数组表示不分层：链上 SPLITS 也应为空时通过。
        params_path = network / "action.params"
        params_text = params_path.read_text()
        params_path.write_text("GROUP_ACTION_SPLITS=\n")
        run("21_check.sh", args=("test",), MOCK_EMPTY_SPLITS="1")
        # 键缺失不能被调用方注入的同名变量顶替：键存在性只看文件。
        params_path.write_text("")
        result, _ = run("21_check.sh", False, ("test",), GROUP_ACTION_SPLITS=env["GROUP_ACTION_SPLITS"])
        assert "GROUP_ACTION_SPLITS must be set" in result.stdout + result.stderr, \
            result.stdout + result.stderr
        params_path.write_text(params_text)
        for contract, signature in [("ACTION_TARGET", "MINT_ADDRESS()(address)"), ("ACTION_TARGET", "VOTE_ADDRESS()(address)"),
                ("ACTION_TARGET", "SUBMIT_ADDRESS()(address)"), ("ACTION_TARGET", "MEMBER_NFT_ADDRESS()(address)"),
                ("ACTION_TARGET", "PHASE_ADDRESS()(address)"), ("LP_EXECUTOR", "ACTION_TARGET_ADDRESS()(address)"),
                ("LP_EXECUTOR", "STAKE_ADDRESS()(address)"), ("LP_EXECUTOR", "PAIR_FACTORY_ADDRESS()(address)"),
                ("GROUP_ACTION_EXECUTOR", "VOTE_ADDRESS()(address)"),
                ("GROUP_SERVICE_EXECUTOR", "LAUNCH_ADDRESS()(address)"),
                ("GROUP_SERVICE_EXECUTOR", "MINT_ADDRESS()(address)"),
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
                      {"BAD_CALL": env["ACTION_TARGET_ADDRESS"] + "/MINT_ADDRESS()(address)"}):
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
        assert any(source_of(call) == "src/GroupActionJoin.sol:GroupActionJoin" for call in verify_calls(log)), log
        assert "Source verification succeeded" not in result.stdout
        _, log = run("31_verify.sh", args=("test",))
        assert_verify_plan(log)
        # ActionTarget 与三个 Executor 的构造参数必须回填，且逐槽与 CONSTRUCTOR_SLOTS 对齐；
        # GroupActionExecutor 的 splits 以数组字面量编码。
        encoder_calls = [call for call in log if call[:2] == ["cast", "abi-encode"]]
        assert len(encoder_calls) == 4, encoder_calls
        splits_call = next(call for call in encoder_calls if "uint256[]" in call[2])
        assert "[" + env["GROUP_ACTION_SPLITS"] + "]" in splits_call, splits_call
        for contract in CONSTRUCTOR_SLOTS:
            verify_constructor_arguments(action, contract, log, env)
        by_source = verifies_by_source(log)
        for source in ("src/ActionTarget.sol:ActionTarget", "src/LpExecutor.sol:LpExecutor",
                       "src/GroupActionExecutor.sol:GroupActionExecutor",
                       "src/GroupServiceExecutor.sol:GroupServiceExecutor"):
            assert by_source[source][by_source[source].index("--constructor-args") + 1] == "0x1234", by_source[source]
        # ActionTarget、LpExecutor、GroupServiceExecutor 共用 constructor(address) 签名：
        # 同签名失败会在第一次编码（ActionTarget）处中止，因此先证明三次编码确实共用该签名，
        # 再用入参地址分别验证三个合约各自的失败路径。
        ctor_address_calls = [call for call in encoder_calls if call[2] == "constructor(address)"]
        assert len(ctor_address_calls) == 3, ctor_address_calls
        result, log = run("31_verify.sh", False, ("test",), ABI_ENCODE_FAIL="constructor(address)")
        assert "Failed to encode ActionTarget constructor arguments" in result.stdout, result.stdout
        assert not any(call[0] == "forge" for call in log)
        result, log = run("31_verify.sh", False, ("test",), ABI_ENCODE_FAIL="constructor(address,uint256[])")
        assert "Failed to encode GroupActionExecutor constructor arguments" in result.stdout, result.stdout
        assert not any(call[0] == "forge" for call in log)
        for arg_key, label in [("MINT_ADDRESS", "ActionTarget"), ("ACTION_TARGET_ADDRESS", "LpExecutor"),
                               ("GROUP_ACTION_EXECUTOR_ADDRESS", "GroupServiceExecutor")]:
            result, log = run("31_verify.sh", False, ("test",), ABI_ENCODE_FAIL_ARG=env[arg_key])
            assert f"Failed to encode {label} constructor arguments" in result.stdout, result.stdout
            assert not any(call[0] == "forge" for call in log)
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
        # 跳过必须显式声明：把 31337 从列表里去掉后，同一条链默认验证而不是静默跳过。
        network.parent.joinpath("verifier.params").write_text(
            "ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api\nVERIFY_SKIP_CHAIN_IDS=\n")
        result, log = run("31_verify.sh", args=("test",))
        assert "Skip" not in result.stdout, result.stdout
        assert [call for call in log if call[:2] == ["forge", "verify-contract"]], log
        network.parent.joinpath("verifier.params").write_text(
            "ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api\nVERIFY_SKIP_CHAIN_IDS=31337\n")
        network.parent.joinpath("verifier.params").write_text(
            "ETHERSCAN_VERIFIER_URL=https://api.etherscan.io/v2/api\nVERIFY_SKIP_CHAIN_IDS=31337\n")
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
