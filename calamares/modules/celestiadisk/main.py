#!/usr/bin/env python3
"""Calamares job: create Celestia's partitions in the place picked in
celestia-diskpick, then publish them the way the partition module would, so
mount, fstab and the rest of the installer work unchanged."""

import json
import subprocess

import libcalamares

TARGET_FILE = "/run/celestia/target"


def pretty_name():
    return "Подготовка диска"


def run():
    try:
        with open(TARGET_FILE) as f:
            target = f.read().strip()
    except OSError:
        return ("Не выбрано место установки",
                "Перезапусти установщик и выбери, куда установить Celestia. Диск не изменён.")

    libcalamares.utils.debug(f"celestiadisk: target {target}")
    proc = subprocess.run(["/usr/local/bin/celestia-disks", "apply", target],
                          capture_output=True, text=True)
    for line in proc.stderr.splitlines():
        libcalamares.utils.debug(line)

    if proc.returncode == 2:
        reason = (proc.stderr.strip().splitlines() or ["Проверка не пройдена."])[-1]
        return ("Установка остановлена — диск НЕ изменён", reason)
    if proc.returncode != 0:
        return ("Ошибка при разметке диска",
                "Разметка прервана. Разделы Windows и другие существующие разделы "
                "проверялись перед записью.\n\n" + proc.stderr.strip()[-1500:])

    partitions = json.loads(proc.stdout)["partitions"]
    gs = libcalamares.globalstorage
    gs.insert("partitions", partitions)
    gs.insert("firmwareType", "efi")
    gs.insert("efiSystemPartition", "/boot/efi")
    return None
