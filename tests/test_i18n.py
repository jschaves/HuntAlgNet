from __future__ import annotations

import json

from fastapi.testclient import TestClient

from app.core.i18n import (
    DEFAULT_LOCALE,
    LOCALES_DIR,
    SUPPORTED_LOCALES,
    catalog_issues,
    negotiate_locale,
    normalize_locale,
)
from app.main import app


def test_supported_locales() -> None:
    assert DEFAULT_LOCALE == "en-US"
    assert len(SUPPORTED_LOCALES) == 10
    assert set(SUPPORTED_LOCALES) == {
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
    }


def test_locale_negotiation() -> None:
    assert negotiate_locale("es-MX,es;q=0.9,en;q=0.8") == "es-ES"
    assert negotiate_locale("fr-CA") == "fr-FR"
    assert negotiate_locale("de-AT") == "de-DE"
    assert negotiate_locale("it-CH") == "it-IT"
    assert negotiate_locale("zh-TW") == "zh-CN"
    assert negotiate_locale("ja") == "ja-JP"
    assert negotiate_locale("pt-BR") == "pt-PT"
    assert negotiate_locale("ar-EG") == "ar-SA"
    assert negotiate_locale("ru") == "ru-RU"
    assert negotiate_locale("en-GB") == "en-US"
    assert negotiate_locale("xx-YY") == DEFAULT_LOCALE
    assert negotiate_locale(None) == DEFAULT_LOCALE
    assert negotiate_locale("") == DEFAULT_LOCALE
    assert normalize_locale("ES_es") == "es-ES"


def test_all_catalogs_have_same_keys() -> None:
    base = json.loads((LOCALES_DIR / "en-US.json").read_text(encoding="utf-8"))
    assert base
    for locale in SUPPORTED_LOCALES:
        data = json.loads((LOCALES_DIR / f"{locale}.json").read_text(encoding="utf-8"))
        assert set(data) == set(base), f"Catalog {locale} has different keys"
        assert all(isinstance(value, str) and value.strip() for value in data.values()), locale


def test_catalog_validation_helper() -> None:
    assert catalog_issues() == []


def test_i18n_endpoints() -> None:
    with TestClient(app) as client:
        response = client.get("/api/v1/i18n/locales")
        assert response.status_code == 200
        assert len(response.json()) == 10
        assert response.headers["content-language"] == "en-US"

        response = client.get(
            "/api/v1/i18n/resolve",
            headers={"Accept-Language": "es-MX,es;q=0.9"},
        )
        assert response.status_code == 200
        assert response.json() == {"locale": "es-ES", "direction": "ltr"}

        response = client.get(
            "/api/v1/i18n/resolve",
            headers={"Accept-Language": "ar-SA"},
        )
        assert response.json() == {"locale": "ar-SA", "direction": "rtl"}
        assert response.headers["content-language-dir"] == "rtl"

        response = client.get("/api/v1/i18n/ar-SA")
        assert response.status_code == 200
        payload = response.json()
        assert payload["direction"] == "rtl"
        assert payload["messages"]["common.language"] == "اللغة"

        response = client.get("/api/v1/i18n/xx")
        assert response.status_code == 404
