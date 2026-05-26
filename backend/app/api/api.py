from fastapi import APIRouter, Depends
from api.endpoints import transcribe

api_router = APIRouter()
api_router.include_router(transcribe.router, prefix="/transcribe", tags=["transcribe"])
