"""Offline tests for celestia-disks with simulated disks (no real disk access).

Run: python3 tests/test_celestia_disks.py   (needs no root, touches no disks)
"""
import copy
import importlib.machinery
import json
import os
import sys
import types

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "profile", "airootfs",
                   "usr", "local", "bin", "celestia-disks")
mod = types.ModuleType("cd")
importlib.machinery.SourceFileLoader("cd", SRC).exec_module(mod)

GiB, MiB = mod.GiB, mod.MiB
SS = 512
ESP, MSR, MSDATA, WINRE = mod.ESP_TYPE, "e3c9e316-0b5c-4db8-817d-f92df00215ae", "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7", "de94bba4-06d1-4d40-a16a-bfd50179d6ac"
LINUX = "0fc63daf-8483-4772-8e79-3d69d8477de4"


def gpt(device, total_bytes, parts):
    """parts: list of (start_mib, size_mib, type, fstype, label, mounted)"""
    tparts, children = [], []
    for i, (s, size, typ, fs, label, mounted) in enumerate(parts, 1):
        node = f"{device}{'p' if 'nvme' in device else ''}{i}"
        uuid = f"00000000-0000-0000-0000-{abs(hash(node)) % 10**12:012d}"
        tparts.append({"node": node, "start": s * MiB // SS, "size": size * MiB // SS, "type": typ.upper(), "uuid": uuid.upper()})
        children.append({"path": node, "type": "part", "size": size * MiB, "parttype": typ, "partuuid": uuid,
                         "fstype": fs, "label": label, "mountpoints": [mounted] if mounted else [None]})
    total = total_bytes // SS
    table = {"label": "gpt", "device": device, "firstlba": 34, "lastlba": total - 34, "sectorsize": SS, "partitions": tparts}
    disk = {"path": device, "type": "disk", "size": total_bytes, "model": "Model " + device, "ro": False,
            "pttype": "gpt", "children": children}
    return disk, table


class World:
    def __init__(self, disks):
        self.disks = {d["path"]: (d, t) for d, t in disks}
        self.cmds = []
        self.live = set()
        self.esp = {}  # path -> (windows, free)
        self.tamper = None

    def install(self):
        mod.lsblk = lambda: [copy.deepcopy(d) for d, _ in self.disks.values()]
        mod.sfdisk_table = lambda p: copy.deepcopy(self.disks[p][1]) if self.disks[p][1] else None
        mod.active_swaps = lambda: set()
        mod.live_medium_disks = lambda devs: self.live
        mod.inspect_esp = lambda p: self.esp.get(p, (False, 50 * MiB))
        mod.blkid = lambda dev, tag: f"{tag}-{dev}"
        mod.run = self.run
        mod.disk_geometry = lambda p: (SS, self.disks[p][0]["size"] // SS)
        mod.wait_for_node = lambda dev, disk: None

    def run(self, cmd, check=True):
        self.cmds.append(cmd)
        if cmd[0] == "sgdisk":
            disk = cmd[-1]
            d, t = self.disks[disk]
            args = cmd[3:-1]
            if "-o" in args:
                t["partitions"] = []
            if "-d" in args:
                n = args[args.index("-d") + 1]
                t["partitions"] = [p for p in t["partitions"] if not p["node"].endswith(("p" if "nvme" in disk else "") + n) or p["node"] == disk]
            if "-n" in args:
                _, s, e = args[args.index("-n") + 1].split(":")
                used = {int(mod.re.search(r"(\d+)$", p["node"]).group(1)) for p in t["partitions"]}
                num = min(set(range(1, 129)) - used)
                t["partitions"].append({"node": f"{disk}{'p' if 'nvme' in disk else ''}{num}", "start": int(s),
                                        "size": int(e) - int(s) + 1, "type": "X", "uuid": f"NEW-{num}"})
                if self.tamper:
                    self.tamper(t)
        return ""


def overlaps(t):
    ps = sorted(t["partitions"], key=lambda p: p["start"])
    for a, b in zip(ps, ps[1:]):
        if a["start"] + a["size"] > b["start"]:
            return True
    return any(p["start"] + p["size"] - 1 > t["lastlba"] for p in ps)


def check(name, cond):
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        global failed
        failed = True


failed = False

# ---- 1. The user's PC: Windows on NVMe + 540.9 GiB free, data HDD, USB stick
def user_pc():
    nvme = gpt("/dev/nvme0n1", 1000204886016, [
        (1, 200, ESP, "vfat", "", None),
        (201, 16, MSR, "", "", None),
        (217, int(389.52 * 1024), MSDATA, "ntfs", "Windows", None),
        (217 + int(389.52 * 1024), 922, WINRE, "ntfs", "", None),
    ])
    hdd = gpt("/dev/sda", 6001175126016, [(1, 16, MSR, "", "", None), (17, 5723000, MSDATA, "ntfs", "Data", None)])
    usb = gpt("/dev/sdb", 16 * GiB, [(1, 5000, LINUX, "iso9660", "CELESTIA", "/run/archiso/bootmnt")])
    w = World([nvme, hdd, usb])
    w.live = {"/dev/sdb"}
    w.esp = {"/dev/nvme0n1p1": (True, 120 * MiB)}
    return w

w = user_pc(); w.install()
s = mod.scan()
print(json.dumps([(o["kind"], o["title"], o.get("reuse_esp")) for o in s["options"]], ensure_ascii=False))
check("user PC: only one option, free space on NVMe", len(s["options"]) == 1 and s["options"][0]["kind"] == "free" and s["options"][0]["disk"] == "/dev/nvme0n1")
check("user PC: free space ~540 GiB", "54" in s["options"][0]["title"])
check("user PC: Windows ESP reused", s["options"][0]["reuse_esp"] == "/dev/nvme0n1p1")
check("user PC: no whole-disk option for Windows/HDD/USB", not any(o["kind"] == "disk" for o in s["options"]))
reasons = {p["device"]: p["reason"] for p in s["protected"]}
check("user PC: Windows ESP protected", reasons.get("/dev/nvme0n1p1") == "загрузчик Windows")
check("user PC: NTFS protected", reasons.get("/dev/nvme0n1p3") == "раздел Windows")
check("user PC: HDD data protected", reasons.get("/dev/sda2") == "раздел Windows")
check("user PC: USB protected", reasons.get("/dev/sdb1") == "флешка с установщиком")
check("user PC: windows detected", s["windows"])

before = copy.deepcopy(w.disks["/dev/nvme0n1"][1]["partitions"])
res = mod.apply(s["options"][0]["id"])
after = w.disks["/dev/nvme0n1"][1]
check("apply free: existing partitions unchanged", after["partitions"][:4] == before)
check("apply free: no overlaps", not overlaps(after))
check("apply free: created boot+root, reused ESP", [r["mountPoint"] for r in res] == ["/boot", "/", "/boot/efi"])
check("apply free: reused ESP not formatted", res[-1]["claimed"] is False and not any(c[0] == "mkfs.fat" for c in w.cmds))
check("apply free: HDD untouched", not any("/dev/sda" in " ".join(c) for c in w.cmds))
check("apply free: never deletes or zaps", not any(("-d" in c or "-Z" in c or "-o" in c) and c[0] == "sgdisk" for c in w.cmds))
check("apply free: never wipes Windows partitions", not any(c[0] == "wipefs" and c[1] in ("/dev/nvme0n1p1", "/dev/nvme0n1p3", "/dev/nvme0n1") for c in w.cmds))
new = after["partitions"][4:]
check("apply free: /boot is 2 GiB", new[0]["size"] * SS == 2 * GiB)
check("apply free: root fills the rest", new[1]["start"] + new[1]["size"] - 1 <= after["lastlba"] and new[1]["size"] * SS > 530 * GiB)

# ---- 2. Option disappears between scan and apply -> refused, nothing written
w = user_pc(); w.install()
oid = mod.scan()["options"][0]["id"]
w.disks["/dev/nvme0n1"][1]["partitions"].append({"node": "/dev/nvme0n1p5", "start": 900 * GiB // SS, "size": GiB // SS, "type": MSDATA, "uuid": "X"})
w.disks["/dev/nvme0n1"][0]["children"].append({"path": "/dev/nvme0n1p5", "type": "part", "size": GiB, "parttype": MSDATA, "partuuid": "x", "fstype": "ntfs", "label": "", "mountpoints": [None]})
try:
    mod.apply(oid); check("changed disk: refused", False)
except mod.Refused:
    check("changed disk: refused, no commands", not any(c[0] in ("sgdisk", "wipefs", "mkfs.btrfs") for c in w.cmds))

# ---- 3. Post-write verification catches a modified neighbour
w = user_pc(); w.install()
oid = mod.scan()["options"][0]["id"]
w.tamper = lambda t: t["partitions"][2].__setitem__("size", t["partitions"][2]["size"] - 1)
try:
    mod.apply(oid); check("tampered neighbour: detected", False)
except mod.WriteFailed:
    check("tampered neighbour: detected", not any(c[0].startswith("mkfs") for c in w.cmds))

# ---- 4. Second disk with an old Linux install: reuse partition or whole disk
lin = gpt("/dev/sdc", 500 * GiB, [(1, 512, ESP, "vfat", "", None), (513, 100 * 1024, LINUX, "ext4", "old", None),
                                  (513 + 100 * 1024, 300 * 1024, LINUX, "btrfs", "", None)])
w = World([lin]); w.install()
s = mod.scan()
kinds = sorted(o["kind"] for o in s["options"])
check("linux disk: part x2 + free + disk offered", kinds == ["disk", "free", "part", "part"])
part = [o for o in s["options"] if o["kind"] == "part" and "sdc2" in o["title"]][0]
check("linux disk: partition reuse marked destructive", part["destructive"])
res = mod.apply(part["id"])
t = w.disks["/dev/sdc"][1]
check("reuse partition: deleted only sdc2", any(c[0] == "sgdisk" and "-d" in c and c[c.index("-d") + 1] == "2" for c in w.cmds))
check("reuse partition: sdc1 and sdc3 kept", {p["node"] for p in t["partitions"]} >= {"/dev/sdc1", "/dev/sdc3"})
check("reuse partition: no overlaps", not overlaps(t))

w = World([gpt("/dev/sdc", 500 * GiB, [(1, 512, ESP, "vfat", "", None), (513, 100 * 1024, LINUX, "ext4", "old", None)])]); w.install()
d = [o for o in mod.scan()["options"] if o["kind"] == "disk"][0]
res = mod.apply(d["id"])
t = w.disks["/dev/sdc"][1]
check("whole disk: new ESP + boot + root", [r["mountPoint"] for r in res] == ["/boot/efi", "/boot", "/"] and len(t["partitions"]) == 3)
check("whole disk: no overlaps, inside disk", not overlaps(t))

# ---- 5. Disk with Windows ESP + BitLocker: no whole-disk, warning shown
bl = gpt("/dev/nvme1n1", 1000 * GiB, [(1, 100, ESP, "vfat", "", None), (101, 16, MSR, "", "", None),
                                      (117, 400 * 1024, MSDATA, "BitLocker", "", None)])
w = World([bl]); w.esp = {"/dev/nvme1n1p1": (True, 10 * MiB)}; w.install()
s = mod.scan()
check("bitlocker: warning", any("BitLocker" in x for x in s["warnings"]))
check("bitlocker: only free space offered", [o["kind"] for o in s["options"]] == ["free"])
check("small Windows ESP: own ESP will be created", s["options"][0]["reuse_esp"] is None)
res = mod.apply(s["options"][0]["id"])
check("small ESP: new ESP created in free space", [r["mountPoint"] for r in res] == ["/boot/efi", "/boot", "/"])
check("small ESP: Windows ESP untouched", not any("/dev/nvme1n1p1" in " ".join(c) for c in w.cmds))

# ---- 6. ext4 partition mounted, exFAT, LUKS -> protected; too-small free -> not offered
m = gpt("/dev/sdd", 100 * GiB, [(1, 40 * 1024, LINUX, "ext4", "", "/mnt"), (40 * 1024 + 1, 40 * 1024, MSDATA, "exfat", "USB", None),
                                 (80 * 1024 + 1, 10 * 1024, LINUX, "crypto_LUKS", "", None)])
w = World([m]); w.install()
s = mod.scan()
check("mounted/exfat/luks: nothing offered", s["options"] == [])
check("mounted/exfat/luks: all protected", len(s["protected"]) == 3)

# ---- 7. C-01: data without a partition table / RAID members -> fully protected
def raw_disk(path, fstype, children=()):
    return {"path": path, "type": "disk", "size": 1000 * GiB, "model": "M", "ro": False,
            "pttype": None, "fstype": fstype, "children": list(children)}

w = World([])
w.install()
raw = [raw_disk("/dev/sdb", "ntfs"),
       raw_disk("/dev/sdc", "isw_raid_member", [{"path": "/dev/md126", "type": "raid0", "size": 2000 * GiB}]),
       raw_disk("/dev/sdd", "crypto_LUKS"),
       raw_disk("/dev/sde", "", [{"path": "/dev/mapper/vg-root", "type": "lvm", "size": GiB}])]
mod.lsblk = lambda: copy.deepcopy(raw)
mod.sfdisk_table = lambda p: None
s = mod.scan()
check("C-01: raw NTFS / RAID member / LUKS / stacked disk -> no options", s["options"] == [])
check("C-01: all four disks listed as protected", {p["device"] for p in s["protected"]} == {"/dev/sdb", "/dev/sdc", "/dev/sdd", "/dev/sde"})
check("C-01: raw NTFS counts as Windows", s["windows"])

empty = [raw_disk("/dev/sdf", "")]
mod.lsblk = lambda: copy.deepcopy(empty)
s = mod.scan()
check("C-01: truly empty disk still offered", [o["kind"] for o in s["options"]] == ["disk"])

live_raw = [raw_disk("/dev/sdg", "iso9660")]
mod.lsblk = lambda: copy.deepcopy(live_raw)
mod.live_medium_disks = lambda devs: {"/dev/sdg"}
s = mod.scan()
check("C-01: installer stick (iso9660 on the disk) protected as such",
      s["options"] == [] and s["protected"][0]["reason"] == "флешка с установщиком")

# Partition used by RAID/LVM/crypt (has holders/children) is not reusable
part_held = gpt("/dev/sdh", 200 * GiB, [(1, 100 * 1024, LINUX, "ext4", "", None)])
part_held[0]["children"][0]["children"] = [{"path": "/dev/md0", "type": "raid1", "size": GiB}]
w = World([part_held])
w.install()
s = mod.scan()
check("C-01: partition with stacked device not offered", not any(o["kind"] == "part" for o in s["options"]))

# ---- 8. H-02: an ESP that cannot be inspected is treated as Windows' (fail closed)
d = gpt("/dev/sdi", 500 * GiB, [(1, 100, ESP, "vfat", "", None), (101, 200 * 1024, LINUX, "ext4", "", None)])
w = World([d])
w.esp = {"/dev/sdi1": (None, 0)}  # mount failed
w.install()
s = mod.scan()
check("H-02: unchecked ESP blocks whole-disk wipe", not any(o["kind"] == "disk" for o in s["options"]))
check("H-02: unchecked ESP listed as possibly Windows",
      any(p["device"] == "/dev/sdi1" and "возможно, Windows" in p["reason"] for p in s["protected"]))
check("H-02: Linux partition next to it still reusable", any(o["kind"] == "part" for o in s["options"]))
part_opt = [o for o in s["options"] if o["kind"] == "part"][0]
check("H-02: unchecked ESP is not reused for rEFInd", part_opt.get("reuse_esp") is None)

# ---- 10. M-10: leftovers of a previous Celestia installation
def label(disk, idx, partlabel, fslabel=""):
    disk[0]["children"][idx]["partlabel"] = partlabel
    disk[0]["children"][idx]["label"] = fslabel

# (a) next to Windows: celestia-boot + celestia-root after the Windows partitions
win = gpt("/dev/nvme0n1", 1000 * GiB, [
    (1, 200, ESP, "vfat", "", None),
    (201, 100 * 1024, MSDATA, "ntfs", "Windows", None),
    (201 + 100 * 1024, 2048, LINUX, "ext4", "celestia-boot", None),
    (201 + 102 * 1024, 300 * 1024, "4f68bce3-e8cd-4db1-96e7-fbcaf984b709", "btrfs", "celestia", None),
])
label(win, 2, "celestia-boot", "celestia-boot")
label(win, 3, "celestia-root", "celestia")
w = World([win]); w.esp = {"/dev/nvme0n1p1": (True, 120 * MiB)}; w.install()
s = mod.scan()
prev = [o for o in s["options"] if o["title"].startswith("Предыдущая установка Celestia")]
check("M-10a: previous installation offered once", len(prev) == 1 and len(prev[0]["delete"]) == 2)
check("M-10a: its partitions are not offered separately",
      not any(o["kind"] == "part" and o not in prev for o in s["options"]))
check("M-10a: Windows ESP reused", prev[0]["reuse_esp"] == "/dev/nvme0n1p1")
before = copy.deepcopy(w.disks["/dev/nvme0n1"][1]["partitions"][:2])
res = mod.apply(prev[0]["id"])
t = w.disks["/dev/nvme0n1"][1]
check("M-10a: both leftovers deleted, Windows partitions unchanged",
      t["partitions"][:2] == before and sum(1 for c in w.cmds if c[0] == "sgdisk" and "-d" in c) == 2)
check("M-10a: no overlaps, boot+root recreated", not overlaps(t) and [r["mountPoint"] for r in res] == ["/boot", "/", "/boot/efi"])

# (b) second disk with own ESP + boot + root: all three deleted, new ESP created
own = gpt("/dev/sdb", 500 * GiB, [
    (1, 512, ESP, "vfat", "CELESTIA", None),
    (513, 2048, LINUX, "ext4", "celestia-boot", None),
    (2561, 200 * 1024, "4f68bce3-e8cd-4db1-96e7-fbcaf984b709", "btrfs", "celestia", None),
])
label(own, 0, "EFI system", "CELESTIA")
label(own, 1, "celestia-boot", "celestia-boot")
label(own, 2, "celestia-root", "celestia")
w = World([own]); w.esp = {"/dev/sdb1": (False, 400 * MiB)}; w.install()
s = mod.scan()
prev = [o for o in s["options"] if o["title"].startswith("Предыдущая установка Celestia")]
check("M-10b: own ESP is part of the leftovers", len(prev) == 1 and len(prev[0]["delete"]) == 3)
check("M-10b: ESP being deleted is not reused", prev[0]["reuse_esp"] is None)
res = mod.apply(prev[0]["id"])
check("M-10b: new ESP + boot + root", [r["mountPoint"] for r in res] == ["/boot/efi", "/boot", "/"]
      and not overlaps(w.disks["/dev/sdb"][1]))

# (c) a foreign partition between leftovers -> apply refuses before writing
mix = gpt("/dev/sdc", 500 * GiB, [
    (1, 2048, LINUX, "ext4", "celestia-boot", None),
    (2049, 1024, MSDATA, "ntfs", "Data", None),
    (3073, 100 * 1024, "4f68bce3-e8cd-4db1-96e7-fbcaf984b709", "btrfs", "celestia", None),
])
label(mix, 0, "celestia-boot", "celestia-boot")
label(mix, 2, "celestia-root", "celestia")
w = World([mix]); w.install()
prev = [o for o in mod.scan()["options"] if o["title"].startswith("Предыдущая установка Celestia")]
try:
    mod.apply(prev[0]["id"])
    check("M-10c: NTFS between leftovers -> refused", False)
except mod.Refused:
    check("M-10c: NTFS between leftovers -> refused, nothing written",
          not any(c[0] in ("sgdisk", "wipefs") for c in w.cmds))

# ---- 9. M-09: waiting for partition nodes
fresh = types.ModuleType("cd2")
importlib.machinery.SourceFileLoader("cd2", SRC).exec_module(fresh)
calls = []
fresh.run = lambda cmd, check=True: calls.append(cmd[0]) or ""
fresh.time = types.SimpleNamespace(sleep=lambda s: None)
seen = {"n": 0}
def appears_later(path):
    seen["n"] += 1
    return seen["n"] > 5
fresh.os = types.SimpleNamespace(path=types.SimpleNamespace(exists=appears_later))
try:
    fresh.wait_for_node("/dev/sdx2", "/dev/sdx")
    check("M-09: node appearing late is awaited (partx retried)", "partx" in calls)
except fresh.WriteFailed:
    check("M-09: node appearing late is awaited (partx retried)", False)
fresh.os = types.SimpleNamespace(path=types.SimpleNamespace(exists=lambda p: False))
try:
    fresh.wait_for_node("/dev/sdx2", "/dev/sdx", timeout=2)
    check("M-09: missing node -> WriteFailed with a clear message", False)
except fresh.WriteFailed as e:
    check("M-09: missing node -> WriteFailed with a clear message", "Windows не затронута" in str(e))

print("\nRESULT:", "FAILED" if failed else "ALL PASSED")
sys.exit(1 if failed else 0)
