from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from app import __version__
from app.api.router import api_router
from app.core.config import settings
from app.core.i18n import is_rtl, negotiate_locale


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        debug=settings.debug,
        docs_url="/docs" if settings.enable_docs else None,
        redoc_url="/redoc" if settings.enable_docs else None,
        openapi_url="/openapi.json" if settings.enable_docs else None,
    )

    if settings.trusted_host_list:
        app.add_middleware(
            TrustedHostMiddleware,
            allowed_hosts=settings.trusted_host_list,
        )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origin_list,
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def locale_headers(request: Request, call_next):
        locale = negotiate_locale(request.headers.get("accept-language"))
        request.state.locale = locale
        response = await call_next(request)
        response.headers["Content-Language"] = locale
        if is_rtl(locale):
            response.headers["Content-Language-Dir"] = "rtl"
        vary = response.headers.get("Vary")
        if vary:
            if "accept-language" not in vary.lower():
                response.headers["Vary"] = f"{vary}, Accept-Language"
        else:
            response.headers["Vary"] = "Accept-Language"
        return response

    app.include_router(api_router, prefix=settings.api_prefix)
    return app


app = create_app()
