"""Open the native settings action using observed accessibility bounds."""
import re
import subprocess
import xml.etree.ElementTree as ET

subprocess.run(["adb", "shell", "uiautomator", "dump", "/sdcard/window.xml"], check=True)
data = subprocess.check_output(["adb", "shell", "cat", "/sdcard/window.xml"])
nodes = ET.fromstring(data).iter("node")
node = next(node for node in nodes if node.get("content-desc") == "设置")
x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.attrib["bounds"]))
subprocess.run(["adb", "shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2)], check=True)
