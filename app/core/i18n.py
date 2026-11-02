from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

DEFAULT_LOCALE = "en-US"

SUPPORTED_LOCALES: tuple[str, ...] = (
    "en-US",
    "es-ES",
    "fr-FR",
    "it-IT",
    "de-DE",
    "zh-CN",
    "ja-JP",
    "pt-PT",
    "ar-SA",
    "ru-RU",
)

RTL_LOCALES = frozenset({"ar-SA"})

LOCALES_DIR = Path(__file__).resolve().parent.parent / "locales"

LOCALE_METADATA: dict[str, dict[str, str]] = {
    "en-US": {"code": "en-US", "name": "English (United States)", "native_name": "English", "direction": "ltr"},
    "es-ES": {"code": "es-ES", "name": "Spanish (Spain)", "native_name": "Español", "direction": "ltr"},
    "fr-FR": {"code": "fr-FR", "name": "French (France)", "native_name": "Français", "direction": "ltr"},
    "it-IT": {"code": "it-IT", "name": "Italian (Italy)", "native_name": "Italiano", "direction": "ltr"},
    "de-DE": {"code": "de-DE", "name": "German (Germany)", "native_name": "Deutsch", "direction": "ltr"},
    "zh-CN": {"code": "zh-CN", "name": "Chinese (Simplified)", "native_name": "中文", "direction": "ltr"},
    "ja-JP": {"code": "ja-JP", "name": "Japanese (Japan)", "native_name": "日本語", "direction": "ltr"},
    "pt-PT": {"code": "pt-PT", "name": "Portuguese (Portugal)", "native_name": "Português", "direction": "ltr"},
    "ar-SA": {"code": "ar-SA", "name": "Arabic (Saudi Arabia)", "native_name": "العربية", "direction": "rtl"},
    "ru-RU": {"code": "ru-RU", "name": "Russian (Russia)", "native_name": "Русский", "direction": "ltr"},
}

_PRIMARY_ALIASES = {
    "en": "en-US",
    "es": "es-ES",
    "fr": "fr-FR",
    "it": "it-IT",
    "de": "de-DE",
    "zh": "zh-CN",
    "ja": "ja-JP",
    "pt": "pt-PT",
    "ar": "ar-SA",
    "ru": "ru-RU",
}


def _candidate_key(value: str) -> str:
    return value.strip().replace("_", "-").lower()


def normalize_locale(value: str | None) -> str | None:
    if not value:
        return None

    for supported in SUPPORTED_LOCALES:
        if supported.lower() == _candidate_key(value):
            return supported

    primary = _candidate_key(value).split("-")[0]
    return _PRIMARY_ALIASES.get(primary)


def _parse_accept_language(header: str | None) -> list[str]:
    if not header:
        return []

    weighted: list[tuple[float, int, str]] = []
    for index, chunk in enumerate(header.split(",")):
        parts = [part.strip() for part in chunk.split(";") if part.strip()]
        if not parts:
            continue
        quality = 1.0
        for part in parts[1:]:
            if part.lower().startswith("q="):
                try:
                    quality = float(part[2:])
                except ValueError:
                    quality = 0.0
        weighted.append((quality, -index, parts[0]))

    weighted.sort(reverse=True)
    return [token for quality, _, token in weighted if token != "*" and quality > 0]


def negotiate_locale(header: str | None) -> str:
    for token in _parse_accept_language(header):
        locale = normalize_locale(token)
        if locale:
            return locale
    return DEFAULT_LOCALE


def is_rtl(locale: str | None) -> bool:
    return normalize_locale(locale) in RTL_LOCALES


def locale_info(locale: str) -> dict[str, str]:
    code = normalize_locale(locale) or DEFAULT_LOCALE
    return dict(LOCALE_METADATA[code])


def supported_locales() -> list[dict[str, str]]:
    return [dict(LOCALE_METADATA[code]) for code in SUPPORTED_LOCALES]


@lru_cache(maxsize=None)
def _load_file(locale: str) -> dict[str, str]:
    path = LOCALES_DIR / f"{locale}.json"
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"Locale catalog {path} must be an object")
    return {str(key): str(value) for key, value in data.items()}


@lru_cache(maxsize=None)
def load_catalog(locale: str) -> dict[str, str]:
    code = normalize_locale(locale) or DEFAULT_LOCALE
    catalog = dict(_load_file(DEFAULT_LOCALE))
    if code != DEFAULT_LOCALE:
        catalog.update(_load_file(code))
    return catalog


def catalog_issues() -> list[str]:
    issues: list[str] = []
    base_keys = set(_load_file(DEFAULT_LOCALE))
    for code in SUPPORTED_LOCALES:
        try:
            data = _load_file(code)
        except FileNotFoundError:
            issues.append(f"{code}: missing catalog")
            continue
        missing = sorted(base_keys - set(data))
        extra = sorted(set(data) - base_keys)
        empty = sorted(
            key
            for key, value in data.items()
            if not isinstance(value, str) or not value.strip()
        )
        if missing:
            issues.append(f"{code}: missing keys: {', '.join(missing)}")
        if extra:
            issues.append(f"{code}: extra keys: {', '.join(extra)}")
        if empty:
            issues.append(f"{code}: empty values: {', '.join(empty)}")
    return issues


def translate(key: str, locale: str | None = None, **params: Any) -> str:
    code = normalize_locale(locale) or DEFAULT_LOCALE
    text = load_catalog(code).get(key)
    if text is None:
        text = load_catalog(DEFAULT_LOCALE).get(key, key)
    if params:
        try:
            return text.format(**params)
        except (KeyError, IndexError):
            return text
    return text
