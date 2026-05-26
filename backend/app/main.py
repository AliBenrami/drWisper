from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from api import api

app = FastAPI(title="drwisper API", description="API for drwisper platform")

# CORS middleware for demo app
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:5173",
        "http://127.0.0.1:3000",
    ],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api.api_router, prefix="/api", tags=["api"])

@app.get("/")
def health_check() -> dict[str, str]:
    return {"status": "ok", "message": "drwisper API is running"}

