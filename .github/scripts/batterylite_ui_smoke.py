#!/usr/bin/env python3
"""Minimal Android emulator smoke check for BatteryLite's three navigation pages."""
import re
import subprocess
import time
import xml.etree.ElementTree as ET

PACKAGE="com.example.batterylite"

def adb(*args):
    return subprocess.run(["adb", *args], check=True, text=True, capture_output=True).stdout

def dump(filename):
    adb("shell","uiautomator","dump",f"/sdcard/{filename}")
    adb("pull",f"/sdcard/{filename}",filename)
    return ET.parse(filename).getroot()

def strings(root):
    return [node.attrib.get("text","") for node in root.iter("node")]

def assert_text(root,s):
    ts=strings(root)
    assert any(s in x for x in ts), f"missing {s!r}; visible texts: {ts!r}"

def tap_tab(root, label):
    nodes=[x for x in root.iter("node") if x.attrib.get("text")==label]
    assert nodes, f"Missing tab {label}"
    x1,y1,x2,y2=map(int,re.findall(r"\d+",nodes[0].attrib["bounds"]))
    adb("shell","input","tap",str((x1+x2)//2),str((y1+y2)//2))

def assert_alive():
    pid=adb("shell","pidof",PACKAGE).strip()
    assert pid, "BatteryLite process terminated unexpectedly"

def main():
    adb("install","batterylite/BatteryLite-OnePlus13-v1.2.apk")
    print(adb("shell","am","start","-W","-n",PACKAGE+"/.MainActivity"))
    time.sleep(6)
    assert_alive()
    home=dump("dashboard.xml")
    assert_text(home,"电池仪表")
    assert_text(home,"电压")
    print("PASS: Dashboard opened")

    tap_tab(home,"统计")
    time.sleep(2)
    stats=dump("stats.xml")
    assert_text(stats,"实时曲线")
    assert_text(stats,"充电记录")
    print("PASS: Statistics and charge history opened")
    assert_alive()

    tap_tab(stats,"诊断")
    time.sleep(2)
    diagnostics=dump("diagnostics.xml")
    assert_text(diagnostics,"原始电池诊断")
    assert_text(diagnostics,"温度提醒阈值")
    print("PASS: Diagnostics and notification settings opened")
    assert_alive()
    print("PASS: BatteryLite 1.2 emulator UI navigation smoke")

if __name__=="__main__":
    main()
