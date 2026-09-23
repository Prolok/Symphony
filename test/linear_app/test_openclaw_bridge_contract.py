"""Synthetic v1 interoperability oracle, NOT the LinearBridge implementation or a live proof."""
import base64
import copy
import hashlib
import hmac
import json
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[2]
FIXTURES = REPO / "test/fixtures/openclaw/linear_bridge"
SCHEMA = json.loads((REPO / "docs/contracts/linearbridge-lifecycle-v1.schema.json").read_text())
KEY = b"*" * 32
METHOD = "linearbridge.symphony.lifecycle.v1"


def shape(value, schema):
    if "$ref" in schema:
        return shape(value, SCHEMA["$defs"][schema["$ref"].rsplit("/", 1)[1]])
    if "oneOf" in schema:
        if sum(matches(value, choice) for choice in schema["oneOf"]) != 1:
            raise ValueError("oneOf")
        return
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        raise ValueError("const")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError("enum")
    kind = schema.get("type")
    expected = {"object": dict, "array": list, "string": str, "boolean": bool, "integer": int, "null": type(None)}
    if kind in expected and type(value) is not expected[kind]:
        raise ValueError("type")
    if kind == "number" and type(value) not in (int, float):
        raise ValueError("number")
    if kind == "object":
        if not set(schema["required"]) <= set(value) or set(value) - set(schema["properties"]):
            raise ValueError("keys")
        for name, item in value.items():
            shape(item, schema["properties"][name])
    if kind == "array":
        if len(value) < schema.get("minItems", 0) or (schema.get("uniqueItems") and len({json.dumps(x, sort_keys=True) for x in value}) != len(value)):
            raise ValueError("items")
        for item in value:
            shape(item, schema["items"])
    if kind == "string":
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", float("inf")):
            raise ValueError("length")
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            raise ValueError("pattern")
    if kind == "integer" and not schema.get("minimum", -float("inf")) <= value <= schema.get("maximum", float("inf")):
        raise ValueError("range")


def matches(value, schema):
    try:
        shape(value, schema)
        return True
    except ValueError:
        return False


def unique_object(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate JSON key")
    return result


def wire(payload=None, raw=None):
    raw = raw if raw is not None else json.dumps(payload, separators=(",", ":")).encode()
    encoded = base64.b64encode(raw).decode()
    message = f"{METHOD}\nproducer-key-example\n{encoded}".encode()
    return dict(version=1, key_id="producer-key-example", payload_b64=encoded,
                mac=hmac.new(KEY, message, hashlib.sha256).hexdigest())


class SyntheticConsumer:
    """An in-memory test oracle: no Linear API, plugin installation, or persistence claim."""
    def __init__(self, bindings):
        self.bindings = bindings
        self.records = {}
        self.active = {}

    def accept(self, envelope):
        shape(envelope, SCHEMA["$defs"]["envelope"])
        if envelope["key_id"] != "producer-key-example":
            raise ValueError("key")
        expected = wire(raw=base64.b64decode(envelope["payload_b64"], validate=True))
        if not hmac.compare_digest(envelope["mac"], expected["mac"]):
            raise ValueError("mac")
        raw = base64.b64decode(envelope["payload_b64"])
        if len(raw) > 262144:
            raise ValueError("size")
        payload = json.loads(raw, object_pairs_hook=unique_object)
        shape(payload, SCHEMA["$defs"]["payload"])
        binding, observation = payload["binding"], payload["observation"]
        order = binding["order_id"]
        if (payload["producer_id"] != "symphony-example" or payload["consumer_account_id"] != "account-example"
                or binding != self.bindings.get(order)):
            raise ValueError("binding")
        end = observation["terminal"]
        terminal = end is not None and end["runId"] == order and observation["state"] in ("completed", "failed", "cancelled")
        if end is not None and not terminal:
            raise ValueError("foreign terminal")
        sequence, digest = payload["sequence"], hashlib.sha256(raw).hexdigest()
        prior = self.records.get(order)
        if prior and sequence < prior[0]:
            return "stale"
        if prior and sequence == prior[0]:
            if digest != prior[1]:
                raise ValueError("sequence conflict")
            return "duplicate"
        if prior and prior[2] and not terminal:
            raise ValueError("terminal tombstone")
        self.records[order] = sequence, digest, terminal
        for issue in binding["issue_ids"]:
            active = self.active.setdefault(issue, set())
            if terminal:
                active.discard(order)
            elif observation["acceptance_observed"] or observation["execution_observed"]:
                active.add(order)
        return "stored"


class BridgeContractTests(unittest.TestCase):
    def setUp(self):
        self.incoming, self.review, self.completed = [json.loads((FIXTURES / name).read_text()) for name in ("incoming.json", "review.json", "review-completed.json")]
        self.consumer = SyntheticConsumer({p["binding"]["order_id"]: p["binding"] for p in (self.incoming, self.review)})

    def test_neutral_fixtures_match_schema_and_native_binding(self):
        for payload in (self.incoming, self.review, self.completed):
            shape(payload, SCHEMA["$defs"]["payload"])
            shape(wire(payload), SCHEMA["$defs"]["envelope"])
            binding = payload["binding"]
            self.assertEqual(binding["issue_ids"], sorted(set(binding["issue_ids"])))
            self.assertEqual(binding["native"]["runId"], binding["order_id"])
            self.assertEqual(binding["native"]["sessionKey"], "agent:{}:symphony:{}:{}:{}".format(binding["openclaw_agent_id"], hashlib.sha256(binding["project_id"].encode()).hexdigest(), binding["group"], binding["order_id"]))

    def test_overlap_duplicate_stale_and_terminal_tombstone(self):
        for payload in (self.incoming, self.review):
            self.assertEqual(self.consumer.accept(wire(payload)), "stored")
            self.assertEqual(self.consumer.accept(wire(payload)), "duplicate")
        shared = self.incoming["binding"]["issue_ids"][0]
        self.assertEqual(len(self.consumer.active[shared]), 2)
        self.consumer.accept(wire(self.completed))
        self.assertEqual(self.consumer.active[shared], {self.incoming["binding"]["order_id"]})
        self.assertEqual(self.consumer.accept(wire(self.review)), "stale")
        late = copy.deepcopy(self.review)
        late["sequence"] = 4
        self.assertRaises(ValueError, self.consumer.accept, wire(late))
        self.assertEqual(len(self.consumer.active[shared]), 1)

    def test_intent_unknown_cancel_ack_do_not_authorize_clear(self):
        intent = copy.deepcopy(self.review)
        intent["sequence"] = 1
        intent["observation"].update(state="intent", acceptance_observed=False)
        self.consumer.accept(wire(intent))
        self.assertFalse(any(self.consumer.active.values()))
        self.consumer.accept(wire(self.review))
        uncertain = copy.deepcopy(self.review)
        uncertain["sequence"] = 3
        uncertain["observation"].update(state="unknown", writable=False, cancel_requested=True, abort_acknowledged=True)
        self.consumer.accept(wire(uncertain))
        self.assertTrue(all(self.consumer.active.values()))

    def test_authenticated_foreign_bindings_and_unsigned_changes_have_no_effect(self):
        for key in self.review["binding"]:
            wrong = copy.deepcopy(self.review)
            wrong["binding"][key] = self.incoming["binding"][key] if self.incoming["binding"][key] != wrong["binding"][key] else "foreign"
            self.assertRaises(ValueError, self.consumer.accept, wire(wrong))
        for key in ("producer_id", "consumer_account_id", "version"):
            wrong = copy.deepcopy(self.review)
            wrong[key] = "foreign"
            self.assertRaises(ValueError, self.consumer.accept, wire(wrong))
        valid = wire(self.review)
        for key, value in (("version", 2), ("key_id", "other-key"), ("mac", "0" * 64)):
            self.assertRaises(ValueError, self.consumer.accept, dict(valid, **{key: value}))
        raw = json.dumps(self.review).replace('"version": 1', '"version": 1, "version": 1').encode()
        self.assertRaises(ValueError, self.consumer.accept, wire(raw=raw))
        self.assertEqual(self.consumer.records, {})
        self.assertEqual(self.consumer.active, {})

    def test_conflicting_sequence_and_foreign_terminal_are_rejected(self):
        self.consumer.accept(wire(self.review))
        conflict = copy.deepcopy(self.review)
        conflict["observation"]["writable"] = False
        self.assertRaises(ValueError, self.consumer.accept, wire(conflict))
        wrong_end = copy.deepcopy(self.completed)
        wrong_end["observation"]["terminal"]["runId"] = self.incoming["binding"]["order_id"]
        self.assertRaises(ValueError, self.consumer.accept, wire(wrong_end))
        self.assertTrue(all(self.consumer.active.values()))
