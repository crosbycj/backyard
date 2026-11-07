"""The Claude client the collector's steps share, and the record of what
every call cost."""

from __future__ import annotations

import json
import os
import subprocess
import sys

import anthropic

import db

MODEL = "claude-opus-5-5"

# Dollars per million tokens: input, output, cache read, cache write.
# A refused request can be finished by a fallback model, so its row counts too.
PRICES = {
    "claude-opus-5-5": (4.00, 20.00, 0.20, 5.00),
    "claude-opus-5": (5.00, 25.00, 0.50, 6.25),
    "claude-sonnet-5-5": (2.00, 10.00, 0.20, 2.50),
    "claude-haiku-5-5": (0.10, 0.50, 0.01, 0.125),
}


def client() -> anthropic.Anthropic:
    """A client using ANTHROPIC_API_KEY, or the Keychain (service "anthropic"):
        security add-generic-password -s anthropic -a api -w
    """
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        try:
            key = subprocess.run(
                ["security", "find-generic-password", "-s", "anthropic", "-w"],
                capture_output=True, text=True, check=True,
            ).stdout.strip()
        except subprocess.CalledProcessError:
            sys.exit("No API key. Set ANTHROPIC_API_KEY, or add it with:\n"
                     "  security add-generic-password -s anthropic -a api -w")
    return anthropic.Anthropic(api_key=key)


def record(response, purpose: str, effort: str) -> float | None:
    """Write a call's tokens and cost to `claude_calls`; returns the cost."""
    usage = response.usage
    tokens = (usage.input_tokens or 0, usage.output_tokens or 0,
              getattr(usage, "cache_read_input_tokens", 0) or 0,
              getattr(usage, "cache_creation_input_tokens", 0) or 0)
    price = PRICES.get(response.model)
    cost = (sum(t * p for t, p in zip(tokens, price)) / 1_000_000) if price else None
    conn = db.connect()
    with conn:
        conn.execute(
            "INSERT INTO claude_calls (at, purpose, model, effort, input_tokens, output_tokens, "
            "cache_read_tokens, cache_write_tokens, cost_usd, request_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (db.now(), purpose, response.model, effort, *tokens, cost,
             getattr(response, "_request_id", None)))
    return cost


def ask_json(api: anthropic.Anthropic, *, purpose: str, system: str, content: list[dict],
             schema: dict, effort: str = "high"):
    """One request whose answer is JSON matching schema, recorded under
    `purpose` (identify, story, cards, digest).

    Returns (answer, response), or (None, response) if Claude declined.
    """
    response = api.beta.messages.create(
        model=MODEL,
        max_tokens=16000,
        system=system,
        output_config={"effort": effort,
                       "format": {"type": "json_schema", "schema": schema}},
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
        messages=[{"role": "user", "content": content}],
    )
    record(response, purpose, effort)
    if response.stop_reason == "refusal":
        return None, response
    text = next(b.text for b in response.content if b.type == "text")
    return json.loads(text), response
