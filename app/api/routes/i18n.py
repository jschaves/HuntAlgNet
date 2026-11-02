from __future__ import annotations

from fastapi import APIRouter, HTTPException, Request, status

from app.core.i18n import (
    DEFAULT_LOCALE,
    is_rtl,
    load_catalog,
    locale_info,
    negotiate_locale,
    normalize_locale,
    supported_locales,
    translate,
)
from app.schemas import LocaleCatalogOut, LocaleOut, LocaleResolveOut

router = APIRouter(prefix="/i18n", tags=["i18n"])


@router.get("/locales", response_model=list[LocaleOut])
def list_locales() -> list[dict[str, str]]:
    return supported_locales()


@router.get("/resolve", response_model=LocaleResolveOut)
def resolve_locale(request: Request) -> LocaleResolveOut:
    locale = negotiate_locale(request.headers.get("accept-language"))
    return LocaleResolveOut(locale=locale, direction="rtl" if is_rtl(locale) else "ltr")


@router.get("/{locale}", response_model=LocaleCatalogOut)
def get_catalog(locale: str) -> LocaleCatalogOut:
    code = normalize_locale(locale)
    if code is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=translate("errors.language_not_supported", DEFAULT_LOCALE),
        )
    info = locale_info(code)
    return LocaleCatalogOut(locale=code, direction=info["direction"], messages=load_catalog(code))
