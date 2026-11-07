"""The weather at the feeder, from Open-Meteo (no key needed).

`now()` is for the masthead: the weather this minute and the sun's times
today and tomorrow. `week()` is for the story: each of the last seven
days, so Claude can notice a busy morning before the rain, if it matters.
Times are local to the feeder, without a time zone, as Open-Meteo gives
them.
"""

from __future__ import annotations

import json
import urllib.request

import config
from datetime import date, datetime

HOME = config.HOME
WORDS = {0: "clear", 1: "mostly clear", 2: "partly cloudy", 3: "cloudy",
         45: "fog", 48: "fog", 51: "drizzle", 53: "drizzle", 55: "drizzle",
         61: "light rain", 63: "rain", 65: "heavy rain", 71: "light snow",
         73: "snow", 75: "heavy snow", 80: "showers", 81: "showers",
         82: "heavy showers", 95: "thunderstorms"}
API = "https://api.open-meteo.com/v1/forecast?temperature_unit=fahrenheit&timezone=auto"


def fetch(query: str) -> dict:
    try:
        with urllib.request.urlopen(f"{API}&{query}", timeout=5) as response:
            return json.load(response)
    except (OSError, ValueError):
        return {}


def now(lat: float, lon: float) -> dict:
    """{"words": "52°, cloudy", "sunrise": [today, tomorrow], "sunset": [...]}."""
    data = fetch(f"latitude={lat}&longitude={lon}&current=temperature_2m,weather_code"
                 "&daily=sunrise,sunset&forecast_days=2")
    if not data:
        return {}
    current = data.get("current", {})
    return {"words": f"{round(current['temperature_2m'])}°, "
                     f"{WORDS.get(current.get('weather_code'), '')}".rstrip(", "),
            "sunrise": [datetime.fromisoformat(t) for t in data["daily"]["sunrise"]],
            "sunset": [datetime.fromisoformat(t) for t in data["daily"]["sunset"]]}


def week(lat: float, lon: float) -> list[tuple[date, str]]:
    """Each of the last seven days and today, as (day, "light rain, 48–55°,
    4 mm of rain")."""
    data = fetch(f"latitude={lat}&longitude={lon}&past_days=7&forecast_days=1"
                 "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum"
                 "&precipitation_unit=mm")
    daily = data.get("daily")
    if not daily:
        return []
    out = []
    for i, day in enumerate(daily["time"]):
        rain = daily["precipitation_sum"][i] or 0
        out.append((date.fromisoformat(day),
                    f"{WORDS.get(daily['weather_code'][i], 'mixed')}, "
                    f"{round(daily['temperature_2m_min'][i])}–{round(daily['temperature_2m_max'][i])}°"
                    + (f", {rain:g} mm of rain" if rain >= 0.5 else "")))
    return out


def ahead(lat: float, lon: float) -> list[dict]:
    """Today and tomorrow: {"day", "words", "low", "high", "rain_mm", and
    "rain_from", the first hour rain is more likely than not, or None}."""
    data = fetch(f"latitude={lat}&longitude={lon}&forecast_days=2"
                 "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum"
                 "&hourly=precipitation_probability&precipitation_unit=mm")
    daily, hourly = data.get("daily"), data.get("hourly")
    if not daily:
        return []
    wet = [datetime.fromisoformat(t) for t, p in zip(hourly["time"], hourly["precipitation_probability"])
           if (p or 0) >= 50] if hourly else []
    out = []
    for i, day in enumerate(daily["time"]):
        d = date.fromisoformat(day)
        out.append({"day": d, "words": WORDS.get(daily["weather_code"][i], "mixed"),
                    "low": round(daily["temperature_2m_min"][i]),
                    "high": round(daily["temperature_2m_max"][i]),
                    "rain_mm": daily["precipitation_sum"][i] or 0,
                    "rain_from": next((t for t in wet if t.date() == d), None)})
    return out
