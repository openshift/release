#!/bin/python3
import os
import subprocess
import xml.etree.cElementTree as ET

ARTIFACT_DIR = os.environ["ARTIFACT_DIR"]
JUNIT_DIR = os.path.join(ARTIFACT_DIR, "junit")
os.mkdir(JUNIT_DIR)
JUNIT_FILE = os.path.join(JUNIT_DIR, "junit_symptoms.xml")
TEST_FAILURES = []

class Symptom:
  search_string = None
  location = None
  test_name = None
  message = None

  def __init__(self, search_string, location, test_name):
    self.search_string = search_string
    self.location = location
    self.test_name = test_name

SYMPTOMS = (
  Symptom(
    search_string="Undiagnosed panic detected in pod",
    location="pods/*",
    test_name="Observed a panic in pod"
  ),
  Symptom(
    search_string="Undiagnosed panic detected in journal",
    location="nodes/*/journal*",
    test_name="Observed a panic in journal"
  ),
  Symptom(
    search_string="segfault",
    location="nodes/*/journal*",
    test_name="Observed process segfault"
  ),
)

for symptom in SYMPTOMS:
  print(f"Looking for '{symptom.search_string}' in '{symptom.location}'")

  cmd = ["zgrep", "-E", symptom.search_string, os.path.join(ARTIFACT_DIR, symptom.location)]
  output = None
  try:
    output = subprocess.check_output(cmd, stderr=subprocess.STDOUT).decode('utf-8')
  except subprocess.CalledProcessError:
    continue
  if not output:
    continue
  print(f'  {output}')
  # Copy symptom and set error message
  error = copy(symptom)
  error.message = output
  TEST_FAILURES += error

print(f"Found {len(TEST_FAILURES)} matching symptoms")

root = ET.Element("root")
xml_testsuite = ET.SubElement(
  root,
  "testsuite",
  name="Symptom Detection",
  tests=str(len(SYMPTOMS)),
  errors="0",
  failures=str(len(TEST_FAILURES)),
  skipped="0",
  time="0",
  timestamp="0001-01-01T00:00:00Z",
  package="symptom")

for failure in TEST_FAILURES:
  testcase = ET.SubElement(
    xml_testsuite,
    "testcase",
    name=failure.test_name)
  ET.SubElement(test_case,"failure").text = failure.message

tree = ET.ElementTree(root)
tree.write(JUNIT_FILE)
