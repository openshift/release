import json

with open("test.json", "r") as test_json:
	json_str = json.dumps(json.loads(test_json.read()))

print(json_str)
print(type(json_str))
