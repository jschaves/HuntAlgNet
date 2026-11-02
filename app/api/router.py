from fastapi import APIRouter

from app.api.routes import auth, channels, health, i18n, integrations, orgs

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(i18n.router)
api_router.include_router(auth.router)
api_router.include_router(orgs.router)
api_router.include_router(channels.router)
api_router.include_router(integrations.router)
